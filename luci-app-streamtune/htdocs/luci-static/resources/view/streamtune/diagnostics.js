'use strict';
'require view';
'require dom';
'require poll';
'require streamtune';

/* StreamTune — диагностика: раскрываемый таймлайн загрузки (фазы из dmesg с
 * длительностью и логом каждой фазы) + сведения о системе. */

var st = streamtune;

function mb(kb) { return kb > 0 ? (Math.round(kb / 1024) + ' ' + _('MB')) : '—'; }
function hms(s) {
	if (!s) return '—';
	var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60);
	return (h ? (h + ' ' + _('h') + ' ') : '') + m + ' ' + _('min');
}

/* Переводимые подписи вех (boot.awk отдаёт английские ключи) */
var BOOTLBL = {
	'Kernel start':                 _('Kernel start'),
	'Memory init':                  _('Memory init'),
	'Rootfs mounted':               _('Rootfs mounted'),
	'Network link ready':           _('Network link ready'),
	'Kernel ready (init handover)': _('Kernel ready (init handover)'),
	'Userspace start':              _('Userspace start'),
	'procd start':                  _('procd start'),
	'System ready':                 _('System ready')
};

function kv(rows) {
	var dl = E('dl', { 'class': 'st-kv' });
	rows.forEach(function(r) {
		if (!r) return;
		dl.appendChild(E('dt', {}, r[0]));
		dl.appendChild(E('dd', {}, r[1]));
	});
	return dl;
}

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function() {
		return Promise.all([
			L.resolveDefault(st.rpc.boot(), {}),
			L.resolveDefault(st.rpc.status(), {})
		]);
	},

	render: function(res) {
		st.injectCSS();
		this.bootBox = E('div', {});
		this.sysBox = E('div', {});

		this.renderBoot(res);   /* один раз — статичен, раскрытия не слетают */
		this.renderSys(res);

		poll.add(L.bind(function() {
			return this.load().then(L.bind(this.renderSys, this));
		}, this), 10);

		return E('div', { 'class': 'st-wrap' }, [
			E('div', { 'class': 'st-cards' }, [ this.bootBox, this.sysBox ])
		]);
	},

	bootLabel: function(l) { return BOOTLBL[l] || l; },

	/* строка фазы: подпись + Gantt-полоса + длительность; раскрытие = лог фазы.
	 * Лог тянется ПО ТРЕБОВАНИЮ (boot_lines from..to) — маленький ответ, не упирается
	 * в лимит размера ubus (полный лог в один get_boot не влезает). */
	tlRow: function(e, delta, leftPct, widPct, from, to, slow) {
		var chev = E('span', { 'class': 'st-tlx-chev' });
		chev.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="9 6 15 12 9 18"/></svg>';
		var seg = E('div', { 'class': 'st-tlx-seg' + (slow ? ' st-slow' : ''),
			'style': 'left:' + leftPct.toFixed(1) + '%;width:' + widPct.toFixed(1) + '%' });

		var head = E('div', { 'class': 'st-tlx-h' }, [
			chev,
			E('span', { 'class': 'st-tlx-lbl' }, this.bootLabel(e.label)),
			E('div', { 'class': 'st-tlx-track' }, [ seg ]),
			E('span', { 'class': 'st-tlx-dt' }, '+' + delta.toFixed(2) + ' ' + _('s'))
		]);

		var log = E('div', { 'class': 'st-tlx-log' });
		var row = E('div', { 'class': 'st-tlx' + (slow ? ' st-tlx-slow' : '') }, [
			head, E('div', { 'class': 'st-tlx-panel' }, [ log ])
		]);
		var loaded = false;
		head.addEventListener('click', function() {
			row.classList.toggle('st-open');
			if (loaded || !row.classList.contains('st-open')) return;
			loaded = true;
			dom.content(log, E('div', { 'class': 'st-tlx-more' }, _('loading…')));
			L.resolveDefault(st.rpc.bootLines(from, to), { lines: [] }).then(function(r) {
				var lines = (r && r.lines) || [];
				if (!lines.length) {
					dom.content(log, E('div', { 'class': 'st-tlx-more' }, _('no kernel messages captured in this phase')));
					return;
				}
				dom.content(log, lines.map(function(l) {
					return E('div', { 'class': 'st-tlx-ln' }, [
						E('span', { 'class': 'st-tlx-lt' }, l.t.toFixed(3)),
						E('span', { 'class': 'st-tlx-lm' }, l.m)
					]);
				}));
			});
		});
		return row;
	},

	buildTimeline: function(boot, sys) {
		if (!boot.available || !(boot.events || []).length) {
			return E('div', { 'class': 'st-note' },
				_('Boot timeline is captured at boot; the kernel ring buffer no longer holds the early-boot lines (uptime %s). Reboot once to populate it.').format(hms(sys.uptime)));
		}
		var total = boot.total || 0;
		var events = (boot.events || []).slice();
		/* синтетическая финальная веха — чтобы «хвост» загрузки после procd был виден */
		var last = events[events.length - 1];
		if (total > 0 && (!last || last.t < total - 0.05)) events.push({ t: total, label: 'System ready' });

		var maxDelta = 0, prev = 0;
		events.forEach(function(e) { var d = e.t - prev; if (d > maxDelta) maxDelta = d; prev = e.t; });

		prev = 0;
		var rows = events.map(L.bind(function(e, i) {
			var delta = Math.max(0, e.t - prev);
			var leftPct = total > 0 ? (prev / total * 100) : 0;
			var widPct = total > 0 ? Math.max(1.2, delta / total * 100) : 0;
			var slow = (delta === maxDelta && delta > 0.1);
			var from = (i === 0) ? -1 : prev;   /* первая фаза включает t=0 */
			var to = e.t;
			prev = e.t;
			return this.tlRow(e, delta, leftPct, widPct, from, to, slow);
		}, this));

		return E('div', {}, [
			E('div', { 'class': 'st-bigtime' }, [
				E('span', { 'class': 'st-bigtime-n' }, total.toFixed(1)),
				E('span', { 'class': 'st-bigtime-u' }, _('s, boot to ready')),
				E('span', { 'class': 'st-bigtime-hint' }, _('click a phase to see what ran'))
			]),
			E('div', { 'class': 'st-tlx-wrap' }, rows)
		]);
	},

	renderBoot: function(res) {
		var boot = (res && res[0] && res[0].boot) || { available: false, events: [] };
		var sys = (res && res[0] && res[0].sys) || {};
		dom.content(this.bootBox, E('div', { 'class': 'st-card' }, [
			E('div', { 'class': 'st-card-h' }, [
				E('span', { 'class': 'st-card-ic' }, [ st.icon('clock') ]),
				E('div', { 'class': 'st-card-t' }, [
					E('div', { 'class': 'st-card-title' }, _('Boot timeline')),
					E('div', { 'class': 'st-card-desc' }, _('Kernel boot phases parsed from dmesg — expand a phase to see its log.'))
				])
			]),
			E('div', { 'class': 'st-card-b' }, [ this.buildTimeline(boot, sys) ])
		]));
	},

	renderSys: function(res) {
		var data = (res && res[0]) || {};
		var status = (res && res[1]) || {};
		var caps = status.caps || {};
		var cfg = status.config || {};
		var sys = data.sys || {};
		dom.content(this.sysBox, E('div', { 'class': 'st-card' }, [
			E('div', { 'class': 'st-card-h' }, [
				E('span', { 'class': 'st-card-ic' }, [ st.icon('cpu') ]),
				E('div', { 'class': 'st-card-t' }, [
					E('div', { 'class': 'st-card-title' }, _('System')),
					E('div', { 'class': 'st-card-desc' }, _('Resources relevant to network load.'))
				])
			]),
			E('div', { 'class': 'st-card-b' }, [ kv([
				[ _('CPU cores'), '' + (sys.cpus || '—') ],
				[ _('Uptime'), hms(sys.uptime) ],
				[ _('RAM total'), mb(sys.mem_total_kb || 0) ],
				[ _('RAM available'), mb(sys.mem_free_kb || 0) ],
				[ _('Tracked connections'), (sys.conntrack_count != null)
					? ((sys.conntrack_count || 0) + ' / ' + (sys.conntrack_max || '—')) : '—' ],
				[ _('RX backlog drops / NAPI squeezes'), (sys.softnet_drop != null)
					? ((sys.softnet_drop || 0) + ' / ' + (sys.softnet_squeeze || 0)) : '—' ],
				[ _('Active profile'), (st.PROFILE_NAMES && st.PROFILE_NAMES[cfg.profile]) || cfg.profile || '—' ],
				[ _('BBR'), st.bbrText(caps) ],
				[ _('WAN interface'), caps.wan ? caps.wan : '—' ]
			]) ])
		]));
	}
});
