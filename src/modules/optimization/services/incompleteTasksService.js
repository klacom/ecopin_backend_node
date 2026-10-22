import { supabaseAdmin as db } from '../../../config/supabase.config.js';

/** Statuses that count as "unfinished" work from a prior dispatch run. */
const INCOMPLETE_STATUSES = ['created', 'pending', 'assigned', 'en_route', 'in_progress', 'partially_completed'];

/**
 * Returns all cleanup tasks from prior dispatch plan runs that are still
 * incomplete (i.e. not yet completed or cancelled). Used to warn the
 * officer before a new optimization run and to optionally carry those
 * tasks' clusters into the new plan.
 *
 * @returns {Promise<{
 *   hasPriorIncomplete: boolean,
 *   count: number,
 *   tasks: Array<object>,
 *   cluster_ids_to_carry: string[],
 *   affected_crew_ids: string[],
 * }>}
 */
export async function getIncompletePriorTasks() {
  // Fetch incomplete tasks that originated from a dispatch plan (source_plan_id is set).
  const { data: tasks, error } = await db
    .from('cleanup_tasks')
    .select(
      'id, title, status, task_type, scheduled_date, assigned_field_crew_id, ' +
      'cluster_id, cluster_ids, report_ids, source_plan_id, created_at'
    )
    .in('status', INCOMPLETE_STATUSES)
    .not('source_plan_id', 'is', null)
    .order('created_at', { ascending: false })
    .limit(200);

  if (error) throw error;
  if (!tasks || tasks.length === 0) {
    return { hasPriorIncomplete: false, count: 0, tasks: [], cluster_ids_to_carry: [], affected_crew_ids: [] };
  }

  // Batch-fetch crew names.
  const crewIds = [...new Set(tasks.map(t => t.assigned_field_crew_id).filter(Boolean))];
  const crewMap = new Map();
  if (crewIds.length > 0) {
    const { data: crews } = await db.from('field_crews').select('id, name').in('id', crewIds);
    (crews ?? []).forEach(c => crewMap.set(c.id, c.name));
  }

  // Batch-fetch plan metadata (planned_date, mode, created_at).
  const planIds = [...new Set(tasks.map(t => t.source_plan_id).filter(Boolean))];
  const planMap = new Map();
  if (planIds.length > 0) {
    const { data: plans } = await db
      .from('dispatch_plans')
      .select('id, planned_date, mode, created_at')
      .in('id', planIds);
    (plans ?? []).forEach(p => planMap.set(p.id, p));
  }

  // Build structured task list.
  const enriched = tasks.map(t => {
    const plan = planMap.get(t.source_plan_id) ?? {};
    const clusterIds = [
      ...(t.cluster_id ? [t.cluster_id] : []),
      ...((Array.isArray(t.cluster_ids) ? t.cluster_ids : [])),
    ];
    return {
      id: t.id,
      title: t.title || (t.task_type === 'sweeper' ? 'Sweeper Task' : 'Cluster Cleanup'),
      status: t.status,
      task_type: t.task_type || 'Cleanup',
      crew_name: crewMap.get(t.assigned_field_crew_id) || null,
      crew_id: t.assigned_field_crew_id || null,
      cluster_ids: [...new Set(clusterIds)],
      report_ids: Array.isArray(t.report_ids) ? t.report_ids : [],
      source_plan_id: t.source_plan_id,
      plan_planned_date: plan.planned_date ?? null,
      plan_mode: plan.mode ?? null,
      plan_created_at: plan.created_at ?? null,
      scheduled_date: t.scheduled_date ?? null,
    };
  });

  // Aggregate helper lists for frontend "carry over" feature.
  const clusterIdsToCarry = [
    ...new Set(enriched.flatMap(t => t.cluster_ids)),
  ];
  const affectedCrewIds = [...new Set(enriched.map(t => t.crew_id).filter(Boolean))];

  return {
    hasPriorIncomplete: true,
    count: enriched.length,
    tasks: enriched,
    cluster_ids_to_carry: clusterIdsToCarry,
    affected_crew_ids: affectedCrewIds,
  };
}
