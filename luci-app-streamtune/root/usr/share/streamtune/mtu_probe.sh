#!/bin/sh
# streamtune — определение path MTU. Выводит JSON:
#   {"mtu":N,"mss":N,"method":"ping|carrier|tracepath|iface","carrier":N,"wan":"<netdev>"}
# SPDX-License-Identifier: GPL-2.0
# Порядок: DF-ping (надёжно, устойчиво к фильтрации ICMP) -> tracepath(-m 12) ->
# затем берётся min с carrier-MTU оператора (mmcli). BusyBox ping не умеет DF.
set -u
ST_SHARE="${ST_SHARE:-/usr/share/streamtune}"
. "$ST_SHARE/lib.sh"

HOST="${ST_PROBE_HOST:-1.1.1.1}"
LO=1280; HI=1500
ND=$(st_wan_netdev)
BIND=""; [ -n "$ND" ] && BIND="-I $ND"

have() { command -v "$1" >/dev/null 2>&1; }
ping_df_ok() { ping -M do -s 56 -c1 -W1 127.0.0.1 >/dev/null 2>&1; }

carrier=$(st_modem_mtu 2>/dev/null)
case "$carrier" in ''|*[!0-9]*) carrier=0 ;; esac

measured=0; method=""

if ping_df_ok; then
	# бинарный поиск самого большого DF-пакета, который проходит
	method="ping"; _lo=$LO; _hi=$HI; _best=0
	while [ "$_lo" -le "$_hi" ]; do
		_mid=$(( (_lo + _hi) / 2 ))
		if ping -M do -s $(( _mid - 28 )) -c1 -W2 $BIND "$HOST" >/dev/null 2>&1; then
			_best=$_mid; _lo=$(( _mid + 1 ))
		else _hi=$(( _mid - 1 )); fi
	done
	measured=$_best
elif have tracepath; then
	method="tracepath"
	measured=$(tracepath -n -m 12 "$HOST" 2>/dev/null | sed -n 's/.*pmtu \([0-9][0-9]*\).*/\1/p' | tail -1)
	case "$measured" in ''|*[!0-9]*) measured=0 ;; esac
fi

# финал = min(measured, carrier); если нет ни того ни другого — MTU интерфейса
best=0
[ "$measured" -gt 0 ] 2>/dev/null && best=$measured
if [ "$carrier" -gt 0 ] 2>/dev/null; then
	if [ "$best" -eq 0 ] || [ "$carrier" -lt "$best" ] 2>/dev/null; then
		best=$carrier; [ -z "$method" ] && method="carrier"
	fi
fi
if [ "$best" -eq 0 ] 2>/dev/null; then
	[ -n "$ND" ] && [ -r "/sys/class/net/$ND/mtu" ] && best=$(cat "/sys/class/net/$ND/mtu" 2>/dev/null)
	method="iface"
fi
case "$best" in ''|*[!0-9]*) best=0 ;; esac
[ -z "$method" ] && method="iface"

mss=0; [ "$best" -gt 40 ] 2>/dev/null && mss=$(( best - 40 ))
printf '{"mtu":%s,"mss":%s,"method":"%s","carrier":%s,"wan":"%s"}\n' "$best" "$mss" "$method" "$carrier" "$ND"
