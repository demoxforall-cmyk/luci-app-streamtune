# luci-app-streamtune

LuCI-модуль оптимизации сетевого стека роутера под **аудио-/видео-стриминг** для
**OpenWRT / ImmortalWRT 25.12.X** (apk, `LUCI_PKGARCH:=all` — подходит любой
target). Снижает задержки и джиттер, уменьшает нагрузку на CPU и помогает с
временем загрузки.

Один пакет, два языка (русский/английский — по системному языку LuCI). Без внешних
сервисов: всё применяется локально (sysctl drop-in, UCI firewall, conntrack,
irqbalance). Самостоятельный проект, не зависит от других LuCI-приложений.

## Что делает

Меню **Stream Optimizer** (`admin/streamtune`), две вкладки:

### Overview (`admin/streamtune/overview`)
Дашборд с «оценкой здоровья» (сколько включённых оптимизаций реально применено) и
карточками по категориям. По каждому **параметру** видно рекомендованное значение,
текущее значение и **статус применения** (Применено / Не применено / Недоступно /
Выключено). Категории включаются тумблерами; «Рекомендуемый профиль» проставляет
безопасный набор + доступные опции; «Применить выбранное» и «Сбросить всё».

Категории и параметры:

| Категория | Параметры | Рекомендация |
|---|---|---|
| Сетевые буферы (TCP/UDP) | `rmem_max/wmem_max/rmem_default/wmem_default`, `optmem_max`, `tcp_rmem`, `tcp_wmem`, `udp_*_min` | большие буферы → меньше дропов |
| Низкая задержка TCP | `tcp_slow_start_after_idle=0`, `tcp_tw_reuse`, `tcp_fin_timeout`, `tcp_max_syn_backlog`, `tcp_max_tw_buckets` | держит длинные сессии быстрыми |
| Очереди/backlog | `netdev_max_backlog`, `netdev_budget` | поглощает всплески |
| Перегрузка BBR+fq *(опц., нужен kmod-tcp-bbr)* | `tcp_congestion_control=bbr`, `default_qdisc=fq` | анти-bufferbloat |
| Flow offloading *(опц.)* | `firewall flow_offloading` + `flow_offloading_hw` | разгрузка CPU |
| conntrack | `nf_conntrack hashsize` | быстрый поиск соединений |
| irqbalance *(опц., нужен irqbalance)* | служба irqbalance | сглаживает пики нагрузки |
| Отключить IPv6 *(риск, выкл по умолчанию)* | `disable_ipv6` (all/default) | быстрее загрузка, меньше джиттера |

### Diagnostics (`admin/streamtune/diagnostics`)
Хронология загрузки из `dmesg` (вехи ядра + время до userspace), сведения о системе
(CPU/ОЗУ/conntrack) и информационные советы по дальнейшей оптимизации (без
авто-применения).

Тёмная/светлая тема — один CSS (`currentColor`/`color-mix`, без `prefers-color-scheme`).

## Как применяется и персистентность
- **sysctl-параметры** пишутся в `/etc/sysctl.d/99-streamtune.conf` (генерируется из
  включённых категорий) и применяются `sysctl -p`; на загрузке drop-in применяет
  системный сервис sysctl — персистентность бесплатна.
- **flow offload** — через UCI `firewall.@defaults[0]` (персистит сам).
- **conntrack hashsize** (параметр модуля в sysfs, не персистит) — восстанавливает
  служба `streamtune` на загрузке.
- **irqbalance** — `enable` + `start` (персистит).
- **«Сбросить всё»** удаляет drop-in, откатывает firewall/IPv6 и обнуляет тумблеры.

## Установка
Кратко (на устройстве, онлайн — опц. зависимости подтянутся сами):
```sh
apk add --allow-untrusted /tmp/luci-app-streamtune-*.apk
/etc/init.d/rpcd restart
```
Готовый `.apk` — в [`dist/`](dist/). Русский перевод **вшит** в пакет; язык
переключается в System → Language. По умолчанию ничего не применяется — откройте
**Stream Optimizer** и нажмите «Применить».

## Сборка
ImmortalWRT SDK в WSL (пакет `all` → подходит любой 25.12 SDK). Скрипты в [`build/`](build/):
- `wsl-build.sh` — сборка/быстрая пересборка (переиспользует подготовленный SDK);
- `build-in-sdk.sh` — сборка в произвольном распакованном SDK;
- `inspect-apk.sh` — просмотр содержимого собранного `.apk`.

Перевод — исходники EN + `luci-app-streamtune/translations/streamtune.ru.po`
(компилится `po2lmo` в `.lmo` внутри пакета).

## Тесты
Без железа, на фикстурах (см. [`tests/README.md`](tests/README.md)):
```sh
sh tests/run_all.sh
deno run --allow-read tests/check_js.mjs
```

## Структура
- `luci-app-streamtune/` — пакет: Makefile, rpcd-бэкенд `root/usr/libexec/rpcd/streamtune`,
  шелл-логика `root/usr/share/streamtune/` (`lib.sh`/`detect.sh`/`apply.sh`/`boot.sh`/`boot.awk`),
  фронтенд `htdocs/luci-static/resources/`, ACL, меню, init.d, uci-defaults, перевод.
- `tests/` — юнит-тесты на фикстурах (детект/применение/парсер загрузки/синтаксис).
- `build/` — сборочные скрипты.
- `docs/` — CHANGELOG, заметки об источнике рекомендаций.

## Лицензия
GPL-2.0
