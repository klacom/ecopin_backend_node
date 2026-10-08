import { jest } from '@jest/globals';
const queries = [];
const answers = [];
const supabaseAdmin = { from: jest.fn(table => {
  const query = { table, filters: [] };
  queries.push(query);
  const builder = {
    select: jest.fn(value => { query.select = value; return builder; }),
    eq: jest.fn((key, value) => { query.filters.push([key, value]); return builder; }),
    in: jest.fn((key,value)=>{query.filters.push([key,value]);return builder;}),
    gte: jest.fn(() => builder), lte: jest.fn(() => builder),
    then: (resolve, reject) => Promise.resolve(answers.shift()).then(resolve, reject)
  };
  return builder;
}) };
jest.unstable_mockModule('../src/config/supabase.config.js', () => ({ supabaseAdmin }));
const { sweeperAnalyticsService } = await import('../src/modules/sweeper/services/sweeper-analytics.service.js');
afterEach(() => { queries.length = 0; answers.length = 0; delete process.env.REPORT_LIFECYCLE_ENABLED; });

test('closed reports retain their breach in compliance and queries use live task columns', async () => {
  process.env.REPORT_LIFECYCLE_ENABLED = 'true';
  answers.push(
    { data: [{ id: 'closed', is_outlier: false, breached_at: '2026-10-01T00:00:00Z' }, { id: 'fresh', breached_at: null }] },
    { data: [] }, { data: [] },
    { data: [{ id: 'task', status: 'completed', estimated_duration_min: 30, cluster_ids: ['c1'] }] }
  );
  const metrics = await sweeperAnalyticsService.getMetrics('2026-10-01', '2026-10-08');
  expect(metrics.slaCompliance).toEqual({ rate: 50, totalReports: 2, breachedReports: 1 });
  expect(queries[1].filters).toContainEqual(['lifecycle_state', 'sla_breached']);
  expect(queries[3].select).toBe('id, status, estimated_duration_min, cluster_ids, report_ids');
  expect(queries[3].filters).toContainEqual(['dispatch_kind','sweeper']);
  expect(metrics.sweeperTasks.averageClustersPerTask).toBe(1);
});

test('database errors are not rendered as 100% compliance', async () => {
  answers.push({ data: null, error: new Error('database unavailable') });
  await expect(sweeperAnalyticsService.getMetrics()).rejects.toThrow('database unavailable');
});
