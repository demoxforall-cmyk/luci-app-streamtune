#!/bin/sh
# streamtune — применение/откат по активному профилю (lte_audio | home_wired).
# SPDX-License-Identifier: GPL-2.0
#
# Печатает JSON {"ok":bool,"action":...,"applied":[...],"errors":[...]}.
# ST_NO_APPLY=1 — тест-режим: генерируются файлы (drop-in, nft-MSS), системные
# команды пропускаются.
set -u
ST_SHARE="${ST_SHARE:-/usr/share/streamtune}"
. "$ST_SHARE/lib.sh"
ST_NO_APPLY="${ST_NO_APPLY:-0}"

ACTION="${1:-apply}"
APPLIED=""; ERRORS=""
js() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
add_applied() { APPLIED="$APPLIED${APPLIED:+,}\"$(js "$1")\""; }
add_error()   { ERRORS="$ERRORS${ERRORS:+,}\"$(js "$1")\""; }
sys() { [ "$ST_NO_APPLY" = "1" ] && return 0; "$@" >/dev/null 2>&1; }

# --- sysctl drop-in по активному профилю ---
generate_dropin() {
	mkdir -p "$ST_SYSCTL_D" 2>/dev/null
	tmp="$ST_DROPIN.tmp.$$"
	{
		echo "# Managed by luci-app-streamtune (profile: $(st_profile)). Do not edit."
		while IFS='|' read -r cat key typ target lte home; do
			[ "$typ" = "sysctl" ] || continue
			st_param_desired "$cat" "$key" || continue
			# tcp_congestion_control пишем только если BBR доступен; fq_codel и
			# прочее — независимо (исправление: пропуск ПО КЛЮЧУ, не по категории)
			if [ "$key" = "net.ipv4.tcp_congestion_control" ] && [ "$(st_cap_bbr)" != "1" ]; then
				continue
			fi
			rec=$(st_recommended "$key" "$lte" "$home")
			[ "$rec" = "@default" ] && continue
			echo "$target = $rec"
		done <<EOF
$(st_registry)
EOF
	} > "$tmp"
	mv "$tmp" "$ST_DROPIN"
}

apply_mtu() {
	st_cat_enabled mobile_lte || return 0
	mtu=$(st_recommended link.mtu auto auto)
	[ "$mtu" = "@default" ] && return 0
	[ "$ST_NO_APPLY" = "1" ] && return 0
	w=$(st_wan_iface); [ -n "$w" ] || { add_error "mtu: WAN iface not found"; return 0; }
	if [ "$mtu" = "auto" ]; then
		resolved=$(sh "$ST_SHARE/mtu_probe.sh" 2>/dev/null | sed -n 's/.*"mtu":\([0-9][0-9]*\).*/\1/p')
		cm=$(st_modem_mtu)
		if [ -n "$cm" ] && [ -n "$resolved" ] && [ "$cm" -lt "$resolved" ] 2>/dev/null; then resolved="$cm"; fi
		[ -z "$resolved" ] && [ -n "$cm" ] && resolved="$cm"
		mtu="$resolved"
	fi
	[ -n "$mtu" ] || { add_error "mtu: probe failed (install iputils-tracepath)"; return 0; }
	uci set "network.$w.mtu=$mtu" >/dev/null 2>&1
	uci commit network >/dev/null 2>&1
	uci set "streamtune.global.mtu_resolved=$mtu" >/dev/null 2>&1
	uci commit streamtune >/dev/null 2>&1
	/etc/init.d/network reload >/dev/null 2>&1
}

apply_mss() {
	st_cat_enabled mobile_lte || return 0
	nd=$(st_wan_netdev)
	[ -n "$nd" ] || { [ "$ST_NO_APPLY" = "1" ] || add_error "mss: WAN netdev not found"; nd="wan"; }
	mkdir -p "$(dirname "$ST_NFT_MSS")" 2>/dev/null
	cat > "$ST_NFT_MSS" <<EOF
# Managed by luci-app-streamtune — MSS clamp to path MTU (pbr-safe, both dirs).
chain streamtune_mss {
    type filter hook forward priority mangle; policy accept;
    oifname "$nd" tcp flags syn / fin,syn,rst tcp option maxseg size set rt mtu
    iifname "$nd" tcp flags syn / fin,syn,rst tcp option maxseg size set rt mtu
}
EOF
	if [ "$ST_NO_APPLY" != "1" ]; then
		if command -v fw4 >/dev/null 2>&1; then fw4 reload >/dev/null 2>&1
		else /etc/init.d/firewall reload >/dev/null 2>&1; fi
	fi
}

apply_disable_ipv6() {
	st_cat_enabled disable_ipv6 || return 0
	# sysctl-часть уже в drop-in; здесь — выдача клиентам + WAN + ULA + odhcpd
	[ "$ST_NO_APPLY" = "1" ] && return 0
	for w in $(st_eth_wan_iface) $(st_uci_cellular_iface); do
		[ -n "$w" ] && uci -q set "network.$w.ipv6=0"
	done
	for s in $(uci -q show dhcp 2>/dev/null | sed -n 's/^dhcp\.\([^.=]*\)=dhcp$/\1/p'); do
		uci -q set "dhcp.$s.dhcpv6=disabled"
		uci -q set "dhcp.$s.ra=disabled"
		uci -q set "dhcp.$s.ndp=disabled"
	done
	uci -q delete network.globals.ula_prefix 2>/dev/null
	uci commit network; uci commit dhcp
	/etc/init.d/odhcpd disable >/dev/null 2>&1
	/etc/init.d/odhcpd stop >/dev/null 2>&1
	/etc/init.d/network reload >/dev/null 2>&1
	sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1
	sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1
}

do_apply() {
	generate_dropin
	sys sysctl -p "$ST_DROPIN"

	for c in net_buffers low_latency backlog; do
		st_cat_enabled "$c" && add_applied "$c"
	done

	if st_cat_enabled congestion; then
		add_applied congestion   # fq_codel применяется всегда
		[ "$(st_cap_bbr)" = "1" ] || add_error "congestion: kmod-tcp-bbr not installed (fq_codel applied, bbr skipped)"
	fi

	if st_cat_enabled flow_offload; then
		hw=0; [ "$(st_cfg flow_offload_hw 0)" = "1" ] && hw=1
		sys uci set firewall.@defaults[0].flow_offloading=1
		sys uci set firewall.@defaults[0].flow_offloading_hw="$hw"
		sys uci commit firewall
		add_applied flow_offload
	else
		sys uci set firewall.@defaults[0].flow_offloading=0
		sys uci set firewall.@defaults[0].flow_offloading_hw=0
		sys uci commit firewall
	fi

	if st_cat_enabled conntrack; then
		hs=$(st_hashsize)
		[ "$ST_NO_APPLY" != "1" ] && [ -w "$ST_SYSFS_HASHSIZE" ] && echo "$hs" > "$ST_SYSFS_HASHSIZE" 2>/dev/null
		add_applied conntrack
	fi

	if st_cat_enabled irqbalance; then
		if [ "$(st_cap_irqbalance)" = "1" ]; then
			sys /etc/init.d/irqbalance enable; sys /etc/init.d/irqbalance start; add_applied irqbalance
		else add_error "irqbalance: package not installed"; fi
	fi

	# mobile LTE link: conntrack-timeout (в drop-in) + MTU(auto) + MSS(nft)
	if st_cat_enabled mobile_lte; then
		apply_mss
		apply_mtu
		add_applied mobile_lte
	fi

	# полное отключение IPv6 (стек в drop-in + клиенты/WAN/ULA/odhcpd)
	st_cat_enabled disable_ipv6 && { apply_disable_ipv6; add_applied disable_ipv6; }

	# firewall перезагрузка под flow_offload/mtu_fix (один раз)
	if [ "$ST_NO_APPLY" != "1" ]; then
		if command -v fw4 >/dev/null 2>&1; then fw4 reload >/dev/null 2>&1
		else /etc/init.d/firewall reload >/dev/null 2>&1; fi
	fi
}

do_revert() {
	rm -f "$ST_DROPIN" "$ST_NFT_MSS" 2>/dev/null
	if [ "$ST_NO_APPLY" != "1" ]; then
		sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1
		sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1
		sysctl --system >/dev/null 2>&1
		# вернуть выдачу IPv6 клиентам (дефолт OpenWRT для lan)
		uci -q set dhcp.lan.dhcpv6='server'; uci -q set dhcp.lan.ra='server'
		uci -q delete dhcp.lan.ndp 2>/dev/null
		uci -q delete network.lan.delegate 2>/dev/null
		for w in $(st_eth_wan_iface) $(st_uci_cellular_iface); do
			[ -n "$w" ] && uci -q delete "network.$w.ipv6" 2>/dev/null
		done
		uci commit dhcp; uci commit network
		/etc/init.d/odhcpd enable >/dev/null 2>&1; /etc/init.d/odhcpd start >/dev/null 2>&1
		# firewall offload off
		uci set firewall.@defaults[0].flow_offloading=0 >/dev/null 2>&1
		uci set firewall.@defaults[0].flow_offloading_hw=0 >/dev/null 2>&1
		uci commit firewall
		/etc/init.d/irqbalance stop >/dev/null 2>&1; /etc/init.d/irqbalance disable >/dev/null 2>&1
		# обнулить тумблеры; профиль остаётся выбранным, но всё выключено
		for c in net_buffers low_latency backlog congestion flow_offload flow_offload_hw \
		         conntrack irqbalance disable_ipv6 mobile_lte; do
			uci set "streamtune.global.$c=0" >/dev/null 2>&1
		done
		uci -q delete streamtune.global.mtu_resolved 2>/dev/null
		uci commit streamtune
		if command -v fw4 >/dev/null 2>&1; then fw4 reload >/dev/null 2>&1
		else /etc/init.d/firewall reload >/dev/null 2>&1; fi
		/etc/init.d/network reload >/dev/null 2>&1
	fi
	add_applied revert
}

case "$ACTION" in
	revert) do_revert ;;
	*)      do_apply ;;
esac
printf '{"ok":true,"action":"%s","applied":[%s],"errors":[%s]}\n' "$ACTION" "$APPLIED" "$ERRORS"
