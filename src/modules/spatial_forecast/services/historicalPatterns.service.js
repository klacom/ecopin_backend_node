import { SPATIAL_FORECAST_CONFIG as config } from '../config/spatial.config.js';
import roster from '../../../../data/pasig-barangay-roster.json' with { type: 'json' };

const DAY = 86400000;
const horizons = { '7d': 7, '30d': 30, '90d': 90 };
const weekOrigin = time => { const d=new Date(time); return Date.UTC(d.getUTCFullYear(),d.getUTCMonth(),d.getUTCDate()-((d.getUTCDay()+6)%7)); };
const names = new Map(roster.barangays.map(b => [b.psgc_code, b.name]));
const labels = new Set(['chronic', 'transient_spike', 'recent_spike', 'recent_concentration', 'historical_only', 'intermittent', 'mixed_membership']);
const fail = () => { throw Object.assign(new Error('Historical analysis returned inconsistent data'), { statusCode: 502 }); };
const count = n => Number.isInteger(n) && n >= 0 && n <= 5000;
const date = d => typeof d === 'string' && Number.isFinite(Date.parse(d));
const identity = id => typeof id === 'string' && /^dbscan_[a-f0-9]{16}$/.test(id);
function geometry(g) {
  if (g?.type !== 'Polygon' || !Array.isArray(g.coordinates) || g.coordinates.length !== 1) fail();
  const r = g.coordinates[0];
  if (!Array.isArray(r) || r.length < 4 || r.length > 5001 || !r.every(p => Array.isArray(p) && p.length === 2 && p.every(Number.isFinite) && Math.abs(p[0]) <= 180 && Math.abs(p[1]) <= 90)
    || r[0][0] !== r.at(-1)[0] || r[0][1] !== r.at(-1)[1]) fail();
  return { type: 'Polygon', coordinates: [r.map(p => [...p])] };
}
function counts(c) {
  if (!c || !Object.keys(horizons).every(k => count(c[k])) || c['7d'] > c['30d'] || c['30d'] > c['90d']) fail();
  return Object.fromEntries(Object.keys(horizons).map(k => [k, c[k]]));
}
function members(rows, total) {
  if (!Array.isArray(rows) || !rows.length || rows.length > 30 || new Set(rows.map(b => b.psgc_code)).size !== rows.length
    || rows.some(b => !names.has(b.psgc_code) || !count(b.report_count) || b.report_count < 1)
    || rows.reduce((n,b) => n + b.report_count, 0) !== total) fail();
  return rows.map(b => ({ psgc_code: b.psgc_code, name: names.get(b.psgc_code), report_count: b.report_count }));
}
function cluster(p) {
  if (!p || !labels.has(p.pattern) || !count(p.report_count) || p.report_count < 3 || !Number.isFinite(p.center_lat) || Math.abs(p.center_lat) > 90
    || !Number.isFinite(p.center_lng) || Math.abs(p.center_lng) > 180 || !['convex_hull','display_circle'].includes(p.geometry_method)) fail();
  return { pattern: p.pattern, report_count: p.report_count, center_lat: p.center_lat, center_lng: p.center_lng,
    geometry_method: p.geometry_method, barangays: members(p.barangays, p.report_count) };
}

// Construct an aggregate-only response; arbitrary ML fields and raw report identities never cross this boundary.
export function sanitizePatternAnalysis(raw) {
  if (raw?.schema_version !== 'historical-dbscan-v1' || !date(raw.generated_at) || !date(raw.history_start)
    || Date.parse(raw.generated_at) > Date.now() + 300000 || Date.now() - Date.parse(raw.generated_at) > DAY
    || Date.parse(raw.generated_at) - Date.parse(raw.history_start) !== 90 * DAY
    || raw.algorithm !== 'DBSCAN (haversine)' || !Number.isFinite(raw.params?.eps_meters) || raw.params.eps_meters <= 0 || raw.params.eps_meters > 1000
    || !Number.isInteger(raw.params.min_samples) || raw.params.min_samples < 3 || raw.params.min_samples > 100) fail();
  const quality = Object.fromEntries(['eligible_reports_90','included_reports_90','excluded_unreconciled_90','excluded_invalid_location_90'].map(k => [k, raw.quality?.[k]]));
  if (!Object.values(quality).every(n => Number.isInteger(n) && n >= 0) || quality.included_reports_90 > 5000
    || quality.eligible_reports_90 !== quality.included_reports_90 + quality.excluded_unreconciled_90 + quality.excluded_invalid_location_90) fail();
  if (!Array.isArray(raw.patterns) || raw.patterns.length > 1666) fail();
  const patterns = raw.patterns.map(p => {
    if (!identity(p.id) || !Array.isArray(p.period_counts) || p.period_counts.length !== 3 || !p.period_counts.every(count)
      || p.period_counts.reduce((a,b) => a+b,0) !== p.report_count || !Number.isInteger(p.active_weeks) || p.active_weeks < 1 || p.active_weeks > 14) fail();
    const observed = counts(p.observed_counts);
    if (observed['90d'] !== p.report_count || observed['30d'] !== p.period_counts[2]) fail();
    return { ...cluster(p), id: p.id, period_counts: [...p.period_counts], active_weeks: p.active_weeks, observed_counts: observed, geometry: geometry(p.geometry) };
  });
  const ids = new Set(patterns.map(p => p.id));
  if (ids.size !== patterns.length) fail();
  const windows = Object.fromEntries(Object.entries(horizons).map(([key,days]) => {
    const w = raw.windows?.[key];
    if (!w || w.lookback_days !== days || !date(w.start) || w.end !== raw.generated_at || Date.parse(w.end) - Date.parse(w.start) !== days * DAY
      || !count(w.report_count) || !count(w.noise_count) || !Array.isArray(w.geojson?.features) || w.geojson.type !== 'FeatureCollection' || w.geojson.features.length > 1666) fail();
    const features = w.geojson.features.map(f => {
      const p = f.properties;
      if (f.type !== 'Feature' || !identity(p?.cluster_id) || !Array.isArray(p.anchor_ids) || !p.anchor_ids.length || !p.anchor_ids.every(id => ids.has(id))) fail();
      return { type: 'Feature', geometry: geometry(f.geometry), properties: { ...cluster(p), cluster_id: p.cluster_id, anchor_ids: [...new Set(p.anchor_ids)] } };
    });
    if (w.cluster_count !== features.length || features.reduce((n,f) => n+f.properties.report_count,0)+w.noise_count !== w.report_count) fail();
    return [key, { lookback_days: days, start: w.start, end: w.end, report_count: w.report_count, noise_count: w.noise_count, cluster_count: features.length, geojson: { type:'FeatureCollection', features } }];
  }));
  if (windows['90d'].report_count !== quality.included_reports_90 || patterns.reduce((n,p) => n+p.report_count,0) + windows['90d'].noise_count !== quality.included_reports_90) fail();
  if (!Array.isArray(raw.barangays) || raw.barangays.length !== 30 || new Set(raw.barangays.map(b => b.psgc_code)).size !== 30) fail();
  const barangays = raw.barangays.map(b => {
    if (!names.has(b.psgc_code) || !Array.isArray(b.pattern_ids) || !b.pattern_ids.every(id => ids.has(id))) fail();
    return { psgc_code: b.psgc_code, name: names.get(b.psgc_code), observed_counts: counts(b.observed_counts), pattern_ids: [...b.pattern_ids] };
  });
  for (const key of Object.keys(horizons)) if (barangays.reduce((n,b) => n+b.observed_counts[key],0) !== windows[key].report_count) fail();
  const forecasts = Object.fromEntries(Object.entries(horizons).map(([key, days]) => {
    const f = raw.forecasts?.[key];
    const origin=weekOrigin(raw.generated_at), buckets=Math.ceil((Date.parse(raw.generated_at)+days*DAY-origin)/(7*DAY));
    if (f?.model_version !== 'zone-timeseries-v1' || f.horizon !== key || f.horizon_days !== days || !date(f.forecast_date_start) || !date(f.forecast_date_end)
      || Date.parse(f.forecast_date_start) !== Date.parse(raw.generated_at) || Date.parse(f.forecast_date_end)-Date.parse(f.forecast_date_start) !== days*DAY
      || Object.keys(f.region_analyses ?? {}).length !== 30) fail();
    const zones = Object.fromEntries(barangays.map(b => {
      const z = f.region_analyses[b.psgc_code];
      if (!z || z.zone_id !== b.psgc_code || !Array.isArray(z.historical_points) || z.historical_points.length !== 52 || !Array.isArray(z.forecast_points) || z.forecast_points.length !== buckets) fail();
      const historical = z.historical_points.map((p,i) => {
        if (!date(p.week_start) || !Number.isInteger(p.actual_count) || p.actual_count < 0 || Date.parse(p.week_start) !== origin-(52-i)*7*DAY) fail();
        return { week_start: p.week_start, actual_count: p.actual_count };
      });
      const projected = z.forecast_points.map((p,i) => {
        if (!date(p.week_start) || Date.parse(p.week_start) !== origin+i*7*DAY || ![p.predicted_count,p.lower_bound,p.upper_bound].every(Number.isFinite) || p.lower_bound < 0 || p.lower_bound > p.predicted_count || p.upper_bound < p.predicted_count) fail();
        return { week_start: p.week_start, predicted_count:p.predicted_count, lower_bound:p.lower_bound, upper_bound:p.upper_bound };
      });
      if (![z.predicted_count,z.predicted_lower_bound,z.predicted_upper_bound].every(Number.isFinite) || z.predicted_lower_bound < 0 || z.predicted_lower_bound > z.predicted_count || z.predicted_upper_bound < z.predicted_count) fail();
      return [b.psgc_code,{ historical_points:historical, forecast_points:projected, predicted_count:z.predicted_count, lower_bound:z.predicted_lower_bound, upper_bound:z.predicted_upper_bound }];
    }));
    return [key,{ horizon_days:days, start:f.forecast_date_start, end:f.forecast_date_end, barangays:zones }];
  }));
  return { schema_version:raw.schema_version, generated_at:raw.generated_at, history_start:raw.history_start,
    algorithm:raw.algorithm, params:{eps_meters:raw.params.eps_meters,min_samples:raw.params.min_samples}, quality, patterns, windows, barangays, forecasts };
}

let cached, pending;
export const clearPatternCache = () => { cached = undefined; pending = undefined; };
export async function getPatternAnalysis({ refresh = false } = {}) {
  if (pending) return pending;
  if (!refresh && cached && Date.now()-cached.time < 300000) return cached.data;
  const token = process.env.SPATIAL_ANALYTICS_TOKEN;
  if (!token) throw Object.assign(new Error('Historical analysis requires server setup'), { statusCode:503 });
  pending = (async () => {
    try {
      const response = await fetch(config.serviceUrl + '/patterns/analyze', { method:'POST', headers:{ 'Content-Type':'application/json', Authorization:'Bearer '+token }, body:'{}', signal:AbortSignal.timeout(config.timeout) });
      if (!response.ok) throw new Error('Service unavailable');
      const data = sanitizePatternAnalysis(await response.json());
      cached = { time:Date.now(), data };
      return data;
    } catch (error) {
      cached = undefined;
      if (error.statusCode === 502) throw error;
      throw Object.assign(new Error('Historical analysis unavailable; verify database and ML service setup or retry shortly'), { statusCode:503 });
    } finally { pending = undefined; }
  })();
  return pending;
}
