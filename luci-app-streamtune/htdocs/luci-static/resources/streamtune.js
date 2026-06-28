'use strict';
'require baseclass';
'require rpc';

/* luci-app-streamtune — общий модуль: RPC, метаданные параметров/категорий,
 * визуальные хелперы (бейджи статуса, кольцо оценки, иконки), загрузка CSS.
 * Реестр параметров — зеркало root/usr/share/streamtune/lib.sh. */

var ST_VER = '2.3';

var callStatus = rpc.declare({ object: 'streamtune', method: 'get_status' });
var callBoot   = rpc.declare({ object: 'streamtune', method: 'get_boot' });
var callRevert = rpc.declare({ object: 'streamtune', method: 'revert' });
var callProbe  = rpc.declare({ object: 'streamtune', method: 'probe_mtu' });
var callApply  = rpc.declare({
	object: 'streamtune', method: 'apply',
	params: [ 'profile', 'param_off', 'wan_iface', 'mtu' ]
});

/* Порядок и метаданные категорий (тумблеров) */
var CATS = [ 'net_buffers', 'low_latency', 'backlog', 'congestion',
             'flow_offload', 'conntrack', 'irqbalance', 'disable_ipv6', 'mobile_lte' ];

/* Пресеты профилей: значения тумблеров категорий (lte_audio и home_wired
 * сейчас совпадают; различия — авто-MTU и WAN-интерфейс, оба автоопределяются) */
var PROFILE_PRESET = { net_buffers: 1, low_latency: 1, backlog: 0, congestion: 1,
	flow_offload: 0, flow_offload_hw: 0, conntrack: 1, irqbalance: 0,
	disable_ipv6: 1, mobile_lte: 1 };
var PROFILES = { lte_audio: PROFILE_PRESET, home_wired: PROFILE_PRESET };
var PROFILE_NAMES = { lte_audio: _('Auto LTE'), home_wired: _('Home, wired') };

/* Параметры, влияющие ТОЛЬКО на трафик самого роутера (не на форвардимый поток) */
var ROUTER_ONLY = {
	'net.core.rmem_max': 1, 'net.core.wmem_max': 1, 'net.core.rmem_default': 1,
	'net.core.wmem_default': 1, 'net.core.optmem_max': 1, 'net.ipv4.tcp_rmem': 1,
	'net.ipv4.tcp_wmem': 1, 'net.ipv4.udp_rmem_min': 1, 'net.ipv4.udp_wmem_min': 1,
	'net.ipv4.tcp_slow_start_after_idle': 1, 'net.ipv4.tcp_tw_reuse': 1,
	'net.ipv4.tcp_fin_timeout': 1, 'net.ipv4.tcp_max_syn_backlog': 1,
	'net.ipv4.tcp_max_tw_buckets': 1, 'net.ipv4.tcp_congestion_control': 1
};

var CATMETA = {
	net_buffers:  { icon: 'layers',  title: _('Network buffers (TCP/UDP)'),
		desc: _('Larger socket buffers reduce packet drops at high bitrate — fewer rebuffering events while streaming.') },
	low_latency:  { icon: 'zap',     title: _('Low-latency TCP'),
		desc: _('Keep long streaming sessions fast: no slow-start after idle pauses, quicker socket reuse.') },
	backlog:      { icon: 'network', title: _('Queues & backlog'),
		desc: _('Absorb traffic bursts without dropping packets (device backlog and NAPI budget).') },
	congestion:   { icon: 'gauge',   title: _('Congestion control (BBR + fq)'),
		desc: _('BBR with fair queueing fights bufferbloat and keeps latency low under load.') },
	flow_offload: { icon: 'cpu',     title: _('Flow offloading'),
		desc: _('Recommended OFF: NAT offload bypasses the fq_codel AQM and conflicts with Podkop policy-routing. Enable the toggle to enforce it off.') },
	conntrack:    { icon: 'sliders', title: _('Connection tracking'),
		desc: _('A bigger conntrack hash table speeds up lookups when there are many connections.') },
	irqbalance:   { icon: 'chip',    title: _('IRQ balancing'),
		desc: _('Core-aware: recommended OFF on 1–3 cores (overhead not worth it, harmful on 1–2), ON from 4 cores. The toggle enforces the recommendation for your CPU.') },
	disable_ipv6: { icon: 'shield',  title: _('Disable IPv6'),
		desc: _('Full IPv6 off — every item changed is listed below: kernel stack, WAN IPv6, DHCPv6/RA/NDP per pool, ULA prefix and odhcpd. Risky in general (can break 464XLAT/CLAT on mobile); here clients are IPv4-only by design.') },
	mobile_lte:   { icon: 'globe',   title: _('Mobile LTE link'),
		desc: _('Forwarded-traffic fixes that actually matter on a cellular link: MTU + MSS clamp (prevents TLS blackhole stalls) and a generous conntrack timeout.') }
};

/* Человекочитаемые метки для не-sysctl ключей (sysctl показываем как есть) */
var PLABEL = {
	'firewall.flow_offloading':    _('Software offload'),
	'firewall.flow_offloading_hw': _('Hardware offload'),
	'nf_conntrack.hashsize':       _('conntrack hashsize'),
	'service.irqbalance':          _('irqbalance service'),
	'nf_conntrack.tcp_established': _('conntrack TCP timeout'),
	'link.mtu':                    _('WAN MTU'),
	'link.mss_clamp':              _('MSS clamping'),
	'network.wan.ipv6':            _('WAN IPv6'),
	'dhcp.dhcpv6':                 _('DHCPv6 server (LAN)'),
	'dhcp.ra':                     _('Router Advertisement (RA)'),
	'dhcp.ndp':                    _('NDP proxy'),
	'network.globals.ula_prefix':  _('ULA prefix'),
	'service.odhcpd':              _('odhcpd service')
};

/* Подсказки по параметрам */
var PHELP = {
	'net.core.rmem_max':                   _('Maximum socket receive buffer size.'),
	'net.core.wmem_max':                   _('Maximum socket send buffer size.'),
	'net.core.rmem_default':               _('Default socket receive buffer size.'),
	'net.core.wmem_default':               _('Default socket send buffer size.'),
	'net.core.optmem_max':                 _('Maximum ancillary buffer size per socket.'),
	'net.ipv4.tcp_rmem':                   _('TCP receive auto-tuning limits: min / default / max.'),
	'net.ipv4.tcp_wmem':                   _('TCP send auto-tuning limits: min / default / max.'),
	'net.ipv4.udp_rmem_min':               _('Minimum UDP receive buffer guaranteed per socket.'),
	'net.ipv4.udp_wmem_min':               _('Minimum UDP send buffer guaranteed per socket.'),
	'net.ipv4.tcp_slow_start_after_idle':  _('0 = do not slow a connection after an idle pause — critical for streaming.'),
	'net.ipv4.tcp_tw_reuse':               _('Reuse TIME_WAIT sockets for new outgoing connections.'),
	'net.ipv4.tcp_fin_timeout':            _('Seconds to keep a socket in FIN-WAIT-2.'),
	'net.ipv4.tcp_max_syn_backlog':        _('Queue of half-open connections awaiting ACK.'),
	'net.ipv4.tcp_max_tw_buckets':         _('Maximum number of TIME_WAIT sockets.'),
	'net.core.netdev_max_backlog':         _('Packets queued when an interface delivers faster than the kernel handles.'),
	'net.core.netdev_budget':              _('Packets processed per NAPI poll cycle.'),
	'net.ipv4.tcp_congestion_control':     _('Congestion control algorithm; bbr is recommended for streaming.'),
	'net.core.default_qdisc':              _('Default queueing discipline; fq pairs with BBR.'),
	'firewall.flow_offloading':            _('Software flow offloading in the firewall.'),
	'firewall.flow_offloading_hw':         _('Hardware NAT offloading (requires a supported SoC).'),
	'nf_conntrack.hashsize':               _('Number of buckets in the conntrack hash table.'),
	'service.irqbalance':                  _('irqbalance daemon that distributes IRQs across cores.'),
	'net.ipv6.conf.all.disable_ipv6':      _('Disable IPv6 on all interfaces.'),
	'net.ipv6.conf.default.disable_ipv6':  _('Disable IPv6 on the default interface template.'),
	'nf_conntrack.tcp_established':        _('Established-TCP conntrack timeout (seconds); keep generous so idle audio streams are not reaped from NAT.'),
	'link.mtu':                            _('WAN MTU; ~1430 compensates cellular tunnel overhead.'),
	'link.mss_clamp':                      _('Clamp TCP MSS to the path MTU so large TLS packets do not silently blackhole on the cellular link.'),
	'network.wan.ipv6':                    _('Disable IPv6 on the WAN interface(s).'),
	'dhcp.dhcpv6':                         _('DHCPv6 server handed to LAN clients (odhcpd); disabled = no IPv6 addressing.'),
	'dhcp.ra':                             _('IPv6 Router Advertisements to LAN; disabled = clients get no IPv6 default route.'),
	'dhcp.ndp':                            _('NDP proxy; disabled with full IPv6 off.'),
	'network.globals.ula_prefix':          _('Unique Local Address prefix; removed when IPv6 is fully off (restored on Reset all).'),
	'service.odhcpd':                      _('odhcpd daemon (RA/DHCPv6/NDP); stopped and disabled when IPv6 is fully off.')
};

/* Три статуса соответствия + edge "unavailable" (нельзя применить — нет пакета) */
var STATE = {
	applied:     { cls: 'st-ok',    txt: _('Applied') },
	match:       { cls: 'st-match', txt: _('Matches') },
	off:         { cls: 'st-off',   txt: _('Off') },
	unavailable: { cls: 'st-mut',   txt: _('Unavailable') }
};

var ICONS = {
	gauge:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 14l4-4"/><path d="M3.3 17A9 9 0 1 1 20.7 17"/><circle cx="12" cy="14" r="1.4" fill="currentColor" stroke="none"/></svg>',
	zap:     '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"/></svg>',
	layers:  '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="12 2 2 7 12 12 22 7 12 2"/><polyline points="2 17 12 22 22 17"/><polyline points="2 12 12 17 22 12"/></svg>',
	network: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="2" width="6" height="6" rx="1"/><rect x="2" y="16" width="6" height="6" rx="1"/><rect x="16" y="16" width="6" height="6" rx="1"/><path d="M12 8v4M5 16v-2h14v2"/></svg>',
	cpu:     '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="6" y="6" width="12" height="12" rx="2"/><path d="M9 2v3M15 2v3M9 19v3M15 19v3M2 9h3M2 15h3M19 9h3M19 15h3"/></svg>',
	chip:    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="5" width="14" height="14" rx="2"/><rect x="9" y="9" width="6" height="6"/><path d="M9 2v3M15 2v3M9 19v3M15 19v3M2 9h3M2 15h3M19 9h3M19 15h3"/></svg>',
	sliders: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="4" y1="21" x2="4" y2="14"/><line x1="4" y1="10" x2="4" y2="3"/><line x1="12" y1="21" x2="12" y2="12"/><line x1="12" y1="8" x2="12" y2="3"/><line x1="20" y1="21" x2="20" y2="16"/><line x1="20" y1="12" x2="20" y2="3"/><line x1="1" y1="14" x2="7" y2="14"/><line x1="9" y1="8" x2="15" y2="8"/><line x1="17" y1="16" x2="23" y2="16"/></svg>',
	shield:  '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/></svg>',
	globe:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c2.5 2.7 2.5 15.3 0 18M12 3c-2.5 2.7-2.5 15.3 0 18"/></svg>',
	clock:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><polyline points="12 7 12 12 16 14"/></svg>',
	check:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"/></svg>',
	alert:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/></svg>',
	info:    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><line x1="12" y1="11" x2="12" y2="16"/><line x1="12" y1="8" x2="12.01" y2="8"/></svg>',
	refresh: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="23 4 23 10 17 10"/><polyline points="1 20 1 14 7 14"/><path d="M3.5 9a9 9 0 0 1 14.9-3.4L23 10M1 14l4.6 4.4A9 9 0 0 0 20.5 15"/></svg>',
	rocket:  '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4.5 16.5c-1.5 1.3-2 5-2 5s3.7-.5 5-2c.7-.8.7-2 0-2.7a1.9 1.9 0 0 0-3 0z"/><path d="M12 15l-3-3a22 22 0 0 1 8-10c2.5 0 4 1.5 4 4a22 22 0 0 1-10 8z"/><path d="M9 12H5s.5-2.8 2-4c1.7-1.4 5-1 5-1M12 15v4s2.8-.5 4-2c1.4-1.4 1-5 1-5"/></svg>'
};

return baseclass.extend({
	VER: ST_VER,
	CATS: CATS,

	rpc: {
		status: callStatus,
		boot:   callBoot,
		apply:  callApply,
		revert: callRevert,
		probe:  callProbe
	},

	PROFILES: PROFILES,
	PROFILE_NAMES: PROFILE_NAMES,

	catMeta:  function(id)  { return CATMETA[id] || { icon: 'info', title: id, desc: '' }; },
	pLabel:   function(key) { return PLABEL[key] || key; },
	pHelp:    function(key) { return PHELP[key] || ''; },
	routerOnly: function(key) { return !!ROUTER_ONLY[key]; },

	/* "v1"/"v3"/… из строки версии модуля tcp_bbr */
	bbrVersionLabel: function(v) {
		if (!v) return _('unknown');
		var m = ('' + v).match(/^(\d+)/);
		return m ? ('v' + m[1]) : ('' + v);
	},

	/* Текст для отображения: версия + размер модуля (доказательство) */
	bbrText: function(caps) {
		if (!caps || caps.bbr !== 1) return _('not available');
		var s = this.bbrVersionLabel(caps.bbr_version);
		if (caps.bbr_ksize) s += ' · ' + caps.bbr_ksize + ' B';
		return s;
	},

	icon: function(name) {
		var s = E('span', { 'class': 'st-ico' });
		s.innerHTML = ICONS[name] || ICONS.info;
		return s;
	},

	statusBadge: function(state) {
		var s = STATE[state] || STATE.off;
		return E('span', { 'class': 'st-badge ' + s.cls }, s.txt);
	},

	/* Перевод состояния сервиса/значения для отображения */
	fmtCur: function(p) {
		if (p.type === 'service') {
			if (p.cur === 'running') return _('running');
			if (p.cur === 'stopped') return _('stopped');
			if (p.cur === 'absent')  return _('not installed');
		}
		if (p.type === 'wanipv6') return (p.cur === '0') ? _('disabled') : _('on (default)');
		if (p.type === 'dhcp6')   return (p.cur === 'disabled') ? _('disabled') : _('enabled (server)');
		if (p.type === 'ula')     return (p.cur === 'removed') ? _('removed') : (p.cur || '—');
		return (p.cur === '' || p.cur == null) ? '—' : p.cur;
	},

	/* Содержимое ячейки имени параметра (метка + тег «router-only») */
	pNameCell: function(key) {
		var kids = [ E('span', { 'class': 'st-pkey', 'title': this.pHelp(key) }, this.pLabel(key)) ];
		if (this.routerOnly(key))
			kids.push(E('span', { 'class': 'st-tag st-tag-ro', 'title': _('Affects only traffic the router itself originates (DNS, updates) — not devices streaming through it.') }, _('router-only')));
		return E('td', { 'class': 'st-pname' }, kids);
	},

	/* Кольцо «оценки здоровья» */
	scoreGauge: function(applied, total) {
		var pct = total > 0 ? Math.round(applied / total * 100) : 0;
		var r = 42, c = 2 * Math.PI * r, off = c * (1 - pct / 100);
		var cls = pct >= 90 ? 'st-ok' : (pct >= 50 ? 'st-warn' : 'st-bad');
		var wrap = E('div', { 'class': 'st-gauge ' + cls });
		wrap.innerHTML =
			'<svg viewBox="0 0 100 100" class="st-gauge-svg">' +
			'<circle class="st-gauge-bg" cx="50" cy="50" r="42"/>' +
			'<circle class="st-gauge-fg" cx="50" cy="50" r="42" ' +
			'style="stroke-dasharray:' + c.toFixed(1) + ';stroke-dashoffset:' + off.toFixed(1) + '"/>' +
			'</svg>';
		wrap.appendChild(E('div', { 'class': 'st-gauge-num' }, [
			E('span', { 'class': 'st-gauge-pct' }, pct + '%'),
			E('span', { 'class': 'st-gauge-sub' }, applied + '/' + total)
		]));
		return wrap;
	},

	injectCSS: function() {
		if (document.getElementById('st-style')) return;
		document.head.appendChild(E('link', {
			'id': 'st-style', 'rel': 'stylesheet', 'type': 'text/css',
			'href': L.resource('view/streamtune/streamtune.css') + '?v=' + ST_VER
		}));
	}
});
