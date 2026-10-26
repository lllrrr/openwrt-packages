'use strict';
'require view';
'require form';
'require fs';
'require uci';
'require ui';

var INITD   = '/etc/init.d/tasks';
var HANDLER = '/usr/bin/tasks-handler';
var CRON    = '/etc/crontabs/root';

/* Load the shared stylesheet once. It only uses theme CSS variables, so it
 * follows the light / dark variant of Bootstrap and Argon by itself. */
function addStylesheet()
{
	if (document.querySelector('link[data-tasks-style]'))
		return;

	document.head.appendChild(E('link', {
		'rel': 'stylesheet',
		'type': 'text/css',
		'href': L.resource('view/tasks.css'),
		'data-tasks-style': '1'
	}));
}

var WEEKDAYS = [
	_('Sunday'), _('Monday'), _('Tuesday'), _('Wednesday'),
	_('Thursday'), _('Friday'), _('Saturday')
];

var ACTION_LABELS = {
	reboot:   _('Reboot'),
	network:  _('Restart network'),
	firewall: _('Restart firewall'),
	cleantmp: _('Clean temporary files'),
	clearmem: _('Free memory'),
	wifion:   _('Turn WiFi on'),
	wifioff:  _('Turn WiFi off')
};

var ACTION_BUTTONS = {
	reboot:   _('Reboot now'),
	network:  _('Restart network now'),
	firewall: _('Restart firewall now'),
	cleantmp: _('Clean temporary files now'),
	clearmem: _('Free memory now')
};

var TASK_NAMES = [
	'reboot', 'network', 'firewall', 'cleantmp', 'clearmem', 'wifion', 'wifioff'
];

/* Set in render(), read by the task picker and by handleReset(). */
var selectedTask = TASK_NAMES[0];
var mapRoot = null;

/* All task cards stay in the form so that saving keeps every task's
 * settings; the picker only decides which card is visible. */
function showSelectedTask()
{
	var node;

	for (var i = 0; i < TASK_NAMES.length; i++) {
		node = mapRoot
			? mapRoot.querySelector('#cbi-tasks-' + TASK_NAMES[i])
			: null;

		if (!node)
			continue;

		/* The id sits on the inner option container; hide the whole card,
		 * including its title and description. */
		node = node.closest('.cbi-section') || node;
		node.style.display = (TASK_NAMES[i] === selectedTask) ? '' : 'none';
	}
}

/* Number choices 0..23 / 0..59 / 1..31, rendered as zero padded labels. */
function numberChoices(o, from, to, width)
{
	for (var i = from; i <= to; i++) {
		var s = String(i);

		while (s.length < width)
			s = '0' + s;

		o.value(String(i), s);
	}
}

/* Attach the shared "when to run" controls to a task section. */
function addScheduleOptions(s, defaultMode, defaultHour)
{
	var o;

	o = s.option(form.Flag, 'enabled', _('Enable'));
	o.rmempty = false;
	o.default = '0';

	o = s.option(form.ListValue, 'mode', _('Run'));
	o.value('daily', _('Every day'));
	o.value('weekly', _('Every week'));
	o.value('monthly', _('Every month'));
	o.value('hourly', _('Every hour'));
	o.value('interval_minutes', _('Every few minutes'));
	o.value('interval_hours', _('Every few hours'));
	o.default = defaultMode;
	o.rmempty = false;

	o = s.option(form.ListValue, 'hour', _('Hour'));
	numberChoices(o, 0, 23, 2);
	o.default = defaultHour || '3';
	o.rmempty = false;
	o.retain = true;
	o.depends('mode', 'daily');
	o.depends('mode', 'weekly');
	o.depends('mode', 'monthly');

	o = s.option(form.ListValue, 'minute', _('Minute'));
	numberChoices(o, 0, 59, 2);
	o.default = '0';
	o.rmempty = false;
	o.retain = true;
	o.depends('mode', 'daily');
	o.depends('mode', 'weekly');
	o.depends('mode', 'monthly');
	o.depends('mode', 'hourly');
	o.depends('mode', 'interval_hours');

	o = s.option(form.ListValue, 'weekday', _('Day of the week'));
	o.value('1-5', _('Monday to Friday'));
	o.value('0,6', _('Saturday and Sunday'));
	for (var d = 0; d <= 6; d++)
		o.value(String(d), WEEKDAYS[d]);
	o.default = '1';
	o.rmempty = false;
	o.retain = true;
	o.depends('mode', 'weekly');

	o = s.option(form.ListValue, 'monthday', _('Day of the month'));
	for (var m = 1; m <= 31; m++)
		o.value(String(m), String(m));
	o.default = '1';
	o.rmempty = false;
	o.retain = true;
	o.depends('mode', 'monthly');

	o = s.option(form.ListValue, 'interval_minutes', _('Number of minutes'));
	numberChoices(o, 5, 55, 2);
	o.default = '15';
	o.rmempty = false;
	o.retain = true;
	o.depends('mode', 'interval_minutes');

	o = s.option(form.ListValue, 'interval_hours', _('Number of hours'));
	numberChoices(o, 1, 23, 2);
	o.default = '6';
	o.rmempty = false;
	o.retain = true;
	o.depends('mode', 'interval_hours');
}

function countEnabledTasks()
{
	var n = 0;

	for (var i = 0; i < TASK_NAMES.length; i++)
		if (uci.get('tasks', TASK_NAMES[i], 'enabled') === '1')
			n++;

	return n;
}

return view.extend({
	load: function() {
		return uci.load('tasks');
	},

	render: function() {
		addStylesheet();

		var m = new form.Map('tasks', '',
			_('Choose what should happen and when. The application writes the needed cron entries for you, no command line or cron syntax required.'));

		this.map = m;

		var s;

		/* --- Scheduled reboot ------------------------------------------- */
		s = m.section(form.NamedSection, 'reboot', 'task', _('Scheduled reboot'),
			_('Restart the device automatically. All connections are dropped for a short time.'));
		addScheduleOptions(s, 'daily');

		/* --- Network restart -------------------------------------------- */
		s = m.section(form.NamedSection, 'network', 'task', _('Scheduled network restart'),
			_('Restart the network service (for example to renew a DHCP lease or recover a stalled connection).'));
		addScheduleOptions(s, 'daily');

		/* --- Firewall restart ------------------------------------------- */
		s = m.section(form.NamedSection, 'firewall', 'task', _('Scheduled firewall restart'),
			_('Reload the firewall rules. Existing connections are usually kept.'));
		addScheduleOptions(s, 'daily');

		/* --- Temporary file cleanup ------------------------------------- */
		s = m.section(form.NamedSection, 'cleantmp', 'task', _('Scheduled temporary file cleanup'),
			_('/tmp lives in memory. Removing old files there frees RAM without touching any settings.'));
		addScheduleOptions(s, 'hourly');

		var o = s.option(form.ListValue, 'clean_mode', _('What to remove'));
		o.value('cache', _('Only known caches (safe)'));
		o.value('age', _('Caches and files older than the age below'));
		o.default = 'cache';
		o.rmempty = false;

		o = s.option(form.Value, 'clean_age', _('Remove files older than (minutes)'));
		o.value('30', _('30 minutes'));
		o.value('60', _('1 hour'));
		o.value('360', _('6 hours'));
		o.value('1440', _('1 day'));
		o.value('4320', _('3 days'));
		o.value('10080', _('7 days'));
		o.datatype = 'range(1,525600)';
		o.default = '1440';
		o.rmempty = false;
		o.depends('clean_mode', 'age');

		/* --- Memory cleanup --------------------------------------------- */
		s = m.section(form.NamedSection, 'clearmem', 'task', _('Scheduled memory cleanup'),
			_('Releases cached file data from RAM. Safe to run at any time, but running it very often can slow the device down.'));
		addScheduleOptions(s, 'interval_hours');

		/* --- WiFi ------------------------------------------------------- */
		s = m.section(form.NamedSection, 'wifion', 'task', _('Scheduled WiFi on'),
			_('Turn all wireless radios on at the scheduled time. The setting is kept across reboots.'));
		addScheduleOptions(s, 'daily', '7');

		s = m.section(form.NamedSection, 'wifioff', 'task', _('Scheduled WiFi off'),
			_('Turn all wireless radios off at the scheduled time. Wired devices and the router itself keep working. The setting is kept across reboots.'));
		addScheduleOptions(s, 'daily', '23');

		/* --- Global switch ---------------------------------------------- */
		s = m.section(form.NamedSection, 'global', 'global', _('Master switch'),
			_('When disabled, all scheduled tasks, startup entries and access control rules are skipped, but their settings are kept.'));

		o = s.option(form.Flag, 'enabled', _('Enable scheduled tasks'));
		o.rmempty = false;
		o.default = '1';

		/* --- Task picker ------------------------------------------------- */
		/* Open on the first enabled task, otherwise on the first one. */
		for (var i = 0; i < TASK_NAMES.length; i++) {
			if (uci.get('tasks', TASK_NAMES[i], 'enabled') === '1') {
				selectedTask = TASK_NAMES[i];
				break;
			}
		}

		var picker = E('div', { 'class': 'cbi-section tasks-picker' }, [
			E('label', { 'for': 'tasks-task-select' }, _('Task')),
			E('select', {
				'class': 'cbi-input-select',
				'id': 'tasks-task-select',
				'change': function(ev) {
					selectedTask = ev.target.value;
					showSelectedTask();
				}
			}, TASK_NAMES.map(function(name) {
				return E('option', {
					'value': name,
					'selected': (name === selectedTask) ? '' : null
				}, ACTION_LABELS[name]);
			}))
		]);

		/* --- Status strip and one-click actions ------------------------- */
		var cronList = E('pre', { 'class': 'tasks-cron-list' },
			_('Cron entries written by this application will appear here after saving.'));

		var cronCount = E('strong', {}, '0');
		var enabledCount = E('strong', {}, String(countEnabledTasks()));
		var globalWarn = E('div', { 'class': 'alert-message warning tasks-warning' },
			_('The master switch is off, so no generated task will run.'));

		function refreshCron() {
			return L.resolveDefault(fs.read(CRON), '').then(function(text) {
				var lines = (text || '').split('\n').filter(function(line) {
					return line.indexOf('# luci-app-tasks:') > -1;
				});

				cronCount.textContent = String(lines.length);
				cronList.textContent = lines.length
					? lines.join('\n')
					: _('No scheduled jobs yet. Enable a task below and click “Save & Apply”.');
				return lines.length;
			});
		}

		function execAction(action) {
			var label = ACTION_LABELS[action] || action;

			ui.showModal(null, [
				E('p', { 'class': 'spinning' }, _('Running “%s”…').format(label))
			]);

			return L.resolveDefault(fs.exec(HANDLER, [ 'exec', action ]), null).then(function(res) {
				ui.hideModal();

				if (res && res.code === 0)
					ui.addNotification(null, E('p', {},
						_('Action completed: %s').format(label)), 'success');
				else
					ui.addNotification(null, E('p', {},
						_('Action failed: %s (%s)').format(label,
							(res && (res.stderr || res.stdout)) || _('unknown error'))), 'danger');

				return refreshCron();
			}).catch(function(err) {
				ui.hideModal();
				ui.addNotification(null, E('p', {},
					_('Action failed: %s (%s)').format(label, err.message || _('unknown error'))), 'danger');
			});
		}

		function confirmAction(action) {
			var label = ACTION_LABELS[action] || action;

			ui.showModal(_('Confirm'), [
				E('p', {}, _('Do you really want to run “%s” now?').format(label)),
				(action === 'reboot')
					? E('p', { 'class': 'alert-message warning' },
						_('The device reboots immediately and this page will become unreachable.'))
					: '',
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')),
					' ',
					E('button', {
						'class': 'cbi-button cbi-button-apply',
						'click': function() {
							ui.hideModal();
							execAction(action);
						}
					}, _('Run now'))
				])
			]);
		}

		function actionButton(action) {
			return E('button', {
				'class': 'cbi-button cbi-button-action',
				'click': function() { confirmAction(action); }
			}, ACTION_BUTTONS[action]);
		}

		var toolbar = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Run a task once, right now')),
			E('div', { 'class': 'tasks-toolbar' }, [
				actionButton('reboot'),
				actionButton('network'),
				actionButton('firewall'),
				actionButton('cleantmp'),
				actionButton('clearmem')
			])
		]);

		var status = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Status')),
			E('p', { 'class': 'tasks-status' }, [
				E('span', {}, [ _('Enabled tasks'), ': ', enabledCount, ' / ' + TASK_NAMES.length ]),
				E('span', {}, [ _('Generated cron entries'), ': ', cronCount ]),
				E('button', {
					'class': 'cbi-button cbi-button-neutral',
					'click': function() { refreshCron(); }
				}, _('Refresh'))
			]),
			(uci.get('tasks', 'global', 'enabled') === '1') ? '' : globalWarn,
			E('details', { 'class': 'tasks-details' }, [
				E('summary', {}, _('Show generated cron entries')),
				cronList
			])
		]);

		return m.render().then(function(formNode) {
			mapRoot = formNode;
			showSelectedTask();
			L.Poll.add(refreshCron, 10);
			refreshCron();

			return E('div', {}, [ status, toolbar, picker, formNode ]);
		});
	},

	/* Map.save() redraws the form contents, which replaces the task cards
	 * with fresh nodes and drops the inline display styles applied by the
	 * picker. Without this, all task cards spread out until the page is
	 * rendered again. */
	handleSave: function(ev) {
		return this.map.save().then(function() {
			showSelectedTask();
		});
	},

	/* Save through the standard footer, then ask the init script to
	 * translate the committed UCI options into cron entries and a boot
	 * script. The `uci-applied` event fires once the commit is done. */
	handleSaveApply: function(ev, mode) {
		function applyNow() {
			document.removeEventListener('uci-applied', applyNow);

			function failed() {
				ui.addNotification(null, E('p', {},
					_('Configuration was saved, but the schedule could not be rebuilt. Reboot the device to retry.')), 'danger');
			}

			return fs.exec(INITD, [ 'reload' ]).then(function(res) {
				if (res && res.code === 0)
					ui.addNotification(null, E('p', {},
						_('Schedule applied. The generated cron entries are up to date.')), 'success');
				else
					failed();
			}).catch(failed);
		}

		document.addEventListener('uci-applied', applyNow);

		return this.handleSave(ev).then(function() {
			ui.changes.apply(mode == '0');
		}, function(err) {
			/* Validation failed, no commit will happen: drop the listener so
			 * it cannot fire for an unrelated apply later on. */
			document.removeEventListener('uci-applied', applyNow);
			throw err;
		});
	},

	/* The picker sits outside the form, so apply the selection again after
	 * the reset has redrawn the task cards. */
	handleReset: function(ev) {
		return this.map.reset().then(function() {
			showSelectedTask();
		});
	}
});
