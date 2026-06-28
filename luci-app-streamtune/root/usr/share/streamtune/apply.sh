#!/bin/sh
# streamtune — применение/откат по активному профилю (lte_audio | home_wired).
# SPDX-License-Identifier: GPL-2.0
#
# Модель per-param: применяются только ВКЛЮЧЁННЫЕ параметры (st_param_enabled).
# Перед изменением исходное значение фиксируется в state-файле (st_state_add) —
# это отличает статус Applied от Matches и позволяет точный откат.
# Печатает JSON {"ok":bool,"action":...,"applied":[...],"errors":[...]}.
# ST_NO_APPLY=1 — тест-режим: файлы (drop-in, nft, state) пишутся, системные
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

TAB=$(printf '\t')

# Рекомендованное значение конкретного ключа по реестру (с учётом профиля).
st_reg_rec() {
	while IFS='|' read -r _c _k _t _tg _l _h; do
		[ "$_k" = "$1" ] || continue
		st_recommended "$_k" "$_l" "$_h"; return
	done <<EOF
$(st_registry)
EOF
}

# Пропуск bbr, если модуль недоступен (fq_codel и прочее — независимо).
skip_bbr() { [ "$1" = "net.ipv4.tcp_congestion_control" ] && [ "$(st_cap_bbr)" != "1" ]; }

# Список включённых sysctl-ключей (без недоступного bbr).
enabled_sysctl_keys() {
	while IFS='|' read -r cat key typ target lte home; do
		[ "$typ" = "sysctl" ] || continue
		st_param_enabled "$key" || continue
		skip_bbr "$key" && continue
		echo "$key"
	done <<EOF
$(st_registry)
EOF
}

# Зафиксировать исходные значения изменяемых sysctl (cur != rec) ДО применения.
record_sysctl_originals() {
	while IFS='|' read -r cat key typ target lte home; do
		[ "$typ" = "sysctl" ] || continue
		st_param_enabled "$key" || continue
		skip_bbr "$key" && continue
		rec=$(st_recommended "$key" "$lte" "$home")
		cur=$(st_read_current sysctl "$target")
		[ -n "$cur" ] && [ "$(st_norm "$cur")" != "$(st_norm "$rec")" ] && st_state_add "$key" "$cur"
	done <<EOF
$(st_registry)
EOF
}

# --- sysctl drop-in по активному профилю (только включённые параметры) ---
generate_dropin() {
	mkdir -p "$ST_SYSCTL_D" 2>/dev/null
	tmp="$ST_DROPIN.tmp.$$"
	{
		echo "# Managed by luci-app-streamtune (profile: $(st_profile)). Do not edit."
		while IFS='|' read -r cat key typ target lte home; do
			[ "$typ" = "sysctl" ] || continue
			st_param_enabled "$key" || continue
			skip_bbr "$key" && continue
			rec=$(st_recommended "$key" "$lte" "$home")
			echo "$target = $rec"
		done <<EOF
$(st_registry)
EOF
	} > "$tmp"
	mv "$tmp" "$ST_DROPIN"
}

# firewall-параметр (@defaults[0]): пишем рекомендованное (для offload = 0).
apply_fw_param() {  # <key>
	st_param_enabled "$1" || return 0
	opt=${1#firewall.}
	rec=$(st_reg_rec "$1"); cur=$(st_read_current firewall "$opt")
	[ "$(st_norm "$cur")" != "$(st_norm "$rec")" ] && st_state_add "$1" "$cur"
	sys uci set "firewall.@defaults[0].$opt=$rec"
	sys uci commit firewall
	add_applied "$1"
}

apply_mtu() {
	mtu=$(st_recommended link.mtu auto auto)
	w=$(st_wan_iface); [ -n "$w" ] || { add_error "mtu: WAN iface not found"; return 0; }
	if [ "$mtu" = "auto" ]; then
		[ "$ST_NO_APPLY" = "1" ] && return 0
		resolved=$(sh "$ST_SHARE/mtu_probe.sh" 2>/dev/null | sed -n 's/.*"mtu":\([0-9][0-9]*\).*/\1/p')
		[ -n "$resolved" ] && mtu="$resolved"
	fi
	case "$mtu" in ''|*[!0-9]*) add_error "mtu: probe failed (install iputils-ping)"; return 0 ;; esac
	cur=$(st_read_current mtu @wan)
	[ -n "$cur" ] && [ "$(st_norm "$cur")" != "$(st_norm "$mtu")" ] && st_state_add link.mtu "$cur"
	[ "$ST_NO_APPLY" = "1" ] && { uci_set_mtu_resolved "$mtu"; return 0; }
	uci set "network.$w.mtu=$mtu" >/dev/null 2>&1
	uci commit network >/dev/null 2>&1
	uci_set_mtu_resolved "$mtu"
	/etc/init.d/network reload >/dev/null 2>&1
}
uci_set_mtu_resolved() {
	[ "$ST_NO_APPLY" = "1" ] && return 0
	uci set "streamtune.global.mtu_resolved=$1" >/dev/null 2>&1
	uci commit streamtune >/dev/null 2>&1
}

apply_mss() {
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
	# ULA-префикс: сохраняем оригинал (для отката) перед удалением
	ula=$(uci -q get network.globals.ula_prefix 2>/dev/null)
	[ -n "$ula" ] && st_state_add "network.globals.ula_prefix" "$ula"
	uci -q delete network.globals.ula_prefix 2>/dev/null
	uci commit network; uci commit dhcp
	/etc/init.d/odhcpd disable >/dev/null 2>&1
	/etc/init.d/odhcpd stop >/dev/null 2>&1
	/etc/init.d/network reload >/dev/null 2>&1
	sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1
	sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1
}

do_apply() {
	# sysctl: зафиксировать оригиналы изменяемых, собрать drop-in, применить
	record_sysctl_originals
	generate_dropin
	sys sysctl -p "$ST_DROPIN"
	for key in $(enabled_sysctl_keys); do add_applied "$key"; done
	if st_param_enabled net.ipv4.tcp_congestion_control && [ "$(st_cap_bbr)" != "1" ]; then
		add_error "congestion: kmod-tcp-bbr not installed (fq_codel applied, bbr skipped)"
	fi

	# conntrack hashsize (sysfs)
	if st_param_enabled nf_conntrack.hashsize; then
		hs=$(st_hashsize); cur=$(st_read_current sysfs hashsize)
		[ -n "$cur" ] && [ "$(st_norm "$cur")" != "$(st_norm "$hs")" ] && st_state_add nf_conntrack.hashsize "$cur"
		[ "$ST_NO_APPLY" != "1" ] && [ -w "$ST_SYSFS_HASHSIZE" ] && echo "$hs" > "$ST_SYSFS_HASHSIZE" 2>/dev/null
		add_applied nf_conntrack.hashsize
	fi

	# flow offload (рекомендация = выкл)
	apply_fw_param firewall.flow_offloading
	apply_fw_param firewall.flow_offloading_hw

	# irqbalance (рекомендация = stopped): остановить+выключить, если запущен
	if st_param_enabled service.irqbalance; then
		if [ "$(st_cap_irqbalance)" = "1" ]; then
			cur=$(st_service_state irqbalance)
			[ "$cur" != "stopped" ] && st_state_add service.irqbalance "$cur"
			sys /etc/init.d/irqbalance stop; sys /etc/init.d/irqbalance disable
			add_applied service.irqbalance
		else add_error "irqbalance: package not installed"; fi
	fi

	# mobile LTE: MSS-clamp (nft) и MTU (auto/число)
	if st_param_enabled link.mss_clamp; then apply_mss; add_applied link.mss_clamp; fi
	if st_param_enabled link.mtu; then apply_mtu; add_applied link.mtu; fi

	# полное отключение IPv6 (sysctl уже в drop-in; здесь клиенты/WAN/ULA/odhcpd)
	if st_param_enabled net.ipv6.conf.all.disable_ipv6; then apply_disable_ipv6; fi

	# firewall перезагрузка под offload/mss (один раз)
	if [ "$ST_NO_APPLY" != "1" ]; then
		if command -v fw4 >/dev/null 2>&1; then fw4 reload >/dev/null 2>&1
		else /etc/init.d/firewall reload >/dev/null 2>&1; fi
	fi
}

# Откатить один параметр к исходному значению из state-файла.
revert_one() {  # <key> <orig>
	_k="$1"; _orig="$2"
	# псевдо-ключ вне реестра: ULA-префикс (удалялся при отключении IPv6)
	if [ "$_k" = "network.globals.ula_prefix" ]; then
		[ -n "$_orig" ] && uci set "network.globals.ula_prefix=$_orig" >/dev/null 2>&1
		uci commit network >/dev/null 2>&1; return
	fi
	_row=$(st_registry | awk -F'|' -v k="$_k" '$2==k{print $3"|"$4; exit}')
	_typ=${_row%%|*}; _tgt=${_row#*|}
	case "$_typ" in
		sysctl) sysctl -w "$_tgt=$_orig" >/dev/null 2>&1 ;;
		sysfs)  [ -w "$ST_SYSFS_HASHSIZE" ] && echo "$_orig" > "$ST_SYSFS_HASHSIZE" 2>/dev/null ;;
		firewall)
			opt=${_k#firewall.}
			uci set "firewall.@defaults[0].$opt=$_orig" >/dev/null 2>&1; uci commit firewall ;;
		service)
			[ "$_orig" = "running" ] && { /etc/init.d/irqbalance enable >/dev/null 2>&1; /etc/init.d/irqbalance start >/dev/null 2>&1; } ;;
		mtu)
			w=$(st_wan_iface); [ -n "$w" ] && uci set "network.$w.mtu=$_orig" >/dev/null 2>&1; uci commit network ;;
		mss) : ;;
	esac
}

do_revert() {
	# 1) удалить наши файлы (drop-in, nft-MSS)
	rm -f "$ST_DROPIN" "$ST_NFT_MSS" 2>/dev/null
	if [ "$ST_NO_APPLY" != "1" ]; then
		# 2) перезагрузить sysctl без нашего drop-in (вернуть дефолты ядра)
		sysctl --system >/dev/null 2>&1
		# 3) восстановить точные исходники применённых параметров
		if [ -f "$ST_STATE_FILE" ]; then
			while IFS="$TAB" read -r key orig; do
				[ -n "$key" ] && revert_one "$key" "$orig"
			done < "$ST_STATE_FILE"
		fi
		# 4) вернуть выдачу IPv6 клиентам (дефолт OpenWRT для lan)
		uci -q set dhcp.lan.dhcpv6='server'; uci -q set dhcp.lan.ra='server'
		uci -q delete dhcp.lan.ndp 2>/dev/null
		uci -q delete network.lan.delegate 2>/dev/null
		for w in $(st_eth_wan_iface) $(st_uci_cellular_iface); do
			[ -n "$w" ] && uci -q delete "network.$w.ipv6" 2>/dev/null
		done
		uci commit dhcp; uci commit network
		/etc/init.d/odhcpd enable >/dev/null 2>&1; /etc/init.d/odhcpd start >/dev/null 2>&1
		uci -q delete streamtune.global.mtu_resolved 2>/dev/null
		uci commit streamtune
		if command -v fw4 >/dev/null 2>&1; then fw4 reload >/dev/null 2>&1
		else /etc/init.d/firewall reload >/dev/null 2>&1; fi
		/etc/init.d/network reload >/dev/null 2>&1
	fi
	# 5) очистить память «применённого»
	st_state_clear
	add_applied revert
}

case "$ACTION" in
	revert) do_revert ;;
	*)      do_apply ;;
esac
printf '{"ok":true,"action":"%s","applied":[%s],"errors":[%s]}\n' "$ACTION" "$APPLIED" "$ERRORS"
