import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

test('FlowLens polls realtime traffic every 2 seconds', () => {
  const appSource = readFileSync(new URL('../src/main.jsx', import.meta.url), 'utf8');
  const luciSource = readFileSync(new URL('../../htdocs/luci-static/resources/view/flowlens/overview.js', import.meta.url), 'utf8');

  assert.match(appSource, /pollInterval\s*=\s*2000/);
  assert.match(luciSource, /pollInterval:\s*2000/);
});
