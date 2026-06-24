#!/bin/sh
# StreamTune — просмотр содержимого собранного .apk и проверка ключевых файлов.
# ImmortalWRT 25.12 использует apk-tools v3 (ADB-формат, НЕ gzip-tar), поэтому
# читаем через `apk adbdump`. Бинарь apk берём из SDK или из PATH.
# Использование: ./inspect-apk.sh <путь к .apk> [путь к SDK]
set -u
APK="${1:?укажите путь к .apk}"
SDK="${2:-$HOME/carmodem-build/sdk}"
[ -f "$APK" ] || { echo "нет файла: $APK"; exit 1; }

APKBIN=""
for c in "$SDK/staging_dir/host/bin/apk" "$SDK/staging_dir/hostpkg/bin/apk" "$(command -v apk 2>/dev/null)"; do
	[ -n "$c" ] && [ -x "$c" ] && { APKBIN="$c"; break; }
done

if [ -z "$APKBIN" ]; then
	echo "apk-бинарь не найден (SDK: $SDK). Список файлов недоступен; пробую tar:"
	tar -ztf "$APK" 2>/dev/null || tar -tf "$APK" 2>/dev/null || echo "  (apk v3 не читается tar)"
	exit 0
fi

DUMP=$("$APKBIN" adbdump "$APK" 2>/dev/null)

echo "== Метаданные =="
printf '%s\n' "$DUMP" | grep -iE "^  (name|version):|^    - (luci|kmod|irqbalance)" | head -12

echo
echo "== Проверка ключевых файлов =="
for f in streamtune detect.sh apply.sh boot.sh boot.awk lib.sh \
         luci-app-streamtune.json streamtune.ru.lmo \
         overview.js diagnostics.js streamtune.css streamtune.js; do
	n=$(printf '%s\n' "$DUMP" | grep -c "name: $f$")
	if [ "$n" -gt 0 ]; then echo "  ok:   $f (x$n)"; else echo "  MISS: $f"; fi
done
