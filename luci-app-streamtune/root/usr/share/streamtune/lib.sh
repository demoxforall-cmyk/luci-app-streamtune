# shellcheck shell=sh
# streamtune — общая библиотека: реестр параметров (единый источник истины),
# профили, переопределяемые пути (для юнит-тестов без железа), хелперы.
# SPDX-License-Identifier: GPL-2.0
#
# Все потребители (detect.sh, apply.sh, rpcd) источат этот файл.
# Тесты переопределяют источники через окружение: ST_PROC_ROOT, ST_SYSCTL_D,
# ST_SYSFS_HASHSIZE, ST_CFG_FILE, ST_FW_FILE, ST_NET_FILE, ST_CAPS_FILE,
# ST_WAN_IFACE, ST_BBR_VERSION.

ST_SHARE="${ST_SHARE:-/usr/share/streamtune}"
ST_PROC_ROOT="${ST_PROC_ROOT:-/proc/sys}"            # корень sysctl (файлы x/y/z)
ST_SYSCTL_D="${ST_SYSCTL_D:-/etc/sysctl.d}"          # каталог drop-in'ов sysctl
ST_DROPIN="${ST_DROPIN:-$ST_SYSCTL_D/99-streamtune.conf}"
ST_SYSFS_HASHSIZE="${ST_SYSFS_HASHSIZE:-/sys/module/nf_conntrack/parameters/hashsize}"
ST_HASHSIZE_DEFAULT="${ST_HASHSIZE_DEFAULT:-16384}"

# ---------------------------------------------------------------------------
# Реестр параметров. Одна строка на параметр, поля разделены '|':
#   category|key|type|target|generic_value|lte_value
#
#   type        — sysctl | firewall | sysfs | service | mtu | mss
#   target      — sysctl: имя ключа (точки->слэши = путь в ST_PROC_ROOT)
#                 firewall: uci-опция в firewall.@defaults[0]
#                 sysfs: hashsize (через ST_SYSFS_HASHSIZE)
#                 service: имя сервиса; mtu: @wan; mss: @wanzone
#   generic_value — значение в профиле generic (как сейчас)
#   lte_value     — значение в профиле lte_audio. Пусто = как generic.
#                   '@default' = НЕ управлять (оставить дефолт ядра/системы).
# ---------------------------------------------------------------------------
st_registry() {
	cat <<'REG'
net_buffers|net.core.rmem_max|sysctl|net.core.rmem_max|16777216|4194304
net_buffers|net.core.wmem_max|sysctl|net.core.wmem_max|16777216|4194304
net_buffers|net.core.rmem_default|sysctl|net.core.rmem_default|16777216|@default
net_buffers|net.core.wmem_default|sysctl|net.core.wmem_default|16777216|@default
net_buffers|net.core.optmem_max|sysctl|net.core.optmem_max|40960|
net_buffers|net.ipv4.tcp_rmem|sysctl|net.ipv4.tcp_rmem|4096 1048576 2097152|4096 131072 4194304
net_buffers|net.ipv4.tcp_wmem|sysctl|net.ipv4.tcp_wmem|4096 65536 16777216|4096 65536 4194304
net_buffers|net.ipv4.udp_rmem_min|sysctl|net.ipv4.udp_rmem_min|8192|
net_buffers|net.ipv4.udp_wmem_min|sysctl|net.ipv4.udp_wmem_min|8192|
low_latency|net.ipv4.tcp_slow_start_after_idle|sysctl|net.ipv4.tcp_slow_start_after_idle|0|
low_latency|net.ipv4.tcp_tw_reuse|sysctl|net.ipv4.tcp_tw_reuse|1|
low_latency|net.ipv4.tcp_fin_timeout|sysctl|net.ipv4.tcp_fin_timeout|10|@default
low_latency|net.ipv4.tcp_max_syn_backlog|sysctl|net.ipv4.tcp_max_syn_backlog|30000|@default
low_latency|net.ipv4.tcp_max_tw_buckets|sysctl|net.ipv4.tcp_max_tw_buckets|2000000|@default
backlog|net.core.netdev_max_backlog|sysctl|net.core.netdev_max_backlog|100000|@default
backlog|net.core.netdev_budget|sysctl|net.core.netdev_budget|50000|@default
congestion|net.ipv4.tcp_congestion_control|sysctl|net.ipv4.tcp_congestion_control|bbr|
congestion|net.core.default_qdisc|sysctl|net.core.default_qdisc|fq|fq_codel
flow_offload|firewall.flow_offloading|firewall|flow_offloading|1|
flow_offload|firewall.flow_offloading_hw|firewall|flow_offloading_hw|1|
conntrack|nf_conntrack.hashsize|sysfs|hashsize|16384|
irqbalance|service.irqbalance|service|irqbalance|running|
disable_ipv6|net.ipv6.conf.all.disable_ipv6|sysctl|net.ipv6.conf.all.disable_ipv6|1|
disable_ipv6|net.ipv6.conf.default.disable_ipv6|sysctl|net.ipv6.conf.default.disable_ipv6|1|
mobile_lte|nf_conntrack.tcp_established|sysctl|net.netfilter.nf_conntrack_tcp_timeout_established|@default|7440
mobile_lte|link.mtu|mtu|@wan|@default|1430
mobile_lte|link.mss_clamp|mss|@wanzone|@default|1
REG
}

# Метаданные категорий: id|kind|requires  (kind: safe|opt|risk)
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
# Конфиг (желаемое состояние). По умолчанию из UCI streamtune.global.<opt>;
# для тестов — из файла ST_CFG_FILE (строки opt=value).
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

# Активный профиль: generic (по умолчанию) | lte_audio.
st_profile() { st_cfg profile generic; }

# Эффективное значение параметра для активного профиля.
st_effval() {
	# st_effval <generic_value> <lte_value>
	if [ "$(st_profile)" = "lte_audio" ]; then
		[ -n "$2" ] && echo "$2" || echo "$1"
	else
		echo "$1"
	fi
}

st_hashsize() { st_cfg hashsize "$ST_HASHSIZE_DEFAULT"; }

# Рекомендованное значение (учёт профиля, '@default' и динамики hashsize).
st_recommended() {
	# st_recommended <key> <generic_value> <lte_value>
	_eff=$(st_effval "$2" "$3")
	[ "$_eff" = "@default" ] && { echo "@default"; return; }
	[ "$1" = "nf_conntrack.hashsize" ] && { st_hashsize; return; }
	echo "$_eff"
}

# Желательна ли категория согласно конфигу (тумблеру). 0 = да.
st_cat_enabled() {
	case "$1" in
		net_buffers|low_latency|backlog|flow_offload|conntrack)
			[ "$(st_cfg "$1" 1)" = "1" ] ;;
		congestion|irqbalance|disable_ipv6|mobile_lte)
			[ "$(st_cfg "$1" 0)" = "1" ] ;;
		*) false ;;
	esac
}

# Базовая желательность параметра (категория вкл + под-опция hw). НЕ учитывает @default.
st_param_desired() {
	# st_param_desired <category> <key>
	st_cat_enabled "$1" || return 1
	if [ "$2" = "firewall.flow_offloading_hw" ]; then
		[ "$(st_cfg flow_offload_hw 0)" = "1" ] || return 1
	fi
	return 0
}

# ---------------------------------------------------------------------------
# WAN-интерфейс / firewall-зона (для MTU/MSS). Переопределяемо ST_WAN_IFACE.
# ---------------------------------------------------------------------------
st_wan_iface() {
	[ -n "${ST_WAN_IFACE:-}" ] && { echo "$ST_WAN_IFACE"; return; }
	_w=$(uci -q get streamtune.global.wan_iface 2>/dev/null)
	[ -n "$_w" ] && { echo "$_w"; return; }
	# автодетект: интерфейс с сотовым proto
	for _s in $(uci -q show network 2>/dev/null | sed -n "s/^network\.\([^.]*\)\.proto=.*/\1/p"); do
		case "$(uci -q get "network.$_s.proto" 2>/dev/null)" in
			modemmanager|qmi|wwan|mbim|ncm|3g) echo "$_s"; return ;;
		esac
	done
	for _s in wan wwan lte modem; do
		uci -q get "network.$_s" >/dev/null 2>&1 && { echo "$_s"; return; }
	done
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
# Чтение ТЕКУЩЕГО значения параметра -> stdout (пусто если недоступно).
# ---------------------------------------------------------------------------
st_sysctl_path() { echo "$ST_PROC_ROOT/$(echo "$1" | tr '.' '/')"; }

st_read_current() {
	# st_read_current <type> <target>
	case "$1" in
		sysctl)
			_p=$(st_sysctl_path "$2")
			[ -r "$_p" ] && st_norm "$(cat "$_p" 2>/dev/null)" ;;
		firewall)
			if [ -n "${ST_FW_FILE:-}" ] && [ -f "$ST_FW_FILE" ]; then
				sed -n "s/^$2=//p" "$ST_FW_FILE" | head -1
			else
				uci -q get "firewall.@defaults[0].$2" 2>/dev/null
			fi ;;
		sysfs)
			[ -r "$ST_SYSFS_HASHSIZE" ] && st_norm "$(cat "$ST_SYSFS_HASHSIZE" 2>/dev/null)" ;;
		service)
			st_service_state "$2" ;;
		mtu)
			if [ -n "${ST_NET_FILE:-}" ] && [ -f "$ST_NET_FILE" ]; then
				sed -n "s/^mtu=//p" "$ST_NET_FILE" | head -1
			else
				_w=$(st_wan_iface); [ -n "$_w" ] && uci -q get "network.$_w.mtu" 2>/dev/null
			fi ;;
		mss)
			if [ -n "${ST_FW_FILE:-}" ] && [ -f "$ST_FW_FILE" ]; then
				sed -n "s/^mtu_fix=//p" "$ST_FW_FILE" | head -1
			else
				_z=$(st_wan_zone); [ -n "$_z" ] && uci -q get "firewall.@zone[$_z].mtu_fix" 2>/dev/null
			fi ;;
	esac
}

# Нормализация пробелов: табы/множественные пробелы -> один пробел, trim.
st_norm() { echo "$1" | tr '\t' ' ' | tr -s ' ' | sed 's/^ //; s/ $//'; }

# ---------------------------------------------------------------------------
# Возможности окружения (capabilities). Для тестов — из ST_CAPS_FILE.
# ---------------------------------------------------------------------------
st_caps_raw() {
	if [ -n "${ST_CAPS_FILE:-}" ] && [ -f "$ST_CAPS_FILE" ]; then
		sed -n "s/^$1=//p" "$ST_CAPS_FILE" | head -1
	fi
}

st_cap_bbr() {
	_v=$(st_caps_raw bbr)
	[ -n "$_v" ] && { echo "$_v"; return; }
	_p=$(st_sysctl_path net.ipv4.tcp_available_congestion_control)
	if [ -r "$_p" ] && grep -qw bbr "$_p" 2>/dev/null; then echo 1; else echo 0; fi
}

# Версия BBR в ядре (строка, напр. "1" или "3"; пусто если неизвестно).
# Mainline 6.12 = BBRv1; BBRv3 — только кастомное ядро.
st_bbr_version() {
	[ -n "${ST_BBR_VERSION:-}" ] && { echo "$ST_BBR_VERSION"; return; }
	if [ -r /sys/module/tcp_bbr/version ]; then
		cat /sys/module/tcp_bbr/version 2>/dev/null; return
	fi
	command -v modinfo >/dev/null 2>&1 && modinfo -F version tcp_bbr 2>/dev/null
}

st_cap_irqbalance() {
	_v=$(st_caps_raw irqbalance)
	[ -n "$_v" ] && { echo "$_v"; return; }
	[ -x /etc/init.d/irqbalance ] && echo 1 || echo 0
}

st_cap_hw_offload() {
	_v=$(st_caps_raw hw_offload)
	[ -n "$_v" ] && { echo "$_v"; return; }
	echo 2
}

# Состояние сервиса: running | stopped | absent
st_service_state() {
	_v=$(st_caps_raw "svc_$1")
	[ -n "$_v" ] && { echo "$_v"; return; }
	[ -x "/etc/init.d/$1" ] || { echo absent; return; }
	if pgrep -x "$1" >/dev/null 2>&1; then echo running; else echo stopped; fi
}

# ---------------------------------------------------------------------------
# Состояние параметра:
#   off         — категория выключена и текущее != рекомендованному
#   match       — категория выключена, но система уже == рекомендованному
#   unmanaged   — профиль оставляет дефолт ядра (@default), мы не управляем
#   applied     — желателен и текущее == рекомендованному
#   pending     — желателен, но не применён
#   unavailable — желателен, но среда не позволяет (нет пакета/модуля/значения)
# ---------------------------------------------------------------------------
st_param_state() {
	# st_param_state <category> <key> <type> <cur> <rec> <managed 0/1>
	_cat="$1"; _key="$2"; _typ="$3"; _cur="$4"; _rec="$5"; _managed="$6"
	if [ "$_managed" = "0" ]; then
		st_cat_enabled "$_cat" && echo unmanaged || echo off
		return
	fi
	if ! st_param_desired "$_cat" "$_key"; then
		if [ -n "$_cur" ] && [ "$(st_norm "$_cur")" = "$(st_norm "$_rec")" ]; then
			echo match
		else
			echo off
		fi
		return
	fi
	case "$_cat" in
		congestion) [ "$(st_cap_bbr)" = "1" ] || { echo unavailable; return; } ;;
		irqbalance) [ "$(st_cap_irqbalance)" = "1" ] || { echo unavailable; return; } ;;
	esac
	if [ "$_typ" = "service" ]; then
		[ "$_cur" = "$_rec" ] && echo applied || echo pending
		return
	fi
	if [ -z "$_cur" ]; then echo unavailable; return; fi
	[ "$(st_norm "$_cur")" = "$(st_norm "$_rec")" ] && echo applied || echo pending
}
