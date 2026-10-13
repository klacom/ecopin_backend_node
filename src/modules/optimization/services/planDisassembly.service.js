import { supabaseAdmin as db } from '../../../config/supabase.config.js';

/**
 * Preview disassembly of a dispatch plan or optimization run.
 * Gathers tasks to be deleted, reports to be reset to the backlog, and clusters to be restored.
 *
 * @param {string} targetId - dispatch_plan ID or optimization_run ID
 * @returns {Promise<object>}
 */
export async function previewPlanDisassembly(targetId) {
  if (!targetId) throw new Error('Target plan or run ID is required');

  // 1. Locate dispatch_plan
  let { data: plan } = await db
    .from('dispatch_plans')
    .select('id, status, optimization_run_id, created_at')
    .or(`id.eq.${targetId},optimization_run_id.eq.${targetId}`)
    .maybeSingle();

  // 2. Locate optimization_run
  let runId = plan?.optimization_run_id || targetId;
  let { data: run } = await db
    .from('optimization_runs')
    .select('id, status, created_at, num_tasks_optimized')
    .or(`id.eq.${runId},id.eq.${targetId}`)
    .maybeSingle();

  if (!plan && !run) {
    const error = new Error('Plan or optimization run not found');
    error.status = 404;
    throw error;
  }

  // 3. Locate cleanup tasks created for this plan/run
  let tasks = [];
  if (plan?.id) {
    const { data: planTasks } = await db
      .from('cleanup_tasks')
      .select('id, title, task_type, status, assigned_field_crew_id, cluster_id, cluster_ids, report_ids, created_at')
      .eq('source_plan_id', plan.id);
    if (planTasks?.length) tasks = planTasks;
  }

  if (run?.id && tasks.length === 0) {
    const { data: routeList } = await db
      .from('crew_routes')
      .select('id')
      .eq('optimization_run_id', run.id);
    const routeIds = (routeList || []).map(r => r.id);
    if (routeIds.length > 0) {
      const { data: routeTasks } = await db
        .from('cleanup_tasks')
        .select('id, title, task_type, status, assigned_field_crew_id, cluster_id, cluster_ids, report_ids, created_at')
        .in('crew_route_id', routeIds);
      if (routeTasks?.length) tasks = routeTasks;
    }
  }

  // 4. Fetch field crew names
  const crewIds = [...new Set(tasks.map(t => t.assigned_field_crew_id).filter(Boolean))];
  const crewMap = new Map();
  if (crewIds.length > 0) {
    const { data: crews } = await db
      .from('field_crews')
      .select('id, name')
      .in('id', crewIds);
    (crews || []).forEach(c => crewMap.set(c.id, c.name));
  }

  // 5. Check if any tasks are already completed
  const completedTasks = tasks.filter(t => t.status === 'completed');
  const inProgressTasks = tasks.filter(t => t.status === 'in_progress');
  const taskIds = tasks.map(t => t.id);

  // 6. Gather affected reports
  let affectedReportIds = new Set();
  tasks.forEach(t => {
    (t.report_ids || []).forEach(rId => affectedReportIds.add(rId));
  });

  if (taskIds.length > 0) {
    const { data: linkedReports } = await db
      .from('reports')
      .select('id')
      .in('cleanup_task_id', taskIds);
    (linkedReports || []).forEach(r => affectedReportIds.add(r.id));
  }

  // 7. Gather affected clusters
  let affectedClusterIds = new Set();
  tasks.forEach(t => {
    if (t.cluster_id) affectedClusterIds.add(t.cluster_id);
    (t.cluster_ids || []).forEach(cId => affectedClusterIds.add(cId));
  });

  const canDisassemble = completedTasks.length === 0;
  const blockingReason = completedTasks.length > 0
    ? `Cannot disassemble plan: ${completedTasks.length} task(s) have already been completed by field crews.`
    : null;

  return {
    can_disassemble: canDisassemble,
    blocking_reason: blockingReason,
    is_committed: tasks.length > 0,
    plan_id: plan?.id || null,
    run_id: run?.id || null,
    plan_status: plan?.status || null,
    run_status: run?.status || null,
    tasks_count: tasks.length,
    completed_tasks_count: completedTasks.length,
    in_progress_tasks_count: inProgressTasks.length,
    tasks: tasks.map(t => ({
      id: t.id,
      title: t.title || (t.task_type === 'sweeper' ? 'Sweeper Task' : 'Cluster Cleanup'),
      task_type: t.task_type,
      status: t.status,
      crew_name: crewMap.get(t.assigned_field_crew_id) || 'Unassigned Crew',
      reports_count: (t.report_ids || []).length || 1
    })),
    reports_count: affectedReportIds.size,
    clusters_count: affectedClusterIds.size
  };
}

/**
 * Disassemble a dispatch plan or optimization run:
 * - Unassigns and restores all linked reports to the backlog ('unresolved')
 * - Resets clusters back to 'queued' or 'prioritized'
 * - Cleans up route waypoints, task events, and deletes created cleanup tasks
 * - Cancels crew routes and marks the plan/run as 'discarded'
 *
 * @param {string} targetId - dispatch_plan ID or optimization_run ID
 * @param {string} actorId - ID of officer initiating disassembly
 * @returns {Promise<object>}
 */
export async function disassemblePlan(targetId, actorId) {
  if (!targetId) throw new Error('Target plan or run ID is required');

  // 1. Locate dispatch_plan
  let { data: plan } = await db
    .from('dispatch_plans')
    .select('id, status, optimization_run_id')
    .or(`id.eq.${targetId},optimization_run_id.eq.${targetId}`)
    .maybeSingle();

  // 2. Locate optimization_run
  let runId = plan?.optimization_run_id || targetId;
  let { data: run } = await db
    .from('optimization_runs')
    .select('id, status')
    .or(`id.eq.${runId},id.eq.${targetId}`)
    .maybeSingle();

  if (!plan && !run) {
    const error = new Error('Plan or optimization run not found');
    error.status = 404;
    throw error;
  }

  // 3. Locate all cleanup_tasks linked to this plan or run
  let tasks = [];
  if (plan?.id) {
    const { data: planTasks } = await db
      .from('cleanup_tasks')
      .select('id, status, cluster_id, cluster_ids, report_ids')
      .eq('source_plan_id', plan.id);
    if (planTasks?.length) tasks = planTasks;
  }

  if (run?.id && tasks.length === 0) {
    const { data: routeList } = await db
      .from('crew_routes')
      .select('id')
      .eq('optimization_run_id', run.id);
    const routeIds = (routeList || []).map(r => r.id);
    if (routeIds.length > 0) {
      const { data: routeTasks } = await db
        .from('cleanup_tasks')
        .select('id, status, cluster_id, cluster_ids, report_ids')
        .in('crew_route_id', routeIds);
      if (routeTasks?.length) tasks = routeTasks;
    }
  }

  const taskIds = tasks.map(t => t.id);

  // 4. Guard against disassembling completed tasks
  const completedTasks = tasks.filter(t => t.status === 'completed');
  if (completedTasks.length > 0) {
    const error = new Error(`Cannot disassemble plan: ${completedTasks.length} cleanup task(s) have already been completed by field crews.`);
    error.status = 400;
    throw error;
  }

  let reportsResetCount = 0;
  let clustersResetCount = 0;
  let tasksUndoneCount = taskIds.length;

  if (taskIds.length > 0) {
    // 5. Cancel cleanup tasks first with failure_class = 'transient'.
    // The database trigger workflow_report_claim_guard blocks clearing reports.cleanup_task_id
    // unless the task is in ('completed', 'cancelled'). Setting status='cancelled' and
    // failure_class='transient' allows report release without creating access blocks.
    const { error: cancelError } = await db
      .from('cleanup_tasks')
      .update({
        status: 'cancelled',
        failure_class: 'transient',
        failure_reason: 'Disassembled by officer'
      })
      .in('id', taskIds);

    if (cancelError) throw cancelError;

    // 6. Gather and explicitly reset reports back to unassigned backlog
    let affectedReportIds = new Set();
    tasks.forEach(t => {
      (t.report_ids || []).forEach(rId => affectedReportIds.add(rId));
    });

    const { data: linkedReports } = await db
      .from('reports')
      .select('id')
      .in('cleanup_task_id', taskIds);
    (linkedReports || []).forEach(r => affectedReportIds.add(r.id));

    const reportIdList = [...affectedReportIds];

    if (reportIdList.length > 0) {
      const { data: updatedReports, error: reportError } = await db
        .from('reports')
        .update({
          cleanup_task_id: null,
          status: 'unresolved',
          updated_at: new Date().toISOString()
        })
        .in('id', reportIdList)
        .select('id');

      if (reportError) throw reportError;
      reportsResetCount = updatedReports?.length || reportIdList.length;
    }

    // 7. Disconnect dispatch_plan_items
    if (plan?.id) {
      await db
        .from('dispatch_plan_items')
        .update({ committed_task_id: null, commit_disposition: 'omitted' })
        .eq('dispatch_plan_id', plan.id);
    } else {
      await db
        .from('dispatch_plan_items')
        .update({ committed_task_id: null, commit_disposition: 'omitted' })
        .in('committed_task_id', taskIds);
    }

    // 8. Delete cascading task-dependent event and block records
    await db.from('route_waypoints').delete().in('cleanup_task_id', taskIds);
    await db.from('dispatch_access_blocks').delete().in('task_id', taskIds);
    await db.from('field_task_failure_events').delete().in('task_id', taskIds);
    await db.from('field_load_events').delete().in('task_id', taskIds);
    await db.from('field_assignment_receipts').delete().in('task_id', taskIds);
    await db.from('report_resolution_events').delete().in('task_id', taskIds);
    await db.from('task_report_outcomes').delete().in('task_id', taskIds);

    // 9. Gather cluster IDs and restore them to queued / prioritized
    let affectedClusterIds = new Set();
    tasks.forEach(t => {
      if (t.cluster_id) affectedClusterIds.add(t.cluster_id);
      (t.cluster_ids || []).forEach(cId => affectedClusterIds.add(cId));
    });
    const clusterIdList = [...affectedClusterIds];

    if (clusterIdList.length > 0) {
      const { data: clustersToReset } = await db
        .from('clusters')
        .select('id, priority_score, status')
        .in('id', clusterIdList)
        .in('status', ['scheduled', 'in_progress']);

      if (clustersToReset?.length) {
        for (const cluster of clustersToReset) {
          const newStatus = (Number(cluster.priority_score) > 0) ? 'prioritized' : 'queued';
          await db
            .from('clusters')
            .update({ status: newStatus, updated_at: new Date().toISOString() })
            .eq('id', cluster.id);
        }
        clustersResetCount = clustersToReset.length;
      }
    }

    // 10. Delete the cleanup tasks
    const { error: deleteTaskError } = await db
      .from('cleanup_tasks')
      .delete()
      .in('id', taskIds);

    if (deleteTaskError) throw deleteTaskError;
  }

  // 11. Clean up crew_routes & route_waypoints for the run
  if (run?.id) {
    const { data: routes } = await db
      .from('crew_routes')
      .select('id')
      .eq('optimization_run_id', run.id);
    const routeIds = (routes || []).map(r => r.id);

    if (routeIds.length > 0) {
      await db.from('route_waypoints').delete().in('crew_route_id', routeIds);
      await db.from('crew_routes').delete().eq('optimization_run_id', run.id);
    }

    await db
      .from('optimization_runs')
      .update({ status: 'discarded' })
      .eq('id', run.id);
  }

  // 12. Mark dispatch plan as discarded
  if (plan?.id) {
    await db
      .from('dispatch_plans')
      .update({ status: 'discarded' })
      .eq('id', plan.id);
  }

  return {
    success: true,
    plan_id: plan?.id || null,
    run_id: run?.id || null,
    tasks_undone: tasksUndoneCount,
    reports_reset: reportsResetCount,
    clusters_reset: clustersResetCount,
    message: tasksUndoneCount > 0
      ? `Plan disassembled successfully: ${tasksUndoneCount} tasks undone, ${reportsResetCount} reports released, ${clustersResetCount} clusters restored to backlog.`
      : 'Plan discarded successfully.'
  };
}
