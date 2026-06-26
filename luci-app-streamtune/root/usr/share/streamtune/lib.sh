# shellcheck shell=sh
# streamtune — общая библиотека: реестр параметров (единый источник истины),
# переопределяемые пути (для юнит-тестов без железа), хелперы чтения/сравнения.
# SPDX-License-Identifier: GPL-2.0
#
# Все потребители (detect.sh, apply.sh, rpcd) источат этот файл.
# Тесты переопределяют пути через окружение: ST_PROC_ROOT, ST_SYSCTL_D,
# ST_SYSFS_HASHSIZE, ST_CFG_FILE, ST_FW_FILE, ST_CAPS_FILE.

ST_SHARE="${ST_SHARE:-/usr/share/streamtune}"
ST_PROC_ROOT="${ST_PROC_ROOT:-/proc/sys}"            # корень sysctl (файлы x/y/z)
ST_SYSCTL_D="${ST_SYSCTL_D:-/etc/sysctl.d}"          # каталог drop-in'ов sysctl
ST_DROPIN="${ST_DROPIN:-$ST_SYSCTL_D/99-streamtune.conf}"
ST_SYSFS_HASHSIZE="${ST_SYSFS_HASHSIZE:-/sys/module/nf_conntrack/parameters/hashsize}"
ST_HASHSIZE_DEFAULT="${ST_HASHSIZE_DEFAULT:-16384}"

# ---------------------------------------------------------------------------
# Реестр параметров. Одна строка на параметр, поля разделены '|':
#   category|key|type|target|recommended
#
#   category    — id категории (тумблера): см. st_catmeta
#   key         — уникальный ключ/отображаемое имя параметра
#   type        — sysctl | firewall | sysfs | service
#   target      — для sysctl: имя ключа (точки -> слэши = путь в ST_PROC_ROOT)
#                 для firewall: uci-опция в firewall.@defaults[0]
#                 для sysfs: абсолютный путь файла (через ST_SYSFS_HASHSIZE)
#                 для service: имя сервиса
#   recommended — рекомендованное значение (может содержать пробелы)
# ---------------------------------------------------------------------------
st_registry() {
	cat <<'REG'
net_buffers|net.core.rmem_max|sysctl|net.core.rmem_max|16777216
net_buffers|net.core.wmem_max|sysctl|net.core.wmem_max|16777216
net_buffers|net.core.rmem_default|sysctl|net.core.rmem_default|16777216
net_buffers|net.core.wmem_default|sysctl|net.core.wmem_default|16777216
net_buffers|net.core.optmem_max|sysctl|net.core.optmem_max|40960
net_buffers|net.ipv4.tcp_rmem|sysctl|net.ipv4.tcp_rmem|4096 1048576 2097152
net_buffers|net.ipv4.tcp_wmem|sysctl|net.ipv4.tcp_wmem|4096 65536 16777216
net_buffers|net.ipv4.udp_rmem_min|sysctl|net.ipv4.udp_rmem_min|8192
net_buffers|net.ipv4.udp_wmem_min|sysctl|net.ipv4.udp_wmem_min|8192
low_latency|net.ipv4.tcp_slow_start_after_idle|sysctl|net.ipv4.tcp_slow_start_after_idle|0
low_latency|net.ipv4.tcp_tw_reuse|sysctl|net.ipv4.tcp_tw_reuse|1
low_latency|net.ipv4.tcp_fin_timeout|sysctl|net.ipv4.tcp_fin_timeout|10
low_latency|net.ipv4.tcp_max_syn_backlog|sysctl|net.ipv4.tcp_max_syn_backlog|30000
low_latency|net.ipv4.tcp_max_tw_buckets|sysctl|net.ipv4.tcp_max_tw_buckets|2000000
backlog|net.core.netdev_max_backlog|sysctl|net.core.netdev_max_backlog|100000
backlog|net.core.netdev_budget|sysctl|net.core.netdev_budget|50000
congestion|net.ipv4.tcp_congestion_control|sysctl|net.ipv4.tcp_congestion_control|bbr
congestion|net.core.default_qdisc|sysctl|net.core.default_qdisc|fq
flow_offload|firewall.flow_offloading|firewall|flow_offloading|1
flow_offload|firewall.flow_offloading_hw|firewall|flow_offloading_hw|1
conntrack|nf_conntrack.hashsize|sysfs|hashsize|16384
irqbalance|service.irqbalance|service|irqbalance|running
disable_ipv6|net.ipv6.conf.all.disable_ipv6|sysctl|net.ipv6.conf.all.disable_ipv6|1
disable_ipv6|net.ipv6.conf.default.disable_ipv6|sysctl|net.ipv6.conf.default.disable_ipv6|1
REG
}

# Метаданные категорий: id|kind|requires
#   kind     — safe | opt (опциональная) | risk (рискованная, выкл по умолчанию)
#   requires — пакет/модуль, нужный для работы (пусто — ничего)
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
CM
}

# Порядок категорий для UI/обхода.
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

# Рекомендованный hashsize: из конфига (option hashsize) либо дефолт.
st_hashsize() { st_cfg hashsize "$ST_HASHSIZE_DEFAULT"; }

# Желательна ли категория согласно конфигу (тумблеру). 0 = да.
st_cat_enabled() {
	case "$1" in
		net_buffers|low_latency|backlog|flow_offload|conntrack)
			[ "$(st_cfg "$1" 1)" = "1" ] ;;
		congestion|irqbalance|disable_ipv6)
			[ "$(st_cfg "$1" 0)" = "1" ] ;;
		*) false ;;
	esac
}

# Желателен ли конкретный параметр (учёт под-опции flow_offload_hw).
st_param_desired() {
	# st_param_desired <category> <key>
	st_cat_enabled "$1" || return 1
	if [ "$2" = "firewall.flow_offloading_hw" ]; then
		[ "$(st_cfg flow_offload_hw 0)" = "1" ] || return 1
	fi
	return 0
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
	esac
}

# Рекомендованное значение для параметра (динамика для hashsize).
st_recommended() {
	# st_recommended <key> <reg_recommended>
	if [ "$1" = "nf_conntrack.hashsize" ]; then st_hashsize; else echo "$2"; fi
}

# Нормализация пробелов: табы/множественные пробелы -> один пробел, trim.
st_norm() { echo "$1" | tr '\t' ' ' | tr -s ' ' | sed 's/^ //; s/ $//'; }

# ---------------------------------------------------------------------------
# Возможности окружения (capabilities) — что вообще доступно на железе.
# Для тестов — из ST_CAPS_FILE (строки cap=0/1 или значение).
# ---------------------------------------------------------------------------
st_caps_raw() {
	# st_caps_raw <cap>
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

st_cap_irqbalance() {
	_v=$(st_caps_raw irqbalance)
	[ -n "$_v" ] && { echo "$_v"; return; }
	[ -x /etc/init.d/irqbalance ] && echo 1 || echo 0
}

# best-effort: поддерживает ли железо аппаратный flow offload
st_cap_hw_offload() {
	_v=$(st_caps_raw hw_offload)
	[ -n "$_v" ] && { echo "$_v"; return; }
	# эвристика: наличие mtk/flow-offload в ядре трудно проверить надёжно,
	# поэтому возвращаем "unknown" (2) — UI покажет мягкое предупреждение.
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
# Вычисление состояния параметра:
#   off         — категория/опция выключена в конфиге (не учитывается в score)
#   applied     — желателен и текущее == рекомендованному
#   pending     — желателен, но не применён
#   unavailable — желателен, но среда не позволяет (нет пакета/модуля)
# ---------------------------------------------------------------------------
st_param_state() {
	# st_param_state <category> <key> <type> <cur> <rec>
	_cat="$1"; _key="$2"; _typ="$3"; _cur="$4"; _rec="$5"
	if ! st_param_desired "$_cat" "$_key"; then
		# Категория/опция не выбрана в профиле. Если система УЖЕ соответствует
		# рекомендованному (значение фактически стоит) — показываем "match",
		# иначе "off". Это снимает двусмысленность статуса "Off".
		if [ -n "$_cur" ] && [ "$(st_norm "$_cur")" = "$(st_norm "$_rec")" ]; then
			echo match
		else
			echo off
		fi
		return
	fi
	case "$_cat" in
		congestion)
			[ "$(st_cap_bbr)" = "1" ] || { echo unavailable; return; } ;;
		irqbalance)
			[ "$(st_cap_irqbalance)" = "1" ] || { echo unavailable; return; } ;;
	esac
	if [ "$_typ" = "service" ]; then
		[ "$_cur" = "$_rec" ] && echo applied || echo pending
		return
	fi
	if [ -z "$_cur" ]; then echo unavailable; return; fi
	[ "$(st_norm "$_cur")" = "$(st_norm "$_rec")" ] && echo applied || echo pending
}
