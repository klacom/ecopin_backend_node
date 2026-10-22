import { jest } from '@jest/globals';
import express from 'express';
import { once } from 'node:events';

const profile = { role: 'officer' };
jest.unstable_mockModule('../src/config/supabase.config.js', () => ({
  supabase: { auth: { getUser: async () => ({ data: { user: { id: 'staff' } } }) } },
  supabaseAdmin: { from: () => ({ select: () => ({ eq: () => ({ single: async () => ({ data: profile }) }) }) }) },
}));
jest.unstable_mockModule('../src/middleware/strike.middleware.js', () => ({ checkSuspension: jest.fn(), expireOldStrikes: jest.fn() }));
jest.unstable_mockModule('../src/services/auth-cache.service.js', () => ({ getCachedUser: () => null, setCachedUser: jest.fn() }));
const getCurrentPredictions = jest.fn(async horizon => {
  if (!['7d', '30d', '90d', 'weekly'].includes(horizon)) throw Object.assign(new Error('Invalid horizon'), { statusCode: 400 });
  return { horizon, total_regions: 1 };
});
const getZoneTrend = jest.fn(async (zoneId, horizon) => ({ zone_id: zoneId, horizon, historical_points: [], forecast_points: [] }));
const getAvailableDates = jest.fn(async () => ['2026-10-18']);
jest.unstable_mockModule('../src/modules/spatial_forecast/services/spatialClient.service.js', () => ({
  generateForecast: jest.fn(), getPredictions: jest.fn(async () => []), getCurrentPredictions,
  getAccuracyMetrics: jest.fn(), getAvailableDates, getZoneTrend,
}));
const { default: routes } = await import('../src/modules/spatial_forecast/routes/spatial.routes.js');
let server, origin;
beforeAll(async () => {
  const app = express(); app.use(express.json());
  app.use('/api/spatial', routes); app.use('/api/spatial-forecast', routes);
  app.use((error, req, res, next) => res.status(error.statusCode ?? 500).json({ error: error.message }));
  server = app.listen(0, '127.0.0.1'); await once(server, 'listening');
  origin = 'http://127.0.0.1:' + server.address().port;
});
afterAll(() => new Promise(resolve => server.close(resolve)));
beforeEach(() => { profile.role = 'officer'; jest.clearAllMocks(); });
const request = (path, authenticated = true) => fetch(origin + path, { headers: authenticated ? { authorization: 'Bearer test-staff' } : {} });

test.each(['/api/spatial/forecast/current?horizon=30d', '/api/spatial/predictions/current?horizon=7d', '/api/spatial-forecast/current/weekly'])('current route accepts canonical and retained legacy path: %s', async path => {
  const response = await request(path);
  expect(response.status).toBe(200);
  expect((await response.json()).count).toBe(1);
});
test('query horizon reaches the service and invalid horizons return 400', async () => {
  const response = await request('/api/spatial/forecast/current?horizon=invalid');
  expect(response.status).toBe(400);
  expect(getCurrentPredictions).toHaveBeenCalledWith('invalid');
});
test.each(['trend', 'history'])('zone %s endpoint exposes historical and projected series', async suffix => {
  const response = await request('/api/spatial/zones/h3-test/' + suffix + '?horizon=90d');
  expect(response.status).toBe(200);
  expect((await response.json()).data).toMatchObject({ zone_id: 'h3-test', horizon: '90d', historical_points: [], forecast_points: [] });
});
test.each(['/api/spatial/forecast/current?horizon=30d', '/api/spatial/predictions/current?horizon=30d', '/api/spatial/zones/h3-test/trend', '/api/spatial/zones/h3-test/history'])('staff-only route rejects missing authentication and citizens: %s', async path => {
  expect((await request(path, false)).status).toBe(401);
  profile.role = 'citizen';
  expect((await request(path)).status).toBe(403);
  expect(getCurrentPredictions).not.toHaveBeenCalled(); expect(getZoneTrend).not.toHaveBeenCalled();
});
test('admins can read the new route', async () => {
  profile.role = 'admin'; expect((await request('/api/spatial/forecast/current?horizon=30d')).status).toBe(200);
});
test('available dates passes the requested horizon through the authenticated handler', async () => {
  const response = await request('/api/spatial/available-dates?horizon=7d');
  expect(response.status).toBe(200); expect(getAvailableDates).toHaveBeenCalledWith('7d');
});
