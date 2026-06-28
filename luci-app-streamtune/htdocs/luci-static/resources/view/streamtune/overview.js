'use strict';
'require view';
'require ui';
'require dom';
'require poll';
'require streamtune';

/* StreamTune — дашборд: профиль (Auto LTE / Home wired), оценка соответствия,
 * карточки категорий с мастер-переключателем, построчный статус параметров с
 * ИНДИВИДУАЛЬНЫМ тумблером у каждого параметра, применение и откат.
 *
 * Статусы (3): Applied (мы изменили) | Matches (совпало само) | Off (отличается).
 * Процент = (Applied + Matches) / всего (кроме Unavailable). Тумблер только
 * выбирает, что попадёт в следующее «Применить»; на статус он не влияет. */

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
		this.paramRows = {};
		this.paramSw = {};
		this.masterSw = {};
		this.catKeys = {};
		this.tbodies = {};
		this.counters = {};
		this.profileBtns = {};
		this.draft = this.cfgToDraft(data);
		this.savedProfile = (data.config && data.config.profile) || 'lte_audio';
		this.caps = data.caps || {};

		this.gaugeBox = E('div', { 'class': 'st-gauge-box' });
		this.scoreLine = E('div', { 'class': 'st-score-sub' });

		/* селектор профиля */
		var seg = E('div', { 'class': 'st-seg' });
		[ [ 'lte_audio', st.PROFILE_NAMES.lte_audio ], [ 'home_wired', st.PROFILE_NAMES.home_wired ] ].forEach(L.bind(function(o) {
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
				E('p', { 'class': 'st-head-desc' }, _('Tune the network stack for low-latency, low-jitter audio/video streaming. Pick a profile, toggle the parameters you want and apply.')),
				E('div', { 'class': 'st-profile-row' }, [
					E('span', { 'class': 'st-profile-label' }, _('Profile:')), seg
				]),
				this.scoreLine,
				this.hintBox,
				E('div', { 'class': 'st-actions' }, [
					E('button', { 'class': 'btn cbi-button-positive', 'click': ui.createHandlerFn(this, 'handleApply') },
						[ st.icon('check'), _('Apply selected') ]),
					E('button', { 'class': 'btn cbi-button-reset', 'click': ui.createHandlerFn(this, 'handleRevert') },
						_('Reset all'))
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

	/* status JSON -> draft (профиль, WAN, MTU, per-param enabled) */
	cfgToDraft: function(data) {
		var cfg = (data && data.config) || {};
		var d = { profile: cfg.profile || 'lte_audio', wan_iface: cfg.wan_iface || '',
		          mtu: cfg.mtu || 'auto', enabled: {} };
		((data && data.params) || []).forEach(function(p) {
			d.enabled[p.key] = (p.enabled === 1 || p.enabled === true);
		});
		return d;
	},

	/* Текст ячейки «Рекомендовано» (MTU подменяем пробитым/ручным значением) */
	recText: function(p) {
		if (p.key === 'link.mtu' && this.draft.mtu && this.draft.mtu !== 'auto') return '' + this.draft.mtu;
		if (p.type === 'service') {
			if (p.key === 'service.irqbalance' && p.rec === 'stopped') return _('stopped / not installed');
			if (p.rec === 'running') return _('running');
			if (p.rec === 'stopped') return _('stopped');
		}
		if (p.type === 'wanipv6' || p.type === 'dhcp6' || p.type === 'ula') return _('disabled / removed');
		return (p.rec === '' || p.rec == null) ? '—' : '' + p.rec;
	},

	/* Строка параметра: [тумблер] имя · рекомендовано · текущее · статус */
	buildParamRow: function(p) {
		var sw = E('input', { 'type': 'checkbox' });
		sw.checked = !!this.draft.enabled[p.key];
		sw.disabled = (p.state === 'unavailable');
		sw.addEventListener('change', L.bind(function() {
			this.draft.enabled[p.key] = sw.checked;
			this.syncMaster(p.cat);
		}, this));
		this.paramSw[p.key] = sw;

		var tr = E('tr', { 'class': 'st-prow st-row-' + p.state, 'data-key': p.key }, [
			st.pNameCell(p.key),
			E('td', { 'class': 'st-prec' }, this.recText(p)),
			E('td', { 'class': 'st-pcur' }, st.fmtCur(p)),
			E('td', { 'class': 'st-pst' }, [ st.statusBadge(p.state) ]),
			E('td', { 'class': 'st-psw' }, [ E('label', { 'class': 'st-switch st-switch-sm' }, [ sw, E('span', { 'class': 'st-slider' }) ]) ])
		]);
		this.paramRows[p.key] = tr;
		return tr;
	},

	/* Обновить ячейки существующей строки (НЕ трогая тумблер) */
	updateParamRow: function(tr, p) {
		tr.className = 'st-prow st-row-' + p.state;
		var rec = tr.querySelector('.st-prec'); if (rec) rec.textContent = this.recText(p);
		var cur = tr.querySelector('.st-pcur'); if (cur) cur.textContent = st.fmtCur(p);
		var stc = tr.querySelector('.st-pst'); if (stc) dom.content(stc, [ st.statusBadge(p.state) ]);
		var sw = this.paramSw[p.key]; if (sw) sw.disabled = (p.state === 'unavailable');
	},

	buildCard: function(cat, data) {
		var meta = st.catMeta(cat);
		var ci = (data.categories || {})[cat] || { kind: 'safe', requires: '', count: 0 };
		var params = (data.params || []).filter(function(p) { return p.cat === cat; });
		this.catKeys[cat] = params.map(function(p) { return p.key; });

		/* мастер-переключатель блока: вкл/выкл все параметры категории */
		var ms = E('input', { 'type': 'checkbox' });
		var card = E('div', { 'class': 'st-card' });
		this.masterSw[cat] = ms;
		ms.addEventListener('change', L.bind(function() {
			var on = ms.checked;
			(this.catKeys[cat] || []).forEach(L.bind(function(k) {
				this.draft.enabled[k] = on;
				var s = this.paramSw[k]; if (s && !s.disabled) s.checked = on;
			}, this));
			this.syncMaster(cat);
		}, this));

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
			E('label', { 'class': 'st-switch', 'title': _('Enable/disable every parameter in this block') }, [ ms, E('span', { 'class': 'st-slider' }) ])
		]);

		var body = E('div', { 'class': 'st-card-b' });

		if (cat === 'congestion' && this.caps.bbr === 0) body.appendChild(pkgNote('kmod-tcp-bbr'));
		if (cat === 'irqbalance' && this.caps.irqbalance === 0) body.appendChild(pkgNote('irqbalance'));

		/* mobile LTE: поле WAN-интерфейса + кнопка пробы MTU */
		if (cat === 'mobile_lte') {
			var wanIn = E('input', { 'type': 'text', 'class': 'cbi-input-text',
				'placeholder': (this.caps.wan ? this.caps.wan : _('auto-detect')), 'value': this.draft.wan_iface || '' });
			wanIn.addEventListener('change', L.bind(function() { this.draft.wan_iface = wanIn.value.replace(/[^a-zA-Z0-9_]/g, ''); wanIn.value = this.draft.wan_iface; }, this));
			this.wanInput = wanIn;
			body.appendChild(E('div', { 'class': 'st-subopt' }, [
				E('span', {}, _('WAN interface (blank = auto)')), wanIn
			]));
			this.probeResult = E('span', { 'class': 'st-sub-note' });
			body.appendChild(E('div', { 'class': 'st-subopt' }, [
				E('button', { 'class': 'btn cbi-button-action',
					'click': ui.createHandlerFn(this, 'handleProbe') },
					[ st.icon('refresh'), _('Determine optimal MTU') ]),
				this.probeResult
			]));
		}

		var tbody = E('tbody', {}, params.map(L.bind(this.buildParamRow, this)));
		this.tbodies[cat] = tbody;
		body.appendChild(E('table', { 'class': 'st-table' }, [
			E('thead', {}, E('tr', {}, [
				E('th', {}, _('Parameter')),
				E('th', {}, _('Recommended')),
				E('th', {}, _('Current')),
				E('th', {}, _('Status')),
				E('th', { 'class': 'st-th-sw' }, _('On'))
			])),
			tbody
		]));

		if (ci.kind === 'risk') card.classList.add('st-card-risk');
		dom.append(card, [ header, body ]);
		this.syncMaster(cat);
		return card;
	},

	/* Привести мастер-переключатель категории к состоянию её параметров */
	syncMaster: function(cat) {
		var ms = this.masterSw[cat]; if (!ms) return;
		var keys = this.catKeys[cat] || [];
		var on = 0;
		keys.forEach(L.bind(function(k) { if (this.draft.enabled[k]) on++; }, this));
		ms.checked = (on > 0);
		ms.indeterminate = (on > 0 && on < keys.length);
		var card = ms.closest('.st-card');
		if (card) card.classList.toggle('st-card-on', on > 0);
	},

	/* Обновление статусной части (не трогает тумблеры-черновик) */
	renderStatus: function(data) {
		if (!data || !data.score) return;
		this.lastData = data;
		this.caps = data.caps || this.caps;
		this.savedProfile = (data.config && data.config.profile) || this.savedProfile;

		dom.content(this.gaugeBox, st.scoreGauge(data.score.good, data.score.total));
		var pct = data.score.total > 0 ? Math.round(data.score.good / data.score.total * 100) : 0;
		var bbrChip = (this.caps.bbr === 1)
			? E('span', { 'class': 'st-pill2',
				'title': this.caps.bbr_ksize
					? _('Detected from tcp_bbr.ko size: %s B (modinfo is stripped on OpenWRT)').format(this.caps.bbr_ksize)
					: _('Kernel BBR version') },
				'BBR ' + st.bbrVersionLabel(this.caps.bbr_version))
			: '';
		dom.content(this.scoreLine, [
			E('strong', {}, _('%d of %d recommendations met').format(data.score.good, data.score.total)),
			bbrChip,
			(pct === 100) ? E('span', { 'class': 'st-ok-tag' }, [ st.icon('check'), _('All set') ]) : ''
		]);
		this.updateHint();

		/* построить-или-обновить строки (самовосстановление, если первый load упал) */
		var byCat = {};
		(data.params || []).forEach(function(p) { (byCat[p.cat] = byCat[p.cat] || []).push(p); });
		st.CATS.forEach(L.bind(function(cat) {
			var tb = this.tbodies[cat];
			(byCat[cat] || []).forEach(L.bind(function(p) {
				var tr = this.paramRows[p.key];
				if (tr) { this.updateParamRow(tr, p); return; }
				if (this.draft.enabled[p.key] === undefined) this.draft.enabled[p.key] = (p.enabled === 1 || p.enabled === true);
				if (tb) tb.appendChild(this.buildParamRow(p));
			}, this));
			this.syncMaster(cat);
			var ci = (data.categories || {})[cat];
			if (ci && this.counters[cat]) {
				var good = (ci.applied || 0) + (ci.match || 0);
				dom.content(this.counters[cat], ci.count > 0 ? (good + '/' + ci.count) : '');
			}
		}, this));
	},

	updateHint: function() {
		if (!this.hintBox) return;
		var changed = this.savedProfile && this.draft.profile !== this.savedProfile;
		this.hintBox.style.display = changed ? '' : 'none';
	},

	/* draft -> [profile, param_off(csv), wan_iface, mtu] */
	collect: function() {
		var off = [];
		Object.keys(this.draft.enabled).forEach(L.bind(function(k) {
			if (!this.draft.enabled[k]) off.push(k);
		}, this));
		return [ this.draft.profile || 'lte_audio', off.join(','), this.draft.wan_iface || '', this.draft.mtu || 'auto' ];
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

	/* Выбор профиля (без применения) — значения параметров одинаковы, меняется
	 * только авто-детект WAN; подсказка зовёт нажать «Применить». */
	handleProfile: function(prof) {
		this.draft.profile = prof;
		Object.keys(this.profileBtns || {}).forEach(L.bind(function(p) {
			this.profileBtns[p].classList.toggle('st-on', prof === p);
		}, this));
		this.updateHint();
		var name = st.PROFILE_NAMES[prof] || prof;
		ui.addNotification(null, E('p', {}, _('Profile “%s” selected. Press “Apply selected” to activate.').format(name)), 'info');
		return Promise.resolve();
	},

	handleProbe: function() {
		if (this.probeResult) dom.content(this.probeResult, _('Probing…'));
		return L.resolveDefault(st.rpc.probe(), {}).then(L.bind(function(res) {
			if (res && res.mtu > 0) {
				this.draft.mtu = '' + res.mtu;
				this.setMtuRec(this.draft.mtu);
				if (this.probeResult)
					dom.content(this.probeResult, _('Path MTU: %s (%s) → MSS %s. Press “Apply selected” to set it.').format(res.mtu, res.method || '?', res.mss));
			} else if (this.probeResult) {
				dom.content(this.probeResult, _('Probe failed — install iputils-ping'));
			}
		}, this));
	},

	/* Подставить значение MTU в колонку «Рекомендовано» строки link.mtu */
	setMtuRec: function(val) {
		var tr = this.paramRows && this.paramRows['link.mtu'];
		if (!tr) return;
		var cell = tr.querySelector('.st-prec');
		if (cell) cell.textContent = val;
	},

	handleRevert: function() {
		if (!confirm(_('Reset all StreamTune changes back to their original values and clear the applied-state memory?')))
			return Promise.resolve();
		return st.rpc.revert()
			.then(L.bind(function() {
				ui.addNotification(null, E('p', {}, _('Reset done. Applied parameters were restored to their original values.')), 'info');
			}, this))
			.then(L.bind(this.load, this))
			.then(L.bind(function(data) {
				this.draft = this.cfgToDraft(data);
				this.savedProfile = (data.config && data.config.profile) || 'lte_audio';
				this.syncSwitches();
				this.renderStatus(data);
			}, this));
	},

	/* Привести тумблеры/поля к this.draft (после отката/перезагрузки) */
	syncSwitches: function() {
		Object.keys(this.paramSw || {}).forEach(L.bind(function(k) {
			var sw = this.paramSw[k]; if (sw) sw.checked = !!this.draft.enabled[k];
		}, this));
		st.CATS.forEach(L.bind(this.syncMaster, this));
		if (this.wanInput) this.wanInput.value = this.draft.wan_iface || '';
		Object.keys(this.profileBtns || {}).forEach(L.bind(function(p) {
			this.profileBtns[p].classList.toggle('st-on', this.draft.profile === p);
		}, this));
		this.updateHint();
	}
});
