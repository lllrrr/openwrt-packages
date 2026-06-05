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
  Languages,
  Radar,
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
  detectInitialLanguage,
  localeForLanguage,
  normalizeLanguage,
  saveLanguagePreference,
  translate
} from './i18n.js';
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
const appVersion = '0.1.27';

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

function SegmentedControl({ value, onChange, counts, t }) {
  const items = [
    ['all', t('filters.all'), counts.total],
    ['online', t('filters.online'), counts.online],
    ['offline', t('filters.offline'), counts.offline]
  ];

  return (
    <div className="fl-segmented" role="tablist" aria-label={t('filters.label')}>
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
      {getDeviceInitial(device.name)}
    </div>
  );
}

function StatusPill({ online, t }) {
  return (
    <span className={`fl-status-pill${online ? ' is-online' : ' is-offline'}`}>
      <span className="fl-status-dot" aria-hidden="true" />
      {online ? t('status.online') : t('status.offline')}
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

function AddressTooltip({ device, t }) {
  const hasHistory = device.history_ipv4.length || device.history_ipv6.length;

  return (
    <div className="fl-ip-popover" role="tooltip">
      <AddressGroup label="IPv4" values={device.ipv4} />
      <AddressGroup label="IPv6" values={device.ipv6} />
      {hasHistory ? (
        <div className="fl-ip-history">
          <strong>{t('address.history')}</strong>
          <AddressGroup label="IPv4" values={device.history_ipv4} />
          <AddressGroup label="IPv6" values={device.history_ipv6} />
        </div>
      ) : null}
    </div>
  );
}

function AddressSummary({ device, t }) {
  const addressCount = device.ipv4.length + device.ipv6.length;
  const historyCount = device.history_ipv4.length + device.history_ipv6.length;
  const hasMore = historyCount > 0 || addressCount > 2 || device.ipv4.length > 1 || device.ipv6.length > 1;

  return (
    <div className={`fl-ip-summary${hasMore ? ' has-more' : ''}`} tabIndex={hasMore ? 0 : undefined}>
      <AddressSummaryLine label="IPv4" values={device.ipv4} />
      <AddressSummaryLine label="IPv6" values={device.ipv6} />
      {hasMore ? <AddressTooltip device={device} t={t} /> : null}
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

function DeviceRow({ device, t }) {
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
      <td><StatusPill online={device.online} t={t} /></td>
      <td className="fl-ip-cell"><AddressSummary device={device} t={t} /></td>
      <td className="fl-mono fl-muted">{device.mac || '-'}</td>
      <td>
        <div className="fl-rate-stack">
          <RateCell label={t('rate.download')} value={device.down_bps} direction="down" />
          <RateCell label={t('rate.upload')} value={device.up_bps} direction="up" />
        </div>
      </td>
      <td className="fl-total-cell" title={t('period.title')}>
        {formatBytes(device.rx_bytes + device.tx_bytes)}
      </td>
    </tr>
  );
}

function getSortColumns(t) {
  return [
    { key: 'device', label: t('columns.device'), defaultDirection: 'asc' },
    { key: 'status', label: t('columns.status'), defaultDirection: 'asc' },
    { key: 'ip', label: t('columns.ip'), defaultDirection: 'asc' },
    { key: 'mac', label: t('columns.mac'), defaultDirection: 'asc' },
    { key: 'rate', label: t('columns.rate'), defaultDirection: 'desc' },
    { key: 'total', label: t('columns.total'), defaultDirection: 'desc', title: t('period.title') }
  ];
}

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

function DeviceCard({ device, t }) {
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
        <StatusPill online={device.online} t={t} />
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
          <dt>{t('rate.download')}</dt>
          <dd>{formatRate(device.down_bps)}</dd>
        </div>
        <div>
          <dt>{t('rate.upload')}</dt>
          <dd>{formatRate(device.up_bps)}</dd>
        </div>
        <div>
          <dt title={t('period.title')}>{t('columns.total')}</dt>
          <dd>{formatBytes(device.rx_bytes + device.tx_bytes)}</dd>
        </div>
      </dl>
    </article>
  );
}

function EmptyState({ t }) {
  return (
    <div className="fl-empty">
      <div className="fl-empty-mark">
        <Router size={24} strokeWidth={2.1} />
      </div>
      <strong>{t('empty.title')}</strong>
      <span>{t('empty.body')}</span>
    </div>
  );
}

function DevicesTable({ devices, sort, onSortChange, sortColumns, t }) {
  if (!devices.length)
    return <EmptyState t={t} />;

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
              <DeviceRow key={device.mac || device.ip || device.name} device={device} t={t} />
            ))}
          </tbody>
        </table>
      </div>
      <div className="fl-card-list">
        {devices.map(device => (
          <DeviceCard key={device.mac || device.ip || device.name} device={device} t={t} />
        ))}
      </div>
    </>
  );
}

function LanguageSelect({ language, onChange, t }) {
  return (
    <label className="fl-language-select" title={t('language.label')}>
      <Languages size={15} strokeWidth={2.2} aria-hidden="true" />
      <select value={language} aria-label={t('language.label')} onChange={onChange}>
        <option value="zh">{t('language.zh')}</option>
        <option value="en">{t('language.en')}</option>
      </select>
      <ChevronDown className="fl-language-chevron" size={14} strokeWidth={2.3} aria-hidden="true" />
    </label>
  );
}

function App({ initialData, fetchDevices, pollInterval = 2000 }) {
  const pendingScrollSnapshot = useRef(null);
  const [payload, setPayload] = useState(initialData || {});
  const [filter, setFilter] = useState('all');
  const [query, setQuery] = useState('');
  const [sort, setSort] = useState({ key: 'rate', direction: 'desc' });
  const [darkMode, setDarkMode] = useState(() => detectDarkTheme());
  const [language, setLanguage] = useState(() => detectInitialLanguage());
  const [error, setError] = useState('');
  const t = useCallback((key, values) => translate(language, key, values), [language]);
  const locale = localeForLanguage(language);

  const fetcher = fetchDevices || fallbackFetcher;

  const refresh = useCallback(async () => {
    setError('');

    try {
      const next = await fetcher();
      const scrollSnapshot = captureScrollSnapshot();

      if (scrollSnapshot.length)
        pendingScrollSnapshot.current = scrollSnapshot;

      setPayload(next || {});
    } catch (refreshError) {
      setError(refreshError?.message || String(refreshError));
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
    const timer = window.setInterval(() => refresh(), pollInterval);
    return () => window.clearInterval(timer);
  }, [pollInterval, refresh]);

  const summary = useMemo(() => buildSummary(payload), [payload]);
  const devices = useMemo(
    () => filterAndSortDevices(payload?.devices, filter, query, sort, { unknownName: t('device.unknown') }),
    [payload, filter, query, sort, t]
  );
  const sortColumns = useMemo(() => getSortColumns(t), [t]);
  const handleSortChange = useCallback(column => {
    setSort(current => nextSort(current, column));
  }, []);
  const handleLanguageChange = useCallback(event => {
    const next = saveLanguagePreference(normalizeLanguage(event.target.value));
    setLanguage(next);
  }, []);
  const meta = payload?.meta || {};
  const periodLabel = getPeriodLabel(meta);

  return (
    <div className="fl-app" data-darkmode={darkMode ? 'true' : undefined}>
      <section className="fl-hero" aria-label={t('hero.label')}>
        <LanguageSelect language={language} onChange={handleLanguageChange} t={t} />
        <div className="fl-hero-copy">
          <div className="fl-brand">
            <span className="fl-brand-mark" aria-hidden="true">
              <Radar size={26} strokeWidth={2.15} />
            </span>
            <div>
              <strong className="fl-brand-name">FlowLens</strong>
              <p>{t('hero.subtitle')}</p>
            </div>
          </div>
        </div>
      </section>

      {error ? <div className="fl-error">{t('error.fetch', { error })}</div> : null}

      <section className="fl-metrics" aria-label={t('metrics.summary')}>
        <MetricCard icon={Wifi} label={t('metrics.online')} value={summary.online} tone="green" />
        <MetricCard icon={WifiOff} label={t('metrics.offline')} value={summary.offline} tone="amber" />
        <MetricCard icon={ArrowDown} label={t('metrics.download')} value={formatRate(summary.down_bps)} tone="cyan" />
        <MetricCard icon={ArrowUp} label={t('metrics.upload')} value={formatRate(summary.up_bps)} tone="violet" />
      </section>

      <section className="fl-panel" aria-label={t('panel.devices')}>
        <div className="fl-panel-head">
          <div>
            <strong className="fl-panel-title">{t('panel.devices')}</strong>
          </div>
          <div className="fl-panel-meta">
            <div className="fl-last-refresh">
              <Clock3 size={14} strokeWidth={2.2} />
              {formatClock(meta.timestamp, locale)}
            </div>
            <div className="fl-period-note" title={t('period.title')}>
              <Info size={13} strokeWidth={2.2} />
              {t('period.label', { period: periodLabel })}
            </div>
          </div>
        </div>

        <div className="fl-toolbar">
          <SegmentedControl value={filter} onChange={setFilter} counts={summary} t={t} />
          <label className="fl-search">
            <Search size={17} strokeWidth={2.1} />
            <input
              type="search"
              value={query}
              placeholder={t('search.placeholder')}
              onChange={event => setQuery(event.target.value)}
            />
          </label>
        </div>

        <DevicesTable devices={devices} sort={sort} onSortChange={handleSortChange} sortColumns={sortColumns} t={t} />
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
