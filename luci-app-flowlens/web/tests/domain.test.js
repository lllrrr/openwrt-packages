import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  buildSummary,
  filterAndSortDevices,
  formatRate,
  normalizeDevice
} from '../src/domain.js';
import { resolveRestoredScrollTop } from '../src/scroll.js';
import { detectDarkTheme, subscribeDarkTheme } from '../src/theme.js';

test('formatRate always displays MB/s', () => {
  assert.equal(formatRate(1024), '0.00 MB/s');
  assert.equal(formatRate(1536), '0.00 MB/s');
  assert.equal(formatRate(60.4 * 1024), '0.06 MB/s');
  assert.equal(formatRate(2 * 1024 * 1024), '2.00 MB/s');
});

test('filterAndSortDevices defaults to live rate and searches visible fields', () => {
  const devices = filterAndSortDevices([
    { name: 'Media Box', mac: 'aa:bb:cc:dd:ee:02', ip: '192.168.5.12', online: false, down_bps: 0 },
    { name: 'Zeta Phone', mac: 'aa:bb:cc:dd:ee:01', ip: '192.168.5.11', online: true, down_bps: 4000 },
    { name: 'Alpha NAS', mac: 'aa:bb:cc:dd:ee:03', ip: '192.168.5.13', online: true, down_bps: 1000 }
  ], 'all', '192.168.5');

  assert.deepEqual(devices.map(device => device.name), ['Zeta Phone', 'Alpha NAS', 'Media Box']);
});

test('filterAndSortDevices can sort by live rate when requested', () => {
  const devices = filterAndSortDevices([
    { name: 'Media Box', mac: 'aa:bb:cc:dd:ee:02', ip: '192.168.5.12', online: false, down_bps: 9000, up_bps: 1000 },
    { name: 'Studio Laptop', mac: 'aa:bb:cc:dd:ee:01', ip: '192.168.5.11', online: true, down_bps: 1000, up_bps: 200 },
    { name: 'NAS', mac: 'aa:bb:cc:dd:ee:03', ip: '192.168.5.13', online: true, down_bps: 4000, up_bps: 500 }
  ], 'all', '', { key: 'rate', direction: 'desc' });

  assert.deepEqual(devices.map(device => device.name), ['Media Box', 'NAS', 'Studio Laptop']);
});

test('normalizeDevice keeps IPv4 and IPv6 addresses separately', () => {
  const device = normalizeDevice({
    ip: '192.168.5.11',
    ipv4: ['192.168.5.11'],
    ipv6: ['240e:3b2:3e81:1a90:f481:8375:7a37:55a3'],
    history_ipv4: ['192.168.5.130'],
    history_ipv6: ['fe80::1c82:53bb:c103:db90']
  });

  assert.deepEqual(device.ipv4, ['192.168.5.11']);
  assert.deepEqual(device.ipv6, ['240e:3b2:3e81:1a90:f481:8375:7a37:55a3']);
  assert.deepEqual(device.history_ipv4, ['192.168.5.130']);
  assert.deepEqual(device.history_ipv6, ['fe80::1c82:53bb:c103:db90']);
  assert.equal(device.ip, '192.168.5.11');
});

test('filterAndSortDevices searches historical neighbour addresses', () => {
  const devices = filterAndSortDevices([
    {
      name: 'Studio Laptop',
      mac: 'aa:bb:cc:dd:ee:01',
      ipv4: ['192.168.5.11'],
      history_ipv6: ['fe80::1c82:53bb:c103:db90']
    }
  ], 'all', 'fe80::1c82');

  assert.deepEqual(devices.map(device => device.name), ['Studio Laptop']);
});

test('buildSummary falls back to device totals when rpc summary is missing', () => {
  const summary = buildSummary({
    devices: [
      { online: true, down_bps: 2048, up_bps: 1024 },
      { online: false, down_bps: 512, up_bps: 256 }
    ]
  });

  assert.equal(summary.total, 2);
  assert.equal(summary.online, 1);
  assert.equal(summary.offline, 1);
  assert.equal(summary.down_bps, 2560);
  assert.equal(summary.up_bps, 1280);
});

test('resolveRestoredScrollTop keeps bottom offset across refresh resizing', () => {
  assert.equal(resolveRestoredScrollTop({
    bottom: 0,
    top: 700
  }, {
    clientHeight: 300,
    scrollHeight: 1200
  }), 900);

  assert.equal(resolveRestoredScrollTop({
    bottom: 420,
    top: 280
  }, {
    clientHeight: 300,
    scrollHeight: 1400
  }), 280);
});

test('detectDarkTheme follows host theme after it changes', () => {
  const htmlAttributes = new Map([['data-darkmode', 'true']]);
  const bodyAttributes = new Map();
  let mainBackground = 'rgb(31, 32, 35)';

  const documentElement = {
    className: '',
    getAttribute: name => htmlAttributes.get(name) || null
  };
  const body = {
    className: '',
    getAttribute: name => bodyAttributes.get(name) || null
  };
  const main = {};
  const document = {
    body,
    documentElement,
    querySelector: selector => selector === '.main-right' ? main : null
  };
  const window = {
    getComputedStyle: node => ({
      backgroundColor: node === main ? mainBackground : 'rgb(255, 255, 255)'
    })
  };

  assert.equal(detectDarkTheme({ document, window }), true);

  htmlAttributes.set('data-darkmode', 'false');
  mainBackground = 'rgb(255, 255, 255)';

  assert.equal(detectDarkTheme({ document, window }), false);
});

test('detectDarkTheme trusts host surface over stale dark markers', () => {
  const htmlAttributes = new Map([['data-darkmode', 'true']]);
  const bodyAttributes = new Map([['data-darkmode', 'true']]);
  const documentElement = {
    className: 'dark',
    getAttribute: name => htmlAttributes.get(name) || null
  };
  const body = {
    className: 'dark',
    getAttribute: name => bodyAttributes.get(name) || null
  };
  const main = {};
  const document = {
    body,
    documentElement,
    querySelector: selector => selector === '.main-right' ? main : null
  };
  const window = {
    getComputedStyle: () => ({
      backgroundColor: 'rgb(255, 255, 255)'
    })
  };

  assert.equal(detectDarkTheme({ document, window }), false);
});

test('subscribeDarkTheme notifies when host theme attributes mutate', () => {
  const htmlAttributes = new Map([['data-darkmode', 'true']]);
  let mainBackground = 'rgb(31, 32, 35)';
  let observer;

  class TestMutationObserver {
    constructor(callback) {
      this.callback = callback;
      observer = this;
    }

    observe() {}

    disconnect() {
      this.disconnected = true;
    }
  }

  const documentElement = {
    className: '',
    getAttribute: name => htmlAttributes.get(name) || null
  };
  const body = {
    className: '',
    getAttribute: () => null
  };
  const main = {};
  const document = {
    body,
    documentElement,
    querySelector: selector => selector === '.main-right' ? main : null
  };
  const window = {
    MutationObserver: TestMutationObserver,
    getComputedStyle: node => ({
      backgroundColor: node === main ? mainBackground : 'rgb(255, 255, 255)'
    }),
    matchMedia: () => ({
      addEventListener() {},
      removeEventListener() {}
    })
  };
  const changes = [];
  const unsubscribe = subscribeDarkTheme(next => changes.push(next), { document, window });

  htmlAttributes.set('data-darkmode', 'false');
  mainBackground = 'rgb(255, 255, 255)';
  observer.callback();

  assert.deepEqual(changes, [false]);
  unsubscribe();
  assert.equal(observer.disconnected, true);
});

test('subscribeDarkTheme rechecks after stylesheet media changes', () => {
  let mainBackground = 'rgb(31, 32, 35)';
  let observer;
  const observed = [];

  class TestMutationObserver {
    constructor(callback) {
      this.callback = callback;
      observer = this;
    }

    observe(node, options) {
      observed.push({ node, options });
    }

    disconnect() {}
  }

  const documentElement = {
    className: '',
    getAttribute: () => null
  };
  const body = {
    className: '',
    getAttribute: () => null
  };
  const head = {};
  const main = {};
  const document = {
    body,
    documentElement,
    head,
    querySelector: selector => selector === '.main-right' ? main : null
  };
  const window = {
    MutationObserver: TestMutationObserver,
    getComputedStyle: node => ({
      backgroundColor: node === main ? mainBackground : 'rgb(255, 255, 255)'
    }),
    matchMedia: () => ({
      addEventListener() {},
      removeEventListener() {}
    }),
    requestAnimationFrame: callback => callback(),
    setTimeout: callback => callback()
  };
  const changes = [];
  const unsubscribe = subscribeDarkTheme(next => changes.push(next), { document, window });

  assert.equal(observed.some(entry => entry.node === head && entry.options.childList && entry.options.subtree), true);

  mainBackground = 'rgb(255, 255, 255)';
  observer.callback();

  assert.deepEqual(changes, [false]);
  unsubscribe();
});
