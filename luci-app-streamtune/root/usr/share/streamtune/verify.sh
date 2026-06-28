#!/bin/sh
# streamtune — проверка применённого состояния + сканирование логов.
# SPDX-License-Identifier: GPL-2.0
# Запуск на роутере:  sh /usr/share/streamtune/verify.sh
. /usr/share/streamtune/lib.sh 2>/dev/null || { echo "lib.sh не найден"; exit 1; }

P=0; F=0; W=0
ck() { # ck "<label>" <0|1|2> "<detail>"
	case "$2" in
		0) printf '[ OK ] %s%s\n'   "$1" "${3:+ — $3}"; P=$((P+1)) ;;
		1) printf '[FAIL] %s%s\n'   "$1" "${3:+ — $3}"; F=$((F+1)) ;;
		2) printf '[WARN] %s%s\n'   "$1" "${3:+ — $3}"; W=$((W+1)) ;;
	esac
}
sv() { sysctl -n "$1" 2>/dev/null; }
eq() { [ "$(st_norm "$1")" = "$(st_norm "$2")" ]; }

echo "=========================================================="
echo " StreamTune verify — профиль: $(st_profile)"
echo "=========================================================="

echo "--- sysctl (drop-in: $ST_DROPIN) ---"
[ -f "$ST_DROPIN" ] && ck "drop-in присутствует" 0 || ck "drop-in отсутствует" 1 "$ST_DROPIN"

v=$(sv net.core.rmem_max);                 eq "$v" 4194304   && ck "rmem_max" 0 "$v"            || ck "rmem_max" 2 "$v (ожид. 4194304)"
v=$(sv net.core.default_qdisc);            eq "$v" fq_codel  && ck "default_qdisc" 0 "$v"       || ck "default_qdisc" 1 "$v (ожид. fq_codel)"
v=$(sv net.ipv4.tcp_slow_start_after_idle);eq "$v" 0         && ck "tcp_slow_start_after_idle" 0 "$v" || ck "tcp_slow_start_after_idle" 2 "$v"
v=$(sv net.ipv4.tcp_congestion_control)
avail=$(sv net.ipv4.tcp_available_congestion_control)
if echo "$avail" | grep -qw bbr; then
	eq "$v" bbr && ck "congestion control" 0 "bbr (доступен)" || ck "congestion control" 2 "$v (bbr доступен, но не активен)"
else
	ck "congestion control" 2 "$v — bbr НЕ установлен (kmod-tcp-bbr); fq_codel важнее"
fi
v=$(sv net.netfilter.nf_conntrack_tcp_timeout_established); eq "$v" 7440 && ck "conntrack established timeout" 0 "$v" || ck "conntrack established timeout" 2 "$v (ожид. 7440)"
v=$(sv net.ipv4.tcp_max_tw_buckets); eq "$v" 65536 && ck "tcp_max_tw_buckets" 0 "$v" || ck "tcp_max_tw_buckets" 2 "$v (ожид. 65536)"
v=$(sv net.core.netdev_budget); eq "$v" 600 && ck "netdev_budget" 0 "$v" || ck "netdev_budget" 2 "$v (ожид. 600)"

echo "--- BBR версия (по размеру модуля; modinfo вырезан) ---"
bv=$(st_bbr_version); bs=$(st_bbr_ksize)
[ -n "$bv" ] && ck "BBR версия" 0 "v$bv (tcp_bbr.ko=${bs:-?} B)" || ck "BBR версия" 2 "неизвестна (встроен в ядро или модуль отсутствует)"

echo "--- MSS-clamp (nftables) ---"
if nft list chain inet fw4 streamtune_mss >/dev/null 2>&1; then
	rc=$(nft list chain inet fw4 streamtune_mss 2>/dev/null | grep -c 'maxseg size set rt mtu')
	[ "${rc:-0}" -ge 2 ] && ck "nft MSS-clamp" 0 "правило загружено, $rc направл." || ck "nft MSS-clamp" 2 "правило есть, но направлений <2 ($rc)"
else
	ck "nft MSS-clamp" 1 "chain streamtune_mss не загружен (проверь $ST_NFT_MSS и fw4 reload)"
fi

echo "--- WAN / MTU ---"
nd=$(st_wan_netdev); li=$(st_wan_iface)
ck "WAN интерфейс" 0 "logical=$li netdev=${nd:-?}"
if [ -n "$nd" ] && [ -r "/sys/class/net/$nd/mtu" ]; then
	cur=$(cat "/sys/class/net/$nd/mtu"); res=$(st_cfg mtu_resolved "")
	if [ -n "$res" ]; then
		eq "$cur" "$res" && ck "MTU на WAN" 0 "$cur (= применённому)" || ck "MTU на WAN" 2 "$cur (применено $res — перезайди ifup?)"
	else ck "MTU на WAN" 2 "$cur (auto-MTU ещё не применён — нажми «Определить MTU»+Применить)"; fi
	cm=$(st_modem_mtu); [ -n "$cm" ] && echo "        carrier-MTU (mmcli): $cm"
else
	ck "MTU на WAN" 2 "netdev '$nd' без /sys/class/net (детект WAN?)"
fi

echo "--- IPv6 полностью выключен ---"
v=$(sv net.ipv6.conf.all.disable_ipv6); eq "$v" 1 && ck "stack disable_ipv6" 0 "$v" || ck "stack disable_ipv6" 1 "$v (ожид. 1)"
if pgrep -x odhcpd >/dev/null 2>&1; then ck "odhcpd остановлен" 1 "процесс запущен"; else ck "odhcpd остановлен" 0; fi
ula=$(uci -q get network.globals.ula_prefix); [ -z "$ula" ] && ck "ULA-префикс удалён" 0 || ck "ULA-префикс удалён" 2 "$ula"
if command -v ip >/dev/null 2>&1; then
	g6=$(ip -6 addr show scope global 2>/dev/null | grep -c 'inet6')
	[ "${g6:-0}" -eq 0 ] && ck "нет глобальных IPv6-адресов" 0 || ck "нет глобальных IPv6" 2 "$g6 шт."
fi

echo "--- flow offload (должен быть OFF) ---"
fo=$(uci -q get firewall.@defaults[0].flow_offloading); fh=$(uci -q get firewall.@defaults[0].flow_offloading_hw)
[ "${fo:-0}" = "1" ] && ck "SW flow offload" 2 "ON (ожид. off)" || ck "SW flow offload" 0 "off"
[ "${fh:-0}" = "1" ] && ck "HW flow offload" 1 "ON (несовм. с AQM/Podkop)" || ck "HW flow offload" 0 "off"

echo "--- conntrack ---"
hs=$(cat "$ST_SYSFS_HASHSIZE" 2>/dev/null); ck "conntrack hashsize" 0 "${hs:-?}"
cc=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null); cm2=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)
ck "conntrack записей" 0 "${cc:-?}/${cm2:-?}"

echo "--- память применённого (state-файл) ---"
if [ -f "$ST_STATE_FILE" ]; then
	n=$(grep -c . "$ST_STATE_FILE" 2>/dev/null)
	ck "state-файл" 0 "$ST_STATE_FILE — изменено параметров (Applied): ${n:-0}"
else
	ck "state-файл" 2 "нет $ST_STATE_FILE (через «Применить» ещё ничего не меняли, либо всё было Matches)"
fi

echo "--- логи (последние ошибки/предупреждения) ---"
if command -v logread >/dev/null 2>&1; then
	echo "  [firewall/fw4/nft/odhcpd]:"
	logread 2>/dev/null | grep -iE 'fw4|nftables|odhcpd|firewall' | grep -iE 'error|fail|warn|invalid' | tail -8 | sed 's/^/    /'
	echo "  [modem/mm/mhi/qmi]:"
	logread 2>/dev/null | grep -iE 'modem|modemmanager|mhi|qmi|wwan' | grep -iE 'error|fail|down|disconnect' | tail -8 | sed 's/^/    /'
	echo "  [streamtune]:"
	logread 2>/dev/null | grep -i streamtune | tail -5 | sed 's/^/    /'
else echo "  logread недоступен"; fi
echo "  [dmesg: bbr/mtk/mhi]:"
dmesg 2>/dev/null | grep -iE 'tcp_bbr|mtk|mhi|nf_conntrack' | tail -5 | sed 's/^/    /'

echo "=========================================================="
echo " Итог: OK=$P  WARN=$W  FAIL=$F"
[ "$F" -eq 0 ] && echo " Критичных проблем нет." || echo " Есть FAIL — см. выше."
echo "=========================================================="
exit "$F"
