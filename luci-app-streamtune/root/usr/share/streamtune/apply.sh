#!/bin/sh
# streamtune — применение/откат оптимизаций на основе UCI streamtune.global.
# SPDX-License-Identifier: GPL-2.0
#
# Действия:
#   apply  (по умолчанию) — сгенерировать /etc/sysctl.d/99-streamtune.conf из
#          включённых категорий и применить sysctl + firewall + conntrack +
#          irqbalance + ipv6. Идемпотентно.
#   revert — удалить drop-in, откатить firewall/ipv6/irqbalance, обнулить тумблеры.
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

# --- генерация sysctl drop-in (чистая, без рута; ядро тестов) ---
generate_dropin() {
	mkdir -p "$ST_SYSCTL_D" 2>/dev/null
	tmp="$ST_DROPIN.tmp.$$"
	{
		echo "# Managed by luci-app-streamtune. Do not edit by hand."
		echo "# Regenerated on each apply from /etc/config/streamtune."
		while IFS='|' read -r cat key typ target rec0; do
			[ "$typ" = "sysctl" ] || continue
			st_param_desired "$cat" "$key" || continue
			# управление перегрузкой пишем только если BBR реально доступен
			if [ "$cat" = "congestion" ] && [ "$(st_cap_bbr)" != "1" ]; then
				continue
			fi
			rec=$(st_recommended "$key" "$rec0")
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

	# отметить применённые «безопасные» sysctl-категории
	for c in net_buffers low_latency backlog disable_ipv6; do
		st_cat_enabled "$c" && add_applied "$c"
	done

	# управление перегрузкой (BBR + fq)
	if st_cat_enabled congestion; then
		if [ "$(st_cap_bbr)" = "1" ]; then add_applied congestion
		else add_error "congestion: kmod-tcp-bbr not installed"; fi
	fi

	# аппаратный/программный flow offload через firewall
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

	# немедленно применить отключение IPv6 в runtime (drop-in покрывает persist)
	if st_cat_enabled disable_ipv6 && [ "$ST_NO_APPLY" != "1" ]; then
		sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1
		sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1
	fi
}

do_revert() {
	rm -f "$ST_DROPIN" 2>/dev/null
	# вернуть IPv6 в runtime
	if [ "$ST_NO_APPLY" != "1" ]; then
		sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1
		sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1
		sysctl --system >/dev/null 2>&1
	fi
	# откатить firewall offload
	sys uci set firewall.@defaults[0].flow_offloading=0
	sys uci set firewall.@defaults[0].flow_offloading_hw=0
	sys uci commit firewall
	if [ "$ST_NO_APPLY" != "1" ]; then
		if command -v fw4 >/dev/null 2>&1; then fw4 reload >/dev/null 2>&1
		else /etc/init.d/firewall reload >/dev/null 2>&1; fi
	fi
	# остановить irqbalance, если мы его запускали
	sys /etc/init.d/irqbalance stop
	sys /etc/init.d/irqbalance disable
	# обнулить тумблеры streamtune
	if [ "$ST_NO_APPLY" != "1" ]; then
		for c in net_buffers low_latency backlog congestion flow_offload flow_offload_hw conntrack irqbalance disable_ipv6; do
			uci set "streamtune.global.$c=0" >/dev/null 2>&1
		done
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
