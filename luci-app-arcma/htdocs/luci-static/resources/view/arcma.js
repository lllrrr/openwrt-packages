'use strict';
'require view';
'require dom';
'require fs';
'require uci';
'require ui';
'require form';

// ─── Constants ─────────────────────────────────────────────────────────────
const OUI_TYPES = ['router', 'wlan', 'eth', 'console'];

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
      fs.exec('arcma', ['show']).catch(() => ({ stdout: '', stderr: '' }))
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

  // ── Build vendor ListValue options for a given type ───────────────────
  vendorOptions(type, allVendors) {
    return allVendors[type] || [];
  },

  // ── Run arcma command and show output ─────────────────────────────────
  handleCommand(cmd, args, outputEl) {
    const buttons = document.querySelectorAll('.arcma-action-btn');
    buttons.forEach(b => b.setAttribute('disabled', 'true'));

    return fs.exec('arcma', [cmd, ...args]).then(res => {
      dom.content(outputEl, res.stdout || res.stderr || _('(no output)'));
      outputEl.style.display = '';
    }).catch(err => {
      ui.addNotification(null, E('p', {}, String(err)));
    }).finally(() => {
      buttons.forEach(b => b.removeAttribute('disabled'));
    });
  },

  handleApply(ev, outputEl) {
    return this.map.save(null, true).then(() =>
      fs.exec('arcma', ['uci-apply'])
    ).then(res => {
      dom.content(outputEl, res.stdout || res.stderr || _('Done'));
      outputEl.style.display = '';
    }).catch(err => {
      ui.addNotification(null, E('p', {}, String(err)));
    });
  },

  handleRestore(ev, outputEl) {
    return fs.exec('arcma', ['uci-restore']).then(res => {
      dom.content(outputEl, res.stdout || res.stderr || _('Done'));
      outputEl.style.display = '';
    }).catch(err => {
      ui.addNotification(null, E('p', {}, String(err)));
    });
  },

  handleShow(ev, outputEl) {
    return fs.exec('arcma', ['show']).then(res => {
      dom.content(outputEl, res.stdout || _('(no output)'));
      outputEl.style.display = '';
    }).catch(err => {
      ui.addNotification(null, E('p', {}, String(err)));
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

    // m1 fix: store map on view instance so handleApply/handleRestore can call this.map.save()
    this.map = new form.Map('arcma',
      _('Auto MAC Randomizer'),
      _('Automatically change MAC addresses of network interfaces on boot and/or interface up. No external dependencies required.')
    );
    const m = this.map;

    // ── Global Settings ─────────────────────────────────────────────
    s = m.section(form.NamedSection, 'global', 'arcma', _('Global Settings'));
    s.anonymous = false;
    s.addremove = false;

    o = s.option(form.Flag, 'enabled', _('Enable arcma'));
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

    o = s.option(form.Flag, 'sequence', _('Sequence mode'),
      _('NIC bytes increment across multiple interfaces (same OUI prefix for all)'));
    o.depends('mode', 'oui');
    o.rmempty = false;

    o = s.option(form.Flag, 'persist', _('Persist MAC'),
      _('Write randomized MAC into <code>uci network.&lt;iface&gt;.macaddr</code> so it survives reboot'));
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

    o = s.option(form.Flag, 'sequence', _('Seq'));
    o.depends('mode', 'oui');
    o.rmempty = false;

    o = s.option(form.Flag, 'persist', _('Persist'));
    o.rmempty = false;

    // ── Action buttons & status output ──────────────────────────────
    // m2 fix: use DummySection instead of TypedSection with a fake UCI type
    s = m.section(form.GridSection, '_actions');
    s.render = L.bind(function (view, section_id) {
      const outputEl = E('pre', {
        'class': 'arcma-output',
        'style': 'display:none; margin-top:8px; padding:8px; background:#1a1a1a; color:#e0e0e0; border-radius:4px; white-space:pre-wrap; max-height:300px; overflow-y:auto'
      });

      return E('div', { 'class': 'cbi-section' }, [
        E('h3', {}, [_('Actions')]),
        E('div', { 'style': 'display:flex; gap:8px; flex-wrap:wrap; margin-bottom:8px' }, [
          E('button', {
            'class': 'btn cbi-button cbi-button-apply arcma-action-btn',
            'click': ui.createHandlerFn(view, 'handleApply', outputEl)
          }, [_('Apply Now')]),
          E('button', {
            'class': 'btn cbi-button cbi-button-reset arcma-action-btn',
            'click': ui.createHandlerFn(view, 'handleRestore', outputEl)
          }, [_('Restore Original')]),
          E('button', {
            'class': 'btn cbi-button arcma-action-btn',
            'click': ui.createHandlerFn(view, 'handleShow', outputEl)
          }, [_('Show Status')]),
        ]),
        outputEl
      ]);
    }, o, this);

    return m.render();
  }
});
