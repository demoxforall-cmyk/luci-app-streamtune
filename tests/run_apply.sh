#!/bin/sh
# streamtune — тесты применения (apply.sh): модель v2.3 (per-param drop-in,
# конкретные значения, запись оригиналов в state-файл, revert чистит state).
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh"
echo "== run_apply =="

TMP=$(mktemp -d 2>/dev/null || echo "/tmp/st_apply_$$"); mkdir -p "$TMP/sysctl.d"
DROPIN="$TMP/sysctl.d/99-streamtune.conf"; NFT="$TMP/mss.nft"; STATE="$TMP/state"

app() { # app <cfg> <caps>
	: > "$STATE"
	ST_SHARE="$SH_DIR" ST_PROC_ROOT="$PROC" ST_CFG_FILE="$FIX/$1" ST_CAPS_FILE="$FIX/$2" \
		ST_SYSFS_HASHSIZE="$FIX/hashsize.txt" ST_SYSCTL_D="$TMP/sysctl.d" ST_DROPIN="$DROPIN" \
		ST_NFT_MSS="$NFT" ST_STATE_FILE="$STATE" ST_WAN_IFACE=wwan ST_WAN_NETDEV=wwan0 ST_NO_APPLY=1 \
		sh "$SH_DIR/apply.sh" apply
}

# --- профиль lte_audio, BBR доступен ---
res=$(app cfg_lte.txt caps_bbr.txt)
body=$(cat "$DROPIN"); nft=$(cat "$NFT"); state=$(cat "$STATE")
echo "[lte_audio drop-in: конкретные значения]"
assert_has "$body" 'net.core.rmem_max = 4194304' "rmem_max 4M"
assert_has "$body" 'net.core.rmem_default = 262144' "rmem_default 262144 (был @default)"
assert_has "$body" 'net.core.optmem_max = 65536' "optmem_max 65536"
assert_has "$body" 'net.ipv4.tcp_rmem = 4096 131072 4194304' "tcp_rmem triple"
assert_has "$body" 'net.ipv4.tcp_tw_reuse = 1' "tw_reuse 1"
assert_has "$body" 'net.ipv4.tcp_fin_timeout = 15' "fin_timeout 15"
assert_has "$body" 'net.ipv4.tcp_max_syn_backlog = 8192' "syn_backlog 8192"
assert_has "$body" 'net.ipv4.tcp_max_tw_buckets = 65536' "tw_buckets 65536"
assert_has "$body" 'net.core.netdev_max_backlog = 5000' "netdev_max_backlog 5000"
assert_has "$body" 'net.core.netdev_budget = 600' "netdev_budget 600"
assert_not "$body" 'netdev_budget_usecs' "netdev_budget_usecs убран (ядро отвергает 4000)"
assert_has "$body" 'net.ipv4.tcp_slow_start_after_idle = 0' "slow_start 0"
assert_has "$body" 'net.ipv4.tcp_congestion_control = bbr' "bbr written"
assert_has "$body" 'net.core.default_qdisc = fq_codel' "fq_codel written"
assert_has "$body" 'net.ipv6.conf.all.disable_ipv6 = 1' "ipv6 disabled"
assert_has "$body" 'net.netfilter.nf_conntrack_tcp_timeout_established = 7440' "conntrack timeout"
assert_not "$body" '16777216' "нет 16M потолков"
assert_not "$body" '@default' "нет @default"

echo "[state-файл: оригиналы изменяемых]"
assert_has "$state" 'net.core.rmem_max	16777216' "orig rmem_max записан"
assert_has "$state" 'net.ipv4.tcp_max_tw_buckets	2000000' "orig tw_buckets записан"
assert_has "$state" 'net.ipv4.tcp_congestion_control	cubic' "orig cc записан"
# совпавшие (match) НЕ должны попадать в state
assert_not "$state" 'net.core.default_qdisc	' "fq_codel (match) не в state"

echo "[nft-MSS]"
assert_has "$nft" 'oifname "wwan0" tcp flags syn / fin,syn,rst tcp option maxseg size set rt mtu' "MSS outgoing"
assert_has "$nft" 'iifname "wwan0" tcp flags syn / fin,syn,rst tcp option maxseg size set rt mtu' "MSS incoming"
echo "[applied: ключи параметров]"
assert_has "$res" '"net.core.rmem_max"' "applied содержит rmem_max"
assert_has "$res" '"net.core.netdev_budget"' "applied содержит netdev_budget"
assert_has "$res" '"link.mss_clamp"' "applied содержит mss_clamp"

# --- per-param off: выключенный параметр НЕ в drop-in ---
DC="$TMP/cfg_off.txt"; printf 'profile=lte_audio\noff=net.core.netdev_budget\n' > "$DC"
: > "$STATE"
ST_SHARE="$SH_DIR" ST_PROC_ROOT="$PROC" ST_CFG_FILE="$DC" ST_CAPS_FILE="$FIX/caps_bbr.txt" \
	ST_SYSFS_HASHSIZE="$FIX/hashsize.txt" ST_SYSCTL_D="$TMP/sysctl.d" ST_DROPIN="$DROPIN" \
	ST_NFT_MSS="$NFT" ST_STATE_FILE="$STATE" ST_WAN_IFACE=wwan ST_WAN_NETDEV=wwan0 ST_NO_APPLY=1 \
	sh "$SH_DIR/apply.sh" apply >/dev/null
bodyx=$(cat "$DROPIN")
echo "[per-param off]"
assert_not "$bodyx" 'netdev_budget = ' "netdev_budget выключен -> не в drop-in"
assert_has "$bodyx" 'netdev_max_backlog = 5000' "netdev_max_backlog остаётся"

# --- идемпотентность drop-in ---
app cfg_lte.txt caps_bbr.txt >/dev/null; cp "$DROPIN" "$TMP/first.conf"; app cfg_lte.txt caps_bbr.txt >/dev/null
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
assert_has "$bodyh" 'net.ipv4.tcp_max_tw_buckets = 65536' "tw_buckets 65536 (home)"

# --- revert удаляет drop-in, nft и чистит state ---
app cfg_lte.txt caps_bbr.txt >/dev/null   # наполнить state
ST_SHARE="$SH_DIR" ST_DROPIN="$DROPIN" ST_NFT_MSS="$NFT" ST_STATE_FILE="$STATE" ST_NO_APPLY=1 \
	sh "$SH_DIR/apply.sh" revert >/dev/null
echo "[revert]"
{ [ -f "$DROPIN" ] || [ -f "$NFT" ]; } && bad "revert removes drop-in + nft" || ok "revert removes drop-in + nft"
[ -f "$STATE" ] && bad "revert clears state-file" || ok "revert clears state-file"

rm -rf "$TMP"
[ "$T_FAIL" -eq 0 ] && echo "run_apply: PASS" || echo "run_apply: FAIL"
exit "$T_FAIL"
