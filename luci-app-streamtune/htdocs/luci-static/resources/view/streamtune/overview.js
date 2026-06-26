'use strict';
'require view';
'require ui';
'require dom';
'require poll';
'require streamtune';

/* StreamTune — дашборд: профиль (generic / Auto LTE-audio), оценка здоровья,
 * карточки категорий с тумблерами, построчный статус параметров, применение
 * и откат. */

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
		this.profileBtns = {};
		this.draft = this.cfgToDraft(data.config || {});
		this.savedProfile = (data.config && data.config.profile) || 'generic';
		this.caps = data.caps || {};

		this.gaugeBox = E('div', { 'class': 'st-gauge-box' });
		this.scoreLine = E('div', { 'class': 'st-score-sub' });

		/* селектор профиля */
		var seg = E('div', { 'class': 'st-seg' });
		[ [ 'generic', _('Generic') ], [ 'lte_audio', _('Auto LTE / audio') ] ].forEach(L.bind(function(o) {
			var b = E('button', {
				'class': 'st-seg-btn' + (this.draft.profile === o[0] ? ' st-on' : ''),
				'click': ui.createHandlerFn(this, 'handleProfile', o[0])
			}, o[1]);
			this.profileBtns[o[0]] = b;
			seg.appendChild(b);
		}, this));

		this.hintBox = E('div', { 'class': 'st-note st-note-warn', 'style': 'display:none' }, [
			st.icon('alert'),
			E('span', {}, _('Profile changed but not applied yet — press “Apply selected”.'))
		]);

		var head = E('div', { 'class': 'st-head' }, [
			this.gaugeBox,
			E('div', { 'class': 'st-head-r' }, [
				E('h2', {}, [ st.icon('rocket'), _('Stream Optimizer') ]),
				E('p', { 'class': 'st-head-desc' }, _('Tune the network stack for low-latency, low-jitter audio/video streaming. Pick a profile, review each parameter and apply.')),
				E('div', { 'class': 'st-profile-row' }, [
					E('span', { 'class': 'st-profile-label' }, _('Profile:')), seg
				]),
				this.scoreLine,
				this.hintBox,
				E('div', { 'class': 'st-actions' }, [
					E('button', { 'class': 'btn cbi-button-positive', 'click': ui.createHandlerFn(this, 'handleApply') },
						[ st.icon('check'), _('Apply selected') ]),
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

	/* config (строки '0'/'1') -> draft */
	cfgToDraft: function(cfg) {
		var d = {};
		st.CATS.forEach(function(c) { d[c] = (cfg[c] === '1' || cfg[c] === 1) ? 1 : 0; });
		d.flow_offload_hw = (cfg.flow_offload_hw === '1' || cfg.flow_offload_hw === 1) ? 1 : 0;
		d.profile = cfg.profile || 'generic';
		d.wan_iface = cfg.wan_iface || '';
		return d;
	},

	buildCard: function(cat, data) {
		var meta = st.catMeta(cat);
		var ci = (data.categories || {})[cat] || { kind: 'safe', requires: '', applied: 0, total: 0 };

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

		/* mobile LTE: поле WAN-интерфейса */
		if (cat === 'mobile_lte') {
			var wanIn = E('input', { 'type': 'text', 'class': 'cbi-input-text',
				'placeholder': (this.caps.wan ? this.caps.wan : _('auto-detect')), 'value': this.draft.wan_iface || '' });
			wanIn.addEventListener('change', L.bind(function() { this.draft.wan_iface = wanIn.value.replace(/[^a-zA-Z0-9_]/g, ''); wanIn.value = this.draft.wan_iface; }, this));
			this.wanInput = wanIn;
			body.appendChild(E('div', { 'class': 'st-subopt' }, [
				E('span', {}, _('WAN interface (blank = auto)')), wanIn
			]));
		}

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

	/* Обновление статусной части (не трогает тумблеры-черновик) */
	renderStatus: function(data) {
		if (!data || !data.score) return;
		this.lastData = data;
		this.caps = data.caps || this.caps;
		this.savedProfile = (data.config && data.config.profile) || this.savedProfile;

		dom.content(this.gaugeBox, st.scoreGauge(data.score.applied, data.score.total));
		var pct = data.score.total > 0 ? Math.round(data.score.applied / data.score.total * 100) : 0;
		var bbrChip = (this.caps.bbr === 1)
			? E('span', { 'class': 'st-pill2', 'title': _('Kernel BBR version') }, 'BBR ' + st.bbrVersionLabel(this.caps.bbr_version))
			: '';
		dom.content(this.scoreLine, [
			E('strong', {}, _('%d of %d enabled optimizations applied').format(data.score.applied, data.score.total)),
			bbrChip,
			(pct === 100) ? E('span', { 'class': 'st-ok-tag' }, [ st.icon('check'), _('All set') ]) : ''
		]);
		this.updateHint();

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

	updateHint: function() {
		if (!this.hintBox) return;
		var changed = this.savedProfile && this.draft.profile !== this.savedProfile;
		this.hintBox.style.display = changed ? '' : 'none';
	},

	collect: function() {
		var d = this.draft, b = function(v) { return v ? '1' : '0'; };
		return [ d.profile || 'generic', b(d.net_buffers), b(d.low_latency), b(d.backlog),
		         b(d.congestion), b(d.flow_offload), b(d.flow_offload_hw), b(d.conntrack),
		         b(d.irqbalance), b(d.disable_ipv6), b(d.mobile_lte), d.wan_iface || '' ];
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
		return st.rpc.apply.apply(null, this.collect())
			.then(L.bind(this.report, this))
			.then(L.bind(this.refresh, this));
	},

	/* Выбор профиля: проставить пресет тумблеров (без применения) */
	handleProfile: function(prof) {
		this.draft.profile = prof;
		var preset = st.PROFILES[prof] || {};
		Object.keys(preset).forEach(L.bind(function(k) { this.draft[k] = preset[k]; }, this));
		this.syncToggles();
		var name = (prof === 'lte_audio') ? _('Auto LTE / audio') : _('Generic');
		ui.addNotification(null, E('p', {}, _('Profile “%s” selected. Press “Apply selected” to activate.').format(name)), 'info');
		return Promise.resolve();
	},

	handleRevert: function() {
		if (!confirm(_('Revert all StreamTune optimizations and reset to the Generic profile?')))
			return Promise.resolve();
		return st.rpc.revert()
			.then(L.bind(function() {
				ui.addNotification(null, E('p', {}, _('Reverted. Buffer-size sysctls return to defaults after reboot.')), 'info');
			}, this))
			.then(L.bind(this.load, this))
			.then(L.bind(function(data) {
				this.draft = this.cfgToDraft(data.config || {});
				this.savedProfile = (data.config && data.config.profile) || 'generic';
				this.syncToggles();
				this.renderStatus(data);
			}, this));
	},

	/* Привести DOM (тумблеры, селектор профиля, поля) к this.draft */
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
		if (this.wanInput) this.wanInput.value = this.draft.wan_iface || '';
		Object.keys(this.profileBtns || {}).forEach(L.bind(function(p) {
			this.profileBtns[p].classList.toggle('st-on', this.draft.profile === p);
		}, this));
		this.updateHint();
	}
});
