#!/bin/sh
# streamtune — диагностика загрузки и системы -> JSON (для get_boot).
# SPDX-License-Identifier: GPL-2.0
#
# {"boot":{...из boot.awk...},"sys":{"cpus":N,"mem_total_kb":N,"mem_free_kb":N,
#  "conntrack_count":N,"conntrack_max":N}}
#
# Тесты: ST_DMESG_FILE (вместо `dmesg`), ST_PROC (корень /proc).
set -u
ST_SHARE="${ST_SHARE:-/usr/share/streamtune}"
ST_PROC="${ST_PROC:-/proc}"
. "$ST_SHARE/lib.sh"

printf '{"boot":'
if [ -n "${ST_DMESG_FILE:-}" ] && [ -f "$ST_DMESG_FILE" ]; then
	awk -f "$ST_SHARE/boot.awk" < "$ST_DMESG_FILE"
elif command -v dmesg >/dev/null 2>&1; then
	dmesg 2>/dev/null | awk -f "$ST_SHARE/boot.awk"
else
	printf '{"available":false,"total":0,"events":[]}'
fi

cpus=$(grep -c '^processor' "$ST_PROC/cpuinfo" 2>/dev/null); [ -n "$cpus" ] || cpus=0
mtot=$(awk '/^MemTotal:/{print $2}' "$ST_PROC/meminfo" 2>/dev/null); [ -n "$mtot" ] || mtot=0
mfree=$(awk '/^MemAvailable:/{print $2}' "$ST_PROC/meminfo" 2>/dev/null); [ -n "$mfree" ] || mfree=0
ctc=$(cat "$ST_PROC/sys/net/netfilter/nf_conntrack_count" 2>/dev/null); [ -n "$ctc" ] || ctc=0
ctm=$(cat "$ST_PROC/sys/net/netfilter/nf_conntrack_max" 2>/dev/null); [ -n "$ctm" ] || ctm=0

printf ',"sys":{"cpus":%s,"mem_total_kb":%s,"mem_free_kb":%s,"conntrack_count":%s,"conntrack_max":%s}}\n' \
	"$cpus" "$mtot" "$mfree" "$ctc" "$ctm"
