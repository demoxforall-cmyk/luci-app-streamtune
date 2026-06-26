#!/bin/sh
# streamtune — детект текущего состояния всех параметров -> JSON.
# SPDX-License-Identifier: GPL-2.0
#
# JSON собирается вручную (без jshn) — скрипт автономен и тестируется на любой
# POSIX-оболочке. rpcd-бэкенд просто отдаёт этот вывод как ответ get_status.
# Учитывает активный профиль (generic | lte_audio): параметры с lte-значением
# '@default' считаются "unmanaged" (профиль оставляет дефолт ядра).
set -u
ST_SHARE="${ST_SHARE:-/usr/share/streamtune}"
. "$ST_SHARE/lib.sh"

js() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

applied=0; desired=0
for cat in $(st_categories); do eval "CA_$cat=0; CT_$cat=0; CM_$cat=0"; done

printf '{'
printf '"params":['
first=1
while IFS='|' read -r cat key typ target gval lval; do
	[ -n "$cat" ] || continue
	eff=$(st_effval "$gval" "$lval")
	if [ "$eff" = "@default" ]; then managed=0; else managed=1; fi
	cur=$(st_read_current "$typ" "$target")
	if [ "$managed" = "1" ]; then rec=$(st_recommended "$key" "$gval" "$lval"); else rec="default"; fi
	state=$(st_param_state "$cat" "$key" "$typ" "$cur" "$rec" "$managed")
	case "$state" in
		applied)
			applied=$((applied + 1)); desired=$((desired + 1))
			eval "CA_$cat=\$((CA_$cat + 1)); CT_$cat=\$((CT_$cat + 1))" ;;
		pending|unavailable)
			desired=$((desired + 1)); eval "CT_$cat=\$((CT_$cat + 1))" ;;
		match)
			eval "CM_$cat=\$((CM_$cat + 1))" ;;
	esac
	[ "$first" -eq 1 ] || printf ','
	first=0
	printf '{"cat":"%s","key":"%s","type":"%s","cur":"%s","rec":"%s","state":"%s","managed":%s}' \
		"$cat" "$(js "$key")" "$typ" "$(js "$cur")" "$(js "$rec")" "$state" "$managed"
done <<EOF
$(st_registry)
EOF
printf ']'

# --- категории ---
printf ',"categories":{'
first=1
while IFS='|' read -r cat kind requires; do
	[ -n "$cat" ] || continue
	eval "ap=\${CA_$cat}; tot=\${CT_$cat}; mt=\${CM_$cat}"
	if st_cat_enabled "$cat"; then en=1; else en=0; fi
	[ "$first" -eq 1 ] || printf ','
	first=0
	printf '"%s":{"kind":"%s","requires":"%s","enabled":%s,"applied":%s,"total":%s,"match":%s}' \
		"$cat" "$kind" "$(js "$requires")" "$en" "$ap" "$tot" "$mt"
done <<EOF
$(st_catmeta)
EOF
printf '}'

# --- capabilities ---
printf ',"caps":{"bbr":%s,"irqbalance":%s,"hw_offload":%s,"bbr_version":"%s","bbr_ksize":"%s","wan":"%s"}' \
	"$(st_cap_bbr)" "$(st_cap_irqbalance)" "$(st_cap_hw_offload)" \
	"$(js "$(st_bbr_version)")" "$(js "$(st_bbr_ksize)")" "$(js "$(st_wan_iface)")"

# --- конфиг (профиль + тумблеры) ---
printf ',"config":{'
printf '"profile":"%s",' "$(st_profile)"
printf '"net_buffers":"%s",' "$(st_cfg net_buffers 1)"
printf '"low_latency":"%s",' "$(st_cfg low_latency 1)"
printf '"backlog":"%s",' "$(st_cfg backlog 1)"
printf '"congestion":"%s",' "$(st_cfg congestion 0)"
printf '"flow_offload":"%s",' "$(st_cfg flow_offload 1)"
printf '"flow_offload_hw":"%s",' "$(st_cfg flow_offload_hw 0)"
printf '"conntrack":"%s",' "$(st_cfg conntrack 1)"
printf '"irqbalance":"%s",' "$(st_cfg irqbalance 0)"
printf '"disable_ipv6":"%s",' "$(st_cfg disable_ipv6 0)"
printf '"mobile_lte":"%s",' "$(st_cfg mobile_lte 0)"
printf '"wan_iface":"%s",' "$(js "$(st_wan_iface)")"
printf '"hashsize":"%s"' "$(st_hashsize)"
printf '}'

# --- сводная оценка ---
printf ',"score":{"applied":%s,"total":%s}' "$applied" "$desired"

printf '}\n'
