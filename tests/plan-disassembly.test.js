import { jest } from '@jest/globals';

const mockDb = {
  from: jest.fn()
};

jest.unstable_mockModule('../src/config/supabase.config.js', () => ({
  supabaseAdmin: mockDb
}));

const { previewPlanDisassembly, disassemblePlan } = await import(
  '../src/modules/optimization/services/planDisassembly.service.js'
);

describe('planDisassembly service', () => {
  beforeEach(() => {
    jest.clearAllMocks();
  });

  test('preview uncommitted draft plan returns is_committed=false and can_disassemble=true', async () => {
    mockDb.from.mockImplementation((table) => {
      if (table === 'dispatch_plans') {
        return {
          select: () => ({
            or: () => ({
              maybeSingle: async () => ({
                data: { id: 'plan-1', status: 'draft', optimization_run_id: null },
                error: null
              })
            })
          })
        };
      }
      if (table === 'optimization_runs') {
        return {
          select: () => ({
            or: () => ({
              maybeSingle: async () => ({ data: null, error: null })
            })
          })
        };
      }
      if (table === 'cleanup_tasks') {
        return {
          select: () => ({
            eq: async () => ({ data: [], error: null })
          })
        };
      }
      throw new Error(`Unexpected table ${table}`);
    });

    const preview = await previewPlanDisassembly('plan-1');
    expect(preview.can_disassemble).toBe(true);
    expect(preview.is_committed).toBe(false);
    expect(preview.tasks_count).toBe(0);
    expect(preview.reports_count).toBe(0);
    expect(preview.clusters_count).toBe(0);
  });

  test('preview committed plan detects completed tasks and flags blocking_reason', async () => {
    mockDb.from.mockImplementation((table) => {
      if (table === 'dispatch_plans') {
        return {
          select: () => ({
            or: () => ({
              maybeSingle: async () => ({
                data: { id: 'plan-2', status: 'published', optimization_run_id: 'run-2' },
                error: null
              })
            })
          })
        };
      }
      if (table === 'optimization_runs') {
        return {
          select: () => ({
            or: () => ({
              maybeSingle: async () => ({
                data: { id: 'run-2', status: 'approved' },
                error: null
              })
            })
          })
        };
      }
      if (table === 'cleanup_tasks') {
        return {
          select: () => ({
            eq: async () => ({
              data: [
                { id: 'task-1', task_type: 'standard', status: 'completed', assigned_field_crew_id: 'crew-1', cluster_id: 'c-1', report_ids: ['r-1'] },
                { id: 'task-2', task_type: 'sweeper', status: 'assigned', assigned_field_crew_id: 'crew-2', cluster_id: null, report_ids: ['r-2'] }
              ],
              error: null
            })
          })
        };
      }
      if (table === 'field_crews') {
        return {
          select: () => ({
            in: async () => ({
              data: [
                { id: 'crew-1', name: 'Crew Alpha' },
                { id: 'crew-2', name: 'Crew Bravo' }
              ],
              error: null
            })
          })
        };
      }
      if (table === 'reports') {
        return {
          select: () => ({
            in: async () => ({ data: [{ id: 'r-1' }, { id: 'r-2' }], error: null })
          })
        };
      }
      throw new Error(`Unexpected table ${table}`);
    });

    const preview = await previewPlanDisassembly('plan-2');
    expect(preview.can_disassemble).toBe(false);
    expect(preview.blocking_reason).toContain('1 task(s) have already been completed');
    expect(preview.tasks_count).toBe(2);
    expect(preview.completed_tasks_count).toBe(1);
  });

  test('disassemblePlan throws error if any task has already been completed', async () => {
    mockDb.from.mockImplementation((table) => {
      if (table === 'dispatch_plans') {
        return {
          select: () => ({
            or: () => ({
              maybeSingle: async () => ({
                data: { id: 'plan-3', status: 'published', optimization_run_id: null },
                error: null
              })
            })
          })
        };
      }
      if (table === 'optimization_runs') {
        return {
          select: () => ({
            or: () => ({
              maybeSingle: async () => ({ data: null, error: null })
            })
          })
        };
      }
      if (table === 'cleanup_tasks') {
        return {
          select: () => ({
            eq: async () => ({
              data: [
                { id: 't-1', status: 'completed', cluster_id: 'c-1', report_ids: ['r-1'] }
              ],
              error: null
            })
          })
        };
      }
      throw new Error(`Unexpected table ${table}`);
    });

    await expect(disassemblePlan('plan-3', 'officer-1')).rejects.toThrow(
      'Cannot disassemble plan: 1 cleanup task(s) have already been completed'
    );
  });

  test('disassemblePlan resets reports, clusters, deletes tasks, and discards plan and run', async () => {
    const reportUpdates = [];
    const clusterUpdates = [];
    const deletedTasks = [];
    const taskUpdates = [];

    mockDb.from.mockImplementation((table) => {
      if (table === 'dispatch_plans') {
        return {
          select: () => ({
            or: () => ({
              maybeSingle: async () => ({
                data: { id: 'plan-4', status: 'published', optimization_run_id: 'run-4' },
                error: null
              })
            })
          }),
          update: (val) => ({ eq: async () => ({ data: val, error: null }) })
        };
      }
      if (table === 'optimization_runs') {
        return {
          select: () => ({
            or: () => ({
              maybeSingle: async () => ({
                data: { id: 'run-4', status: 'approved' },
                error: null
              })
            })
          }),
          update: (val) => ({ eq: async () => ({ data: val, error: null }) })
        };
      }
      if (table === 'cleanup_tasks') {
        return {
          select: () => ({
            eq: async () => ({
              data: [
                { id: 'task-a', status: 'assigned', cluster_id: 'c-1', cluster_ids: [], report_ids: ['r-1'] },
                { id: 'task-b', status: 'assigned', cluster_id: null, cluster_ids: [], report_ids: ['r-2'] }
              ],
              error: null
            })
          }),
          update: (payload) => ({
            in: async (col, ids) => {
              taskUpdates.push({ payload, ids });
              return { data: null, error: null };
            }
          }),
          delete: () => ({
            in: async (col, ids) => {
              deletedTasks.push(...ids);
              return { data: null, error: null };
            }
          })
        };
      }
      if (table === 'reports') {
        return {
          select: () => ({
            in: async () => ({ data: [{ id: 'r-1' }, { id: 'r-2' }], error: null })
          }),
          update: (payload) => ({
            in: (col, ids) => ({
              select: async () => {
                reportUpdates.push({ payload, ids });
                return { data: ids.map(id => ({ id })), error: null };
              }
            })
          })
        };
      }
      if (table === 'dispatch_plan_items') {
        return {
          update: () => ({ eq: async () => ({ data: null, error: null }) })
        };
      }
      if (table === 'route_waypoints') {
        return {
          delete: () => ({ in: async () => ({ data: null, error: null }) })
        };
      }
      if (table === 'crew_routes') {
        return {
          select: () => ({ eq: async () => ({ data: [{ id: 'cr-1' }], error: null }) }),
          delete: () => ({ eq: async () => ({ data: null, error: null }) })
        };
      }
      if (['dispatch_access_blocks', 'field_task_failure_events', 'field_load_events', 'field_assignment_receipts', 'report_resolution_events', 'task_report_outcomes'].includes(table)) {
        return {
          delete: () => ({ in: async () => ({ data: null, error: null }) })
        };
      }
      if (table === 'clusters') {
        return {
          select: () => ({
            in: () => ({
              in: async () => ({
                data: [{ id: 'c-1', priority_score: 50, status: 'scheduled' }],
                error: null
              })
            })
          }),
          update: (payload) => ({
            eq: async (col, id) => {
              clusterUpdates.push({ payload, id });
              return { data: null, error: null };
            }
          })
        };
      }
      throw new Error(`Unexpected table ${table}`);
    });

    const result = await disassemblePlan('plan-4', 'officer-1');
    expect(result.success).toBe(true);
    expect(result.tasks_undone).toBe(2);
    expect(result.reports_reset).toBe(2);
    expect(result.clusters_reset).toBe(1);
    expect(taskUpdates[0].payload.status).toBe('cancelled');
    expect(taskUpdates[0].payload.failure_class).toBe('transient');
    expect(deletedTasks).toEqual(['task-a', 'task-b']);
    expect(clusterUpdates[0].payload.status).toBe('prioritized');
    expect(reportUpdates[0].payload.status).toBe('unresolved');
    expect(reportUpdates[0].payload.cleanup_task_id).toBeNull();
  });
});
