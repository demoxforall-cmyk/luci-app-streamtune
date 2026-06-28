#!/bin/sh
# streamtune — строки dmesg одной фазы загрузки (для раскрытия в таймлайне).
# SPDX-License-Identifier: GPL-2.0
# Вход: ST_FROM/ST_TO (секунды) — диапазон (from, to]. Читает снимок init.d.
# Выход: {"lines":[{"t":N,"m":"..."}]} (не более 40 строк — ответ маленький,
# чтобы не упереться в лимит размера ubus, в отличие от полного лога).
# tr отсекает не-ASCII/непечатные байты, иначе JSON может сломаться.
set -u
ST_SHARE="${ST_SHARE:-/usr/share/streamtune}"
BOOTDMESG="${ST_BOOT_DMESG:-/tmp/streamtune-boot.dmesg}"
FROM="${ST_FROM:-0}"; TO="${ST_TO:-999999}"
case "$FROM" in ''|*[!0-9.-]*) FROM=0 ;; esac
case "$TO"   in ''|*[!0-9.]*)  TO=999999 ;; esac

if [ ! -s "$BOOTDMESG" ]; then printf '{"lines":[]}\n'; exit 0; fi

tr -cd '\11\12\40-\176' < "$BOOTDMESG" | awk -v from="$FROM" -v to="$TO" '
function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, " ", s); return s }
BEGIN { printf "{\"lines\":[" }
{
	if (match($0, /^\[[ ]*[0-9]+\.[0-9]+\]/)) {
		ts = substr($0, RSTART, RLENGTH); gsub(/[^0-9.]/, "", ts); t = ts + 0
		if (t > from + 0 && t <= to + 0 && n < 40) {
			rest = substr($0, RSTART + RLENGTH); sub(/^[ ]+/, "", rest)
			if (n > 0) printf ","
			printf "{\"t\":%.3f,\"m\":\"%s\"}", t, esc(substr(rest, 1, 140))
			n++
		}
	}
}
END { printf "]}\n" }
'
