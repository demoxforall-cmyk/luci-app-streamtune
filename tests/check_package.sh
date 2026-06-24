#!/bin/sh
# streamtune — проверка целостности пакета: наличие файлов + синтаксис sh/awk.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh"
echo "== check_package =="
PKG="$ROOT_T/luci-app-streamtune"

FILES="
Makefile
htdocs/luci-static/resources/streamtune.js
htdocs/luci-static/resources/view/streamtune/overview.js
htdocs/luci-static/resources/view/streamtune/diagnostics.js
htdocs/luci-static/resources/view/streamtune/streamtune.css
root/usr/libexec/rpcd/streamtune
root/usr/share/streamtune/lib.sh
root/usr/share/streamtune/detect.sh
root/usr/share/streamtune/apply.sh
root/usr/share/streamtune/boot.sh
root/usr/share/streamtune/boot.awk
root/usr/share/luci/menu.d/luci-app-streamtune.json
root/usr/share/rpcd/acl.d/luci-app-streamtune.json
root/etc/init.d/streamtune
root/etc/config/streamtune
root/etc/uci-defaults/80-streamtune-init
root/etc/uci-defaults/99-streamtune-lang
translations/streamtune.ru.po
"
for f in $FILES; do
	[ -f "$PKG/$f" ] && ok "exists: $f" || bad "missing: $f"
done

echo "[shell syntax]"
for s in root/usr/libexec/rpcd/streamtune root/usr/share/streamtune/lib.sh \
         root/usr/share/streamtune/detect.sh root/usr/share/streamtune/apply.sh \
         root/usr/share/streamtune/boot.sh root/etc/init.d/streamtune \
         root/etc/uci-defaults/80-streamtune-init root/etc/uci-defaults/99-streamtune-lang; do
	if sh -n "$PKG/$s" 2>/dev/null; then ok "sh -n: $s"; else bad "sh -n: $s"; fi
done

echo "[awk syntax]"
if awk -f "$PKG/root/usr/share/streamtune/boot.awk" </dev/null >/dev/null 2>&1; then
	ok "awk -f boot.awk"; else bad "awk -f boot.awk"; fi

[ "$T_FAIL" -eq 0 ] && echo "check_package: PASS" || echo "check_package: FAIL"
exit "$T_FAIL"
