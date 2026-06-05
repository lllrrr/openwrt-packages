export const languageStorageKey = 'flowlens.language';

const defaultLanguage = 'zh';

const messages = {
  zh: {
    'address.history': '历史/邻居缓存',
    'columns.device': '设备',
    'columns.ip': 'IP 地址',
    'columns.mac': 'MAC 地址',
    'columns.rate': '实时上下行',
    'columns.status': '状态',
    'columns.total': '本周期累计',
    'device.unknown': '未知设备',
    'empty.body': '等待 DHCP、ARP 或 nlbwmon 采样后会自动出现。',
    'empty.title': '没有匹配的设备',
    'error.fetch': '无法读取 FlowLens 数据：{error}',
    'filters.all': '全部',
    'filters.label': '设备状态筛选',
    'filters.offline': '离线',
    'filters.online': '在线',
    'hero.label': 'FlowLens 总览',
    'hero.subtitle': '设备实时流量视图',
    'language.label': '语言',
    'language.zh': '中文',
    'language.en': 'English',
    'metrics.download': '下载速率',
    'metrics.offline': '离线设备',
    'metrics.online': '在线设备',
    'metrics.summary': '流量摘要',
    'metrics.upload': '上传速率',
    'panel.devices': '设备列表',
    'period.label': '本周期: {period}',
    'period.title': '本周期累计来自 nlbwmon 当前统计周期',
    'rate.download': '下载',
    'rate.upload': '上传',
    'search.placeholder': '搜索设备、IP 或 MAC',
    'status.offline': '离线',
    'status.online': '在线'
  },
  en: {
    'address.history': 'History / neighbor cache',
    'columns.device': 'Device',
    'columns.ip': 'IP Address',
    'columns.mac': 'MAC Address',
    'columns.rate': 'Realtime Rate',
    'columns.status': 'Status',
    'columns.total': 'Period Total',
    'device.unknown': 'Unknown device',
    'empty.body': 'Devices will appear automatically after DHCP, ARP, or nlbwmon samples are available.',
    'empty.title': 'No matching devices',
    'error.fetch': 'Unable to read FlowLens data: {error}',
    'filters.all': 'All',
    'filters.label': 'Device status filter',
    'filters.offline': 'Offline',
    'filters.online': 'Online',
    'hero.label': 'FlowLens overview',
    'hero.subtitle': 'Realtime device traffic view',
    'language.label': 'Language',
    'language.zh': '中文',
    'language.en': 'English',
    'metrics.download': 'Download Rate',
    'metrics.offline': 'Offline Devices',
    'metrics.online': 'Online Devices',
    'metrics.summary': 'Traffic summary',
    'metrics.upload': 'Upload Rate',
    'panel.devices': 'Device List',
    'period.label': 'Period: {period}',
    'period.title': 'Period totals come from the current nlbwmon accounting period',
    'rate.download': 'Download',
    'rate.upload': 'Upload',
    'search.placeholder': 'Search device, IP, or MAC',
    'status.offline': 'Offline',
    'status.online': 'Online'
  }
};

function matchingLanguage(value) {
  const normalized = String(value || '').trim().replace(/_/g, '-').toLowerCase();

  if (!normalized)
    return '';

  if (normalized === 'zh' || normalized.startsWith('zh-'))
    return 'zh';

  if (normalized === 'en' || normalized.startsWith('en-'))
    return 'en';

  return '';
}

function safeGetAttribute(node, name) {
  if (!node || typeof node.getAttribute !== 'function')
    return '';

  try {
    return node.getAttribute(name) || '';
  } catch {
    return '';
  }
}

function safeGetStoredLanguage(storage) {
  if (!storage || typeof storage.getItem !== 'function')
    return '';

  try {
    return storage.getItem(languageStorageKey) || '';
  } catch {
    return '';
  }
}

export function normalizeLanguage(value, fallback = defaultLanguage) {
  return matchingLanguage(value) || matchingLanguage(fallback) || defaultLanguage;
}

export function localeForLanguage(language) {
  return normalizeLanguage(language) === 'en' ? 'en-US' : 'zh-CN';
}

export function detectInitialLanguage(options = {}) {
  const documentRef = options.document || (typeof document !== 'undefined' ? document : undefined);
  const navigatorRef = options.navigator || (typeof navigator !== 'undefined' ? navigator : undefined);
  const storage = options.storage || (typeof localStorage !== 'undefined' ? localStorage : undefined);
  const stored = matchingLanguage(safeGetStoredLanguage(storage));

  if (stored)
    return stored;

  const html = documentRef?.documentElement;
  const body = documentRef?.body;
  const candidates = [
    html?.lang,
    safeGetAttribute(html, 'lang'),
    safeGetAttribute(html, 'xml:lang'),
    safeGetAttribute(html, 'data-language'),
    safeGetAttribute(html, 'data-lang'),
    body?.lang,
    safeGetAttribute(body, 'lang'),
    safeGetAttribute(body, 'data-language'),
    safeGetAttribute(body, 'data-lang')
  ];

  if (Array.isArray(navigatorRef?.languages))
    candidates.push(...navigatorRef.languages);

  candidates.push(navigatorRef?.language, navigatorRef?.userLanguage);

  for (const candidate of candidates) {
    const language = matchingLanguage(candidate);

    if (language)
      return language;
  }

  return defaultLanguage;
}

export function saveLanguagePreference(language, storage = typeof localStorage !== 'undefined' ? localStorage : undefined) {
  const next = normalizeLanguage(language);

  if (!storage || typeof storage.setItem !== 'function')
    return next;

  try {
    storage.setItem(languageStorageKey, next);
  } catch {
    // Ignore storage failures; language switching should still work in-memory.
  }

  return next;
}

export function translate(language, key, values = {}) {
  const normalized = normalizeLanguage(language);
  const template = messages[normalized]?.[key] || messages[defaultLanguage][key] || key;

  return template.replace(/\{([^}]+)\}/g, (match, name) => {
    if (Object.prototype.hasOwnProperty.call(values, name))
      return String(values[name]);

    return match;
  });
}
