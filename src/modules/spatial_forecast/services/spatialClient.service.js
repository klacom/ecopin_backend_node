import { supabaseAdmin } from '../../../config/supabase.config.js';
import { SPATIAL_FORECAST_CONFIG, normalizeHorizon } from '../config/spatial.config.js';

const currentPredictionsCache = new Map();
const MODEL_VERSION = 'zone-timeseries-v1';
export const clearCurrentPredictionsCache = () => currentPredictionsCache.clear();
const day = value => value.slice(0, 10);
const today = () => new Date().toISOString().slice(0, 10);
const httpError = (message, statusCode) => Object.assign(new Error(message), { statusCode });
const missingForwardSchema = error => ['42703', '42P01', 'PGRST204', 'PGRST205'].includes(error?.code);
const unavailableForecast = (horizon, setupRequired = false) => ({
  horizon, time_horizon: horizon, horizon_days: SPATIAL_FORECAST_CONFIG.timeHorizons[horizon],
  prediction_date: null, forecast_date_start: null, forecast_date_end: null,
  total_regions: 0, hotspot_count: 0, total_reports: 0, region_analyses: {},
  geojson: { type: 'FeatureCollection', features: [] }, heatmap_geojson: null,
  stale: false, status: setupRequired ? 'setup_required' : 'unavailable', source: null,
  message: setupRequired
    ? 'Forecasting setup is incomplete. Ask an administrator to finish setup.'
    : 'No current forward forecast is available. Try again after forecast generation.',
});
const parseJson = (value, fallback) => {
  try { return typeof value === 'string' ? JSON.parse(value) : (value ?? fallback); }
  catch { return fallback; }
};
const validGeometry = geometry => {
  if (!['Polygon', 'MultiPolygon'].includes(geometry?.type) || !Array.isArray(geometry.coordinates)) return false;
  const polygons = geometry.type === 'Polygon' ? [geometry.coordinates] : geometry.coordinates;
  return polygons.length > 0 && polygons.every(polygon => Array.isArray(polygon) && polygon.length > 0
    && polygon.every(ring => Array.isArray(ring) && ring.length >= 4
      && ring.every(point => Array.isArray(point) && point.length >= 2 && Number.isFinite(point[0]) && Number.isFinite(point[1])
        && Math.abs(point[0]) <= 180 && Math.abs(point[1]) <= 90)
      && ring[0][0] === ring.at(-1)[0] && ring[0][1] === ring.at(-1)[1]));
};

function remember(horizon, result) {
  currentPredictionsCache.set(horizon, { timestamp: Date.now(), data: result });
  return result;
}

function validateForecast(result, horizon) {
  if (!result || typeof result !== 'object') throw httpError('Forecast service returned invalid data', 502);
  const days = SPATIAL_FORECAST_CONFIG.timeHorizons[horizon];
  const start = Date.parse(result.forecast_date_start);
  const end = Date.parse(result.forecast_date_end);
  if ((result.horizon ?? result.time_horizon) !== horizon || result.horizon_days !== days
    || !Number.isFinite(start) || !Number.isFinite(end) || Math.abs((end - start) / 86400000 - days) > 0.001
    || typeof result.prediction_date !== 'string' || !Number.isFinite(Date.parse(result.prediction_date))
    || typeof result.forecast_date_start !== 'string' || typeof result.forecast_date_end !== 'string'
    || day(result.prediction_date) !== day(result.forecast_date_start)
    || result.model_version !== MODEL_VERSION || !result.region_analyses || typeof result.region_analyses !== 'object' || Array.isArray(result.region_analyses)
    || !Array.isArray(result.geojson?.features)) {
    throw httpError('Forecast service returned invalid forward forecast metadata', 502);
  }
  const geometries = new Map(result.geojson.features.map(feature => [feature.properties?.zone_id ?? feature.properties?.region_id, feature.geometry]));
  for (const [id, zone] of Object.entries(result.region_analyses)) {
    if (!zone || zone.zone_id !== id || zone.region_id !== id || !validGeometry(geometries.get(id))
      || !Array.isArray(zone.historical_points) || !Array.isArray(zone.forecast_points) || zone.forecast_points.length === 0
      || ![zone.predicted_count, zone.predicted_lower_bound, zone.predicted_upper_bound, zone.growth_velocity_percent, zone.risk_score].every(Number.isFinite)
      || !['low', 'medium', 'high'].includes(zone.risk_level) || !Number.isInteger(zone.report_count) || zone.report_count < 0
      || !Number.isFinite(zone.region_center_lat) || !Number.isFinite(zone.region_center_lng)
      || !zone.historical_points.every(point => Number.isFinite(Date.parse(point.week_start)) && Number.isFinite(point.actual_count) && point.actual_count >= 0)
      || !zone.forecast_points.every(point => Number.isFinite(Date.parse(point.week_start))
        && [point.predicted_count, point.lower_bound, point.upper_bound].every(Number.isFinite)
        && point.lower_bound >= 0 && point.lower_bound <= point.predicted_count && point.upper_bound >= point.predicted_count)
      || zone.predicted_lower_bound < 0 || zone.predicted_lower_bound > zone.predicted_count
      || zone.predicted_upper_bound < zone.predicted_count || zone.risk_score < 0 || zone.risk_score > 1) {
      throw httpError('Forecast service returned an invalid zone forecast', 502);
    }
  }
}

/** Generate a forward forecast. Stable polygons and trend points survive cache reloads. */
export const generateForecast = async (timeHorizon = '30d') => {
  const horizon = normalizeHorizon(timeHorizon);
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), SPATIAL_FORECAST_CONFIG.timeout);
  let result;
  try {
    const response = await fetch(SPATIAL_FORECAST_CONFIG.serviceUrl + '/forecast/project', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ horizon, zone_type: 'h3' }), signal: controller.signal,
    });
    if (!response.ok) throw httpError('Forecast service is unavailable', 502);
    result = await response.json();
    validateForecast(result, horizon);
  } finally {
    clearTimeout(timeout);
  }
  result = { ...result, horizon, time_horizon: horizon, stale: false, status: 'ready', source: 'generated_forecast' };
  await storePredictions(result);
  return remember(horizon, result);
};

const storePredictions = async result => {
  const geometries = new Map(result.geojson.features.map(feature => [feature.properties.zone_id ?? feature.properties.region_id, feature.geometry]));
  const rows = Object.entries(result.region_analyses).map(([id, zone]) => ({
    region_id: id, zone_id: id, zone_name: zone.zone_name,
    time_horizon: result.horizon, horizon_days: result.horizon_days,
    prediction_date: day(result.prediction_date),
    forecast_date_start: result.forecast_date_start, forecast_date_end: result.forecast_date_end,
    model_version: result.model_version,
    risk_score: zone.risk_score, risk_level: zone.risk_level, report_count: zone.report_count,
    predicted_count: zone.predicted_count, predicted_lower_bound: zone.predicted_lower_bound,
    predicted_upper_bound: zone.predicted_upper_bound, growth_velocity_percent: zone.growth_velocity_percent,
    historical_points: zone.historical_points, forecast_points: zone.forecast_points,
    region_center_lat: zone.region_center_lat, region_center_lng: zone.region_center_lng,
    geojson_polygon: JSON.stringify(geometries.get(id)),
  }));
  if (rows.length) {
    const { error } = await supabaseAdmin.from('hotspot_predictions')
      .upsert(rows, { onConflict: 'region_id,prediction_date,time_horizon' });
    if (error) throw error;
  }
};

function restoreForecast(records, horizon, stale) {
  const region_analyses = {};
  const features = [];
  for (const row of records) {
    const geometry = parseJson(row.geojson_polygon, null);
    // Stable boundaries are required; never invent circles for old DBSCAN records.
    if (!validGeometry(geometry) || row.model_version !== MODEL_VERSION
      || row.horizon_days !== SPATIAL_FORECAST_CONFIG.timeHorizons[horizon]
      || Date.parse(row.forecast_date_start) !== Date.parse(records[0].forecast_date_start)
      || Date.parse(row.forecast_date_end) !== Date.parse(records[0].forecast_date_end)) return null;
    const analysis = {
      region_id: row.region_id, zone_id: row.zone_id, zone_name: row.zone_name,
      risk_score: Number(row.risk_score), risk_level: row.risk_level, report_count: Number(row.report_count),
      is_hotspot: row.risk_level === 'high',
      predicted_count: Number(row.predicted_count), predicted_lower_bound: Number(row.predicted_lower_bound),
      predicted_upper_bound: Number(row.predicted_upper_bound), growth_velocity_percent: Number(row.growth_velocity_percent),
      historical_points: parseJson(row.historical_points, []), forecast_points: parseJson(row.forecast_points, []),
      region_center_lat: Number(row.region_center_lat), region_center_lng: Number(row.region_center_lng),
    };
    region_analyses[row.region_id] = analysis;
    features.push({ type: 'Feature', geometry, properties: { ...analysis, center_lat: row.region_center_lat, center_lng: row.region_center_lng } });
  }
  const result = {
    horizon, time_horizon: horizon, horizon_days: SPATIAL_FORECAST_CONFIG.timeHorizons[horizon],
    prediction_date: records[0].prediction_date, forecast_date_start: records[0].forecast_date_start,
    forecast_date_end: records[0].forecast_date_end, model_version: records[0].model_version,
    total_regions: records.length, hotspot_count: records.filter(row => row.risk_level === 'high').length,
    total_reports: records.reduce((sum, row) => sum + Number(row.report_count || 0), 0),
    region_analyses, geojson: { type: 'FeatureCollection', features }, heatmap_geojson: null,
    stale, status: 'ready', source: 'stored_forecast',
  };
  try { validateForecast(result, horizon); return result; }
  catch { return null; }
}

export const getCurrentPredictions = async (timeHorizon = '30d', options = {}) => {
  const horizon = normalizeHorizon(timeHorizon);
  const refresh = Boolean(options?.refresh);
  const date = today();
  const now = new Date().toISOString();
  const cached = currentPredictionsCache.get(horizon);
  if (!refresh && SPATIAL_FORECAST_CONFIG.cache.enabled && cached && Date.now() - cached.timestamp < SPATIAL_FORECAST_CONFIG.cache.ttl
    && day(cached.data.prediction_date) === date && Date.parse(cached.data.forecast_date_end) > Date.now()) return cached.data;

  const { data, error } = await supabaseAdmin.from('hotspot_predictions').select('*')
    .eq('time_horizon', horizon).eq('horizon_days', SPATIAL_FORECAST_CONFIG.timeHorizons[horizon])
    .eq('model_version', MODEL_VERSION).not('zone_id', 'is', null)
    .lte('prediction_date', date).lte('forecast_date_start', now)
    .gt('forecast_date_end', now).order('prediction_date', { ascending: false });
  if (missingForwardSchema(error)) return unavailableForecast(horizon, true);
  if (error) throw error;
  const latestDate = data?.[0]?.prediction_date;
  const latest = (data ?? []).filter(row => row.prediction_date === latestDate);
  if (!refresh && latest.length && day(latestDate) === date) {
    const result = restoreForecast(latest, horizon, false);
    if (result) return remember(horizon, result);
  }
  try {
    return await generateForecast(horizon);
  } catch {
    console.warn('[SpatialForecast] Fresh forecast unavailable', { horizon });
    if (latest.length) {
      const result = restoreForecast(latest, horizon, true);
      if (result) return result;
    }
    // Empty data is distinguishable from a zero-risk prediction.
    return unavailableForecast(horizon);
  }
};

export const getZoneTrend = async (zoneId, timeHorizon = '30d') => {
  if (typeof zoneId !== 'string' || !/^[a-zA-Z0-9_-]{1,64}$/.test(zoneId)) throw httpError('Invalid zone ID', 400);
  const result = await getCurrentPredictions(timeHorizon);
  const zone = result.region_analyses[zoneId];
  if (!zone) throw httpError('Zone forecast is not available', 404);
  return { ...zone, horizon: result.horizon, horizon_days: result.horizon_days, prediction_date: result.prediction_date,
    forecast_date_start: result.forecast_date_start, forecast_date_end: result.forecast_date_end,
    model_version: result.model_version, stale: result.stale, source: result.source };
};

/** Historical endpoint returns forward model records, never legacy clusters. */
export const getPredictions = async (filters = {}) => {
  const horizon = filters.timeHorizon === undefined ? null : normalizeHorizon(filters.timeHorizon);
  for (const value of [filters.startDate, filters.endDate].filter(value => value !== undefined)) {
    if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value) || !Number.isFinite(Date.parse(value))) throw httpError('Invalid prediction date', 400);
  }
  const limit = filters.limit ?? 500;
  if (!Number.isInteger(limit) || limit < 1 || limit > 1000) throw httpError('Limit must be between 1 and 1000', 400);
  if (filters.regionId !== undefined && (typeof filters.regionId !== 'string' || !/^[a-zA-Z0-9_-]{1,64}$/.test(filters.regionId))) throw httpError('Invalid zone ID', 400);
  let query = supabaseAdmin.from('hotspot_predictions').select('*').eq('model_version', MODEL_VERSION)
    .not('zone_id', 'is', null).order('prediction_date', { ascending: false });
  if (horizon) query = query.eq('time_horizon', horizon);
  if (filters.regionId) query = query.eq('zone_id', filters.regionId);
  if (filters.startDate) query = query.gte('prediction_date', filters.startDate);
  if (filters.endDate) query = query.lte('prediction_date', filters.endDate);
  const { data, error } = await query.limit(limit);
  if (error) throw error;
  return data ?? [];
};

export const getAvailableDates = async (timeHorizon = null) => {
  const horizon = timeHorizon === null ? null : normalizeHorizon(timeHorizon);
  const dates = new Set();
  const pageSize = 1000;
  for (let offset = 0; ; offset += pageSize) {
    let query = supabaseAdmin.from('hotspot_predictions').select('prediction_date')
      .eq('model_version', MODEL_VERSION).not('zone_id', 'is', null)
      .order('prediction_date', { ascending: true }).order('region_id', { ascending: true });
    if (horizon) query = query.eq('time_horizon', horizon);
    const { data, error } = await query.range(offset, offset + pageSize - 1);
    if (missingForwardSchema(error)) return [];
    if (error) throw error;
    for (const row of data ?? []) dates.add(day(row.prediction_date));
    if (!data || data.length < pageSize) break;
  }
  return [...dates].sort();
};

export const getAccuracyMetrics = async (timeHorizon = null) => {
  const horizon = timeHorizon === null ? null : normalizeHorizon(timeHorizon);
  return { horizon, status: 'not_evaluated', records: [], averageAccuracy: null, totalEvaluations: 0,
    message: 'Forward forecasts have not yet been evaluated against completed forecast windows.' };
};
