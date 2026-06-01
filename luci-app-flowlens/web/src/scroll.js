const BOTTOM_LOCK_DISTANCE = 160;

function numberValue(value) {
  const next = Number(value);
  return Number.isFinite(next) ? next : 0;
}

function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max);
}

function uniqueElements(elements) {
  return elements.filter((element, index, list) => element && list.indexOf(element) === index);
}

export function resolveRestoredScrollTop(snapshot, metrics) {
  const maxTop = Math.max(0, numberValue(metrics?.scrollHeight) - numberValue(metrics?.clientHeight));
  const top = numberValue(snapshot?.top);
  const bottom = numberValue(snapshot?.bottom);

  if (bottom <= BOTTOM_LOCK_DISTANCE)
    return clamp(maxTop - bottom, 0, maxTop);

  return clamp(top, 0, maxTop);
}

export function getScrollTargets() {
  if (typeof document === 'undefined')
    return [];

  return uniqueElements([
    document.scrollingElement || document.documentElement,
    document.querySelector('.main-right'),
    document.querySelector('#maincontent'),
    document.querySelector('.main')
  ]).filter(element => element.scrollHeight > element.clientHeight);
}

export function captureScrollSnapshot() {
  return getScrollTargets()
    .map(element => ({
      bottom: Math.max(0, element.scrollHeight - element.clientHeight - element.scrollTop),
      element,
      left: element.scrollLeft,
      top: element.scrollTop
    }))
    .filter(item => item.top > 0 || item.bottom <= BOTTOM_LOCK_DISTANCE);
}

export function restoreScrollSnapshot(snapshot) {
  if (!Array.isArray(snapshot) || !snapshot.length)
    return;

  snapshot.forEach(item => {
    const element = item?.element;

    if (!element)
      return;

    element.scrollTop = resolveRestoredScrollTop(item, {
      clientHeight: element.clientHeight,
      scrollHeight: element.scrollHeight
    });
    element.scrollLeft = numberValue(item.left);
  });
}
