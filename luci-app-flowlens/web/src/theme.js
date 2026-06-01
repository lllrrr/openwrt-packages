const DARK_VALUES = new Set(['1', 'true', 'dark', 'yes', 'on']);
const LIGHT_VALUES = new Set(['0', 'false', 'light', 'no', 'off']);
const THEME_ATTRIBUTES = [
  'data-darkmode',
  'data-theme',
  'data-bs-theme',
  'data-color-scheme',
  'color-scheme'
];

function classNameValue(element) {
  const className = element?.className;

  if (typeof className === 'string')
    return className;

  return className?.baseVal || '';
}

function uniqueElements(elements) {
  return elements.filter((element, index, list) => element && list.indexOf(element) === index);
}

export function parseRgbColor(color) {
  const match = String(color || '').match(/rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?\)/i);

  if (!match || match[4] === '0')
    return null;

  return [
    Number(match[1]),
    Number(match[2]),
    Number(match[3])
  ];
}

export function isDarkColor(color) {
  const rgb = parseRgbColor(color);

  if (!rgb)
    return false;

  return (rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722) < 128;
}

function readThemeSignal(element) {
  if (!element?.getAttribute)
    return '';

  for (const attribute of THEME_ATTRIBUTES) {
    const value = String(element.getAttribute(attribute) || '').trim().toLowerCase();

    if (DARK_VALUES.has(value))
      return 'dark';

    if (LIGHT_VALUES.has(value))
      return 'light';
  }

  const classes = ` ${classNameValue(element).toLowerCase()} `;

  if (/(^|\s)(dark|theme-dark|argon-dark|luci-dark)(\s|$)/.test(classes))
    return 'dark';

  if (/(^|\s)(light|theme-light|argon-light|luci-light)(\s|$)/.test(classes))
    return 'light';

  return '';
}

function getEnvironment(env = {}) {
  const win = env.window || (typeof window !== 'undefined' ? window : undefined);
  const doc = env.document || win?.document || (typeof document !== 'undefined' ? document : undefined);

  return { document: doc, window: win };
}

function getThemeNodes(doc) {
  return uniqueElements([
    doc?.querySelector?.('.main-right'),
    doc?.querySelector?.('#maincontent'),
    doc?.querySelector?.('.main'),
    doc?.body,
    doc?.documentElement
  ]);
}

function colorTheme(color) {
  const rgb = parseRgbColor(color);

  if (!rgb)
    return '';

  return isDarkColor(color) ? 'dark' : 'light';
}

function readHostSurfaceTheme(doc, win) {
  for (const node of getThemeNodes(doc)) {
    const theme = colorTheme(win.getComputedStyle(node).backgroundColor);

    if (theme)
      return theme;
  }

  return '';
}

export function detectDarkTheme(env = {}) {
  const { document: doc, window: win } = getEnvironment(env);

  if (!win?.getComputedStyle || !doc)
    return false;

  const hostSurfaceTheme = readHostSurfaceTheme(doc, win);

  if (hostSurfaceTheme)
    return hostSurfaceTheme === 'dark';

  const explicitSignal = [
    readThemeSignal(doc.documentElement),
    readThemeSignal(doc.body)
  ].find(Boolean);

  if (explicitSignal)
    return explicitSignal === 'dark';

  return getThemeNodes(doc).some(node => isDarkColor(win.getComputedStyle(node).backgroundColor));
}

export function subscribeDarkTheme(callback, env = {}) {
  const { document: doc, window: win } = getEnvironment(env);

  if (!doc || !win || typeof callback !== 'function')
    return () => {};

  let current = detectDarkTheme({ document: doc, window: win });
  const notify = () => {
    const next = detectDarkTheme({ document: doc, window: win });

    if (next === current)
      return;

    current = next;
    callback(next);
  };
  const notifyAfterStyleFlush = () => {
    notify();

    if (typeof win.requestAnimationFrame === 'function')
      win.requestAnimationFrame(notify);

    if (typeof win.setTimeout === 'function') {
      win.setTimeout(notify, 80);
      win.setTimeout(notify, 240);
    }
  };

  const observer = typeof win.MutationObserver === 'function'
    ? new win.MutationObserver(notifyAfterStyleFlush)
    : (typeof MutationObserver === 'function' ? new MutationObserver(notifyAfterStyleFlush) : null);
  const observedNodes = uniqueElements([
    doc.documentElement,
    doc.body,
    doc.querySelector?.('.main-right'),
    doc.querySelector?.('#maincontent'),
    doc.querySelector?.('.main')
  ]);

  if (observer) {
    observedNodes.forEach(node => observer.observe(node, {
      attributeFilter: ['class', 'style', ...THEME_ATTRIBUTES],
      attributes: true
    }));

    if (doc.head) {
      observer.observe(doc.head, {
        attributeFilter: ['class', 'disabled', 'href', 'media', 'style'],
        attributes: true,
        childList: true,
        subtree: true
      });
    }
  }

  const mediaQuery = typeof win.matchMedia === 'function'
    ? win.matchMedia('(prefers-color-scheme: dark)')
    : null;

  if (mediaQuery?.addEventListener)
    mediaQuery.addEventListener('change', notifyAfterStyleFlush);
  else if (mediaQuery?.addListener)
    mediaQuery.addListener(notifyAfterStyleFlush);

  if (win.addEventListener) {
    win.addEventListener('storage', notifyAfterStyleFlush);
    win.addEventListener('focus', notifyAfterStyleFlush);
    win.addEventListener('pageshow', notifyAfterStyleFlush);
  }

  return () => {
    observer?.disconnect();

    if (mediaQuery?.removeEventListener)
      mediaQuery.removeEventListener('change', notifyAfterStyleFlush);
    else if (mediaQuery?.removeListener)
      mediaQuery.removeListener(notifyAfterStyleFlush);

    if (win.removeEventListener) {
      win.removeEventListener('storage', notifyAfterStyleFlush);
      win.removeEventListener('focus', notifyAfterStyleFlush);
      win.removeEventListener('pageshow', notifyAfterStyleFlush);
    }
  };
}
