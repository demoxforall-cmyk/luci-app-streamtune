'use strict';
'require view';
'require ui';
'require dom';
'require poll';
'require streamtune';

/* StreamTune — дашборд: оценка здоровья, карточки категорий с тумблерами,
 * построчный статус параметров (рекомендованное / текущее / применено),
 * применение профиля и откат. */

var st = streamtune;

function pkgNote(requires) {
	return E('div', { 'class': 'st-note st-note-warn' }, [
		st.icon('alert'),
		E('span', {}, _('Requires package %s — it will be pulled in automatically on online install, or install it manually.').format(requires))
	]);
}

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function() {
		return L.resolveDefault(st.rpc.status(), {});
	},

	render: function(data) {
		st.injectCSS();
		this.toggles = {};
		this.tbodies = {};
		this.counters = {};
		this.draft = this.cfgToDraft(data.config || {});
		this.caps = data.caps || {};

		this.gaugeBox = E('div', { 'class': 'st-gauge-box' });
		this.scoreLine = E('div', { 'class': 'st-score-sub' });

		var head = E('div', { 'class': 'st-head' }, [
			this.gaugeBox,
			E('div', { 'class': 'st-head-r' }, [
				E('h2', {}, [ st.icon('rocket'), _('Stream Optimizer') ]),
				E('p', { 'class': 'st-head-desc' }, _('Tune the network stack for low-latency, low-jitter audio/video streaming. Review each parameter, pick a profile and apply.')),
				this.scoreLine,
				E('div', { 'class': 'st-actions' }, [
					E('button', { 'class': 'btn cbi-button-positive', 'click': ui.createHandlerFn(this, 'handleApply') },
						[ st.icon('check'), _('Apply selected') ]),
					E('button', { 'class': 'btn cbi-button-neutral', 'click': ui.createHandlerFn(this, 'handlePreset') },
						_('Recommended preset')),
					E('button', { 'class': 'btn cbi-button-reset', 'click': ui.createHandlerFn(this, 'handleRevert') },
						_('Revert all'))
				])
			])
		]);

		var grid = E('div', { 'class': 'st-cards' });
		st.CATS.forEach(L.bind(function(cat) {
			grid.appendChild(this.buildCard(cat, data));
		}, this));

		this.renderStatus(data);

		poll.add(L.bind(function() {
			return this.load().then(L.bind(this.renderStatus, this));
		}, this), 5);

		return E('div', { 'class': 'st-wrap' }, [ head, grid ]);
	},

	/* config (строки '0'/'1') -> draft (числа 0/1) */
	cfgToDraft: function(cfg) {
		var d = {};
		st.CATS.forEach(function(c) { d[c] = (cfg[c] === '1' || cfg[c] === 1) ? 1 : 0; });
		d.flow_offload_hw = (cfg.flow_offload_hw === '1' || cfg.flow_offload_hw === 1) ? 1 : 0;
		return d;
	},

	buildCard: function(cat, data) {
		var meta = st.catMeta(cat);
		var ci = (data.categories || {})[cat] || { kind: 'safe', requires: '', applied: 0, total: 0 };

		/* тумблер категории */
		var sw = E('input', { 'type': 'checkbox' });
		sw.checked = !!this.draft[cat];
		var card = E('div', { 'class': 'st-card' });
		sw.addEventListener('change', L.bind(function() {
			this.draft[cat] = sw.checked ? 1 : 0;
			card.classList.toggle('st-card-on', sw.checked);
			if (cat === 'flow_offload' && this.hwToggle) this.hwToggle.disabled = !sw.checked;
		}, this));
		this.toggles[cat] = sw;

		var kindBadge = '';
		if (ci.kind === 'opt')  kindBadge = E('span', { 'class': 'st-kind st-kind-opt' }, _('optional'));
		if (ci.kind === 'risk') kindBadge = E('span', { 'class': 'st-kind st-kind-risk' }, _('risky'));

		var counter = E('span', { 'class': 'st-card-count' });
		this.counters[cat] = counter;

		var header = E('div', { 'class': 'st-card-h' }, [
			E('span', { 'class': 'st-card-ic' }, [ st.icon(meta.icon) ]),
			E('div', { 'class': 'st-card-t' }, [
				E('div', { 'class': 'st-card-title' }, [ meta.title, kindBadge, counter ]),
				E('div', { 'class': 'st-card-desc' }, meta.desc)
			]),
			E('label', { 'class': 'st-switch' }, [ sw, E('span', { 'class': 'st-slider' }) ])
		]);

		var body = E('div', { 'class': 'st-card-b' });

		/* предупреждение о недостающем пакете/модуле */
		if (cat === 'congestion' && this.caps.bbr === 0) body.appendChild(pkgNote('kmod-tcp-bbr'));
		if (cat === 'irqbalance' && this.caps.irqbalance === 0) body.appendChild(pkgNote('irqbalance'));

		/* под-опция: аппаратный offload */
		if (cat === 'flow_offload') {
			var hw = E('input', { 'type': 'checkbox' });
			hw.checked = !!this.draft.flow_offload_hw;
			hw.disabled = !this.draft.flow_offload;
			hw.addEventListener('change', L.bind(function() {
				this.draft.flow_offload_hw = hw.checked ? 1 : 0;
			}, this));
			this.hwToggle = hw;
			var hwNote = (this.caps.hw_offload === 0)
				? E('span', { 'class': 'st-sub-note' }, _('(hardware offload not detected on this device)'))
				: '';
			body.appendChild(E('label', { 'class': 'st-subopt' }, [
				hw, E('span', {}, _('Enable hardware NAT offloading')), hwNote
			]));
		}

		/* таблица параметров */
		var tbody = E('tbody');
		this.tbodies[cat] = tbody;
		body.appendChild(E('table', { 'class': 'st-table' }, [
			E('thead', {}, E('tr', {}, [
				E('th', {}, _('Parameter')),
				E('th', {}, _('Recommended')),
				E('th', {}, _('Current')),
				E('th', {}, _('Status'))
			])),
			tbody
		]));

		card.classList.toggle('st-card-on', !!this.draft[cat]);
		if (ci.kind === 'risk') card.classList.add('st-card-risk');
		dom.append(card, [ header, body ]);
		return card;
	},

	/* Обновление только статусной части (не трогает тумблеры-черновик) */
	renderStatus: function(data) {
		if (!data || !data.score) return;
		this.lastData = data;
		this.caps = data.caps || this.caps;

		dom.content(this.gaugeBox, st.scoreGauge(data.score.applied, data.score.total));
		var pct = data.score.total > 0 ? Math.round(data.score.applied / data.score.total * 100) : 0;
		dom.content(this.scoreLine, [
			E('strong', {}, _('%d of %d enabled optimizations applied').format(data.score.applied, data.score.total)),
			(pct === 100) ? E('span', { 'class': 'st-ok-tag' }, [ st.icon('check'), _('All set') ]) : ''
		]);

		var byCat = {};
		(data.params || []).forEach(function(p) { (byCat[p.cat] = byCat[p.cat] || []).push(p); });

		st.CATS.forEach(L.bind(function(cat) {
			var tb = this.tbodies[cat];
			if (tb) dom.content(tb, (byCat[cat] || []).map(L.bind(st.paramRow, st)));
			var ci = (data.categories || {})[cat];
			if (ci && this.counters[cat]) {
				var label = '';
				if (ci.total > 0) label = ci.applied + '/' + ci.total;
				else if (ci.match > 0) label = _('%d matching').format(ci.match);
				dom.content(this.counters[cat], label);
			}
		}, this));
	},

	collect: function() {
		var d = this.draft, b = function(v) { return v ? '1' : '0'; };
		return [ b(d.net_buffers), b(d.low_latency), b(d.backlog), b(d.congestion),
		         b(d.flow_offload), b(d.flow_offload_hw), b(d.conntrack),
		         b(d.irqbalance), b(d.disable_ipv6) ];
	},

	report: function(res) {
		var ok = res && res.ok;
		var msg = ok ? _('Optimizations applied.') : _('Apply failed.');
		if (ok && res.errors && res.errors.length)
			msg = _('Applied with notes: %s').format(res.errors.join('; '));
		ui.addNotification(null, E('p', {}, msg), ok ? 'info' : 'warning');
	},

	refresh: function() {
		return this.load().then(L.bind(this.renderStatus, this));
	},

	handleApply: function() {
		var args = this.collect();
		return st.rpc.apply.apply(null, args)
			.then(L.bind(this.report, this))
			.then(L.bind(this.refresh, this));
	},

	handlePreset: function() {
		var c = this.caps || {};
		this.draft = {
			net_buffers: 1, low_latency: 1, backlog: 1, conntrack: 1, flow_offload: 1,
			congestion: (c.bbr === 1) ? 1 : 0,
			irqbalance: (c.irqbalance === 1) ? 1 : 0,
			flow_offload_hw: (c.hw_offload === 1) ? 1 : 0,
			disable_ipv6: 0
		};
		this.syncToggles();
		ui.addNotification(null, E('p', {}, _('Recommended profile selected. Press “Apply selected” to activate.')), 'info');
		return Promise.resolve();
	},

	handleRevert: function() {
		if (!confirm(_('Revert all StreamTune optimizations and reset all toggles?')))
			return Promise.resolve();
		return st.rpc.revert()
			.then(L.bind(function() {
				ui.addNotification(null, E('p', {}, _('Reverted. Buffer-size sysctls return to defaults after reboot.')), 'info');
			}, this))
			.then(L.bind(this.load, this))
			.then(L.bind(function(data) {
				this.draft = this.cfgToDraft(data.config || {});
				this.syncToggles();
				this.renderStatus(data);
			}, this));
	},

	/* Привести состояние тумблеров в DOM к this.draft */
	syncToggles: function() {
		st.CATS.forEach(L.bind(function(cat) {
			var sw = this.toggles[cat];
			if (!sw) return;
			sw.checked = !!this.draft[cat];
			var card = sw.closest('.st-card');
			if (card) card.classList.toggle('st-card-on', !!this.draft[cat]);
		}, this));
		if (this.hwToggle) {
			this.hwToggle.checked = !!this.draft.flow_offload_hw;
			this.hwToggle.disabled = !this.draft.flow_offload;
		}
	}
});
