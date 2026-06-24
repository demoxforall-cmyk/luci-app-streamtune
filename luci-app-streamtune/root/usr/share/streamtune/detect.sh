#!/bin/sh
# streamtune — детект текущего состояния всех параметров -> JSON.
# SPDX-License-Identifier: GPL-2.0
#
# JSON собирается вручную (без jshn) — скрипт автономен и тестируется на любой
# POSIX-оболочке. rpcd-бэкенд просто отдаёт этот вывод как ответ get_status.
#
# Тесты переопределяют источники через окружение (см. lib.sh):
#   ST_SHARE ST_PROC_ROOT ST_SYSFS_HASHSIZE ST_CFG_FILE ST_FW_FILE ST_CAPS_FILE
set -u
ST_SHARE="${ST_SHARE:-/usr/share/streamtune}"
. "$ST_SHARE/lib.sh"

js() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

applied=0; desired=0
for cat in $(st_categories); do eval "CA_$cat=0; CT_$cat=0"; done

printf '{'
printf '"params":['
first=1
while IFS='|' read -r cat key typ target rec0; do
	[ -n "$cat" ] || continue
	cur=$(st_read_current "$typ" "$target")
	rec=$(st_recommended "$key" "$rec0")
	state=$(st_param_state "$cat" "$key" "$typ" "$cur" "$rec")
	if [ "$state" != "off" ]; then
		desired=$((desired + 1)); eval "CT_$cat=\$((CT_$cat + 1))"
	fi
	if [ "$state" = "applied" ]; then
		applied=$((applied + 1)); eval "CA_$cat=\$((CA_$cat + 1))"
	fi
	[ "$first" -eq 1 ] || printf ','
	first=0
	printf '{"cat":"%s","key":"%s","type":"%s","cur":"%s","rec":"%s","state":"%s"}' \
		"$cat" "$(js "$key")" "$typ" "$(js "$cur")" "$(js "$rec")" "$state"
done <<EOF
$(st_registry)
EOF
printf ']'

# --- категории ---
printf ',"categories":{'
first=1
while IFS='|' read -r cat kind requires; do
	[ -n "$cat" ] || continue
	eval "ap=\${CA_$cat}; tot=\${CT_$cat}"
	if st_cat_enabled "$cat"; then en=1; else en=0; fi
	[ "$first" -eq 1 ] || printf ','
	first=0
	printf '"%s":{"kind":"%s","requires":"%s","enabled":%s,"applied":%s,"total":%s}' \
		"$cat" "$kind" "$(js "$requires")" "$en" "$ap" "$tot"
done <<EOF
$(st_catmeta)
EOF
printf '}'

# --- capabilities ---
printf ',"caps":{"bbr":%s,"irqbalance":%s,"hw_offload":%s}' \
	"$(st_cap_bbr)" "$(st_cap_irqbalance)" "$(st_cap_hw_offload)"

# --- конфиг (тумблеры) ---
printf ',"config":{'
printf '"net_buffers":"%s",' "$(st_cfg net_buffers 1)"
printf '"low_latency":"%s",' "$(st_cfg low_latency 1)"
printf '"backlog":"%s",' "$(st_cfg backlog 1)"
printf '"congestion":"%s",' "$(st_cfg congestion 0)"
printf '"flow_offload":"%s",' "$(st_cfg flow_offload 1)"
printf '"flow_offload_hw":"%s",' "$(st_cfg flow_offload_hw 0)"
printf '"conntrack":"%s",' "$(st_cfg conntrack 1)"
printf '"irqbalance":"%s",' "$(st_cfg irqbalance 0)"
printf '"disable_ipv6":"%s",' "$(st_cfg disable_ipv6 0)"
printf '"hashsize":"%s"' "$(st_hashsize)"
printf '}'

# --- сводная оценка ---
printf ',"score":{"applied":%s,"total":%s}' "$applied" "$desired"

printf '}\n'
