#!/bin/sh
# streamtune — тесты применения (apply.sh): drop-in + nft-MSS, профили v2.0.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh"
echo "== run_apply =="

TMP=$(mktemp -d 2>/dev/null || echo "/tmp/st_apply_$$"); mkdir -p "$TMP/sysctl.d"
DROPIN="$TMP/sysctl.d/99-streamtune.conf"; NFT="$TMP/mss.nft"

app() { # app <cfg> <caps>
	ST_SHARE="$SH_DIR" ST_PROC_ROOT="$PROC" ST_CFG_FILE="$FIX/$1" ST_CAPS_FILE="$FIX/$2" \
		ST_SYSFS_HASHSIZE="$FIX/hashsize.txt" ST_SYSCTL_D="$TMP/sysctl.d" ST_DROPIN="$DROPIN" \
		ST_NFT_MSS="$NFT" ST_WAN_IFACE=wwan ST_WAN_NETDEV=wwan0 ST_NO_APPLY=1 \
		sh "$SH_DIR/apply.sh" apply
}

# --- профиль lte_audio, BBR доступен ---
res=$(app cfg_lte.txt caps_bbr.txt)
body=$(cat "$DROPIN"); nft=$(cat "$NFT")
echo "[lte_audio drop-in]"
assert_has "$body" 'net.core.rmem_max = 4194304' "rmem_max 4M"
assert_has "$body" 'net.ipv4.udp_rmem_min = 8192' "udp_rmem_min 8192"
assert_has "$body" 'net.ipv4.tcp_slow_start_after_idle = 0' "slow_start 0"
assert_has "$body" 'net.ipv4.tcp_congestion_control = bbr' "bbr written"
assert_has "$body" 'net.core.default_qdisc = fq_codel' "fq_codel written"
assert_has "$body" 'net.ipv6.conf.all.disable_ipv6 = 1' "ipv6 disabled"
assert_has "$body" 'net.netfilter.nf_conntrack_tcp_timeout_established = 7440' "conntrack timeout"
assert_not "$body" 'rmem_default' "rmem_default @default (skipped)"
assert_not "$body" 'tcp_max_tw_buckets' "tw_buckets @default (skipped)"
assert_not "$body" 'netdev_max_backlog' "netdev @default (skipped)"
assert_not "$body" '16777216' "no 16M ceilings"
echo "[lte_audio nft-MSS]"
assert_has "$nft" 'oifname "wwan0" tcp flags syn / fin,syn,rst tcp option maxseg size set rt mtu' "MSS outgoing"
assert_has "$nft" 'iifname "wwan0" tcp flags syn / fin,syn,rst tcp option maxseg size set rt mtu' "MSS incoming"
assert_has "$res" '"applied":["net_buffers","low_latency","congestion","conntrack","mobile_lte","disable_ipv6"]' "applied set"

# --- идемпотентность ---
cp "$DROPIN" "$TMP/first.conf"; app cfg_lte.txt caps_bbr.txt >/dev/null
if cmp -s "$TMP/first.conf" "$DROPIN"; then ok "idempotent drop-in"; else bad "idempotent"; fi

# --- BBR недоступен: fq_codel есть, tcp_congestion_control нет ---
app cfg_lte.txt caps_default.txt >/dev/null
bodyn=$(cat "$DROPIN")
echo "[no bbr]"
assert_has "$bodyn" 'net.core.default_qdisc = fq_codel' "fq_codel applied without bbr"
assert_not "$bodyn" 'tcp_congestion_control' "bbr skipped (key-specific)"

# --- home_wired: значения те же ---
app cfg_home.txt caps_bbr.txt >/dev/null
bodyh=$(cat "$DROPIN")
echo "[home_wired]"
assert_has "$bodyh" 'net.core.rmem_max = 4194304' "rmem_max 4M (home)"
assert_has "$bodyh" 'net.core.default_qdisc = fq_codel' "fq_codel (home)"

# --- revert удаляет drop-in и nft ---
ST_SHARE="$SH_DIR" ST_DROPIN="$DROPIN" ST_NFT_MSS="$NFT" ST_NO_APPLY=1 sh "$SH_DIR/apply.sh" revert >/dev/null
{ [ -f "$DROPIN" ] || [ -f "$NFT" ]; } && bad "revert removes files" || ok "revert removes drop-in + nft"

rm -rf "$TMP"
[ "$T_FAIL" -eq 0 ] && echo "run_apply: PASS" || echo "run_apply: FAIL"
exit "$T_FAIL"
