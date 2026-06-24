#!/bin/sh
# StreamTune — просмотр содержимого собранного .apk и проверка ключевых файлов.
# Использование: ./inspect-apk.sh <путь к .apk>
set -u
APK="${1:?укажите путь к .apk}"
[ -f "$APK" ] || { echo "нет файла: $APK"; exit 1; }

echo "== Содержимое $APK =="
# apk (gzip-tar) — пробуем оба варианта
LIST=$(tar -ztf "$APK" 2>/dev/null || tar -tf "$APK" 2>/dev/null)
echo "$LIST"

echo
echo "== Проверка ключевых файлов =="
for f in usr/libexec/rpcd/streamtune usr/share/streamtune/detect.sh \
         usr/share/streamtune/apply.sh usr/share/luci/menu.d/luci-app-streamtune.json \
         usr/share/rpcd/acl.d/luci-app-streamtune.json etc/init.d/streamtune \
         etc/config/streamtune usr/lib/lua/luci/i18n/streamtune.ru.lmo \
         www/luci-static/resources/view/streamtune/overview.js; do
	case "$LIST" in
		*"$f"*) echo "  ok:   $f" ;;
		*)      echo "  MISS: $f" ;;
	esac
done
