# Тюнинг под аудио-стриминг по LTE в движущейся машине

> **Итоговые значения, реализованные в v2.0** — см. [CHANGELOG](CHANGELOG.md) и
> профили `lte_audio`/`home_wired`: буферы 4 МБ; серверные/TIME_WAIT/backlog-крутилки
> и 16 МБ `*_default` → дефолт ядра; `bbr` + `fq_codel`; полное отключение IPv6;
> conntrack established 7440; MTU auto-probe + MSS-clamp через pbr-safe nftables.
> Текст ниже — обоснование (часть значений в старой таблице ниже приведена для
> сравнения с docx и может отличаться от финала).


Справка по выбору значений для **GL.iNet GL-X3000 (MT7981B, 2×Cortex-A53, 512 МБ)**
+ **Quectel RM520N-GL**, который форвардит буферизованный аудиопоток
(**Spotify** ≤320 кбит/с, **Qobuz** FLAC 1–9 Мбит/с) в движущемся автомобиле.

Основано на двух независимых анализах (Claude + Perplexity) и adversarial-проверке по
первоисточникам. Профиль **Auto LTE / audio** в модуле реализует выводы этой справки.

## Что реально важно

Буферизованное аудио — это «ручеёк» против LTE, и плеер держит буфер на много секунд,
который поглощает джиттер. TCP гарантирует побитовую целостность. Единственная реальная
причина прерываний в движении — **опустошение буфера плеера при хэндовере/в тоннеле/при
провале покрытия**, то есть стабильность пропускной и устойчивость к потерям, а не
микросекунды.

**Решающая оговорка:** роутер **NAT-форвардит** поток телефона и **не является
TCP-эндпоинтом**. Поэтому sysctl-крутилки TCP на нём (congestion control, буферы,
TIME_WAIT, slow-start) действуют **только на трафик, который роутер генерирует сам**
(DNS, NTP, обновления) — и **не влияют** на поток телефон↔Spotify/Qobuz. В UI такие
параметры помечены тегом **«только роутер»**. На форвардимый звук со стороны роутера
влияют лишь: **qdisc/AQM, flow offload, conntrack, MTU/MSS, IPv6/CLAT, DNS**.

Происхождение значений docx: пост «SpitzAX3000» на форуме GL.iNet, взятый из
Cloudflare/netdata для устранения потерь на спидтесте **>800 Мбит/с** — это
server-throughput тюнинг под 4-ГБ BPI-R4, не под аудио/мобайл/512 МБ.

## Значения по параметрам (профиль lte_audio)

| Параметр | docx (generic) | lte_audio | Почему |
|---|---|---|---|
| `rmem_max` / `wmem_max` | 16 МБ | **4 МБ** | потолок автотюнинга; худший BDP LTE ≤~2 МБ |
| `rmem_default` / `wmem_default` | 16 МБ | **дефолт ядра** | `*_default` — принудительный базовый размер на сокет; 16 МБ зря держит RAM |
| `tcp_rmem` | 4096 1048576 2097152 | **4096 131072 4194304** | default 1 МБ over-commit'ит; max 4 МБ |
| `tcp_wmem` | 4096 65536 16777216 | **4096 65536 4194304** | роутер качает, а не отдаёт |
| `optmem_max`, `udp_*_min` | 40960 / 8192 | без изменений | копейки; для TCP-аудио плацебо |
| `tcp_slow_start_after_idle` | 0 | 0 *(router-only)* | полезно, безвредно |
| `tcp_tw_reuse` | 1 | 1 *(router-only)* | плацебо для форвардера |
| `tcp_fin_timeout` | 10 | **дефолт** | FIN_WAIT2, не TIME_WAIT; миф |
| `tcp_max_syn_backlog` | 30000 | **дефолт** | серверный приём входящих |
| `tcp_max_tw_buckets` | 2000000 | **дефолт** | риск ~400 МБ RAM на 512 МБ |
| `netdev_max_backlog` | 100000 | **дефолт** | длинный FIFO = bufferbloat |
| `netdev_budget` | 50000 | **дефолт** | 167× дефолта; CPU-starvation на 2 ядрах |
| `tcp_congestion_control` | bbr | bbr *(router-only)* | устойчив к потерям LTE; на форвард не влияет |
| `default_qdisc` | fq | **fq_codel** | роутеру нужен AQM, а не host-pacing |
| flow_offloading (SW) | вкл | **выкл** | держим путь видимым для AQM |
| flow_offloading_hw | вкл | **выкл** | баг задержки MT7981 (#19449), несовместим с AQM, рвёт долгие потоки |
| conntrack hashsize | 16384 | без изменений | норм |
| irqbalance | — | **выкл** | на ≤2 ядрах нейтрально/вредно |
| disable_ipv6 | 1 | **0 (не отключать)** | ломает 464XLAT/CLAT; эмпирически подтверждено логами модема |
| **MTU на WAN** (новое) | — | **1430** | компенсирует туннельный оверхед сотовой сети |
| **MSS-clamp** (новое) | — | **вкл** | крупные TLS-пакеты не уходят в «чёрную дыру» |
| **conntrack established** (новое) | — | **7440 (не укорачивать)** | тихий поток не выпадает из NAT |

## Главные рычаги (по убыванию) для одного аудиопотока

1. **MTU 1430 + MSS-clamp** — единственный роутер-side фикс, прямо влияющий на
   форвардимый поток. Убирает залипания, похожие на провал покрытия.
2. **Не отключать IPv6** (APN IPV4V6) — сохраняет 464XLAT/CLAT.
3. **Щедрый conntrack established timeout** — поток не выпадает из NAT между догрузками.
4. **DNS-кэш** (dnsmasq) — мгновенный реконнект после хэндовера.
5. **fq_codel** вместо fq — корректный AQM для форвардера (заметно при общем канале).
6. **bbr** — оставить (помогает трафику роутера; безвредно).

**Не нужно для одного потока:** SQM/cake-autorate (плацебо без конкурирующего трафика;
статический SQM на едущей машине вреден — полоса плавает). Имеет смысл при нескольких
устройствах.

**Карго-культ на 512 МБ (профиль возвращает дефолт):** `tw_buckets=2M`,
`syn_backlog=30000`, `fin_timeout=10`, `netdev_*`, 16 МБ `*_default`, irqbalance.

## Вне модуля (модем/сеть)

- Прошивка модема, не лочить бэнды жёстко в движении (нужен хэндовер), keepalive/watchdog
  для зависшего соединения.
- BBRv3 — только кастомное ядро (mainline 6.12 = v1); модуль показывает фактическую версию,
  значения не зависят (`bbr` задействует v3 автоматически).

## Источники

- WPI «TCP CUBIC vs BBR on the Highway» — https://web.cs.wpi.edu/~claypool/papers/driving-bbr/paper-final.pdf
- APNIC «When to use and not use BBR» — https://blog.apnic.net/2020/01/10/when-to-use-and-not-use-bbr/
- OpenWRT #19449 (MT7981 HW-offload latency) — https://github.com/openwrt/openwrt/issues/19449
- OpenWRT: flow offload vs SQM — https://forum.openwrt.org/t/how-does-software-flow-offloading-interact-with-sqm/114310
- bufferbloat.net SQM / cake-autorate — https://www.bufferbloat.net/projects/bloat/wiki/Getting_SQM_Running_Right/ , https://github.com/lynxthecat/cake-autorate
- Cloudflare (буферы) — https://blog.cloudflare.com/optimizing-tcp-for-high-throughput-and-low-latency/
- ESnet host tuning — https://fasterdata.es.net/host-tuning/linux/
- 464XLAT/CLAT (T-Mobile) — https://www.internetsociety.org/deploy360/2014/case-study-t-mobile-us-goes-ipv6-only-using-464xlat/
- MTU на сотовых сетях (Digi) — https://www.digi.com/support/knowledge-base/recommended-mtu-mru-settings-on-cellular-networks
- Источник sysctl-таблицы — https://forum.gl-inet.com/t/how-to-installing-vanilla-openwrt-on-gl-x3000/45404
