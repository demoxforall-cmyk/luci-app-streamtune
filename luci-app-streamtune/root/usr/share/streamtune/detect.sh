#!/bin/sh
# streamtune — детект текущего состояния всех параметров -> JSON.
# SPDX-License-Identifier: GPL-2.0
#
# JSON собирается вручную (без jshn) — скрипт автономен и тестируется на любой
# POSIX-оболочке. Модель per-param: у каждого параметра свой тумблер (enabled)
# и один из 3 статусов (applied|match|off; edge — unavailable). Процент
# соответствия = (applied + match) / (всё, кроме unavailable).
set -u
ST_SHARE="${ST_SHARE:-/usr/share/streamtune}"
. "$ST_SHARE/lib.sh"

js() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

good=0; total=0
for cat in $(st_categories); do eval "CA_$cat=0; CM_$cat=0; CO_$cat=0; CE_$cat=0; CN_$cat=0"; done

printf '{'
printf '"params":['
first=1
while IFS='|' read -r cat key typ target gval lval; do
	[ -n "$cat" ] || continue
	cur=$(st_read_current "$typ" "$target")
	rec=$(st_recommended "$key" "$gval" "$lval")
	state=$(st_param_state "$cat" "$key" "$typ" "$cur" "$rec")
	if st_param_enabled "$key"; then en=1; else en=0; fi
	eval "CN_$cat=\$((CN_$cat + 1))"
	[ "$en" = "1" ] && eval "CE_$cat=\$((CE_$cat + 1))"
	case "$state" in
		applied) good=$((good + 1)); total=$((total + 1)); eval "CA_$cat=\$((CA_$cat + 1))" ;;
		match)   good=$((good + 1)); total=$((total + 1)); eval "CM_$cat=\$((CM_$cat + 1))" ;;
		off)     total=$((total + 1)); eval "CO_$cat=\$((CO_$cat + 1))" ;;
		# unavailable — в процент не входит
	esac
	[ "$first" -eq 1 ] || printf ','
	first=0
	printf '{"cat":"%s","key":"%s","type":"%s","cur":"%s","rec":"%s","state":"%s","enabled":%s}' \
		"$cat" "$(js "$key")" "$typ" "$(js "$cur")" "$(js "$rec")" "$state" "$en"
done <<EOF
$(st_registry)
EOF
printf ']'

# --- категории (для шапок карточек: счётчики + мастер-тумблер) ---
printf ',"categories":{'
first=1
while IFS='|' read -r cat kind requires; do
	[ -n "$cat" ] || continue
	eval "ap=\${CA_$cat}; mt=\${CM_$cat}; of=\${CO_$cat}; en=\${CE_$cat}; nn=\${CN_$cat}"
	[ "$first" -eq 1 ] || printf ','
	first=0
	printf '"%s":{"kind":"%s","requires":"%s","count":%s,"enabled":%s,"applied":%s,"match":%s,"off":%s}' \
		"$cat" "$kind" "$(js "$requires")" "$nn" "$en" "$ap" "$mt" "$of"
done <<EOF
$(st_catmeta)
EOF
printf '}'

# --- capabilities ---
printf ',"caps":{"bbr":%s,"irqbalance":%s,"hw_offload":%s,"bbr_version":"%s","bbr_ksize":"%s","wan":"%s"}' \
	"$(st_cap_bbr)" "$(st_cap_irqbalance)" "$(st_cap_hw_offload)" \
	"$(js "$(st_bbr_version)")" "$(js "$(st_bbr_ksize)")" "$(js "$(st_wan_iface)")"

# --- конфиг (профиль + WAN + MTU) ---
printf ',"config":{'
printf '"profile":"%s",' "$(st_profile)"
printf '"wan_iface":"%s",' "$(js "$(st_wan_iface)")"
printf '"wan_netdev":"%s",' "$(js "$(st_wan_netdev)")"
printf '"mtu":"%s",' "$(js "$(st_cfg mtu auto)")"
printf '"mtu_resolved":"%s",' "$(js "$(st_cfg mtu_resolved "")")"
printf '"hashsize":"%s"' "$(st_hashsize)"
printf '}'

# --- сводная оценка: good = applied + match ---
printf ',"score":{"good":%s,"total":%s}' "$good" "$total"

printf '}\n'
