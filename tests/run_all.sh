#!/bin/sh
# streamtune — прогон всех тестов без железа. Запуск: sh tests/run_all.sh
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
rc=0
echo "============================================"
echo " StreamTune test suite"
echo "============================================"
sh "$HERE/run_detect.sh"   || rc=1; echo
sh "$HERE/run_apply.sh"    || rc=1; echo
sh "$HERE/run_boot.sh"     || rc=1; echo
sh "$HERE/check_package.sh" || rc=1; echo

if command -v deno >/dev/null 2>&1; then
	deno run --allow-read "$HERE/check_js.mjs" || rc=1
else
	echo "== check_js == SKIP (deno not found; run: deno run --allow-read tests/check_js.mjs)"
fi

echo "============================================"
[ "$rc" -eq 0 ] && echo " ALL TESTS PASSED" || echo " SOME TESTS FAILED"
echo "============================================"
exit "$rc"
