'use strict';
'require view';
'require dom';
'require fs';
'require uci';
'require ui';
'require form';

// ─── Constants ─────────────────────────────────────────────────────────────
const OUI_TYPES = ['router', 'wlan', 'eth', 'console'];
const ARCMA_BIN = '/usr/sbin/arcma';

return view.extend({

  // ── Load phase: gather all required data in parallel ──────────────────
  load() {
    return Promise.all([
      uci.load('arcma'),
      // Read each vendor file from the embedded OUI database
      ...OUI_TYPES.map(t =>
        fs.read(`/usr/share/arcma/oui/${t}.txt`).catch(() => '')
      ),
      // Read current interface MAC addresses from sysfs
      fs.exec(ARCMA_BIN, ['show']).catch(() => ({ stdout: '', stderr: '' }))
    ]);
  },

  // ── Parse vendor file: "Name\tOUI1 OUI2 ..." → [{value,label}] ────────
  parseVendors(txt) {
    if (!txt) return [];
    return txt.split('\n')
      .filter(l => l.trim() && !l.startsWith('#'))
      .map(l => l.split('\t')[0].trim())
      .filter(Boolean)
      .map(n => ({ value: n, label: n }));
  },

  setActionBusy(busy) {
    const buttons = document.querySelectorAll('.arcma-action-btn');
    buttons.forEach(b => {
      if (busy)
        b.setAttribute('disabled', 'true');
      else
        b.removeAttribute('disabled');
    });
  },

  showOutput(outputEl, text) {
    if (!outputEl)
      return;

    dom.content(outputEl, text || _('(no output)'));
    outputEl.style.display = '';
  },

  sleep(ms) {
    return new Promise(resolve => window.setTimeout(resolve, ms));
  },

  readLastLog() {
    return fs.exec(ARCMA_BIN, ['last-log']).then(res =>
      res.stdout || res.stderr || _('(no output)')
    );
  },

  waitForAsyncResult(outputEl, startedText) {
    const finishedRe = /\[arcma\] .+ finished rc=([0-9]+)/;
    let attempts = 0;

    this.showOutput(outputEl, startedText || _('Started'));

    const poll = () => {
      attempts++;
      return this.sleep(1000).then(() => this.readLastLog()).then(text => {
        this.showOutput(outputEl, text);

        const match = finishedRe.exec(text);
        if (match) {
          if (match[1] !== '0')
            ui.addNotification(null, E('p', {}, _('ARCMA finished with errors. Check the output log.')));
          return text;
        }

        if (attempts >= 30) {
          ui.addNotification(null, E('p', {}, _('ARCMA is still running or did not report completion. Check /tmp/arcma/last.log.')));
          return text;
        }

        return poll();
      });
    };

    return poll();
  },

  handleApply(outputEl, ev) {
    this.setActionBusy(true);

    return this.map.save(null, true).then(() =>
      fs.exec(ARCMA_BIN, ['uci-apply-async'])
    ).then(res => {
      return this.waitForAsyncResult(outputEl, res.stdout || res.stderr || _('Started'));
    }).catch(err => {
      ui.addNotification(null, E('p', {}, String(err)));
    }).finally(() => {
      this.setActionBusy(false);
    });
  },

  handleRestore(outputEl, ev) {
    this.setActionBusy(true);

    return fs.exec(ARCMA_BIN, ['uci-restore-async']).then(res => {
      return this.waitForAsyncResult(outputEl, res.stdout || res.stderr || _('Started'));
    }).catch(err => {
      ui.addNotification(null, E('p', {}, String(err)));
    }).finally(() => {
      this.setActionBusy(false);
    });
  },

  handleShow(outputEl, ev) {
    this.setActionBusy(true);

    return fs.exec(ARCMA_BIN, ['show']).then(res => {
      this.showOutput(outputEl, res.stdout || res.stderr || _('(no output)'));
    }).catch(err => {
      ui.addNotification(null, E('p', {}, String(err)));
    }).finally(() => {
      this.setActionBusy(false);
    });
  },

  // ── Render ─────────────────────────────────────────────────────────────
  render(data) {
    const allVendorRaw = {
      router: data[1],
      wlan: data[2],
      eth: data[3],
      console: data[4]
    };
    const allVendors = {};
    for (const t of OUI_TYPES)
      allVendors[t] = this.parseVendors(allVendorRaw[t]);

    let s, o;

    // Store map on the view instance so action handlers can save it.
    this.map = new form.Map('arcma',
      _('ARCMA'),
      _('Automatically change MAC addresses of physical network interfaces on boot and/or interface up.')
    );
    const m = this.map;

    // ── Global Settings ─────────────────────────────────────────────
    s = m.section(form.NamedSection, 'global', 'arcma', _('Global Settings'));
    s.anonymous = false;
    s.addremove = false;

    o = s.option(form.Flag, 'enabled', _('Enable ARCMA'));
    o.rmempty = false;

    o = s.option(form.ListValue, 'trigger', _('Trigger'),
      _('<b>boot</b>: apply at startup only. <b>ifup</b>: apply on every interface-up event. <b>both</b>: apply on both.'));
    o.value('boot', _('Boot only'));
    o.value('ifup', _('Interface up (hotplug)'));
    o.value('both', _('Boot + Interface up'));
    o.default = 'both';
    o.rmempty = false;

    // MAC mode
    o = s.option(form.ListValue, 'mode', _('Default MAC mode'));
    o.value('local', _('Locally administered (random)'));
    o.value('oui', _('Vendor OUI prefix'));
    o.value('static', _('Static MAC address'));
    o.default = 'local';
    o.rmempty = false;

    // OUI type (only relevant when mode=oui)
    o = s.option(form.ListValue, 'oui_type', _('Default OUI type'));
    for (const t of OUI_TYPES) o.value(t, t.charAt(0).toUpperCase() + t.slice(1));
    o.default = 'router';
    o.depends('mode', 'oui');
    o.rmempty = false;

    // Per oui_type: show vendor list dynamically
    for (const t of OUI_TYPES) {
      o = s.option(form.ListValue, `_vendor_${t}`, _('Vendor name'));
      for (const v of allVendors[t]) o.value(v.value, v.label);
      o.depends({ mode: 'oui', oui_type: t });
      o.ucioption = 'oui_vendor';
      o.rmempty = true;
    }

    // Manual OUI prefix
    o = s.option(form.Value, 'oui_prefix', _('Manual OUI prefix'),
      _('Overrides vendor selection. Format: <code>XX:XX:XX</code>'));
    o.placeholder = 'e.g. 74:D0:2B';
    o.depends('mode', 'oui');
    o.rmempty = true;
    o.validate = function (section_id, value) {
      if (!value) return true;
      return /^[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}$/.test(value)
        ? true : _('Must be XX:XX:XX format');
    };

    o = s.option(form.Value, 'static_mac', _('Static MAC address'));
    o.placeholder = 'XX:XX:XX:XX:XX:XX';
    o.depends('mode', 'static');
    o.rmempty = false;
    o.validate = function (section_id, value) {
      return /^[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}$/.test(value)
        ? true : _('Must be XX:XX:XX:XX:XX:XX format');
    };

    o = s.option(form.Flag, 'sequence', _('Sequence mode'),
      _('NIC bytes increment across multiple interfaces (same OUI prefix for all)'));
    o.depends('mode', 'oui');
    o.rmempty = false;

    o = s.option(form.Flag, 'persist', _('Persist MAC'),
      _('Write randomized MAC into <code>/etc/config/network</code> so it survives reboot. If no matching device section exists, ARCMA creates one.<br /><b>Warning:</b> Frequent writes to UCI config can wear out flash memory on some devices.'));
    o.rmempty = false;

    // ── Per-interface table ──────────────────────────────────────────
    s = m.section(form.TableSection, 'iface', _('Per-interface Override'),
      _('Leave empty to apply global settings to all physical interfaces. Add rows to override per interface.'));
    s.anonymous = true;
    s.addremove = true;
    s.sortable = false;
    s.nodescriptions = true;

    o = s.option(form.Flag, 'enabled', _('Enable'));
    o.rmempty = false;
    o.default = '1';

    o = s.option(form.Value, 'device', _('Interface / Device'));
    o.placeholder = '* (all) or eth0, wlan0 …';
    o.rmempty = false;

    o = s.option(form.ListValue, 'mode', _('Mode'));
    o.value('local', _('Local'));
    o.value('oui', _('OUI'));
    o.value('static', _('Static'));
    o.default = 'local';
    o.rmempty = false;

    o = s.option(form.ListValue, 'oui_type', _('OUI type'));
    for (const t of OUI_TYPES) o.value(t, t);
    o.default = 'router';
    o.depends('mode', 'oui');
    o.rmempty = true;

    // vendor fields per type (table section)
    for (const t of OUI_TYPES) {
      o = s.option(form.ListValue, `_tvendor_${t}`, _('Vendor'));
      for (const v of allVendors[t]) o.value(v.value, v.label);
      o.depends({ mode: 'oui', oui_type: t });
      o.ucioption = 'oui_vendor';
      o.rmempty = true;
    }

    o = s.option(form.Value, 'oui_prefix', _('Manual OUI'));
    o.placeholder = 'XX:XX:XX';
    o.depends('mode', 'oui');
    o.rmempty = true;
    o.validate = function (section_id, value) {
      if (!value) return true;
      return /^[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}$/.test(value)
        ? true : _('Must be XX:XX:XX format');
    };

    o = s.option(form.Value, 'static_mac', _('Static MAC'));
    o.placeholder = 'XX:XX:XX:XX:XX:XX';
    o.depends('mode', 'static');
    o.rmempty = false;
    o.validate = function (section_id, value) {
      return /^[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}$/.test(value)
        ? true : _('Must be XX:XX:XX:XX:XX:XX format');
    };

    o = s.option(form.Flag, 'sequence', _('Seq'));
    o.depends('mode', 'oui');
    o.rmempty = false;

    o = s.option(form.Flag, 'persist', _('Persist'));
    o.rmempty = false;

    return m.render().then(node => {
      const outputEl = E('pre', {
        'class': 'arcma-output',
        'style': 'display:none; margin-top:8px; padding:8px; background:#1a1a1a; color:#e0e0e0; border-radius:4px; white-space:pre-wrap; max-height:300px; overflow-y:auto'
      });

      return E('div', {}, [
        node,
        E('div', { 'class': 'cbi-section' }, [
          E('h3', {}, [_('Actions')]),
          E('div', { 'style': 'display:flex; gap:8px; flex-wrap:wrap; margin-bottom:8px' }, [
            E('button', {
              'class': 'btn cbi-button cbi-button-apply arcma-action-btn',
              'click': ui.createHandlerFn(this, 'handleApply', outputEl)
            }, [_('Apply Now')]),
            E('button', {
              'class': 'btn cbi-button cbi-button-reset arcma-action-btn',
              'click': ui.createHandlerFn(this, 'handleRestore', outputEl)
            }, [_('Restore Original')]),
            E('button', {
              'class': 'btn cbi-button arcma-action-btn',
              'click': ui.createHandlerFn(this, 'handleShow', outputEl)
            }, [_('Show Status')]),
          ]),
          outputEl
        ])
      ]);
    });
  }
});
