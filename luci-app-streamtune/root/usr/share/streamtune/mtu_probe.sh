#!/bin/sh
# streamtune — определение path MTU (DF-проба / tracepath). Выводит JSON:
#   {"mtu":N,"mss":N,"method":"tracepath|ping|iface","wan":"<netdev>"}
# SPDX-License-Identifier: GPL-2.0
# BusyBox ping не умеет -M do (DF), поэтому: tracepath -> iputils ping -> iface.
set -u
ST_SHARE="${ST_SHARE:-/usr/share/streamtune}"
. "$ST_SHARE/lib.sh"

HOSTS="${ST_PROBE_HOSTS:-1.1.1.1 8.8.8.8}"
LO=1280; HI=1500
ND=$(st_wan_netdev)
BIND=""; [ -n "$ND" ] && BIND="-I $ND"

have() { command -v "$1" >/dev/null 2>&1; }
ping_df_ok() { ping -M do -s 100 -c1 -W1 127.0.0.1 >/dev/null 2>&1; }

probe_host() {   # echo path MTU к $1
	_h="$1"
	if have tracepath; then
		tracepath -n -m "$HI" $BIND "$_h" 2>/dev/null | sed -n 's/.*pmtu \([0-9][0-9]*\).*/\1/p' | tail -1
		return
	fi
	if ping_df_ok; then
		_lo=$LO; _hi=$HI; _best=$LO
		while [ "$_lo" -le "$_hi" ]; do
			_mid=$(( (_lo + _hi) / 2 ))
			if ping -M do -s $(( _mid - 28 )) -c1 -W2 $BIND "$_h" >/dev/null 2>&1; then
				_best=$_mid; _lo=$(( _mid + 1 ))
			else _hi=$(( _mid - 1 )); fi
		done
		echo "$_best"
	fi
}

method="iface"; best=0
if have tracepath; then method="tracepath"; elif ping_df_ok; then method="ping"; fi

if [ "$method" != "iface" ]; then
	for h in $HOSTS; do
		m=$(probe_host "$h")
		[ -n "$m" ] || continue
		[ "$best" -eq 0 ] && best="$m"
		[ "$m" -lt "$best" ] 2>/dev/null && best="$m"
	done
fi

# fallback: текущий MTU интерфейса
if [ "$best" -eq 0 ] 2>/dev/null; then
	[ -n "$ND" ] && [ -r "/sys/class/net/$ND/mtu" ] && best=$(cat "/sys/class/net/$ND/mtu" 2>/dev/null)
	method="iface"
fi
[ -n "$best" ] && [ "$best" -gt 0 ] 2>/dev/null || best=0

mss=0; [ "$best" -gt 40 ] 2>/dev/null && mss=$(( best - 40 ))
printf '{"mtu":%s,"mss":%s,"method":"%s","wan":"%s"}\n' "$best" "$mss" "$method" "$ND"
