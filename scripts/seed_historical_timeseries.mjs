import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import path from 'node:path';

const DAY = 86400000;
const MARKER = 'ecopin-forecast-history-v1';
const catalogUrl = new URL('../data/pasig-h3-r8.geojson', import.meta.url);

export function parseOptions(args) {
  const { values } = parseArgs({ args, options: {
    weeks: { type: 'string', default: '52' }, seed: { type: 'string', default: '20261018' },
    'as-of': { type: 'string', default: new Date().toISOString().slice(0, 10) },
    'user-id': { type: 'string' }, output: { type: 'string' },
    'dry-run': { type: 'boolean', default: false }, help: { type: 'boolean', default: false },
  } });
  const weeks = Number(values.weeks), seed = Number(values.seed);
  if (!Number.isInteger(weeks) || weeks < 26 || weeks > 52) throw new Error('--weeks must be 26..52.');
  if (!Number.isSafeInteger(seed) || seed < 0 || seed > 0xffffffff) throw new Error('--seed must be a uint32.');
  if (!/^\d{4}-\d{2}-\d{2}$/.test(values['as-of']) ||
      !Number.isFinite(Date.parse(values['as-of'])) ||
      new Date(values['as-of']).toISOString().slice(0, 10) !== values['as-of']) throw new Error('--as-of must be YYYY-MM-DD.');
  if (values['user-id'] && !/^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/i.test(values['user-id'])) {
    throw new Error('--user-id must be an existing profile UUID.');
  }
  if (values.output && values['dry-run']) throw new Error('Choose --output or --dry-run.');
  return { weeks, seed, asOf: values['as-of'], userId: values['user-id'] ?? null,
    output: values.output, help: values.help };
}

function randomGenerator(seed) {
  return () => {
    seed |= 0;
    seed = seed + 0x6d2b79f5 | 0;
    let t = Math.imul(seed ^ seed >>> 15, 1 | seed);
    t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
    return ((t ^ t >>> 14) >>> 0) / 4294967296;
  };
}

function poisson(mean, random) {
  const limit = Math.exp(-mean);
  let product = 1, count = 0;
  do { product *= random(); count++; } while (product > limit);
  return count - 1;
}

export function dailyRate(lat, lng, date, progress) {
  const proximity = (a, b, width) => Math.exp(-((lat - a) ** 2 + (lng - b) ** 2) / width ** 2);
  const base = 0.06 + 1.5 * proximity(14.5595, 121.0753, 0.009)
    + 0.7 * proximity(14.5478, 121.0945, 0.012);
  const rainySeason = date.getUTCMonth() >= 6 && date.getUTCMonth() <= 9 ? 1.45 : 1;
  const weekday = [0.85, 1.8, 1.05, 1, 1, 1.1, 0.8][date.getUTCDay()];
  return base * rainySeason * weekday * (0.9 + progress * 0.2);
}

export function buildHistory({ weeks, seed, asOf, userId = null }, catalog) {
  // Reuse CLI validation for programmatic callers too.
  parseOptions(['--weeks', String(weeks), '--seed', String(seed), '--as-of', asOf,
    ...(userId ? ['--user-id', userId] : [])]);
  if (!catalog?.features?.length) throw new Error('A populated stable zone catalog is required.');
  const random = randomGenerator(seed), end = Date.parse(asOf), rows = [];
  for (let day = 0; day < weeks * 7; day++) {
    const stamp = end - (weeks * 7 - day) * DAY;
    const date = new Date(stamp), dateKey = date.toISOString().slice(0, 10);
    for (const feature of catalog.features) {
      const { id: zoneId, centroid_lat: lat, centroid_lng: lng } = feature.properties;
      const count = poisson(dailyRate(lat, lng, date, day / (weeks * 7)), random);
      for (let n = 0; n < count; n++) {
        const key = `${MARKER}:${seed}:${zoneId}:${dateKey}:${n}`;
        const hash = createHash('sha256').update(key).digest('hex');
        const id = `${hash.slice(0, 8)}-${hash.slice(8, 12)}-${hash.slice(12, 16)}-${hash.slice(16, 20)}-${hash.slice(20, 32)}`;
        const created = stamp + Math.floor((7 + 10 * random()) * 3600000);
        const severity = Math.floor(15 + random() * 70);
        rows.push({ id, user_id: userId, title: `[SYNTHETIC FORECAST] Waste incident ${zoneId}`,
          description: 'Synthetic time-series fixture; not a citizen submission or verified field operation.',
          issue_type: 'waste', location: `SRID=4326;POINT(${lng} ${lat})`,
          validation_status: 'approved', status: 'closed', stage: 'closed',
          lifecycle_state: 'closed', severity_score: severity,
          severity_level: severity >= 67 ? 'High' : severity >= 34 ? 'Medium' : 'Low',
          created_at: new Date(created).toISOString(), updated_at: new Date(created).toISOString(),
          idempotency_key: key });
      }
    }
  }
  return rows;
}

export function renderSql(rows) {
  const columns = Object.keys(rows[0] ?? {});
  let sql = '-- Synthetic forecasting history. Review and apply ONLY to a demo/staging database.\n'
    + '-- This file preserves existing reports. Repeating the same seed/date inserts no duplicates.\n'
    + '-- Closed fixtures avoid adding work to the dispatch queue. No field completion is claimed.\n'
    + "BEGIN;\nSET LOCAL lock_timeout = '5s';\nSET LOCAL statement_timeout = '120s';\n";
  for (let offset = 0; offset < rows.length; offset += 250) {
    const payload = JSON.stringify(rows.slice(offset, offset + 250)).replaceAll("'", "''");
    sql += `INSERT INTO public.reports (${columns.join(', ')})\n`
      + `SELECT ${columns.join(', ')} FROM jsonb_populate_recordset(NULL::public.reports, '${payload}'::jsonb)\n`
      + 'ON CONFLICT (idempotency_key) DO NOTHING;\n';
  }
  return sql + 'COMMIT;\n';
}

export function summarize(rows, weeks) {
  const zones = new Set(), weekdays = Array(7).fill(0), months = Array(12).fill(0);
  for (const row of rows) {
    zones.add(row.title.split(' ').at(-1));
    const date = new Date(row.created_at);
    weekdays[date.getUTCDay()]++; months[date.getUTCMonth()]++;
  }
  return { synthetic: true, weeks, reports: rows.length, populatedZones: zones.size,
    weekdayCountsSundayFirst: weekdays, monthlyCountsJanuaryFirst: months };
}

async function main() {
  const options = parseOptions(process.argv.slice(2));
  if (options.help) {
    console.log('node scripts/seed_historical_timeseries.mjs [--weeks 26..52] [--seed N] [--as-of YYYY-MM-DD]\n'
      + '[--user-id EXISTING_PROFILE_UUID] [--dry-run | --output FILE.sql]\n'
      + 'Default is an offline preview. --output writes reviewable SQL; never connects to a database.');
    return;
  }
  if (Date.parse(options.asOf) > Date.now()) throw new Error('--as-of must not be in the future.');
  const catalog = JSON.parse(await readFile(catalogUrl, 'utf8'));
  const rows = buildHistory(options, catalog);
  console.log(JSON.stringify(summarize(rows, options.weeks), null, 2));
  if (options.output) {
    await writeFile(options.output, renderSql(rows), { encoding: 'utf8', flag: 'wx' });
    console.log(`Review SQL at ${path.resolve(options.output)}. No database was changed.`);
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
}
