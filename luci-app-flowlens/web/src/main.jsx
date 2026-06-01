import React, { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import {
  ArrowDown,
  ArrowUp,
  ChevronDown,
  ChevronUp,
  ChevronsUpDown,
  Clock3,
  Info,
  Monitor,
  RefreshCw,
  Router,
  Search,
  Wifi,
  WifiOff
} from 'lucide-react';
import {
  buildSummary,
  filterAndSortDevices,
  formatBytes,
  formatClock,
  formatRate,
  getDeviceInitial
} from './domain.js';
import {
  captureScrollSnapshot,
  restoreScrollSnapshot
} from './scroll.js';
import {
  detectDarkTheme,
  subscribeDarkTheme
} from './theme.js';
import './styles.css';

const roots = new WeakMap();
const appVersion = '0.1.18';

const fallbackFetcher = async () => ({
  devices: [],
  summary: {
    total: 0,
    online: 0,
    offline: 0,
    down_bps: 0,
    up_bps: 0
  },
  meta: {
    timestamp: Math.floor(Date.now() / 1000),
    rate_source: 'demo'
  }
});

function IconButton({ title, loading, onClick }) {
  return (
    <button className={`fl-icon-button${loading ? ' is-loading' : ''}`} type="button" title={title} aria-label={title} onClick={onClick}>
      <RefreshCw size={18} strokeWidth={2.2} />
    </button>
  );
}

function MetricCard({ icon: Icon, label, value, detail, tone }) {
  return (
    <article className={`fl-metric fl-metric-${tone}`}>
      <div className="fl-metric-icon" aria-hidden="true">
        <Icon size={18} strokeWidth={2.2} />
      </div>
      <div>
        <p>{label}</p>
        <strong>{value}</strong>
        {detail ? <span>{detail}</span> : null}
      </div>
    </article>
  );
}

function SegmentedControl({ value, onChange, counts }) {
  const items = [
    ['all', '全部', counts.total],
    ['online', '在线', counts.online],
    ['offline', '离线', counts.offline]
  ];

  return (
    <div className="fl-segmented" role="tablist" aria-label="设备状态筛选">
      {items.map(([key, label, count]) => (
        <button
          key={key}
          className={value === key ? 'is-active' : ''}
          type="button"
          role="tab"
          aria-selected={value === key}
          onClick={() => onChange(key)}
        >
          <span>{label}</span>
          <em>{count}</em>
        </button>
      ))}
    </div>
  );
}

function DeviceAvatar({ device }) {
  return (
    <div className="fl-avatar" aria-hidden="true">
      {device.online ? <Monitor size={18} strokeWidth={2.15} /> : getDeviceInitial(device.name)}
    </div>
  );
}

function StatusPill({ online }) {
  return (
    <span className={`fl-status-pill${online ? ' is-online' : ' is-offline'}`}>
      {online ? <Wifi size={13} strokeWidth={2.2} /> : <WifiOff size={13} strokeWidth={2.2} />}
      {online ? '在线' : '离线'}
    </span>
  );
}

function firstAddress(device) {
  return device.ipv4[0] || device.ipv6[0] || device.ip || '-';
}

function AddressGroup({ label, values }) {
  return (
    <div className="fl-ip-line">
      <span>{label}</span>
      {values.length ? (
        <div>
          {values.map(value => <code key={value}>{value}</code>)}
        </div>
      ) : (
        <em>-</em>
      )}
    </div>
  );
}

function compactValues(values) {
  return {
    first: values[0] || '-',
    more: Math.max(0, values.length - 1)
  };
}

function AddressSummaryLine({ label, values }) {
  const compact = compactValues(values);

  return (
    <div className="fl-ip-summary-line">
      <span>{label}</span>
      <code>{compact.first}</code>
      {compact.more ? <em>+{compact.more}</em> : null}
    </div>
  );
}

function AddressTooltip({ device }) {
  const hasHistory = device.history_ipv4.length || device.history_ipv6.length;

  return (
    <div className="fl-ip-popover" role="tooltip">
      <AddressGroup label="IPv4" values={device.ipv4} />
      <AddressGroup label="IPv6" values={device.ipv6} />
      {hasHistory ? (
        <div className="fl-ip-history">
          <strong>历史/邻居缓存</strong>
          <AddressGroup label="IPv4" values={device.history_ipv4} />
          <AddressGroup label="IPv6" values={device.history_ipv6} />
        </div>
      ) : null}
    </div>
  );
}

function AddressSummary({ device }) {
  const addressCount = device.ipv4.length + device.ipv6.length;
  const historyCount = device.history_ipv4.length + device.history_ipv6.length;
  const hasMore = historyCount > 0 || addressCount > 2 || device.ipv4.length > 1 || device.ipv6.length > 1;

  return (
    <div className={`fl-ip-summary${hasMore ? ' has-more' : ''}`} tabIndex={hasMore ? 0 : undefined}>
      <AddressSummaryLine label="IPv4" values={device.ipv4} />
      <AddressSummaryLine label="IPv6" values={device.ipv6} />
      {hasMore ? <AddressTooltip device={device} /> : null}
    </div>
  );
}

function RateCell({ label, value, direction }) {
  const Icon = direction === 'down' ? ArrowDown : ArrowUp;

  return (
    <div className={`fl-rate fl-rate-${direction}`}>
      <span>
        <Icon size={13} strokeWidth={2.4} />
        {label}
      </span>
      <strong>{formatRate(value)}</strong>
    </div>
  );
}

function getPeriodLabel(meta) {
  if (meta?.period_label)
    return meta.period_label;

  if (meta?.period_start && meta?.period_end)
    return `${meta.period_start} - ${meta.period_end}`;

  return meta?.rate_source || 'nlbwmon';
}

function DeviceRow({ device }) {
  return (
    <tr className={device.online ? 'is-online' : 'is-offline'}>
      <td className="fl-device-cell">
        <div className="fl-device">
          <DeviceAvatar device={device} />
          <div className="fl-device-copy">
            <strong title={device.name}>{device.name}</strong>
          </div>
        </div>
      </td>
      <td><StatusPill online={device.online} /></td>
      <td className="fl-ip-cell"><AddressSummary device={device} /></td>
      <td className="fl-mono fl-muted">{device.mac || '-'}</td>
      <td>
        <div className="fl-rate-stack">
          <RateCell label="下载" value={device.down_bps} direction="down" />
          <RateCell label="上传" value={device.up_bps} direction="up" />
        </div>
      </td>
      <td className="fl-total-cell" title="来自 nlbwmon 当前统计周期">
        {formatBytes(device.rx_bytes + device.tx_bytes)}
      </td>
    </tr>
  );
}

const sortColumns = [
  { key: 'device', label: '设备', defaultDirection: 'asc' },
  { key: 'status', label: '状态', defaultDirection: 'asc' },
  { key: 'ip', label: 'IP 地址', defaultDirection: 'asc' },
  { key: 'mac', label: 'MAC 地址', defaultDirection: 'asc' },
  { key: 'rate', label: '实时上下行', defaultDirection: 'desc' },
  { key: 'total', label: '本周期累计', defaultDirection: 'desc', title: '来自 nlbwmon 当前统计周期' }
];

function nextSort(current, column) {
  if (current.key === column.key) {
    return {
      key: column.key,
      direction: current.direction === 'asc' ? 'desc' : 'asc'
    };
  }

  return {
    key: column.key,
    direction: column.defaultDirection || 'asc'
  };
}

function SortIcon({ active, direction }) {
  if (!active)
    return <ChevronsUpDown size={13} strokeWidth={2.2} />;

  return direction === 'asc'
    ? <ChevronUp size={13} strokeWidth={2.4} />
    : <ChevronDown size={13} strokeWidth={2.4} />;
}

function SortHeader({ column, sort, onSortChange }) {
  const active = sort.key === column.key;

  return (
    <th title={column.title} aria-sort={active ? (sort.direction === 'asc' ? 'ascending' : 'descending') : 'none'}>
      <button
        className={`fl-sort-button${active ? ' is-active' : ''}`}
        type="button"
        onClick={() => onSortChange(column)}
      >
        <span>{column.label}</span>
        <SortIcon active={active} direction={sort.direction} />
      </button>
    </th>
  );
}

function DeviceCard({ device }) {
  return (
    <article className={`fl-device-card${device.online ? ' is-online' : ' is-offline'}`}>
      <div className="fl-device-card-head">
        <div className="fl-device">
          <DeviceAvatar device={device} />
          <div className="fl-device-copy">
            <strong>{device.name}</strong>
            <span>{firstAddress(device)}</span>
          </div>
        </div>
        <StatusPill online={device.online} />
      </div>
      <dl>
        <div>
          <dt>IPv4</dt>
          <dd>{device.ipv4.join(', ') || '-'}</dd>
        </div>
        <div>
          <dt>IPv6</dt>
          <dd>{device.ipv6.join(', ') || '-'}</dd>
        </div>
        <div>
          <dt>MAC</dt>
          <dd>{device.mac || '-'}</dd>
        </div>
        <div>
          <dt>下载</dt>
          <dd>{formatRate(device.down_bps)}</dd>
        </div>
        <div>
          <dt>上传</dt>
          <dd>{formatRate(device.up_bps)}</dd>
        </div>
        <div>
          <dt title="来自 nlbwmon 当前统计周期">本周期累计</dt>
          <dd>{formatBytes(device.rx_bytes + device.tx_bytes)}</dd>
        </div>
      </dl>
    </article>
  );
}

function EmptyState() {
  return (
    <div className="fl-empty">
      <div className="fl-empty-mark">
        <Router size={24} strokeWidth={2.1} />
      </div>
      <strong>没有匹配的设备</strong>
      <span>等待 DHCP、ARP 或 nlbwmon 采样后会自动出现。</span>
    </div>
  );
}

function DevicesTable({ devices, sort, onSortChange }) {
  if (!devices.length)
    return <EmptyState />;

  return (
    <>
      <div className="fl-table-wrap">
        <table className="fl-table">
          <thead>
            <tr>
              {sortColumns.map(column => (
                <SortHeader key={column.key} column={column} sort={sort} onSortChange={onSortChange} />
              ))}
            </tr>
          </thead>
          <tbody>
            {devices.map(device => (
              <DeviceRow key={device.mac || device.ip || device.name} device={device} />
            ))}
          </tbody>
        </table>
      </div>
      <div className="fl-card-list">
        {devices.map(device => (
          <DeviceCard key={device.mac || device.ip || device.name} device={device} />
        ))}
      </div>
    </>
  );
}

function App({ initialData, fetchDevices, pollInterval = 1000 }) {
  const pendingScrollSnapshot = useRef(null);
  const [payload, setPayload] = useState(initialData || {});
  const [filter, setFilter] = useState('all');
  const [query, setQuery] = useState('');
  const [sort, setSort] = useState({ key: 'rate', direction: 'desc' });
  const [darkMode, setDarkMode] = useState(() => detectDarkTheme());
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  const fetcher = fetchDevices || fallbackFetcher;

  const refresh = useCallback(async (quiet = false) => {
    if (!quiet)
      setLoading(true);

    setError('');

    try {
      const next = await fetcher();
      const scrollSnapshot = captureScrollSnapshot();

      if (scrollSnapshot.length)
        pendingScrollSnapshot.current = scrollSnapshot;

      setPayload(next || {});
    } catch (refreshError) {
      setError(refreshError?.message || String(refreshError));
    } finally {
      setLoading(false);
    }
  }, [fetcher]);

  useLayoutEffect(() => {
    const scrollSnapshot = pendingScrollSnapshot.current;

    if (!scrollSnapshot)
      return;

    pendingScrollSnapshot.current = null;
    restoreScrollSnapshot(scrollSnapshot);
    window.requestAnimationFrame(() => restoreScrollSnapshot(scrollSnapshot));
  }, [payload]);

  useEffect(() => subscribeDarkTheme(setDarkMode), []);

  useEffect(() => {
    const timer = window.setInterval(() => refresh(true), pollInterval);
    return () => window.clearInterval(timer);
  }, [pollInterval, refresh]);

  const summary = useMemo(() => buildSummary(payload), [payload]);
  const devices = useMemo(
    () => filterAndSortDevices(payload?.devices, filter, query, sort),
    [payload, filter, query, sort]
  );
  const handleSortChange = useCallback(column => {
    setSort(current => nextSort(current, column));
  }, []);
  const meta = payload?.meta || {};
  const activeTraffic = summary.down_bps + summary.up_bps;
  const periodLabel = getPeriodLabel(meta);

  return (
    <div className="fl-app" data-darkmode={darkMode ? 'true' : undefined}>
      <section className="fl-hero" aria-label="FlowLens 总览">
        <div className="fl-hero-copy">
          <div className="fl-brand">
            <span>F</span>
            <div>
              <strong className="fl-brand-name">FlowLens</strong>
              <p>设备实时流量视图</p>
            </div>
          </div>
          <div className="fl-hero-stats">
            <div>
              <span>当前吞吐</span>
              <strong>{formatRate(activeTraffic)}</strong>
            </div>
            <div>
              <span>数据源</span>
              <strong>{meta.rate_source || '-'}</strong>
            </div>
          </div>
        </div>

        <div className="fl-hero-actions">
          <IconButton title="刷新" loading={loading} onClick={() => refresh(false)} />
        </div>
      </section>

      {error ? <div className="fl-error">无法读取 FlowLens 数据：{error}</div> : null}

      <section className="fl-metrics" aria-label="流量摘要">
        <MetricCard icon={Wifi} label="在线设备" value={summary.online} tone="green" />
        <MetricCard icon={WifiOff} label="离线设备" value={summary.offline} tone="amber" />
        <MetricCard icon={ArrowDown} label="下载速率" value={formatRate(summary.down_bps)} tone="cyan" />
        <MetricCard icon={ArrowUp} label="上传速率" value={formatRate(summary.up_bps)} tone="violet" />
      </section>

      <section className="fl-panel" aria-label="设备列表">
        <div className="fl-panel-head">
          <div>
            <strong className="fl-panel-title">设备列表</strong>
          </div>
          <div className="fl-panel-meta">
            <div className="fl-last-refresh">
              <Clock3 size={14} strokeWidth={2.2} />
              {formatClock(meta.timestamp)}
            </div>
            <div className="fl-period-note" title="本周期累计来自 nlbwmon 当前统计周期">
              <Info size={13} strokeWidth={2.2} />
              本周期: {periodLabel}
            </div>
          </div>
        </div>

        <div className="fl-toolbar">
          <SegmentedControl value={filter} onChange={setFilter} counts={summary} />
          <label className="fl-search">
            <Search size={17} strokeWidth={2.1} />
            <input
              type="search"
              value={query}
              placeholder="搜索设备、IP 或 MAC"
              onChange={event => setQuery(event.target.value)}
            />
          </label>
        </div>

        <DevicesTable devices={devices} sort={sort} onSortChange={handleSortChange} />
      </section>
    </div>
  );
}

function mount(element, options = {}) {
  const existing = roots.get(element);

  if (existing)
    existing.dispose();

  const root = createRoot(element);
  const syncRootTheme = darkMode => {
    if (darkMode)
      element.setAttribute('data-darkmode', 'true');
    else
      element.removeAttribute('data-darkmode');
  };
  const unsubscribeTheme = subscribeDarkTheme(syncRootTheme);
  let disposed = false;
  const observer = new MutationObserver(() => {
    if (document.body.contains(element))
      return;

    dispose();
  });
  const dispose = () => {
    if (disposed)
      return;

    disposed = true;
    root.unmount();
    unsubscribeTheme();
    observer.disconnect();
    roots.delete(element);
  };

  observer.observe(document.body, {
    childList: true,
    subtree: true
  });

  roots.set(element, { dispose, root });
  syncRootTheme(detectDarkTheme());
  root.render(<App {...options} />);
  return root;
}

window.FlowLensApp = {
  mount,
  version: appVersion
};
