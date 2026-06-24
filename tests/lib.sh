# shellcheck shell=sh
# streamtune tests — общие переменные путей и ассерты.
HERE_T=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_T=$(CDPATH= cd -- "$HERE_T/.." && pwd)
SH_DIR="$ROOT_T/luci-app-streamtune/root/usr/share/streamtune"
FIX="$HERE_T/fixtures"
PROC="$FIX/proc"

T_FAIL=0
ok()   { echo "  ok:   $1"; }
bad()  { echo "  FAIL: $1"; T_FAIL=1; }
assert_has()  { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 (missing: $2)" ;; esac; }
assert_not()  { case "$1" in *"$2"*) bad "$3 (unexpected: $2)" ;; *) ok "$3" ;; esac; }
