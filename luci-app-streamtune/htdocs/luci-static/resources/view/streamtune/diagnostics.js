'use strict';
'require view';
'require dom';
'require poll';
'require streamtune';

/* StreamTune — диагностика: таймлайн загрузки (из dmesg), сведения о системе и
 * информационные советы по дальнейшей оптимизации (без авто-применения). */

var st = streamtune;

function mb(kb) { return kb > 0 ? (Math.round(kb / 1024) + ' ' + _('MB')) : '—'; }

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

	render: function(data) {
		st.injectCSS();

		this.bootBox = E('div', {});
		this.sysBox = E('div', {});
		this.renderBoot(data);

		poll.add(L.bind(function() {
			return this.load().then(L.bind(this.renderBoot, this));
		}, this), 10);

		var tips = E('div', { 'class': 'st-card' }, [
			E('div', { 'class': 'st-card-h' }, [
				E('span', { 'class': 'st-card-ic' }, [ st.icon('info') ]),
				E('div', { 'class': 'st-card-t' }, [
					E('div', { 'class': 'st-card-title' }, _('Further optimization ideas')),
					E('div', { 'class': 'st-card-desc' }, _('Device-specific tweaks that StreamTune does not apply automatically.'))
				])
			]),
			E('div', { 'class': 'st-card-b' }, [
				E('ul', { 'class': 'st-tips' }, [
					E('li', {}, _('A router only forwards your phone’s streams — it is not the TCP endpoint. So TCP/buffer sysctls (tagged “router-only”) affect only the router’s own traffic, not the audio stream.')),
					E('li', {}, _('Keep IPv6 enabled and the modem APN as IPV4V6: mobile carriers often use 464XLAT/CLAT, and disabling IPv6 can break connectivity.')),
					E('li', {}, _('When several devices share the car link, install luci-app-sqm with cake-autorate (adaptive shaping for variable cellular bandwidth) — for a single audio stream it is not needed.')),
					E('li', {}, _('In a moving vehicle do not hard-lock LTE bands — free handover keeps coverage continuous; add a modem keepalive/watchdog for stuck connections.')),
					E('li', {}, _('“RX backlog drops / NAPI squeezes” above is informational: non-zero values mean the per-CPU packet queue or NAPI budget is saturating — the netdev_max_backlog / netdev_budget recommendations directly address that.'))
				])
			])
		]);

		return E('div', { 'class': 'st-wrap' }, [
			E('div', { 'class': 'st-cards' }, [ this.bootBox, this.sysBox ]),
			tips
		]);
	},

	renderBoot: function(res) {
		var data = (res && res[0]) || {};
		var status = (res && res[1]) || {};
		var caps = status.caps || {};
		var cfg = status.config || {};
		var boot = data.boot || { available: false, total: 0, events: [] };
		var sys = data.sys || {};

		/* --- таймлайн загрузки --- */
		var inner;
		if (!boot.available || !(boot.events || []).length) {
			inner = E('div', { 'class': 'st-note' }, _('Boot log (dmesg) is not available on this device.'));
		} else {
			var total = boot.total || 0;
			var rows = boot.events.map(function(e) {
				var pct = total > 0 ? Math.min(100, Math.round(e.t / total * 100)) : 0;
				return E('div', { 'class': 'st-tl-row' }, [
					E('div', { 'class': 'st-tl-label' }, e.label),
					E('div', { 'class': 'st-tl-bar' }, [
						E('div', { 'class': 'st-tl-fill', 'style': 'width:' + pct + '%' })
					]),
					E('div', { 'class': 'st-tl-time' }, e.t.toFixed(2) + ' ' + _('s'))
				]);
			});
			inner = E('div', {}, [
				E('div', { 'class': 'st-bigtime' }, [
					E('span', { 'class': 'st-bigtime-n' }, total.toFixed(1)),
					E('span', { 'class': 'st-bigtime-u' }, _('s to userspace'))
				]),
				E('div', { 'class': 'st-tl' }, rows)
			]);
		}
		dom.content(this.bootBox, E('div', { 'class': 'st-card' }, [
			E('div', { 'class': 'st-card-h' }, [
				E('span', { 'class': 'st-card-ic' }, [ st.icon('clock') ]),
				E('div', { 'class': 'st-card-t' }, [
					E('div', { 'class': 'st-card-title' }, _('Boot timeline')),
					E('div', { 'class': 'st-card-desc' }, _('Kernel milestones parsed from dmesg.'))
				])
			]),
			E('div', { 'class': 'st-card-b' }, [ inner ])
		]));

		/* --- сведения о системе --- */
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
