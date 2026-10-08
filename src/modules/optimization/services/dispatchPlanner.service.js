import { supabaseAdmin as supabase } from '../../../config/supabase.config.js';
import { prioritizeBacklog } from './workQueue.service.js';
import { resolvePlanSettings, selectPlanItems, reportPriority } from './planningPolicy.js';

async function rows(query) {
  const { data, error } = await query;
  if (error) throw error;
  return data ?? [];
}

export async function generateDispatchPlan(userId, input = {}) {
  const settings = resolvePlanSettings(input);
  await prioritizeBacklog();
  const [crews, activeTasks, workTimes, weightsRows, blocks] = await Promise.all([
    rows(supabase.from('field_crews').select('*').eq('availability_status', 'available')),
    rows(supabase.from('cleanup_tasks').select('assigned_field_crew_id, assigned_crew_ids, status, estimated_duration_min').not('status', 'in', '(completed,cancelled)')),
    rows(supabase.from('work_time_configuration').select('report_type, work_time_minutes')),
    rows(supabase.from('optimization_settings').select('value').eq('key', 'mcda_weights')),
    rows(supabase.from('dispatch_access_blocks').select('cluster_id, report_id').is('cleared_at', null))
  ]);
  const blockedClusters = new Set(blocks.map(block => block.cluster_id).filter(Boolean));
  const blockedReports = new Set(blocks.map(block => block.report_id).filter(Boolean));
  let candidates;
  if (settings.mode === 'standard') {
    const clusters = await rows(supabase.from('clusters')
      .select('id, estimated_effort_minutes, priority_score, recommended_task_type, reports(id, status, cleanup_task_id)')
      .in('status', ['new', 'unresolved', 'prioritized', 'queued', 'monitoring']).order('priority_score', { ascending: false }).limit(200));
    candidates = clusters.filter(cluster => !blockedClusters.has(cluster.id) && !(cluster.reports ?? []).some(report => report.cleanup_task_id && !['resolved','completed','closed','rejected'].includes(report.status)))
      .filter(cluster => !settings.cluster_ids || settings.cluster_ids.includes(cluster.id))
      .filter(cluster => !settings.included_task_types?.length || settings.included_task_types.includes(cluster.recommended_task_type))
      .map(cluster => ({
        item_type: 'cluster', cluster_id: cluster.id, report_id: null, group_key: 'cluster:' + cluster.id,
        report_ids: (cluster.reports ?? []).filter(report => !['resolved', 'completed', 'closed', 'rejected'].includes(report.status)).map(report => report.id),
        service_minutes: Math.max(1, cluster.estimated_effort_minutes ?? 60), priority_score: cluster.priority_score ?? 0
      })).filter(candidate => candidate.report_ids.length && !candidate.report_ids.some(id => blockedReports.has(id)));
  } else {
    const reports = await rows(supabase.from('reports')
      .select('id, issue_type, severity_score, urgency_score, sla_started_at, created_at, lifecycle_state')
      .in('lifecycle_state', ['maturing', 'sla_breached']).is('cluster_id', null).is('cleanup_task_id', null)
      .eq('status', 'unresolved').order('deadline_at', { ascending: true }).limit(200));
    const serviceTimes = new Map(workTimes.map(row => [row.report_type, row.work_time_minutes]));
    candidates = reports.filter(report => !blockedReports.has(report.id) && (!settings.report_ids || settings.report_ids.includes(report.id))).map(report => ({
      lifecycle_state: report.lifecycle_state, item_type: 'report', cluster_id: null, report_id: report.id, group_key: 'report:' + report.id,
      report_ids: [report.id], service_minutes: serviceTimes.get(report.issue_type) ?? 30,
      priority_score: reportPriority(report, weightsRows[0]?.value)
    }));
  }
  const selected = selectPlanItems(candidates, crews, activeTasks, settings);
  const { data: plan, error } = await supabase.rpc('save_dispatch_plan', {
    actor: userId, plan_mode: settings.mode, settings, items: selected.items,
    available_crews: crews.length, capacity_minutes: selected.totalCapacityMinutes
  });
  if (error) throw error;
  return { plan, selectedCount: selected.items.filter(item => item.is_selected).length,
    omittedLoggedCount: selected.items.filter(item => !item.is_selected).length,
    capacityUtilized: selected.capacityUtilized,
    unassigned: selected.items.filter(item => !item.is_selected).map(item => ({ group_key: item.group_key, reason: item.reason })) };
}
