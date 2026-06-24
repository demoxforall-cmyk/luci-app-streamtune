# Источник рекомендаций

Набор оптимизаций основан на материале из `optimization.docx` (выгрузка Deep
Research) — практики настройки роутеров под стриминг, в т.ч. данные с форума
GL-iNet (GL-X3000 / Quectel RM520N) и опыт с Banana Pi R4 / ImmortalWRT.

Ключевые рекомендации, перенесённые в модуль:

- **TCP/UDP-буферы** — увеличение `rmem/wmem` (`net.core.*`, `net.ipv4.tcp_rmem`,
  `tcp_wmem`, `udp_*_min`) для снижения дропов на высоких скоростях.
- **`tcp_slow_start_after_idle = 0`** — критично для стриминга: без этого TCP
  замедляется после пауз и вызывает буферизацию.
- **`tcp_tw_reuse=1`, `tcp_fin_timeout=10`**, увеличенные `tcp_max_syn_backlog`,
  `tcp_max_tw_buckets` — быстрее переиспользование соединений.
- **`netdev_max_backlog=100000`, `netdev_budget=50000`** — burst-трафик без дропов.
- **BBR + fq** — управление перегрузкой и борьба с bufferbloat.
- **Hardware flow offloading** — разгрузка CPU (через firewall).
- **conntrack hashsize** — ускорение поиска при множестве соединений
  (в источнике — `echo … > /sys/module/nf_conntrack/parameters/hashsize`).
- **irqbalance** — распределение прерываний по ядрам.
- **Отключение IPv6** — убирает RA/DHCPv6-handshake, ускоряет загрузку (в
  источнике дало основной выигрыш по времени старта).

Информационно (без авто-применения, т.к. зависит от устройства): удаление лишних
kmod, SQM/fq_codel под конкретные скорости линка, правка DTS под пустые слоты PCIe.
