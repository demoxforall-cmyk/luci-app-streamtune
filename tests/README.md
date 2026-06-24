# Тесты streamtune

Без железа, на фикстурах. Бэкенд-скрипты переопределяют пути через окружение
(`ST_PROC_ROOT`, `ST_CFG_FILE`, `ST_FW_FILE`, `ST_CAPS_FILE`, `ST_SYSFS_HASHSIZE`,
`ST_SYSCTL_D`, `ST_DROPIN`, `ST_NO_APPLY`), поэтому запускаются на любой POSIX-оболочке.

```sh
sh tests/run_all.sh                       # всё сразу (sh + deno, если есть)
# по отдельности:
sh tests/run_detect.sh                    # detect.sh: статусы и score на фикстурах /proc
sh tests/run_apply.sh                     # apply.sh: генерация sysctl drop-in + идемпотентность
sh tests/run_boot.sh                      # boot.awk: таймлайн из dmesg
sh tests/check_package.sh                 # наличие файлов + синтаксис sh/awk
deno run --allow-read tests/check_js.mjs  # синтаксис JS-вью + валидность JSON ACL/menu
```

Фикстуры в `fixtures/`:
- `proc/` — снимок `/proc/sys` (safe-параметры = рекомендованным).
- `cfg_default.txt` / `cfg_all.txt` — наборы тумблеров (UCI).
- `caps_default.txt` (нет bbr/irqbalance) / `caps_bbr.txt` (всё доступно).
- `fw_default.txt` / `fw_offload_on.txt` — состояние firewall offload.
- `dmesg/dmesg_sample.txt` — пример вывода dmesg.
