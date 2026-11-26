'use strict';
'require view';
'require form';
'require uci';
'require rpc';

var callGetAllCurves = rpc.declare({
	object: 'luci.fan',
	method: 'getAllCurves'
});

function drawCurveCanvas(canvasId, curves, activePreset) {
	var canvas = document.getElementById(canvasId);
	if (!canvas) return;

	var ctx = canvas.getContext('2d');
	var width = canvas.width;
	var height = canvas.height;
	var padding = 40;

	ctx.fillStyle = '#fff';
	ctx.fillRect(0, 0, width, height);

	ctx.strokeStyle = '#e0e0e0';
	ctx.lineWidth = 1;

	for (var t = 0; t <= 100; t += 10) {
		var x = padding + (t / 100) * (width - 2 * padding);
		ctx.beginPath();
		ctx.moveTo(x, padding);
		ctx.lineTo(x, height - padding);
		ctx.stroke();
	}

	for (var p = 0; p <= 255; p += 51) {
		var y = height - padding - (p / 255) * (height - 2 * padding);
		ctx.beginPath();
		ctx.moveTo(padding, y);
		ctx.lineTo(width - padding, y);
		ctx.stroke();
	}

	ctx.strokeStyle = '#333';
	ctx.lineWidth = 2;
	ctx.beginPath();
	ctx.moveTo(padding, padding);
	ctx.lineTo(padding, height - padding);
	ctx.lineTo(width - padding, height - padding);
	ctx.stroke();

	ctx.fillStyle = '#333';
	ctx.font = '12px sans-serif';
	ctx.textAlign = 'center';
	ctx.fillText('Temperature (\u00B0C)', width / 2, height - 5);

	ctx.save();
	ctx.translate(12, height / 2);
	ctx.rotate(-Math.PI / 2);
	ctx.fillText('PWM (0-255)', 0, 0);
	ctx.restore();

	ctx.textAlign = 'center';
	for (var t = 0; t <= 100; t += 20) {
		var x = padding + (t / 100) * (width - 2 * padding);
		ctx.fillText(t.toString(), x, height - padding + 15);
	}

	ctx.textAlign = 'right';
	for (var p = 0; p <= 255; p += 51) {
		var y = height - padding - (p / 255) * (height - 2 * padding);
		ctx.fillText(p.toString(), padding - 5, y + 4);
	}

	var colors = {
		'quiet': '#28a745',
		'balanced': '#007bff',
		'performance': '#dc3545',
		'custom': '#6f42c1'
	};

	Object.keys(curves).forEach(function(preset) {
		var points = curves[preset];
		var color = colors[preset] || '#999';
		var isActive = preset === activePreset;

		ctx.strokeStyle = color;
		ctx.lineWidth = isActive ? 3 : 1.5;
		ctx.globalAlpha = isActive ? 1 : 0.4;

		ctx.beginPath();
		points.forEach(function(point, idx) {
			var x = padding + (point.temp / 100) * (width - 2 * padding);
			var y = height - padding - (point.pwm / 255) * (height - 2 * padding);
			if (idx === 0) ctx.moveTo(x, y);
			else ctx.lineTo(x, y);
		});
		ctx.stroke();

		if (isActive) {
			ctx.fillStyle = color;
			points.forEach(function(point) {
				var x = padding + (point.temp / 100) * (width - 2 * padding);
				var y = height - padding - (point.pwm / 255) * (height - 2 * padding);
				ctx.beginPath();
				ctx.arc(x, y, 5, 0, 2 * Math.PI);
				ctx.fill();
			});
		}
		ctx.globalAlpha = 1;
	});

	var legendY = 15;
	Object.keys(colors).forEach(function(preset) {
		ctx.fillStyle = colors[preset];
		ctx.fillRect(width - 100, legendY, 15, 15);
		ctx.fillStyle = '#333';
		ctx.textAlign = 'left';
		ctx.fillText(preset.charAt(0).toUpperCase() + preset.slice(1), width - 80, legendY + 12);
		legendY += 20;
	});
}

function parseStrictUint(value, min, max) {
	var str = String(value == null ? '' : value).trim();
	if (!/^(0|[1-9][0-9]*)$/.test(str))
		return null;
	var num = parseInt(str, 10);
	if (num < min || num > max)
		return null;
	return num;
}

function readOptionValue(opt, section_id, uciKey) {
	var val = opt && typeof(opt.formvalue) == 'function' ? opt.formvalue(section_id) : null;
	return val != null ? val : uci.get('fan', section_id, uciKey);
}

function validatePwm(section_id, value) {
	return parseStrictUint(value, 0, 255) !== null
		? true
		: _('PWM must be an integer between 0 and 255 without leading zeros');
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('fan'),
			callGetAllCurves()
		]);
	},

	render: function(data) {
		var curves = data[1] || {};
		var m, s, o, modeOpt, presetOpt, customSection;
		var customNode = null;
		var tempOptions = {};
		var pwmOptions = {};
		var revalidatingTemps = false;
		var syncScheduled = false;

		function isCustomActive() {
			var mode = readOptionValue(modeOpt, 'settings', 'mode') || 'auto';
			var preset = readOptionValue(presetOpt, 'settings', 'curve_preset') || 'balanced';
			return mode === 'auto' && preset === 'custom';
		}

		function syncCustomVisibility() {
			if (!customNode)
				return;
			var visible = isCustomActive();
			customNode.style.display = visible ? '' : 'none';
			customNode.hidden = !visible;
		}

		function buildCurves() {
			var out = Object.assign({}, curves);
			var customPoints = [];

			for (var k = 1; k <= 5; k++) {
				var fb = (curves.custom && curves.custom[k - 1]) || { temp: 0, pwm: 0 };
				var t = parseStrictUint(readOptionValue(tempOptions[k], 'custom', 'point' + k + '_temp'), 0, 100);
				var p = k === 5 ? 255 : parseStrictUint(readOptionValue(pwmOptions[k], 'custom', 'point' + k + '_pwm'), 0, 255);
				customPoints.push({
					temp: t !== null ? t : fb.temp,
					pwm: p !== null ? p : fb.pwm
				});
			}

			out.custom = customPoints;
			return out;
		}

		function syncUI() {
			var preset = readOptionValue(presetOpt, 'settings', 'curve_preset') || 'balanced';
			syncCustomVisibility();
			drawCurveCanvas('curve-canvas', buildCurves(), preset);
		}

		function scheduleSync() {
			if (typeof(requestAnimationFrame) != 'function') {
				syncUI();
				return;
			}
			if (syncScheduled)
				return;
			syncScheduled = true;
			requestAnimationFrame(function() {
				syncScheduled = false;
				syncUI();
			});
		}

		var FanMap = form.Map.extend({
			renderContents: function() {
				return Promise.resolve(this.super('renderContents', arguments)).then(function(node) {
					scheduleSync();
					return node;
				});
			}
		});

		var CustomCurveSection = form.NamedSection.extend({
			render: function() {
				return Promise.resolve(this.super('render', arguments)).then(function(secNode) {
					customNode = secNode;
					syncCustomVisibility();
					return secNode;
				});
			},

			parse: function() {
				if (!isCustomActive())
					return Promise.resolve();
				return this.super('parse', arguments);
			}
		});

		m = new FanMap('fan', _('Fan Control - Settings'),
			_('Configure fan control mode and speed curves.'));

		s = m.section(form.NamedSection, 'settings', 'fancontrol', _('Control Mode'));
		s.anonymous = true;

		modeOpt = s.option(form.ListValue, 'mode', _('Mode'));
		modeOpt.value('auto', _('Automatic (Follow Curve)'));
		modeOpt.value('manual', _('Manual (Fixed Speed)'));
		modeOpt.default = 'auto';
		modeOpt.onchange = syncUI;

		o = s.option(form.Value, 'manual_pwm', _('Manual Fan Speed (PWM)'),
			_('Set a fixed PWM value (0-255). 0 = Off, 255 = Full Speed'));
		o.datatype = 'and(uinteger,range(0,255))';
		o.default = '127';
		o.depends('mode', 'manual');
		o.rmempty = false;
		o.validate = validatePwm;

		presetOpt = s.option(form.ListValue, 'curve_preset', _('Fan Curve Preset'));
		presetOpt.value('quiet', _('Quiet - Lower speeds, higher temps'));
		presetOpt.value('balanced', _('Balanced - Good mix of noise and cooling'));
		presetOpt.value('performance', _('Performance - Higher speeds, lower temps'));
		presetOpt.value('custom', _('Custom - Define your own curve'));
		presetOpt.default = 'balanced';
		presetOpt.depends('mode', 'auto');
		presetOpt.onchange = syncUI;

		o = s.option(form.DummyValue, '_curve_graph', _('Curve Preview'));
		o.depends('mode', 'auto');
		o.rawhtml = true;
		o.cfgvalue = function() {
			scheduleSync();
			return '<canvas id="curve-canvas" width="500" height="300" style="border: 1px solid #ccc; background: #fff; display: block; margin: 10px auto;"></canvas>';
		};

		customSection = m.section(CustomCurveSection, 'custom', 'curve', _('Custom Curve Editor'),
			_('Define temperature thresholds and corresponding fan speeds.'));
		customSection.anonymous = true;
		customSection.addremove = false;
		customSection.tab('points', _('Curve Points'));

		for (var i = 1; i <= 5; i++) {
			o = customSection.taboption('points', form.Value, 'point' + i + '_temp', _('Point %d Temperature (\u00B0C)').format(i));
			o.datatype = 'and(uinteger,range(0,100))';
			o.rmempty = false;
			o.onchange = syncUI;
			tempOptions[i] = o;
			o.validate = (function(idx) {
				return function(section_id, value) {
					var res = true;
					var curr = parseStrictUint(value, 0, 100);

					if (curr === null) {
						res = _('Temperature must be an integer between 0 and 100 without leading zeros');
					}
					else {
						if (idx > 1) {
							var prev = parseStrictUint(
								readOptionValue(tempOptions[idx - 1], section_id, 'point' + (idx - 1) + '_temp'),
								0, 100
							);
							if (prev !== null && curr < prev)
								res = _('Point %d temperature must be >= Point %d temperature').format(idx, idx - 1);
						}

						if (res === true && idx < 5) {
							var next = parseStrictUint(
								readOptionValue(tempOptions[idx + 1], section_id, 'point' + (idx + 1) + '_temp'),
								0, 100
							);
							if (next !== null && curr > next)
								res = _('Point %d temperature must be <= Point %d temperature').format(idx, idx + 1);
						}
					}

					if (!revalidatingTemps) {
						revalidatingTemps = true;
						try {
							for (var j = 1; j <= 5; j++) {
								if (j !== idx && tempOptions[j] && typeof(tempOptions[j].triggerValidation) == 'function')
									tempOptions[j].triggerValidation(section_id);
							}
						}
						finally {
							revalidatingTemps = false;
						}
					}

					return res;
				};
			})(i);

			if (i === 5) {
				o = customSection.taboption('points', form.Value, 'point5_pwm', _('Point %d PWM (0-255)').format(i),
					_('Hardware-fixed at 255 (full speed) on NCT7802.'));
				o.default = '255';
				o.readonly = true;
				o.forcewrite = true;
				o.rmempty = false;
				o.cfgvalue = function() {
					return '255';
				};
				o.formvalue = function() {
					return '255';
				};
				o.validate = function(section_id, value) {
					return String(value == null ? '' : value).trim() === '255'
						? true
						: _('Point 5 PWM is hardware-fixed at 255');
				};
				o.write = function(section_id) {
					return uci.set('fan', section_id, 'point5_pwm', '255');
				};
			}
			else {
				o = customSection.taboption('points', form.Value, 'point' + i + '_pwm', _('Point %d PWM (0-255)').format(i));
				o.datatype = 'and(uinteger,range(0,255))';
				o.rmempty = false;
				o.onchange = syncUI;
				o.validate = validatePwm;
				pwmOptions[i] = o;
			}
		}

		return m.render().then(function(node) {
			scheduleSync();
			return node;
		});
	}
});
