#!/bin/sh
# streamtune — применение/откат оптимизаций на основе UCI streamtune.global.
# SPDX-License-Identifier: GPL-2.0
#
#   apply  — сгенерировать /etc/sysctl.d/99-streamtune.conf по активному профилю
#            и применить sysctl + firewall + conntrack + irqbalance + ipv6 +
#            (профиль lte_audio) MTU/MSS-clamp. Идемпотентно.
#   revert — удалить drop-in, откатить firewall/ipv6/irqbalance, профиль->generic.
#
# Печатает JSON: {"ok":bool,"action":...,"applied":[...],"errors":[...]}.
# В тест-режиме ST_NO_APPLY=1 системные команды пропускаются (drop-in всё равно
# генерируется — это и проверяют юнит-тесты).
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

# --- генерация sysctl drop-in по активному профилю ---
generate_dropin() {
	mkdir -p "$ST_SYSCTL_D" 2>/dev/null
	tmp="$ST_DROPIN.tmp.$$"
	{
		echo "# Managed by luci-app-streamtune (profile: $(st_profile)). Do not edit by hand."
		echo "# Regenerated on each apply from /etc/config/streamtune."
		while IFS='|' read -r cat key typ target gval lval; do
			[ "$typ" = "sysctl" ] || continue
			st_param_desired "$cat" "$key" || continue
			# управление перегрузкой пишем только если BBR реально доступен
			if [ "$cat" = "congestion" ] && [ "$(st_cap_bbr)" != "1" ]; then
				continue
			fi
			rec=$(st_recommended "$key" "$gval" "$lval")
			[ "$rec" = "@default" ] && continue   # профиль оставляет дефолт ядра
			echo "$target = $rec"
		done <<EOF
$(st_registry)
EOF
	} > "$tmp"
	mv "$tmp" "$ST_DROPIN"
}

do_apply() {
	generate_dropin
	sys sysctl -p "$ST_DROPIN"

	for c in net_buffers low_latency backlog disable_ipv6; do
		st_cat_enabled "$c" && add_applied "$c"
	done

	if st_cat_enabled congestion; then
		if [ "$(st_cap_bbr)" = "1" ]; then add_applied congestion
		else add_error "congestion: kmod-tcp-bbr not installed"; fi
	fi

	# flow offload через firewall
	if st_cat_enabled flow_offload; then
		hw=0; [ "$(st_cfg flow_offload_hw 0)" = "1" ] && hw=1
		sys uci set firewall.@defaults[0].flow_offloading=1
		sys uci set firewall.@defaults[0].flow_offloading_hw="$hw"
		sys uci commit firewall
		if [ "$ST_NO_APPLY" != "1" ]; then
			if command -v fw4 >/dev/null 2>&1; then fw4 reload >/dev/null 2>&1
			else /etc/init.d/firewall reload >/dev/null 2>&1; fi
		fi
		add_applied flow_offload
	else
		sys uci set firewall.@defaults[0].flow_offloading=0
		sys uci set firewall.@defaults[0].flow_offloading_hw=0
		sys uci commit firewall
	fi

	# conntrack hashsize
	if st_cat_enabled conntrack; then
		hs=$(st_hashsize)
		if [ "$ST_NO_APPLY" != "1" ] && [ -w "$ST_SYSFS_HASHSIZE" ]; then
			echo "$hs" > "$ST_SYSFS_HASHSIZE" 2>/dev/null
		fi
		add_applied conntrack
	fi

	# irqbalance
	if st_cat_enabled irqbalance; then
		if [ "$(st_cap_irqbalance)" = "1" ]; then
			sys /etc/init.d/irqbalance enable
			sys /etc/init.d/irqbalance start
			add_applied irqbalance
		else
			add_error "irqbalance: package not installed"
		fi
	fi

	# mobile LTE link: MTU + MSS-clamp (conntrack-timeout уже в drop-in как sysctl)
	if st_cat_enabled mobile_lte; then
		mtu=$(st_recommended link.mtu "@default" 1430)
		if [ "$mtu" != "@default" ]; then
			w=$(st_wan_iface)
			if [ -n "$w" ]; then
				sys uci set "network.$w.mtu=$mtu"
				sys uci commit network
				z=$(st_wan_zone)
				[ -n "$z" ] && { sys uci set "firewall.@zone[$z].mtu_fix=1"; sys uci commit firewall; }
				if [ "$ST_NO_APPLY" != "1" ]; then
					/etc/init.d/network reload >/dev/null 2>&1
					if command -v fw4 >/dev/null 2>&1; then fw4 reload >/dev/null 2>&1
					else /etc/init.d/firewall reload >/dev/null 2>&1; fi
				fi
				add_applied mobile_lte
			else
				add_error "mobile_lte: WAN interface not found (set streamtune.global.wan_iface)"
			fi
		fi
	fi

	# немедленно применить отключение IPv6 в runtime (drop-in покрывает persist)
	if st_cat_enabled disable_ipv6 && [ "$ST_NO_APPLY" != "1" ]; then
		sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1
		sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1
	fi
}

do_revert() {
	rm -f "$ST_DROPIN" 2>/dev/null
	if [ "$ST_NO_APPLY" != "1" ]; then
		sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1
		sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1
		sysctl --system >/dev/null 2>&1
	fi
	sys uci set firewall.@defaults[0].flow_offloading=0
	sys uci set firewall.@defaults[0].flow_offloading_hw=0
	sys uci commit firewall
	if [ "$ST_NO_APPLY" != "1" ]; then
		if command -v fw4 >/dev/null 2>&1; then fw4 reload >/dev/null 2>&1
		else /etc/init.d/firewall reload >/dev/null 2>&1; fi
	fi
	sys /etc/init.d/irqbalance stop
	sys /etc/init.d/irqbalance disable
	# Примечание: MTU/MSS на WAN при revert НЕ трогаем (исходное значение неизвестно).
	if [ "$ST_NO_APPLY" != "1" ]; then
		for c in net_buffers low_latency backlog congestion flow_offload flow_offload_hw \
		         conntrack irqbalance disable_ipv6 mobile_lte; do
			uci set "streamtune.global.$c=0" >/dev/null 2>&1
		done
		uci set "streamtune.global.profile=generic" >/dev/null 2>&1
		uci commit streamtune >/dev/null 2>&1
	fi
	add_applied revert
}

case "$ACTION" in
	revert) do_revert ;;
	*)      do_apply ;;
esac

printf '{"ok":true,"action":"%s","applied":[%s],"errors":[%s]}\n' \
	"$ACTION" "$APPLIED" "$ERRORS"
