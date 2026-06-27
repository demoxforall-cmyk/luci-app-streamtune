#!/bin/sh
# streamtune — тесты детекта статуса (detect.sh) на фикстурах /proc, профили v2.0.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh"
echo "== run_detect =="

det() { # det <cfg> <caps> [extra env...]
	_cfg="$1"; _caps="$2"; shift 2
	ST_SHARE="$SH_DIR" ST_PROC_ROOT="$PROC" ST_CFG_FILE="$FIX/$_cfg" ST_CAPS_FILE="$FIX/$_caps" \
		ST_SYSFS_HASHSIZE="$FIX/hashsize.txt" ST_NET_FILE="$FIX/net_default.txt" \
		ST_WAN_IFACE=wwan ST_WAN_NETDEV=wwan0 ST_NFT_MSS="$FIX/_nomss" "$@" sh "$SH_DIR/detect.sh"
}

# --- профиль lte_audio (BBR доступен) ---
out=$(det cfg_lte.txt caps_bbr.txt env ST_BBR_KSIZE=13856)
echo "[lte_audio]"
assert_has "$out" '"profile":"lte_audio"' "profile lte_audio"
assert_has "$out" '"key":"net.core.rmem_max","type":"sysctl","cur":"16777216","rec":"4194304","state":"pending"' "rmem_max -> 4M"
assert_has "$out" '"key":"net.core.rmem_default","type":"sysctl","cur":"16777216","rec":"default","state":"unmanaged","managed":0' "rmem_default @default"
assert_has "$out" '"key":"net.ipv4.tcp_max_tw_buckets","type":"sysctl","cur":"2000000","rec":"default","state":"unmanaged"' "tw_buckets @default"
assert_has "$out" '"key":"net.core.default_qdisc","type":"sysctl","cur":"fq_codel","rec":"fq_codel","state":"applied"' "default_qdisc fq_codel applied"
assert_has "$out" '"key":"net.ipv4.tcp_congestion_control","type":"sysctl","cur":"cubic","rec":"bbr","state":"pending"' "bbr pending"
assert_has "$out" '"key":"net.ipv6.conf.all.disable_ipv6","type":"sysctl","cur":"0","rec":"1","state":"pending"' "disable_ipv6 pending"
assert_has "$out" '"key":"nf_conntrack.tcp_established","type":"sysctl","cur":"432000","rec":"7440","state":"pending"' "conntrack timeout 7440"
assert_has "$out" '"key":"link.mtu","type":"mtu","cur":"1500","rec":"auto","state":"pending"' "MTU auto pending"
assert_has "$out" '"bbr_version":"1"' "BBR v1 by size"

# --- профиль home_wired (значения те же) ---
outh=$(det cfg_home.txt caps_bbr.txt env ST_BBR_KSIZE=13856)
echo "[home_wired]"
assert_has "$outh" '"profile":"home_wired"' "profile home_wired"
assert_has "$outh" '"key":"net.core.rmem_max","type":"sysctl","cur":"16777216","rec":"4194304"' "rmem_max 4M (same)"
assert_has "$outh" '"key":"net.core.default_qdisc","type":"sysctl","cur":"fq_codel","rec":"fq_codel","state":"applied"' "fq_codel (same)"

# --- BBR недоступен: congestion -> unavailable, но fq_codel остаётся applied ---
outn=$(det cfg_lte.txt caps_default.txt)
echo "[no bbr]"
assert_has "$outn" '"key":"net.ipv4.tcp_congestion_control","type":"sysctl","cur":"cubic","rec":"bbr","state":"unavailable"' "cc unavailable without bbr"
assert_has "$outn" '"key":"net.core.default_qdisc","type":"sysctl","cur":"fq_codel","rec":"fq_codel","state":"applied"' "fq_codel still applied (decoupled)"

# --- MTU override (ручное число вместо auto) ---
TMPC=$(mktemp 2>/dev/null || echo "/tmp/st_cfgm_$$"); cp "$FIX/cfg_lte.txt" "$TMPC"; echo "mtu=1430" >> "$TMPC"
outm=$(ST_SHARE="$SH_DIR" ST_PROC_ROOT="$PROC" ST_CFG_FILE="$TMPC" ST_CAPS_FILE="$FIX/caps_bbr.txt" \
	ST_SYSFS_HASHSIZE="$FIX/hashsize.txt" ST_NET_FILE="$FIX/net_default.txt" \
	ST_WAN_IFACE=wwan ST_WAN_NETDEV=wwan0 ST_NFT_MSS="$FIX/_nomss" sh "$SH_DIR/detect.sh")
echo "[mtu override]"
assert_has "$outm" '"key":"link.mtu","type":"mtu","cur":"1500","rec":"1430","state":"pending"' "MTU override -> rec=1430"
rm -f "$TMPC"

[ "$T_FAIL" -eq 0 ] && echo "run_detect: PASS" || echo "run_detect: FAIL"
exit "$T_FAIL"
