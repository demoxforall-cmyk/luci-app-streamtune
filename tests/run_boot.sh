#!/bin/sh
# streamtune — тесты парсера загрузки boot.awk.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh"
echo "== run_boot =="

out=$(awk -f "$SH_DIR/boot.awk" < "$FIX/dmesg/dmesg_sample.txt")
assert_has "$out" '"available":true' "boot available"
assert_has "$out" '"total":13.00' "total time 13s"
assert_has "$out" '"label":"Kernel start"' "kernel start event"
assert_has "$out" '"label":"Userspace start"' "userspace event"
assert_has "$out" '"label":"Network link ready"' "network event"

# пустой/без таймстампов вход -> available:false
empty=$(printf 'no timestamps here\n' | awk -f "$SH_DIR/boot.awk")
assert_has "$empty" '"available":false' "no timestamps -> unavailable"

[ "$T_FAIL" -eq 0 ] && echo "run_boot: PASS" || echo "run_boot: FAIL"
exit "$T_FAIL"
