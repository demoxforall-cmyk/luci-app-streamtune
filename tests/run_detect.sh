#!/bin/sh
# streamtune — тесты детекта статуса (detect.sh): модель v2.3 (3 статуса, конкретные
# значения, per-param enabled, state-файл отличает applied от matches).
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh"
echo "== run_detect =="

STATE=$(mktemp 2>/dev/null || echo "/tmp/st_state_$$"); : > "$STATE"

det() { # det <cfg> <caps> [extra env...]
	_cfg="$1"; _caps="$2"; shift 2
	ST_SHARE="$SH_DIR" ST_PROC_ROOT="$PROC" ST_CFG_FILE="$_cfg" ST_CAPS_FILE="$FIX/$_caps" \
		ST_SYSFS_HASHSIZE="$FIX/hashsize.txt" ST_NET_FILE="$FIX/net_default.txt" ST_STATE_FILE="$STATE" \
		ST_WAN_IFACE=wwan ST_WAN_NETDEV=wwan0 ST_NFT_MSS="$FIX/_nomss" "$@" sh "$SH_DIR/detect.sh"
}

# --- профиль lte_audio (BBR доступен), state пуст ---
: > "$STATE"
out=$(det "$FIX/cfg_lte.txt" caps_bbr.txt env ST_BBR_KSIZE=13856)
echo "[lte_audio]"
assert_has "$out" '"profile":"lte_audio"' "profile lte_audio"
assert_has "$out" '"key":"net.core.rmem_max","type":"sysctl","cur":"16777216","rec":"4194304","state":"off","enabled":1' "rmem_max -> 4M, off"
assert_has "$out" '"key":"net.core.rmem_default","type":"sysctl","cur":"16777216","rec":"262144"' "rmem_default -> 262144 (был @default)"
assert_has "$out" '"key":"net.ipv4.tcp_max_tw_buckets","type":"sysctl","cur":"2000000","rec":"65536"' "tw_buckets -> 65536"
assert_has "$out" '"key":"net.core.netdev_budget_usecs","type":"sysctl","cur":"","rec":"4000","state":"off","enabled":1' "netdev_budget_usecs -> 4000 (новый)"
assert_has "$out" '"key":"net.ipv4.tcp_tw_reuse","type":"sysctl","cur":"1","rec":"1","state":"match"' "tw_reuse=1 matches"
assert_has "$out" '"key":"net.core.default_qdisc","type":"sysctl","cur":"fq_codel","rec":"fq_codel","state":"match"' "fq_codel matches"
assert_has "$out" '"key":"net.ipv4.tcp_congestion_control","type":"sysctl","cur":"cubic","rec":"bbr","state":"off"' "bbr off"
assert_has "$out" '"key":"net.ipv6.conf.all.disable_ipv6","type":"sysctl","cur":"0","rec":"1","state":"off"' "disable_ipv6 off"
assert_has "$out" '"key":"firewall.flow_offloading","type":"firewall","cur":"0","rec":"0","state":"match"' "flow_offload рекомендован 0 -> match"
assert_has "$out" '"key":"nf_conntrack.tcp_established","type":"sysctl","cur":"432000","rec":"7440","state":"off"' "conntrack timeout 7440"
assert_has "$out" '"key":"link.mtu","type":"mtu","cur":"1500","rec":"auto"' "MTU auto (не пробит)"
assert_has "$out" '"bbr_version":"1"' "BBR v1 by size"
assert_has "$out" '"score":{"good":' "score.good present"
# в модели v2.3 не должно быть старых статусов
assert_not "$out" '"state":"pending"' "нет статуса pending"
assert_not "$out" '"state":"unmanaged"' "нет статуса unmanaged"
assert_not "$out" '@default' "нет @default"

# --- applied: state-файл содержит совпавший параметр => applied (не match) ---
printf 'net.core.default_qdisc\tcubic\n' > "$STATE"
outa=$(det "$FIX/cfg_lte.txt" caps_bbr.txt env ST_BBR_KSIZE=13856)
echo "[applied via state]"
assert_has "$outa" '"key":"net.core.default_qdisc","type":"sysctl","cur":"fq_codel","rec":"fq_codel","state":"applied"' "default_qdisc applied (в state)"
: > "$STATE"

# --- per-param off: выключенный параметр enabled=0 ---
DC=$(mktemp 2>/dev/null || echo "/tmp/st_dc_$$"); printf 'profile=lte_audio\noff=net.core.netdev_budget\n' > "$DC"
outo=$(det "$DC" caps_bbr.txt env ST_BBR_KSIZE=13856)
echo "[per-param off]"
assert_has "$outo" '"key":"net.core.netdev_budget","type":"sysctl","cur":"50000","rec":"600","state":"off","enabled":0' "netdev_budget enabled=0"
assert_has "$outo" '"key":"net.core.netdev_max_backlog","type":"sysctl","cur":"100000","rec":"5000","state":"off","enabled":1' "соседний netdev_max_backlog enabled=1"
rm -f "$DC"

# --- профиль home_wired (значения те же) ---
outh=$(det "$FIX/cfg_home.txt" caps_bbr.txt env ST_BBR_KSIZE=13856)
echo "[home_wired]"
assert_has "$outh" '"profile":"home_wired"' "profile home_wired"
assert_has "$outh" '"key":"net.core.rmem_max","type":"sysctl","cur":"16777216","rec":"4194304"' "rmem_max 4M (same)"
assert_has "$outh" '"key":"net.ipv4.tcp_max_tw_buckets","type":"sysctl","cur":"2000000","rec":"65536"' "tw_buckets 65536 (same)"

# --- BBR недоступен: congestion -> unavailable, fq_codel остаётся match ---
outn=$(det "$FIX/cfg_lte.txt" caps_default.txt)
echo "[no bbr]"
assert_has "$outn" '"key":"net.ipv4.tcp_congestion_control","type":"sysctl","cur":"cubic","rec":"bbr","state":"unavailable"' "cc unavailable without bbr"
assert_has "$outn" '"key":"net.core.default_qdisc","type":"sysctl","cur":"fq_codel","rec":"fq_codel","state":"match"' "fq_codel matches (decoupled)"

# --- MTU override (ручное число вместо auto) ---
TMPC=$(mktemp 2>/dev/null || echo "/tmp/st_cfgm_$$"); cp "$FIX/cfg_lte.txt" "$TMPC"; echo "mtu=1430" >> "$TMPC"
outm=$(det "$TMPC" caps_bbr.txt env ST_BBR_KSIZE=13856)
echo "[mtu override]"
assert_has "$outm" '"key":"link.mtu","type":"mtu","cur":"1500","rec":"1430","state":"off"' "MTU override -> rec=1430"
rm -f "$TMPC" "$STATE"

[ "$T_FAIL" -eq 0 ] && echo "run_detect: PASS" || echo "run_detect: FAIL"
exit "$T_FAIL"
