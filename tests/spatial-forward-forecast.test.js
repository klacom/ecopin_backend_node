import { jest } from '@jest/globals';

let records = [];
let databaseError = null;
const from = jest.fn(() => {
  let selected = records;
  const query = {
    select: () => query,
    eq: (key, value) => { selected = selected.filter(row => row[key] === value); return query; },
    gte: (key, value) => { selected = selected.filter(row => row[key] >= value); return query; },
    lte: (key, value) => { selected = selected.filter(row => row[key] <= value); return query; },
    gt: (key, value) => { selected = selected.filter(row => row[key] > value); return query; },
    not: (key, operator, value) => { selected = selected.filter(row => row[key] !== value); return query; },
    order: (key, { ascending }) => { selected = [...selected].sort((a, b) => ascending ? String(a[key]).localeCompare(String(b[key])) : String(b[key]).localeCompare(String(a[key]))); return query; },
    limit: value => { selected = selected.slice(0, value); return query; },
    range: (start, end) => { selected = selected.slice(start, end + 1); return query; },
    upsert: async rows => { records = structuredClone(rows); return { error: null }; },
    then: resolve => Promise.resolve({ data: databaseError ? null : structuredClone(selected.slice(0, 1000)), error: databaseError }).then(resolve),
  };
  return query;
});
jest.unstable_mockModule('../src/config/supabase.config.js', () => ({ supabaseAdmin: { from } }));
const service = await import('../src/modules/spatial_forecast/services/spatialClient.service.js');
const originalFetch = global.fetch;
const geometry = { type: 'Polygon', coordinates: [[[121.08, 14.57], [121.09, 14.57], [121.09, 14.58], [121.08, 14.57]]] };
function forecast(horizon = '30d', predictionDate = '2026-10-18', count = 3) {
  const days = Number.parseInt(horizon);
  const end = new Date(`${predictionDate}T00:00:00.000Z`);
  end.setUTCDate(end.getUTCDate() + days);
  const zone = {
    region_id: 'h3-test', zone_id: 'h3-test', zone_name: 'Test zone', risk_level: 'low', risk_score: count ? 0.2 : 0,
    report_count: 8, predicted_count: count, predicted_lower_bound: Math.min(count, 1), predicted_upper_bound: Math.max(count, 7),
    growth_velocity_percent: 12, region_center_lat: 14.575, region_center_lng: 121.085,
    historical_points: [{ week_start: '2026-10-05', actual_count: 8 }],
    forecast_points: [{ week_start: predictionDate, predicted_count: count, lower_bound: Math.min(count, 1), upper_bound: Math.max(count, 7) }],
  };
  return {
    horizon, time_horizon: horizon, horizon_days: days, prediction_date: predictionDate,
    forecast_date_start: predictionDate, forecast_date_end: end.toISOString().slice(0, 10),
    model_version: 'zone-timeseries-v1', total_regions: 1, hotspot_count: 0, total_reports: 8,
    region_analyses: { 'h3-test': zone }, geojson: { type: 'FeatureCollection', features: [{ type: 'Feature', geometry, properties: zone }] },
  };
}
beforeEach(() => {
  jest.useFakeTimers({ now: new Date('2026-10-18T06:00:00Z') });
  records = [];
  databaseError = null;
  from.mockClear();
  service.clearCurrentPredictionsCache?.();
  global.fetch = jest.fn().mockResolvedValue({ ok: true, json: async () => forecast() });
});
afterEach(() => { jest.useRealTimers(); global.fetch = originalFetch; });

test.each(['42703', '42P01', 'PGRST204', 'PGRST205'])('missing migration (%s) has an explicit setup state instead of crashing dates/current', async code => {
  databaseError = { code, message: 'synthetic schema detail' };
  await expect(service.getAvailableDates('7d')).resolves.toEqual([]);
  await expect(service.getCurrentPredictions('7d')).resolves.toMatchObject({ status: 'setup_required', horizon: '7d', geojson: { features: [] } });
  expect(global.fetch).not.toHaveBeenCalled();
});

test('schema handling does not hide database permission failures as empty history', async () => {
  databaseError = { code: '42501', message: 'synthetic permission failure' };
  await expect(service.getAvailableDates('7d')).rejects.toEqual(databaseError);
  await expect(service.getCurrentPredictions('7d')).rejects.toEqual(databaseError);
});

test('projects forward horizons and roundtrips every zone polygon, trend point and interval through persistence', async () => {
  const result = await service.generateForecast('30d');
  expect(global.fetch).toHaveBeenCalledWith(expect.stringContaining('/forecast/project'), expect.objectContaining({ body: JSON.stringify({ horizon: '30d', zone_type: 'h3' }) }));
  expect(records[0]).toMatchObject({ zone_id: 'h3-test', horizon_days: 30, forecast_date_start: '2026-10-18', forecast_date_end: '2026-11-17', model_version: 'zone-timeseries-v1' });
  service.clearCurrentPredictionsCache();
  const cached = await service.getCurrentPredictions('30d');
  expect(cached.region_analyses['h3-test']).toMatchObject(result.region_analyses['h3-test']);
  expect(cached.geojson.features[0].geometry).toEqual(geometry);
  expect(cached).toMatchObject({ horizon: '30d', horizon_days: 30, total_reports: 8, stale: false });
  expect(global.fetch).toHaveBeenCalledTimes(1);
});

test('zero-risk zones retain stable geometry in cached map layers', async () => {
  global.fetch.mockResolvedValue({ ok: true, json: async () => forecast('30d', '2026-10-18', 0) });
  await service.generateForecast('30d'); service.clearCurrentPredictionsCache();
  const cached = await service.getCurrentPredictions('30d');
  expect(cached.geojson.features).toHaveLength(1);
  expect(cached.geojson.features[0].geometry).toEqual(geometry);
});

test('offline fallback is same-horizon, forward-only and explicitly stale', async () => {
  global.fetch.mockResolvedValue({ ok: true, json: async () => forecast('30d', '2026-10-17') });
  await service.generateForecast('30d'); service.clearCurrentPredictionsCache();
  global.fetch.mockRejectedValue(new Error('offline'));
  const result = await service.getCurrentPredictions('30d');
  expect(result).toMatchObject({ horizon: '30d', stale: true, source: 'stored_forecast', forecast_date_start: '2026-10-17' });
  const differentHorizon = await service.getCurrentPredictions('90d');
  expect(differentHorizon.geojson.features).toEqual([]);
  expect(differentHorizon).toMatchObject({ horizon: '90d', status: 'unavailable' });
});

test('expired forward forecasts and legacy clusters never masquerade as current predictions', async () => {
  records = [{ ...forecast().region_analyses['h3-test'], time_horizon: '30d', prediction_date: '2026-10-18', geojson_polygon: geometry },
    { ...forecast().region_analyses['h3-test'], zone_id: 'old', horizon_days: 30, model_version: 'zone-timeseries-v1', time_horizon: '30d', prediction_date: '2026-09-01', forecast_date_start: '2026-09-01', forecast_date_end: '2026-10-01', geojson_polygon: geometry }];
  global.fetch.mockRejectedValue(new Error('offline'));
  const result = await service.getCurrentPredictions('30d');
  expect(result).toMatchObject({ status: 'unavailable', total_regions: 0 });
});

test('fresh generation replaces the cached response and preserves horizon isolation', async () => {
  await service.generateForecast('30d');
  global.fetch.mockResolvedValue({ ok: true, json: async () => forecast('30d', '2026-10-18', 9) });
  await service.generateForecast('30d');
  expect((await service.getCurrentPredictions('30d')).region_analyses['h3-test'].predicted_count).toBe(9);
  global.fetch.mockResolvedValue({ ok: true, json: async () => forecast('7d') });
  expect((await service.getCurrentPredictions('weekly')).horizon_days).toBe(7);
});

test.each(['1d', '100d', '', ['7d'], '__proto__'])('rejects invalid horizon %p before service or database access', async horizon => {
  await expect(service.getCurrentPredictions(horizon)).rejects.toMatchObject({ statusCode: 400 });
  expect(global.fetch).not.toHaveBeenCalled(); expect(from).not.toHaveBeenCalled();
});

test('rejects a mismatched forecast horizon instead of caching it', async () => {
  await expect(service.generateForecast('90d')).rejects.toMatchObject({ statusCode: 502 });
  expect(records).toEqual([]);
});

test('request failure always releases its timeout', async () => {
  global.fetch.mockRejectedValue(new Error('offline'));
  await expect(service.generateForecast('30d')).rejects.toThrow('offline');
  expect(jest.getTimerCount()).toBe(0);
});

test('accuracy endpoint explicitly reports missing forward evaluation', async () => {
  expect(await service.getAccuracyMetrics('30d')).toMatchObject({ status: 'not_evaluated', averageAccuracy: null, records: [] });
  expect(from).not.toHaveBeenCalled();
});

test('available dates are horizon-specific and continue beyond the first thousand zone records', async () => {
  records = Array.from({ length: 1002 }, (_, index) => ({
    zone_id: 'zone-' + index, model_version: 'zone-timeseries-v1', time_horizon: '7d',
    prediction_date: index === 1001 ? '2026-10-17' : '2026-10-18',
  }));
  records.push({ zone_id: 'monthly', model_version: 'zone-timeseries-v1', time_horizon: '30d', prediction_date: '2026-10-16' });
  records.push({ zone_id: 'legacy', model_version: 'unrecognized', time_horizon: '7d', prediction_date: '2026-10-15' });
  expect(await service.getAvailableDates('7d')).toEqual(['2026-10-17', '2026-10-18']);
});

test.each(['interval', 'model', 'empty_geometry'])('invalid stored forecast %s is never shown as forward data', async corruption => {
  await service.generateForecast('30d'); service.clearCurrentPredictionsCache();
  if (corruption === 'interval') records[0].predicted_lower_bound = 100;
  if (corruption === 'model') records[0].model_version = 'legacy';
  if (corruption === 'empty_geometry') records[0].geojson_polygon = { type: 'Polygon', coordinates: [[]] };
  global.fetch.mockRejectedValue(new Error('offline'));
  expect(await service.getCurrentPredictions('30d')).toMatchObject({ status: 'unavailable' });
});

test('precise forecast timestamps survive storage and exclude an expired window on its end date', async () => {
  const result = forecast('7d', '2026-10-11');
  result.forecast_date_start = '2026-10-11T05:00:00Z'; result.forecast_date_end = '2026-10-18T05:00:00Z';
  global.fetch.mockResolvedValue({ ok: true, json: async () => result });
  await service.generateForecast('7d'); service.clearCurrentPredictionsCache();
  expect(records[0].forecast_date_start).toBe('2026-10-11T05:00:00Z');
  global.fetch.mockRejectedValue(new Error('offline'));
  expect(await service.getCurrentPredictions('7d')).toMatchObject({ status: 'unavailable' });
});
