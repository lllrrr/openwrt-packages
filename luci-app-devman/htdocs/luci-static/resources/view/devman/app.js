const API = '/cgi-bin/luci/admin/network/devman/api';

const vendorColors = {
  Xiaomi: '#ff6900', Samsung: '#3c6cfa', Apple: '#555',
  Huawei: '#cf0a2c', OnePlus: '#eb0028', Google: '#4285f4',
  Windows: '#0078d4', Linux: '#f5a623', Android: '#3ddc84',
  iOS: '#999', IoT: '#888'
};

function unknownIcon() {
  return '<svg width="18" height="18" viewBox="0 0 140 160" style="flex-shrink:0"><ellipse cx="70" cy="110" rx="55" ry="40" fill="#222"/><ellipse cx="70" cy="65" rx="40" ry="35" fill="#222"/><ellipse cx="55" cy="100" rx="22" ry="22" fill="#222"/><ellipse cx="85" cy="100" rx="22" ry="22" fill="#222"/><ellipse cx="50" cy="60" rx="8" ry="10" fill="#fff"/><ellipse cx="90" cy="60" rx="8" ry="10" fill="#fff"/><circle cx="52" cy="58" r="3" fill="#111"/><circle cx="92" cy="58" r="3" fill="#111"/><path d="M55 78Q70 70 85 78" stroke="#f5a623" stroke-width="4" fill="none" stroke-linecap="round"/><ellipse cx="70" cy="105" rx="25" ry="20" fill="#fff"/></svg>';
}

const { createApp } = Vue;

createApp({
  data() {
    return {
      title: '设备管理',
      devices: [],
      loading: true,
      refreshMs: 5000,
      timer: null,
      showUnknown: false,
      showLimitModal: false,
      showRenameModal: false,
      limitTarget: null,
      renameTarget: null,
      renameVal: '',
      limitUp: 0, limitUpUnit: '1000000',
      limitDn: 0, limitDnUnit: '1000000'
    };
  },
  computed: {
    knownDevices() {
      return this.devices.filter(d => d.device_type !== 'Unknown');
    },
    unknownDevices() {
      return this.devices.filter(d => d.device_type === 'Unknown');
    },
    deviceGroups() {
      const groups = [];
      if (this.knownDevices.length) {
        this.knownDevices.sort((a,b) => (a.current_ip||'').localeCompare(b.current_ip||''));
        groups.push({ label: '已知设备', devices: this.knownDevices });
      }
      return groups;
    }
  },
  methods: {
    deviceName(dev) { return dev.alias || dev.hostname || '未知设备'; },
    fmtSpeed(bps) {
      if (!bps || bps > 1e12) return '0';
      if (bps >= 1e9) return (bps / 1e9).toFixed(2) + ' Gbps';
      if (bps >= 1e6) return (bps / 1e6).toFixed(1) + ' Mbps';
      if (bps >= 1e3) return (bps / 1e3).toFixed(0) + ' Kbps';
      return bps + ' bps';
    },
    vendorIcon(t) {
      if (t === 'Unknown' || t === 'Linux' || !t) return unknownIcon();
      const c = vendorColors[t] || '#999';
      let n = t;
      if (n.length > 8) n = n.substring(0, 7) + '…';
      return '<span style="color:' + c + ';font-weight:700;font-size:15px;flex-shrink:0;line-height:1">' + this.esc(n) + '</span>';
    },
    esc(s) { return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); },
    async load() {
      try {
        const r = await fetch(API + '_devices');
        this.devices = await r.json();
        this.loading = false;
      } catch (e) { this.loading = false; }
    },
    changeRefresh() {
      if (this.timer) clearInterval(this.timer);
      this.timer = setInterval(() => this.load(), this.refreshMs);
    },
    async toggleBlock(dev) {
      await fetch(API + '_block?device_id=' + dev.id + '&block=' + (dev.is_blocked ? 0 : 1));
      await this.load();
    },
    showLimit(dev) {
      this.limitTarget = dev;
      const toVal = (v) => {
        if (!v) return 0;
        if (v >= 1e9) return { val: v / 1e9, unit: '1000000000' };
        if (v >= 1e6) return { val: v / 1e6, unit: '1000000' };
        return { val: v / 1e3, unit: '1000' };
      };
      const up = toVal(dev.rate_limit);
      const dn = toVal(dev.rate_limit_down);
      this.limitUp = +up.val.toFixed(1);
      this.limitUpUnit = up.unit;
      this.limitDn = +dn.val.toFixed(1);
      this.limitDnUnit = dn.unit;
      this.showLimitModal = true;
    },
    async applyLimit() {
      const up = Math.round(this.limitUp * parseInt(this.limitUpUnit)) || 0;
      const dn = Math.round(this.limitDn * parseInt(this.limitDnUnit)) || 0;
      await fetch(API + '_limit?device_id=' + this.limitTarget.id + '&rate_limit=' + up + '&rate_limit_down=' + dn);
      this.showLimitModal = false;
      await this.load();
    },
    showRename(dev) {
      this.renameTarget = dev;
      this.renameVal = dev.alias || dev.hostname || '';
      this.showRenameModal = true;
    },
    async applyRename() {
      if (this.renameVal) {
        await fetch(API + '_limit?device_id=' + this.renameTarget.id + '&rate_limit=-1&alias=' + encodeURIComponent(this.renameVal));
      }
      this.showRenameModal = false;
      await this.load();
    }
  },
  mounted() {
    this.load();
    this.timer = setInterval(() => this.load(), this.refreshMs);
  },
  beforeUnmount() {
    if (this.timer) clearInterval(this.timer);
  }
}).mount('#dm-app');
