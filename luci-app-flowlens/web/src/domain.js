export function numberValue(value) {
  const next = Number(value);
  return Number.isFinite(next) ? next : 0;
}

export function asDeviceList(value) {
  return Array.isArray(value) ? value : [];
}

export function asStringList(value) {
  if (Array.isArray(value))
    return Array.from(new Set(value.map(item => String(item || '').trim()).filter(Boolean)));

  const next = String(value || '').trim();
  return next ? [next] : [];
}

export function splitIpAddress(value) {
  const ip = String(value || '').trim();

  if (!ip)
    return { ipv4: [], ipv6: [] };

  return ip.includes(':')
    ? { ipv4: [], ipv6: [ip] }
    : { ipv4: [ip], ipv6: [] };
}

export function formatRate(bytesPerSecond) {
  const value = numberValue(bytesPerSecond);
  return `${(value / 1024 / 1024).toFixed(2)} MB/s`;
}

export function formatBytes(bytes) {
  const value = numberValue(bytes);
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let current = Math.abs(value);
  let index = 0;

  while (current >= 1024 && index < units.length - 1) {
    current /= 1024;
    index += 1;
  }

  const signed = value < 0 ? -current : current;
  const precision = index === 0 ? 0 : current >= 100 ? 0 : 1;
  return `${signed.toFixed(precision)} ${units[index]}`;
}

export function formatClock(timestamp) {
  const value = numberValue(timestamp);

  if (!value)
    return '-';

  return new Date(value * 1000).toLocaleTimeString([], {
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit'
  });
}

export function normalizeDevice(device) {
  const name = device?.name || 'Unknown device';
  const fallbackIp = splitIpAddress(device?.ip);
  const ipv4 = asStringList(device?.ipv4).concat(fallbackIp.ipv4)
    .filter((item, index, list) => list.indexOf(item) === index);
  const ipv6 = asStringList(device?.ipv6).concat(fallbackIp.ipv6)
    .filter((item, index, list) => list.indexOf(item) === index);
  const history_ipv4 = asStringList(device?.history_ipv4);
  const history_ipv6 = asStringList(device?.history_ipv6);

  return {
    mac: String(device?.mac || '').toLowerCase(),
    ip: String(device?.ip || ipv4[0] || ipv6[0] || ''),
    ipv4,
    ipv6,
    history_ipv4,
    history_ipv6,
    name,
    online: Boolean(device?.online),
    down_bps: numberValue(device?.down_bps),
    up_bps: numberValue(device?.up_bps),
    rx_bytes: numberValue(device?.rx_bytes),
    tx_bytes: numberValue(device?.tx_bytes),
    connections: numberValue(device?.connections),
    last_seen: numberValue(device?.last_seen)
  };
}

export function getDeviceInitial(name) {
  const value = String(name || '?').trim();
  return value ? value.charAt(0).toUpperCase() : '?';
}

export function getDeviceText(device) {
  return [
    device.name,
    device.ip,
    ...asStringList(device.ipv4),
    ...asStringList(device.ipv6),
    ...asStringList(device.history_ipv4),
    ...asStringList(device.history_ipv6),
    device.mac
  ].join(' ').toLowerCase();
}

function compareText(a, b) {
  return String(a || '').localeCompare(String(b || ''), undefined, {
    numeric: true,
    sensitivity: 'base'
  });
}

function firstAddress(device) {
  return device.ipv4[0] || device.ipv6[0] || device.ip || '';
}

function sortMetric(device, key) {
  switch (key) {
    case 'rate':
      return device.down_bps + device.up_bps;
    case 'total':
      return device.rx_bytes + device.tx_bytes;
    default:
      return 0;
  }
}

export function compareDevices(a, b, sort = {}) {
  const key = sort?.key || 'status';
  const direction = sort?.direction === 'desc' ? -1 : 1;
  let result = 0;

  switch (key) {
    case 'device':
      result = compareText(a.name || a.mac, b.name || b.mac);
      break;
    case 'ip':
      result = compareText(firstAddress(a), firstAddress(b));
      break;
    case 'mac':
      result = compareText(a.mac, b.mac);
      break;
    case 'rate':
    case 'total':
      result = sortMetric(a, key) - sortMetric(b, key);
      break;
    case 'status':
    default:
      result = a.online === b.online ? 0 : a.online ? -1 : 1;
      break;
  }

  if (result !== 0)
    return result * direction;

  if (key !== 'status' && a.online !== b.online)
    return a.online ? -1 : 1;

  return compareText(a.name || a.mac, b.name || b.mac);
}

export function filterAndSortDevices(devices, filter = 'all', query = '', sort = { key: 'rate', direction: 'desc' }) {
  const normalizedQuery = String(query || '').trim().toLowerCase();

  return asDeviceList(devices)
    .map(normalizeDevice)
    .filter(device => {
      if (filter === 'online' && !device.online)
        return false;

      if (filter === 'offline' && device.online)
        return false;

      return !normalizedQuery || getDeviceText(device).includes(normalizedQuery);
    })
    .sort((a, b) => compareDevices(a, b, sort));
}

export function buildSummary(payload) {
  const summary = payload?.summary || {};
  const devices = asDeviceList(payload?.devices).map(normalizeDevice);

  return {
    total: numberValue(summary.total || devices.length),
    online: numberValue(summary.online || devices.filter(device => device.online).length),
    offline: numberValue(summary.offline || devices.filter(device => !device.online).length),
    down_bps: numberValue(summary.down_bps || devices.reduce((total, device) => total + device.down_bps, 0)),
    up_bps: numberValue(summary.up_bps || devices.reduce((total, device) => total + device.up_bps, 0))
  };
}
