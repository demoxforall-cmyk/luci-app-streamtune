#!/bin/sh
# StreamTune — сборка пакета в распакованном ImmortalWRT SDK 25.12.
# Пакет архитектурно-независим (LUCI_PKGARCH:=all) -> подходит SDK ЛЮБОГО target
# для 25.12 (например, mediatek/filogic для Banana Pi R4).
#
# Использование: ./build-in-sdk.sh /путь/к/распакованному/immortalwrt-sdk-25.12...
set -eu
SDK="${1:?укажите путь к распакованному SDK: ./build-in-sdk.sh <SDK_DIR>}"
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_SRC="$HERE/../luci-app-streamtune"
PKG=luci-app-streamtune

[ -f "$SDK/scripts/feeds" ] || { echo "Не похоже на SDK: нет $SDK/scripts/feeds"; exit 1; }

echo "[1/6] Копирую пакет в $SDK/package/$PKG"
rm -rf "$SDK/package/$PKG"
cp -r "$PKG_SRC" "$SDK/package/$PKG"

echo "[2/6] Нормализую переводы строк (CRLF->LF) и выставляю бит исполнения"
find "$SDK/package/$PKG" -type f ! -name '*.lmo' -exec sed -i 's/\r$//' {} + 2>/dev/null || true
chmod 0755 "$SDK/package/$PKG/root/usr/libexec/rpcd/streamtune" \
           "$SDK/package/$PKG/root/etc/init.d/streamtune"

echo "[3/6] feeds update/install (luci)"
cd "$SDK"
./scripts/feeds update -a >/dev/null
./scripts/feeds install -a >/dev/null

echo "[4/6] Вшиваю русский перевод (po2lmo -> root/usr/lib/lua/luci/i18n/)"
PO="$SDK/package/$PKG/translations/streamtune.ru.po"
P2L="$SDK/staging_dir/hostpkg/bin/po2lmo"
if [ -f "$PO" ] && [ -x "$P2L" ]; then
	mkdir -p "$SDK/package/$PKG/root/usr/lib/lua/luci/i18n"
	"$P2L" "$PO" "$SDK/package/$PKG/root/usr/lib/lua/luci/i18n/streamtune.ru.lmo" \
		&& echo "    перевод RU вшит: streamtune.ru.lmo"
else
	echo "    po2lmo ещё не собран — пакет соберётся без RU (.lmo добавится при повторной сборке)"
fi

echo "[5/6] defconfig + сборка пакета"
make defconfig >/dev/null
grep -q "^CONFIG_PACKAGE_$PKG=" .config || echo "CONFIG_PACKAGE_$PKG=m" >> .config
make "package/$PKG/compile" V=s

echo "[6/6] Готовый пакет:"
find "$SDK/bin" -name "$PKG*" \( -name '*.apk' -o -name '*.ipk' \) -print
