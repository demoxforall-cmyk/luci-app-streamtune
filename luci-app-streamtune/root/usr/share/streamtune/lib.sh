# shellcheck shell=sh
# streamtune — общая библиотека: реестр параметров (единый источник истины),
# профили (lte_audio | home_wired), WAN-детект (modem via ModemManager / eth),
# переопределяемые пути для юнит-тестов.
# SPDX-License-Identifier: GPL-2.0
#
# Тесты переопределяют окружение: ST_PROC_ROOT, ST_SYSCTL_D, ST_SYSFS_HASHSIZE,
# ST_CFG_FILE, ST_FW_FILE, ST_NET_FILE, ST_CAPS_FILE, ST_WAN_IFACE,
# ST_WAN_NETDEV, ST_BBR_VERSION, ST_BBR_KSIZE, ST_MODEM_MTU.

ST_SHARE="${ST_SHARE:-/usr/share/streamtune}"
ST_PROC_ROOT="${ST_PROC_ROOT:-/proc/sys}"
ST_SYSCTL_D="${ST_SYSCTL_D:-/etc/sysctl.d}"
ST_DROPIN="${ST_DROPIN:-$ST_SYSCTL_D/99-streamtune.conf}"
ST_NFT_MSS="${ST_NFT_MSS:-/etc/nftables.d/13-streamtune-mss.nft}"
ST_SYSFS_HASHSIZE="${ST_SYSFS_HASHSIZE:-/sys/module/nf_conntrack/parameters/hashsize}"
ST_HASHSIZE_DEFAULT="${ST_HASHSIZE_DEFAULT:-16384}"

# ---------------------------------------------------------------------------
# Реестр параметров: category|key|type|target|lte_audio|home_wired
#   type   — sysctl | firewall | sysfs | service | mtu | mss
#   target — sysctl: имя ключа; firewall: опция @defaults[0]; sysfs: hashsize;
#            service: имя; mtu: @wan; mss: @wan
#   значения профилей: число/строка | '@default' (не управлять) | 'auto' (MTU: проба)
# ---------------------------------------------------------------------------
st_registry() {
	cat <<'REG'
net_buffers|net.core.rmem_max|sysctl|net.core.rmem_max|4194304|4194304
net_buffers|net.core.wmem_max|sysctl|net.core.wmem_max|4194304|4194304
net_buffers|net.core.rmem_default|sysctl|net.core.rmem_default|@default|@default
net_buffers|net.core.wmem_default|sysctl|net.core.wmem_default|@default|@default
net_buffers|net.core.optmem_max|sysctl|net.core.optmem_max|@default|@default
net_buffers|net.ipv4.tcp_rmem|sysctl|net.ipv4.tcp_rmem|@default|@default
net_buffers|net.ipv4.tcp_wmem|sysctl|net.ipv4.tcp_wmem|@default|@default
net_buffers|net.ipv4.udp_rmem_min|sysctl|net.ipv4.udp_rmem_min|8192|8192
net_buffers|net.ipv4.udp_wmem_min|sysctl|net.ipv4.udp_wmem_min|8192|8192
low_latency|net.ipv4.tcp_slow_start_after_idle|sysctl|net.ipv4.tcp_slow_start_after_idle|0|0
low_latency|net.ipv4.tcp_tw_reuse|sysctl|net.ipv4.tcp_tw_reuse|@default|@default
low_latency|net.ipv4.tcp_fin_timeout|sysctl|net.ipv4.tcp_fin_timeout|@default|@default
low_latency|net.ipv4.tcp_max_syn_backlog|sysctl|net.ipv4.tcp_max_syn_backlog|@default|@default
low_latency|net.ipv4.tcp_max_tw_buckets|sysctl|net.ipv4.tcp_max_tw_buckets|@default|@default
backlog|net.core.netdev_max_backlog|sysctl|net.core.netdev_max_backlog|@default|@default
backlog|net.core.netdev_budget|sysctl|net.core.netdev_budget|@default|@default
congestion|net.ipv4.tcp_congestion_control|sysctl|net.ipv4.tcp_congestion_control|bbr|bbr
congestion|net.core.default_qdisc|sysctl|net.core.default_qdisc|fq_codel|fq_codel
flow_offload|firewall.flow_offloading|firewall|flow_offloading|1|1
flow_offload|firewall.flow_offloading_hw|firewall|flow_offloading_hw|1|1
conntrack|nf_conntrack.hashsize|sysfs|hashsize|16384|16384
irqbalance|service.irqbalance|service|irqbalance|running|running
disable_ipv6|net.ipv6.conf.all.disable_ipv6|sysctl|net.ipv6.conf.all.disable_ipv6|1|1
disable_ipv6|net.ipv6.conf.default.disable_ipv6|sysctl|net.ipv6.conf.default.disable_ipv6|1|1
mobile_lte|nf_conntrack.tcp_established|sysctl|net.netfilter.nf_conntrack_tcp_timeout_established|7440|7440
mobile_lte|link.mtu|mtu|@wan|auto|auto
mobile_lte|link.mss_clamp|mss|@wan|1|1
REG
}

# id|kind|requires  (kind: safe|opt|risk)
st_catmeta() {
	cat <<'CM'
net_buffers|safe|
low_latency|safe|
backlog|safe|
congestion|opt|kmod-tcp-bbr
flow_offload|opt|
conntrack|safe|
irqbalance|opt|irqbalance
disable_ipv6|risk|
mobile_lte|opt|
CM
}

st_categories() { st_catmeta | cut -d'|' -f1; }

# ---------------------------------------------------------------------------
# Конфиг / профиль
# ---------------------------------------------------------------------------
st_cfg() {
	# st_cfg <option> <default>
	_opt="$1"; _def="$2"; _v=""
	if [ -n "${ST_CFG_FILE:-}" ] && [ -f "$ST_CFG_FILE" ]; then
		_v=$(sed -n "s/^$_opt=//p" "$ST_CFG_FILE" | head -1)
	else
		_v=$(uci -q get "streamtune.global.$_opt" 2>/dev/null)
	fi
	[ -n "$_v" ] && echo "$_v" || echo "$_def"
}

# Активный профиль: lte_audio (по умолчанию) | home_wired.
st_profile() { st_cfg profile lte_audio; }

# Эффективное значение параметра для активного профиля.
st_effval() {
	# st_effval <lte_value> <home_value>
	[ "$(st_profile)" = "home_wired" ] && echo "$2" || echo "$1"
}

st_hashsize() { st_cfg hashsize "$ST_HASHSIZE_DEFAULT"; }

# Рекомендованное значение (учёт профиля, '@default', 'auto', hashsize).
st_recommended() {
	# st_recommended <key> <lte_value> <home_value>
	_eff=$(st_effval "$2" "$3")
	[ "$_eff" = "@default" ] && { echo "@default"; return; }
	[ "$1" = "nf_conntrack.hashsize" ] && { st_hashsize; return; }
	# link.mtu: ручной/пробитый override (UCI mtu) перекрывает профильный 'auto'
	[ "$1" = "link.mtu" ] && { echo "$(st_cfg mtu "$_eff")"; return; }
	echo "$_eff"
}

# Желательна ли категория (тумблер). Дефолты = общий пресет профилей.
st_cat_enabled() {
	case "$1" in
		net_buffers|low_latency|conntrack) [ "$(st_cfg "$1" 1)" = "1" ] ;;
		congestion|mobile_lte)             [ "$(st_cfg "$1" 1)" = "1" ] ;;
		disable_ipv6)                      [ "$(st_cfg "$1" 1)" = "1" ] ;;
		backlog|flow_offload|irqbalance)   [ "$(st_cfg "$1" 0)" = "1" ] ;;
		*) false ;;
	esac
}

st_param_desired() {
	# st_param_desired <category> <key>
	st_cat_enabled "$1" || return 1
	if [ "$2" = "firewall.flow_offloading_hw" ]; then
		[ "$(st_cfg flow_offload_hw 0)" = "1" ] || return 1
	fi
	return 0
}

# ---------------------------------------------------------------------------
# WAN-детект (профиле-зависимый). Modem — через ModemManager.
# ---------------------------------------------------------------------------
st_uci_cellular_iface() {
	for _s in $(uci -q show network 2>/dev/null | sed -n "s/^network\.\([^.]*\)\.proto=.*/\1/p"); do
		case "$(uci -q get "network.$_s.proto" 2>/dev/null)" in
			modemmanager|qmi|wwan|mbim|ncm|3g) echo "$_s"; return ;;
		esac
	done
	for _s in wwan lte modem wan; do
		uci -q get "network.$_s" >/dev/null 2>&1 && { echo "$_s"; return; }
	done
	echo ""
}

# DBus-путь активного bearer (формат ключа `...bearers.value[1]` со скобками).
st_modem_bearer() {
	command -v mmcli >/dev/null 2>&1 || return 0
	_m=$(mmcli -L 2>/dev/null | sed -n 's#.*/Modem/\([0-9][0-9]*\).*#\1#p' | head -1)
	[ -n "$_m" ] || return 0
	mmcli -m "$_m" -K 2>/dev/null | grep 'generic.bearers.value' \
		| grep -o '/org/[^ ]*Bearer/[0-9][0-9]*' | head -1
}

# netdev модема (напр. wwan0) через ModemManager; fallback — UCI-интерфейс.
st_modem_iface() {
	_b=$(st_modem_bearer)
	_if=""
	[ -n "$_b" ] && _if=$(mmcli -b "$_b" -K 2>/dev/null | sed -n 's/^bearer\.status\.interface *: *//p')
	[ -n "$_if" ] && echo "$_if" || st_uci_cellular_iface
}

# carrier-MTU, выданный оператором (через MM); пусто если недоступно.
st_modem_mtu() {
	[ -n "${ST_MODEM_MTU:-}" ] && { echo "$ST_MODEM_MTU"; return; }
	_b=$(st_modem_bearer)
	[ -n "$_b" ] && mmcli -b "$_b" -K 2>/dev/null | sed -n 's/^bearer\.ipv4-config\.mtu *: *//p'
}

st_eth_wan_iface() {
	for _s in wan wan6 internet; do
		case "$(uci -q get "network.$_s.proto" 2>/dev/null)" in
			dhcp|static|pppoe|dhcpv6) echo "$_s"; return ;;
		esac
	done
	echo "wan"
}

# Логический UCI-интерфейс WAN (для uci set ...mtu) — по профилю.
st_wan_iface() {
	[ -n "${ST_WAN_IFACE:-}" ] && { echo "$ST_WAN_IFACE"; return; }
	_w=$(uci -q get streamtune.global.wan_iface 2>/dev/null)
	[ -n "$_w" ] && { echo "$_w"; return; }
	case "$(st_profile)" in
		home_wired) st_eth_wan_iface ;;
		*)          st_uci_cellular_iface ;;
	esac
}

# Kernel netdev WAN (для nft oifname/iifname, ping -I, sysfs).
# Возвращаем ТОЛЬКО реальный netdev (с /sys/class/net), не логическое имя.
st_wan_netdev() {
	[ -n "${ST_WAN_NETDEV:-}" ] && { echo "$ST_WAN_NETDEV"; return; }
	# 1) netdev модема напрямую из ModemManager (если это реальный netdev)
	if [ "$(st_profile)" != "home_wired" ]; then
		_d=$(st_modem_iface)
		[ -n "$_d" ] && [ -e "/sys/class/net/$_d" ] && { echo "$_d"; return; }
	fi
	# 2) l3_device логического WAN-интерфейса через ubus
	_d=$(ubus call "network.interface.$(st_wan_iface)" status 2>/dev/null | sed -n 's/.*"l3_device": *"\([^"]*\)".*/\1/p' | head -1)
	[ -n "$_d" ] && [ -e "/sys/class/net/$_d" ] && { echo "$_d"; return; }
	# 3) интерфейс default route
	_d=$(ip -o route show default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
	[ -n "$_d" ] && { echo "$_d"; return; }
	echo ""
}

st_wan_zone() {
	_w=$(st_wan_iface); [ -n "$_w" ] || { echo ""; return; }
	_i=0
	while uci -q get "firewall.@zone[$_i]" >/dev/null 2>&1; do
		case " $(uci -q get "firewall.@zone[$_i].network" 2>/dev/null) " in
			*" $_w "*) echo "$_i"; return ;;
		esac
		_i=$((_i + 1))
	done
	echo ""
}

# ---------------------------------------------------------------------------
# Чтение текущего значения параметра
# ---------------------------------------------------------------------------
st_sysctl_path() { echo "$ST_PROC_ROOT/$(echo "$1" | tr '.' '/')"; }

st_read_current() {
	# st_read_current <type> <target>
	case "$1" in
		sysctl)
			_p=$(st_sysctl_path "$2"); [ -r "$_p" ] && st_norm "$(cat "$_p" 2>/dev/null)" ;;
		firewall)
			if [ -n "${ST_FW_FILE:-}" ] && [ -f "$ST_FW_FILE" ]; then
				sed -n "s/^$2=//p" "$ST_FW_FILE" | head -1
			else uci -q get "firewall.@defaults[0].$2" 2>/dev/null; fi ;;
		sysfs)
			[ -r "$ST_SYSFS_HASHSIZE" ] && st_norm "$(cat "$ST_SYSFS_HASHSIZE" 2>/dev/null)" ;;
		service) st_service_state "$2" ;;
		mtu)
			if [ -n "${ST_NET_FILE:-}" ] && [ -f "$ST_NET_FILE" ]; then
				sed -n "s/^mtu=//p" "$ST_NET_FILE" | head -1
			else
				_d=$(st_wan_netdev)
				[ -n "$_d" ] && [ -r "/sys/class/net/$_d/mtu" ] && cat "/sys/class/net/$_d/mtu" 2>/dev/null
			fi ;;
		mss)
			# наличие nft-правила MSS = "включено" (1), иначе 0
			if [ -n "${ST_FW_FILE:-}" ] && [ -f "$ST_FW_FILE" ]; then
				sed -n "s/^mss=//p" "$ST_FW_FILE" | head -1
			else
				[ -f "$ST_NFT_MSS" ] && echo 1 || echo 0
			fi ;;
	esac
}

st_norm() { echo "$1" | tr '\t' ' ' | tr -s ' ' | sed 's/^ //; s/ $//'; }

# ---------------------------------------------------------------------------
# Capabilities
# ---------------------------------------------------------------------------
st_caps_raw() {
	if [ -n "${ST_CAPS_FILE:-}" ] && [ -f "$ST_CAPS_FILE" ]; then
		sed -n "s/^$1=//p" "$ST_CAPS_FILE" | head -1
	fi
}

st_cap_bbr() {
	_v=$(st_caps_raw bbr); [ -n "$_v" ] && { echo "$_v"; return; }
	_p=$(st_sysctl_path net.ipv4.tcp_available_congestion_control)
	if [ -r "$_p" ] && grep -qw bbr "$_p" 2>/dev/null; then echo 1; else echo 0; fi
}

st_bbr_ksize() {
	[ -n "${ST_BBR_KSIZE:-}" ] && { echo "$ST_BBR_KSIZE"; return; }
	_f="/lib/modules/$(uname -r 2>/dev/null)/tcp_bbr.ko"
	[ -f "$_f" ] || _f=$(find /lib/modules -name 'tcp_bbr.ko' 2>/dev/null | head -1)
	[ -n "$_f" ] && [ -f "$_f" ] && wc -c < "$_f" 2>/dev/null | tr -d ' '
}

# Версия BBR: "1"|"3"|"" (modinfo вырезан в OpenWRT -> по размеру модуля).
st_bbr_version() {
	[ -n "${ST_BBR_VERSION:-}" ] && { echo "$ST_BBR_VERSION"; return; }
	if [ -r /sys/module/tcp_bbr/version ]; then
		_v=$(cat /sys/module/tcp_bbr/version 2>/dev/null); [ -n "$_v" ] && { echo "$_v"; return; }
	fi
	_sz=$(st_bbr_ksize); [ -n "$_sz" ] || { echo ""; return; }
	_thr=$(st_cfg bbr_v1_maxsize 14500)
	if [ "$_sz" -gt "$_thr" ] 2>/dev/null; then echo 3; else echo 1; fi
}

st_cap_irqbalance() {
	_v=$(st_caps_raw irqbalance); [ -n "$_v" ] && { echo "$_v"; return; }
	[ -x /etc/init.d/irqbalance ] && echo 1 || echo 0
}

st_cap_hw_offload() {
	_v=$(st_caps_raw hw_offload); [ -n "$_v" ] && { echo "$_v"; return; }
	echo 2
}

st_service_state() {
	_v=$(st_caps_raw "svc_$1"); [ -n "$_v" ] && { echo "$_v"; return; }
	[ -x "/etc/init.d/$1" ] || { echo absent; return; }
	if pgrep -x "$1" >/dev/null 2>&1; then echo running; else echo stopped; fi
}

# ---------------------------------------------------------------------------
# Состояние параметра (см. detect.sh); managed=0 => @default => "unmanaged".
# ---------------------------------------------------------------------------
st_param_state() {
	# <category> <key> <type> <cur> <rec> <managed 0/1>
	_cat="$1"; _key="$2"; _typ="$3"; _cur="$4"; _rec="$5"; _managed="$6"
	if [ "$_managed" = "0" ]; then
		st_cat_enabled "$_cat" && echo unmanaged || echo off; return
	fi
	if ! st_param_desired "$_cat" "$_key"; then
		if [ -n "$_cur" ] && [ "$(st_norm "$_cur")" = "$(st_norm "$_rec")" ]; then echo match; else echo off; fi
		return
	fi
	case "$_cat" in
		congestion) [ "$_key" = "net.ipv4.tcp_congestion_control" ] && [ "$(st_cap_bbr)" != "1" ] && { echo unavailable; return; } ;;
		irqbalance) [ "$(st_cap_irqbalance)" = "1" ] || { echo unavailable; return; } ;;
	esac
	if [ "$_typ" = "service" ]; then [ "$_cur" = "$_rec" ] && echo applied || echo pending; return; fi
	if [ "$_typ" = "mss" ]; then [ "$_cur" = "1" ] && echo applied || echo pending; return; fi
	if [ "$_rec" = "auto" ]; then
		# MTU: сравниваем с последним применённым (mtu_resolved)
		_res=$(st_cfg mtu_resolved "")
		if [ -z "$_res" ]; then echo pending; return; fi
		[ "$(st_norm "$_cur")" = "$(st_norm "$_res")" ] && echo applied || echo pending; return
	fi
	if [ -z "$_cur" ]; then echo unavailable; return; fi
	[ "$(st_norm "$_cur")" = "$(st_norm "$_rec")" ] && echo applied || echo pending
}
