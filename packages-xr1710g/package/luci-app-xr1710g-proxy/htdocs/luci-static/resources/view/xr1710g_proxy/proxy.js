'use strict';
'require view';
'require form';
'require rpc';
'require ui';
'require uci';

var callStatus = rpc.declare({
	object: 'luci.xr1710g_proxy',
	method: 'getStatus',
	expect: { }
});

var callUpdateCn = rpc.declare({
	object: 'luci.xr1710g_proxy',
	method: 'updateCnList',
	expect: { }
});

var HELP = {
	enabled: _('Master switch. When disabled the init script exits immediately: no nft table, no policy route, no process.') + '<br />' +
		_('Toggling only does uci commit plus /etc/init.d/xr1710g-proxy reload; the firewall (fw4) is never reloaded, because a fw4 reload rebuilds the hardware flowtable.'),
	proxy_hosts: _('Proxy clients (source IP / CIDR, one entry per line).') + '<br />' +
		_('Only these clients are captured into userspace. Every other client keeps exactly the same forwarding path as if this component did not exist, so hardware offload (PPE/NPU) is fully preserved.') + '<br />' +
		_('Note: the set must not contain overlapping or nested ranges. If you list 192.168.1.0/24, do not also list 192.168.1.5 - rendering rejects it and the service refuses to start.'),
	cn_update: _('Off by default: only the snapshot shipped in the read-only firmware volume is used, so there are zero NAND writes at runtime.') + '<br />' +
		_('When enabled, lists are fetched to /tmp periodically and swapped into the kernel set atomically only after validation; a failed validation keeps the previous set.'),
	fwmark: _('Policy-routing mark (hex). Conflicts are detected before start; if the mark is already taken (for example Tailscale uses 0x80000/0xff0000) the service refuses to start and logs it, never touching someone else\u2019s entries.'),
	route_table: _('Policy-routing table number. A conflict with an existing routing table makes the service refuse to start.')
};

return view.extend({
	load: function() {
		return Promise.all([ callStatus(), uci.load('xr1710g_proxy') ]);
	},

	render: function(data) {
		var st = data[0] || {};
		var m, s, o, self = this;

		m = new form.Map('xr1710g_proxy', _('Proxy and networking - split-routing proxy'),
			_('Kernel-level classification. Only clients on the proxy list are captured into userspace; all other clients stay on the original forwarding path with hardware offload fully preserved. Disabled by default. On start failure or process crash it fails open by removing the capture and redirect rules, so the proxy clients fall back to direct routing and normal networking is never affected.'));

		s = m.section(form.NamedSection, 'global', 'global', _('Split-routing settings'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('Enable split-routing proxy'));
		o.rmempty = false;
		o.default = '0';
		o.description = HELP.enabled;

		o = s.option(form.DynamicList, 'proxy_hosts', _('Proxy clients'));
		o.placeholder = '192.168.123.224';
		o.description = HELP.proxy_hosts;
		o.validate = function(section_id, value) {
			if (/^\s*$/.test(value || ''))
				return true;
			if (!/^\d{1,3}(\.\d{1,3}){3}(\/\d{1,2})?$/.test(value))
				return _('Must be an IPv4 address or CIDR, for example 192.168.123.224 or 192.168.123.0/24');
			return true;
		};

		o = s.option(form.Value, 'dns_scope', _('Fake-IP scope'));
		o.readonly = true;
		o.default = 'proxy_hosts';
		o.description = _('Hard constraint of this architecture: fake-IP may only be handed to proxy clients. Ordinary clients always receive real IPs. If an ordinary client received 198.18.x, the kernel allow-rule (which only matches proxy clients) would never let it out, so foreign sites would be unreachable rather than merely slow.');

		s = m.section(form.NamedSection, 'global', 'global', _('China allow-list (what preserves hardware offload)'));

		o = s.option(form.DummyValue, '_snap', _('Snapshot shipped in firmware'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return (st.cn4_snapshot || 0) + ' IPv4 / ' + (st.cn6_snapshot || 0) + ' IPv6' +
				(st.snapshot_time ? ' (' + st.snapshot_time + ')' : '');
		};
		o.description = _('The snapshot lives in the read-only squashfs volume, so it uses no overlay space and causes no NAND writes. China domains of proxy clients must resolve to real IPs, otherwise the kernel cannot match this set and the direct path - which is what keeps hardware offload for domestic traffic - stops working.');

		o = s.option(form.DummyValue, '_kern', _('Live kernel set entries'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return (st.cn4_kernel || 0) + ' IPv4 / ' + (st.cn6_kernel || 0) + ' IPv6';
		};

		o = s.option(form.Flag, 'cn_list_update', _('Enable scheduled update'));
		o.rmempty = false;
		o.default = '0';
		o.description = HELP.cn_update;

		o = s.option(form.Button, '_upd', ' ');
		o.inputtitle = _('Update China allow-list now');
		o.inputstyle = 'apply';
		o.onclick = function() {
			return callUpdateCn().then(function(res) {
				var ok = res && (res.success === true || res.success === 'true' || res.success === 1);
				ui.addNotification(null, E('p', {}, (ok ? _('Update succeeded:') : _('Update failed, the previous set was kept:')) +
					' ' + ((res && res.output) || '')), ok ? 'info' : 'error');
				return self.load().then(function(d) { st = d[0] || {}; });
			});
		};

		s = m.section(form.NamedSection, 'global', 'global', _('Policy routing'),
			_('Conflicts are detected before start. On conflict the service refuses to start instead of overwriting foreign entries.'));

		o = s.option(form.Value, 'fwmark', _('fwmark'));
		o.datatype = 'hexstring';
		o.default = '0x40';
		o.description = HELP.fwmark;

		o = s.option(form.Value, 'route_table', _('Routing table'));
		o.datatype = 'uinteger';
		o.default = '100';
		o.description = HELP.route_table;

		o = s.option(form.Value, 'singbox_dns_port', _('sing-box DNS port'));
		o.datatype = 'port';
		o.default = '5333';

		o = s.option(form.Value, 'singbox_tun', _('TUN interface name'));
		o.default = 'singtun0';
		o.description = _('auto_route and auto_redirect are always false, so traffic is never taken over globally.');

		s = m.section(form.NamedSection, 'global', 'global', _('Runtime state'));

		o = s.option(form.DummyValue, '_running', _('sing-box process'));
		o.rawhtml = true;
		o.cfgvalue = function() { return st.running ? _('Running') : _('Not running'); };
		o.description = _('Not running is the normal state while the master switch is off.');

		o = s.option(form.DummyValue, '_nft', _('Capture table inet xr1710g_proxy'));
		o.rawhtml = true;
		o.cfgvalue = function() { return st.nft_table ? _('Loaded') : _('Absent'); };

		o = s.option(form.DummyValue, '_rule', _('Policy-routing entries'));
		o.rawhtml = true;
		o.cfgvalue = function() { return st.ip_rule ? _('Installed') : _('Not installed'); };

		o = s.option(form.DummyValue, '_failopen', _('Fail-open state'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			if (st.fail_open)
				return _('Fail-open is active: capture and redirect rules were removed, proxy clients fall back to direct routing.');
			return _('Normal (not triggered)');
		};
		o.description = _('Failing open is deliberate: if the proxy core dies, proxy clients fall back to direct routing instead of losing connectivity, which matches the rule that a failure must never affect normal networking. The trade-off is that during a fault those clients are not proxied, which is stated here explicitly.');

		o = s.option(form.DummyValue, '_rules', _('Effective policy routes'));
		o.rawhtml = true;
		o.cfgvalue = function() { return st.rules || _('(none)'); };

		o = s.option(form.DummyValue, '_logs', _('Recent log lines'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			var l = (st.logs || '').split('|').filter(Boolean);
			return l.length ? l.join('\n') : _('(none)');
		};

		return m.render();
	}
});
