#!/bin/sh
# streamtune — тесты детекта статуса (detect.sh) на фикстурах /proc.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh"
echo "== run_detect =="

# --- сценарий 1: безопасный профиль, опц/риск выкл ---
out=$(ST_SHARE="$SH_DIR" ST_PROC_ROOT="$PROC" ST_CFG_FILE="$FIX/cfg_default.txt" \
	ST_FW_FILE="$FIX/fw_default.txt" ST_CAPS_FILE="$FIX/caps_default.txt" \
	ST_SYSFS_HASHSIZE="$FIX/hashsize.txt" sh "$SH_DIR/detect.sh")

echo "[safe profile]"
assert_has "$out" '"score":{"applied":16,"total":18}' "score 16/18"
assert_has "$out" '"key":"net.core.rmem_max","type":"sysctl","cur":"16777216","rec":"16777216","state":"applied"' "rmem_max applied"
assert_has "$out" '"key":"net.ipv4.tcp_rmem","type":"sysctl","cur":"4096 1048576 2097152","rec":"4096 1048576 2097152","state":"applied"' "tcp_rmem normalized+applied"
assert_has "$out" '"key":"nf_conntrack.hashsize","type":"sysfs","cur":"4096","rec":"16384","state":"pending"' "conntrack pending"
assert_has "$out" '"key":"firewall.flow_offloading","type":"firewall","cur":"0","rec":"1","state":"pending"' "flow offload pending"
assert_has "$out" '"cat":"congestion","key":"net.ipv4.tcp_congestion_control","type":"sysctl","cur":"cubic","rec":"bbr","state":"off"' "congestion off"
assert_has "$out" '"net_buffers":{"kind":"safe","requires":"","enabled":1,"applied":9,"total":9,"match":0}' "net_buffers 9/9"

# --- сценарий 2: всё включено, но bbr/irqbalance недоступны ---
out2=$(ST_SHARE="$SH_DIR" ST_PROC_ROOT="$PROC" ST_CFG_FILE="$FIX/cfg_all.txt" \
	ST_FW_FILE="$FIX/fw_default.txt" ST_CAPS_FILE="$FIX/caps_default.txt" \
	ST_SYSFS_HASHSIZE="$FIX/hashsize.txt" sh "$SH_DIR/detect.sh")

echo "[all-on, deps missing]"
assert_has "$out2" '"cat":"congestion","key":"net.ipv4.tcp_congestion_control","type":"sysctl","cur":"cubic","rec":"bbr","state":"unavailable"' "congestion unavailable (no bbr)"
assert_has "$out2" '"key":"service.irqbalance","type":"service","cur":"absent","rec":"running","state":"unavailable"' "irqbalance unavailable (absent)"
assert_has "$out2" '"key":"net.ipv6.conf.all.disable_ipv6","type":"sysctl","cur":"0","rec":"1","state":"pending"' "ipv6 disable pending"
assert_has "$out2" '"key":"firewall.flow_offloading_hw","type":"firewall","cur":"0","rec":"1","state":"pending"' "hw offload now desired"
assert_has "$out2" '"caps":{"bbr":0,"irqbalance":0,"hw_offload":2,' "caps reflect missing deps"

# --- сценарий 3: все категории выключены, но значения уже совпадают -> "match" ---
out3=$(ST_SHARE="$SH_DIR" ST_PROC_ROOT="$PROC" ST_CFG_FILE="$FIX/cfg_alloff.txt" \
	ST_FW_FILE="$FIX/fw_offload_on.txt" ST_CAPS_FILE="$FIX/caps_default.txt" \
	ST_SYSFS_HASHSIZE="$FIX/hashsize.txt" sh "$SH_DIR/detect.sh")

echo "[all-off, system already matches]"
assert_has "$out3" '"score":{"applied":0,"total":0}' "nothing desired -> score 0/0"
assert_has "$out3" '"cat":"net_buffers","key":"net.core.rmem_max","type":"sysctl","cur":"16777216","rec":"16777216","state":"match"' "rmem_max -> match (off but equal)"
assert_has "$out3" '"net_buffers":{"kind":"safe","requires":"","enabled":0,"applied":0,"total":0,"match":9}' "net_buffers 9 matching"
assert_has "$out3" '"key":"firewall.flow_offloading","type":"firewall","cur":"1","rec":"1","state":"match"' "flow offload already set -> match"
assert_has "$out3" '"cat":"congestion","key":"net.ipv4.tcp_congestion_control","type":"sysctl","cur":"cubic","rec":"bbr","state":"off"' "mismatch stays off"

# --- сценарий 4: профиль lte_audio (выверенные значения + @default + mobile_lte) ---
out4=$(ST_SHARE="$SH_DIR" ST_PROC_ROOT="$PROC" ST_CFG_FILE="$FIX/cfg_lte.txt" \
	ST_FW_FILE="$FIX/fw_lte.txt" ST_NET_FILE="$FIX/net_default.txt" \
	ST_CAPS_FILE="$FIX/caps_bbr.txt" ST_SYSFS_HASHSIZE="$FIX/hashsize.txt" \
	ST_WAN_IFACE=wwan0 ST_BBR_VERSION=3 sh "$SH_DIR/detect.sh")

echo "[lte_audio profile]"
assert_has "$out4" '"profile":"lte_audio"' "profile reported"
assert_has "$out4" '"key":"net.core.rmem_max","type":"sysctl","cur":"16777216","rec":"4194304","state":"pending"' "rmem_max -> 4M target"
assert_has "$out4" '"key":"net.core.rmem_default","type":"sysctl","cur":"16777216","rec":"default","state":"unmanaged","managed":0' "rmem_default unmanaged (@default)"
assert_has "$out4" '"key":"net.ipv4.tcp_max_tw_buckets","type":"sysctl","cur":"2000000","rec":"default","state":"unmanaged"' "tw_buckets unmanaged"
assert_has "$out4" '"key":"net.core.default_qdisc","type":"sysctl","cur":"fq_codel","rec":"fq_codel","state":"applied"' "default_qdisc -> fq_codel"
assert_has "$out4" '"key":"link.mtu","type":"mtu","cur":"1500","rec":"1430","state":"pending"' "MTU lever pending"
assert_has "$out4" '"key":"nf_conntrack.tcp_established","type":"sysctl","cur":"432000","rec":"7440","state":"pending"' "conntrack timeout lever"
assert_has "$out4" '"bbr_version":"3"' "BBR version surfaced"

# --- сценарий 5: версия BBR по размеру модуля (modinfo в OpenWRT вырезан) ---
mk_size() { ST_SHARE="$SH_DIR" ST_PROC_ROOT="$PROC" ST_CFG_FILE="$FIX/cfg_lte.txt" \
	ST_CAPS_FILE="$FIX/caps_bbr.txt" ST_SYSFS_HASHSIZE="$FIX/hashsize.txt" \
	ST_FW_FILE="$FIX/fw_lte.txt" ST_NET_FILE="$FIX/net_default.txt" ST_WAN_IFACE=wwan0 \
	ST_BBR_KSIZE="$1" sh "$SH_DIR/detect.sh"; }

echo "[bbr version by module size]"
assert_has "$(mk_size 15736)" '"bbr_version":"3","bbr_ksize":"15736"' "15736 B -> v3"
assert_has "$(mk_size 13856)" '"bbr_version":"1","bbr_ksize":"13856"' "13856 B -> v1"

[ "$T_FAIL" -eq 0 ] && echo "run_detect: PASS" || echo "run_detect: FAIL"
exit "$T_FAIL"
