#!/usr/bin/env bash
# StreamTune — сборка .apk внутри WSL. Переиспользует уже подготовленный SDK в
# ext4 ($HOME/carmodem-build/sdk): пакет architecture-independent (all), поэтому
# подходит любой 25.12 SDK. Если SDK не подготовлен — делает полную подготовку.
# Запуск из Windows: wsl.exe bash -lc '/mnt/c/.../build/wsl-build.sh'
set -uo pipefail

REPO_WIN="/mnt/c/Users/demox/Documents/Code/luci-app-streamtune"
OUT_WIN="/mnt/c/Users/demox/Downloads"
WORK="$HOME/carmodem-build"
SDK="$WORK/sdk"
PKG="luci-app-streamtune"
SDK_URL="https://downloads.immortalwrt.org/releases/25.12.0/targets/mediatek/filogic/immortalwrt-sdk-25.12.0-mediatek-filogic_gcc-14.3.0_musl.Linux-x86_64.tar.zst"

mkdir -p "$WORK"

# --- подготовка SDK при первом запуске ---
if [ ! -f "$SDK/scripts/feeds" ]; then
	echo "[prep] SDK не найден — скачиваю и распаковываю в $SDK"
	cd "$WORK"
	[ -f sdk.tar.zst ] || wget -q --show-progress "$SDK_URL" -O sdk.tar.zst
	rm -rf "$SDK"; mkdir -p "$SDK"
	tar --use-compress-program=unzstd -xf sdk.tar.zst -C "$SDK" --strip-components=1
fi

echo "[1/5] Копирую пакет в SDK + нормализация LF + биты +x"
rm -rf "$SDK/package/$PKG"
cp -r "$REPO_WIN/luci-app-streamtune" "$SDK/package/$PKG"
find "$SDK/package/$PKG" -type f ! -name '*.lmo' -exec sed -i 's/\r$//' {} + 2>/dev/null || true
chmod 0755 "$SDK/package/$PKG/root/usr/libexec/rpcd/streamtune" \
           "$SDK/package/$PKG/root/etc/init.d/streamtune"

echo "[2/5] feeds (если ещё не установлены)"
cd "$SDK"
[ -d feeds/luci ] || ./scripts/feeds update -a >/dev/null
[ -d package/feeds/luci ] || ./scripts/feeds install -a >/dev/null
[ -f .config ] || make defconfig >/dev/null

echo "[3/5] Вшиваю русский перевод (po2lmo)"
PO="$SDK/package/$PKG/translations/streamtune.ru.po"
P2L="$SDK/staging_dir/hostpkg/bin/po2lmo"
if [ -f "$PO" ] && [ -x "$P2L" ]; then
	mkdir -p "$SDK/package/$PKG/root/usr/lib/lua/luci/i18n"
	"$P2L" "$PO" "$SDK/package/$PKG/root/usr/lib/lua/luci/i18n/streamtune.ru.lmo" \
		&& echo "    перевод RU вшит"
fi
grep -q "^CONFIG_PACKAGE_$PKG=" .config || echo "CONFIG_PACKAGE_$PKG=m" >> .config

echo "[4/5] Сборка пакета"
make "package/$PKG/clean" >/dev/null 2>&1
make "package/$PKG/compile" V=s
rc=$?
[ "$rc" -eq 0 ] || { echo "make завершился с кодом $rc"; exit "$rc"; }

echo "[5/5] Копирую .apk -> dist/ и Downloads"
mkdir -p "$REPO_WIN/dist" "$OUT_WIN"
found=$(find "$SDK/bin" -name "$PKG*" \( -name '*.apk' -o -name '*.ipk' \) -print)
[ -n "$found" ] || { echo "ВНИМАНИЕ: пакет не найден в bin/"; exit 3; }
echo "$found"
echo "$found" | while read -r p; do
	[ -n "$p" ] && cp "$p" "$REPO_WIN/dist/" && cp "$p" "$OUT_WIN/"
done
echo "=== СБОРКА УСПЕШНА ==="
ls -la "$REPO_WIN/dist/"
