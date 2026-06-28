# streamtune — парсер dmesg в таймлайн загрузки (JSON).
# SPDX-License-Identifier: GPL-2.0
# Совместимо с BusyBox awk (без gensub/asort).
# Вход: вывод `dmesg` (строки вида "[   12.345678] ...").
# Выход: {"available":bool,"total":sec,"events":[{"t":sec,"label":..,"line":..}]}

BEGIN {
	NM = 0; maxt = 0
	add("Linux version",                                  "Kernel start")
	add("Memory:",                                        "Memory init")
	add("Freeing unused kernel",                          "Kernel ready (init handover)")
	add("Run /sbin/init|Run /etc/preinit",                "Userspace start")
	add("procd",                                          "procd start")
	add("mount_root|overlayfs|jffs2|UBIFS|F2FS|EXT4-fs",  "Rootfs mounted")
	add("link becomes ready|Link is Up|entered forwarding state|br-lan", "Network link ready")
}

function add(p, l) { NM++; pat[NM] = p; lab[NM] = l }

function esc(s) {
	gsub(/\\/, "\\\\", s)
	gsub(/"/, "\\\"", s)
	gsub(/\t/, " ", s)
	return s
}

{
	if (match($0, /^\[[ ]*[0-9]+\.[0-9]+\]/)) {
		ts = substr($0, RSTART, RLENGTH)
		# оставляем только цифры и точку. ВАЖНО: BusyBox awk на роутере не вырезает
		# класс [\[\] ] (экранированные скобки внутри [...]) -> таймстамп бы остался
		# "[12.3]" и "+0" дал бы 0. [^0-9.] переносимо между gawk/mawk/BusyBox.
		gsub(/[^0-9.]/, "", ts)
		t = ts + 0
		if (t > maxt) maxt = t
		rest = substr($0, RSTART + RLENGTH)
		sub(/^[ ]+/, "", rest)
		# накапливаем весь лог (с лимитом) — фронтенд бьёт его по фазам для раскрытия
		if (NL < 240) { NL++; LT[NL] = t; LM[NL] = esc(substr(rest, 1, 120)) }
		for (i = 1; i <= NM; i++) {
			if (!(lab[i] in tfound) && rest ~ pat[i]) tfound[lab[i]] = t
		}
	}
}

END {
	# собрать найденные события в индексируемые массивы
	k = 0
	for (l in tfound) { k++; L[k] = l; T[k] = tfound[l] }
	# сортировка по времени (вставками; событий мало)
	for (a = 2; a <= k; a++) {
		vl = L[a]; vt = T[a]; b = a - 1
		while (b >= 1 && T[b] > vt) { L[b+1] = L[b]; T[b+1] = T[b]; b-- }
		L[b+1] = vl; T[b+1] = vt
	}
	avail = (maxt > 0) ? "true" : "false"
	printf "{\"available\":%s,\"total\":%.2f,\"events\":[", avail, maxt
	for (a = 1; a <= k; a++) {
		if (a > 1) printf ","
		printf "{\"t\":%.2f,\"label\":\"%s\"}", T[a], esc(L[a])
	}
	printf "],\"log\":["
	for (n = 1; n <= NL; n++) {
		if (n > 1) printf ","
		printf "{\"t\":%.2f,\"m\":\"%s\"}", LT[n], LM[n]
	}
	printf "]}\n"
}
