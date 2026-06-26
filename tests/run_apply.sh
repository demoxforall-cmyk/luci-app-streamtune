#!/bin/sh
# streamtune — тесты применения (apply.sh): генерация sysctl drop-in + идемпотентность.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh"
echo "== run_apply =="

TMP=$(mktemp -d 2>/dev/null || echo "/tmp/st_apply_$$"); mkdir -p "$TMP/sysctl.d"
DROPIN="$TMP/sysctl.d/99-streamtune.conf"

# --- сценарий 1: безопасный профиль (без bbr, без ipv6) ---
res=$(ST_SHARE="$SH_DIR" ST_PROC_ROOT="$PROC" ST_CFG_FILE="$FIX/cfg_default.txt" \
	ST_CAPS_FILE="$FIX/caps_default.txt" ST_SYSFS_HASHSIZE="$FIX/hashsize.txt" \
	ST_SYSCTL_D="$TMP/sysctl.d" ST_DROPIN="$DROPIN" ST_NO_APPLY=1 \
	sh "$SH_DIR/apply.sh" apply)
body=$(cat "$DROPIN")

echo "[safe profile]"
assert_has "$res" '"ok":true' "apply ok"
assert_has "$body" 'net.core.rmem_max = 16777216' "rmem_max written"
assert_has "$body" 'net.ipv4.tcp_slow_start_after_idle = 0' "slow_start written"
assert_has "$body" 'net.ipv4.tcp_rmem = 4096 1048576 2097152' "tcp_rmem written"
assert_not "$body" 'tcp_congestion_control' "no bbr (unavailable)"
assert_not "$body" 'disable_ipv6' "no ipv6 (disabled)"
assert_not "$body" 'flow_offloading' "firewall not in sysctl drop-in"

# --- идемпотентность: второй прогон -> идентичный файл ---
cp "$DROPIN" "$TMP/first.conf"
ST_SHARE="$SH_DIR" ST_PROC_ROOT="$PROC" ST_CFG_FILE="$FIX/cfg_default.txt" \
	ST_CAPS_FILE="$FIX/caps_default.txt" ST_SYSFS_HASHSIZE="$FIX/hashsize.txt" \
	ST_SYSCTL_D="$TMP/sysctl.d" ST_DROPIN="$DROPIN" ST_NO_APPLY=1 \
	sh "$SH_DIR/apply.sh" apply >/dev/null
if cmp -s "$TMP/first.conf" "$DROPIN"; then ok "idempotent (identical drop-in)"; else bad "idempotent"; fi

# --- сценарий 2: всё включено + bbr/ipv6 доступны ---
res2=$(ST_SHARE="$SH_DIR" ST_PROC_ROOT="$PROC" ST_CFG_FILE="$FIX/cfg_all.txt" \
	ST_CAPS_FILE="$FIX/caps_bbr.txt" ST_SYSFS_HASHSIZE="$FIX/hashsize.txt" \
	ST_SYSCTL_D="$TMP/sysctl.d" ST_DROPIN="$DROPIN" ST_NO_APPLY=1 \
	sh "$SH_DIR/apply.sh" apply)
body2=$(cat "$DROPIN")

echo "[all-on, deps available]"
assert_has "$body2" 'net.ipv4.tcp_congestion_control = bbr' "bbr written"
assert_has "$body2" 'net.core.default_qdisc = fq' "fq qdisc written"
assert_has "$body2" 'net.ipv6.conf.all.disable_ipv6 = 1' "ipv6 disable written"
assert_has "$res2" '"applied":["net_buffers","low_latency","backlog","disable_ipv6","congestion","flow_offload","conntrack","irqbalance"]' "applied list complete"

# --- сценарий 3: профиль lte_audio -> выверенный drop-in ---
res3=$(ST_SHARE="$SH_DIR" ST_PROC_ROOT="$PROC" ST_CFG_FILE="$FIX/cfg_lte.txt" \
	ST_CAPS_FILE="$FIX/caps_bbr.txt" ST_SYSFS_HASHSIZE="$FIX/hashsize.txt" \
	ST_SYSCTL_D="$TMP/sysctl.d" ST_DROPIN="$DROPIN" ST_WAN_IFACE=wwan0 ST_NO_APPLY=1 \
	sh "$SH_DIR/apply.sh" apply)
body3=$(cat "$DROPIN")

echo "[lte_audio profile]"
assert_has "$body3" 'net.core.rmem_max = 4194304' "rmem_max 4M"
assert_has "$body3" 'net.ipv4.tcp_rmem = 4096 131072 4194304' "tcp_rmem retuned"
assert_has "$body3" 'net.core.default_qdisc = fq_codel' "fq_codel"
assert_has "$body3" 'net.ipv4.tcp_congestion_control = bbr' "bbr kept"
assert_has "$body3" 'net.netfilter.nf_conntrack_tcp_timeout_established = 7440' "conntrack timeout lever"
assert_not "$body3" 'rmem_default' "rmem_default dropped (@default)"
assert_not "$body3" 'tcp_max_tw_buckets' "tw_buckets dropped (@default)"
assert_not "$body3" 'netdev_max_backlog' "netdev dropped (backlog off)"
assert_not "$body3" '16777216' "no 16M server ceilings"
assert_has "$res3" '"applied":["net_buffers","low_latency","congestion","conntrack","mobile_lte"]' "applied set"

# --- revert удаляет drop-in ---
ST_SHARE="$SH_DIR" ST_DROPIN="$DROPIN" ST_NO_APPLY=1 sh "$SH_DIR/apply.sh" revert >/dev/null
[ -f "$DROPIN" ] && bad "revert removes drop-in" || ok "revert removes drop-in"

rm -rf "$TMP"
[ "$T_FAIL" -eq 0 ] && echo "run_apply: PASS" || echo "run_apply: FAIL"
exit "$T_FAIL"
