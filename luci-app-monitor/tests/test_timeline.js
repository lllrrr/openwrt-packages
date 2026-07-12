'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const overview = fs.readFileSync(path.join(
	__dirname,
	'..',
	'htdocs',
	'luci-static',
	'resources',
	'view',
	'internet-monitor',
	'overview.js'
), 'utf8');

function extractFunction(name) {
	const marker = `function ${name}(`;
	const start = overview.indexOf(marker);
	const bodyStart = overview.indexOf('{', start);
	let depth = 0;

	assert.notEqual(start, -1, `missing ${name}()`);
	assert.notEqual(bodyStart, -1, `missing body for ${name}()`);

	for (let index = bodyStart; index < overview.length; index++) {
		if (overview[index] === '{')
			depth++;
		else if (overview[index] === '}' && --depth === 0)
			return overview.slice(start, index + 1);
	}

	throw new Error(`unterminated ${name}()`);
}

const timelineBins = Function([
	extractFunction('toTimestamp'),
	extractFunction('canonicalState'),
	extractFunction('timelineBins'),
	'return timelineBins;'
].join('\n'))();

// An 18-hour monitor lifetime in a 24-hour view must fill 72 of 96
// fifteen-minute bars, even when the browser clock differs from the router.
const generatedAt = 1800000000;
const monitoredAt = generatedAt - 18 * 3600;
const points = [];

for (let timestamp = monitoredAt; timestamp < generatedAt; timestamp += 300)
	points.push({ timestamp: timestamp, state: 'online', latency_ms: 20 });

const lifetimeBins = timelineBins(points, 24, 96, generatedAt);

assert.equal(lifetimeBins.length, 96);
assert.equal(lifetimeBins.filter(bin => bin.state === 'unknown').length, 24);
assert.equal(lifetimeBins.filter(bin => bin.state === 'operational').length, 72);
assert.equal(lifetimeBins[95].end, generatedAt * 1000);

// The right edge is exclusive: a state beginning exactly at generated_at has
// zero duration and must not recolor the preceding bar.
const edgeBins = timelineBins([
	{ timestamp: generatedAt - 900, state: 'online', latency_ms: 18 },
	{ timestamp: generatedAt, state: 'offline', latency_ms: -1 }
], 1, 4, generatedAt);

assert.equal(edgeBins[3].state, 'operational');

// A real no-data observation cannot be hidden by a later success or degraded
// sample in the same frontend bin.
const priorityBins = timelineBins([
	{ timestamp: generatedAt - 800, state: 'online', latency_ms: 18 },
	{ timestamp: generatedAt - 700, state: 'unknown', latency_ms: -1 },
	{ timestamp: generatedAt - 600, state: 'degraded', latency_ms: 80 }
], 1, 4, generatedAt);

assert.equal(priorityBins[3].state, 'unknown');
