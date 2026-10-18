import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { buildHistory, dailyRate, parseOptions, renderSql, summarize } from './seed_historical_timeseries.mjs';

const catalog = JSON.parse(readFileSync(new URL('../data/pasig-h3-r8.geojson', import.meta.url)));
const options = { weeks: 52, seed: 20261018, asOf: '2026-10-18' };

test('catalog has stable closed resolution-8 polygons around the study area', () => {
  assert.equal(catalog.features.length, 122);
  assert.equal(new Set(catalog.features.map(f => f.id)).size, 122);
  for (const f of catalog.features) {
    assert.match(f.id, /^88[0-9a-f]{13}$/);
    const ring = f.geometry.coordinates[0];
    assert.equal(ring.length, 7);
    assert.deepEqual(ring[0], ring.at(-1));
    assert.ok(ring.every(([lng, lat]) => lng > 121 && lng < 121.2 && lat > 14.5 && lat < 14.7));
  }
});

test('seed is deterministic, covers 52 weeks, and preserves plausible rhythms', () => {
  const rows = buildHistory(options, catalog);
  assert.deepEqual(rows, buildHistory(options, catalog));
  assert.notDeepEqual(rows, buildHistory({ ...options, seed: 1 }, catalog));
  assert.ok(rows.length > 2000);
  assert.equal(new Set(rows.map(r => r.id)).size, rows.length);
  assert.ok(rows.every(r => r.validation_status === 'approved' && r.status === 'closed'));
  assert.ok(rows.every(r => r.created_at < `${options.asOf}T00:00:00.000Z`));
  const summary = summarize(rows, options.weeks);
  assert.equal(summary.populatedZones, catalog.features.length);
  assert.ok(summary.weekdayCountsSundayFirst[1] > 1.4 * summary.weekdayCountsSundayFirst[3]);
  const rainy = rows.filter(r => new Date(r.created_at).getUTCMonth() >= 6 && new Date(r.created_at).getUTCMonth() <= 9).length;
  assert.ok(rainy / 123 > (rows.length - rainy) / (364 - 123) * 1.25);
  assert.ok(new Set(rows.map(r => r.created_at.slice(0, 10))).size > 350);
});

test('commercial intensity exceeds Pinagbuhatan and low density residential background', () => {
  const date = new Date('2026-08-03');
  assert.ok(dailyRate(14.5595, 121.0753, date, 0.5) > dailyRate(14.5478, 121.0945, date, 0.5));
  assert.ok(dailyRate(14.5478, 121.0945, date, 0.5) > dailyRate(14.61, 121.10, date, 0.5));
});

test('invalid ranges fail and SQL is additive and idempotent', () => {
  for (const args of [['--weeks', '25'], ['--weeks', '53'], ['--seed', '-1'], ['--as-of', '2026-02-30'], ['--user-id', 'bad']]) {
    assert.throws(() => parseOptions(args));
  }
  assert.throws(() => parseOptions(['--dry-run', '--output', 'seed.sql']));
  const rows = buildHistory(options, catalog).slice(0, 2);
  rows[0].description = "Operator's synthetic fixture";
  const sql = renderSql(rows);
  assert.match(sql, /Operator''s/);
  assert.match(sql, /ON CONFLICT \(idempotency_key\) DO NOTHING/);
  assert.doesNotMatch(sql, /\b(?:DELETE|TRUNCATE|DISABLE TRIGGER)\b/i);
});
