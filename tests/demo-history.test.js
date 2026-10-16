import { describe, expect, it } from '@jest/globals';
import { buildHistory, renderSql, parseOptions } from '../scripts/populate-demo-history.mjs';

const fixture = {
  days: 60, now: new Date('2026-10-16T08:00:00Z'),
  citizens: [{ id: '10000000-0000-0000-0000-000000000001' }],
  officer: { id: '20000000-0000-0000-0000-000000000001' },
  crews: [{ id: '30000000-0000-0000-0000-000000000001',
    member_profile_ids: ['40000000-0000-0000-0000-000000000001'] }],
  media: ['storage://Report%20Evidence/demo-history-v1/photo.jpg'],
  timing: { normal: 24, high: 12, sla: 48 },
};

describe('demo history', () => {
  it('creates linked, chronological history with a current workload and repeatable IDs', () => {
    const rows = buildHistory(fixture);
    expect(rows.reports.length).toBeGreaterThan(400);
    expect(buildHistory(fixture)).toEqual(rows);
    const tasks = new Map(rows.cleanup_tasks.map(t => [t.id, t]));
    const reports = new Map(rows.reports.map(r => [r.id, r]));
    expect(new Set(rows.reports.map(r => r.status))).toEqual(new Set(['closed', 'resolved', 'unresolved', 'in_progress']));
    expect(rows.manual_review_queue.length).toBeGreaterThan(0);
    expect(Math.min(...rows.reports.map(r => Date.parse(r.created_at)))).toBeLessThan(+fixture.now - 59 * 86400000);
    for (const r of rows.reports) {
      expect(Date.parse(r.updated_at)).toBeGreaterThanOrEqual(Date.parse(r.created_at));
      expect(Date.parse(r.updated_at)).toBeLessThanOrEqual(+fixture.now);
      expect(Date.parse(r.deadline_at)).toBe(Date.parse(r.sla_started_at) + 48 * 3600000);
      if (r.cleanup_task_id) {
        const task = tasks.get(r.cleanup_task_id);
        expect(task.report_ids).toContain(r.id);
        expect(['completed', 'cancelled']).not.toContain(task.status);
      }
    }
    for (const task of tasks.values()) {
      for (const id of task.report_ids) expect(reports.has(id)).toBe(true);
      if (task.status === 'completed') {
        expect(Date.parse(task.completed_at)).toBeGreaterThan(Date.parse(task.created_at));
        for (const id of task.report_ids) expect(reports.get(id).cleanup_task_id).toBeNull();
      }
    }
  });

  it('refuses invalid ranges and missing prerequisites before building data', () => {
    for (const days of [0, 29, 61, NaN]) expect(() => buildHistory({ ...fixture, days })).toThrow();
    for (const key of ['citizens', 'crews', 'media']) expect(() => buildHistory({ ...fixture, [key]: [] })).toThrow();
    expect(() => parseOptions(['--confrim'])).toThrow();
    expect(() => parseOptions(['--days'])).toThrow();
    expect(parseOptions([]).confirm).toBe(false);
  });

  it('renders one atomic import, prevents duplicate seeds, and preserves protected tables', () => {
    const sql = renderSql(buildHistory(fixture));
    expect(sql).toContain('BEGIN;');
    expect(sql).toContain('COMMIT;');
    expect(sql).toContain('Demo history already exists');
    expect(sql).toContain('ENABLE ALWAYS TRIGGER');
    expect(sql).toContain('jsonb_populate_recordset');
    expect(sql).not.toMatch(/DISABLE TRIGGER (ALL|USER)/);
    expect(sql).not.toMatch(/(?:INSERT INTO|UPDATE|DELETE FROM|ALTER TABLE) public\.(?:profiles|field_crews|system_settings|system_logs|strikes|optimization_settings|sweeper_configuration)\b/i);
  });
});
