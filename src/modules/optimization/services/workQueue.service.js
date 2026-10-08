import { supabaseAdmin as supabase } from '../../../config/supabase.config.js';
import { calculateClusterPriorities } from './mcdaPrioritizer.service.js';

export async function prioritizeBacklog(weatherCondition = 'normal') {
  // 1. Fetch MCDA weights
  const { data: weightsData, error: weightsError } = await supabase.from('optimization_settings').select('value').eq('key', 'mcda_weights').single();
  if (weightsError && weightsError.code !== 'PGRST116') throw weightsError;
  const weights = weightsData?.value || { severity: 0.40, urgency: 0.25, report_count: 0.15, waiting_time: 0.15, weather: 0.05 };

  // 2. Fetch all clusters that need prioritization (new, monitoring, deferred)
  const { data: clustersToPrioritize, error: queueError } = await supabase
    .from('clusters')
    .select('id')
    .in('status', ['new', 'monitoring', 'unresolved']);

  if (queueError) throw queueError;
  if (!clustersToPrioritize || clustersToPrioritize.length === 0) {
    return [];
  }

  // 3. Calculate new priorities
  const clusterIds = clustersToPrioritize.map(c => c.id);
  const prioritized = await calculateClusterPriorities(clusterIds, weatherCondition, weights);

  // 4. Update the database with new scores and status
  const updatedClusters = [];
  for (const p of prioritized) {
    const { data: updated, error: updateError } = await supabase
      .from('clusters')
      .update({
        priority: p.priority,
        priority_score: p.priority_score,
        status: 'prioritized' // Move to prioritized status in the backlog
      })
      .eq('id', p.id)
      .in('status', ['new', 'monitoring', 'unresolved'])
      .select()
      .single();
      
    if (updateError && updateError.code !== 'PGRST116') throw updateError;
    if (updated) updatedClusters.push(updated);
  }

  return updatedClusters;
}

export async function getWorkQueue(limit = 100, targetOutliersOnly = false) {
  const boundedLimit=Math.max(1,Math.min(200,Number.isFinite(limit)?limit:100));
  const query=targetOutliersOnly ? supabase.from('reports').select('id,issue_type,status,severity_score,deadline_at,lifecycle_state')
    .is('cluster_id',null).is('cleanup_task_id',null).in('lifecycle_state',['maturing','sla_breached']).eq('status','unresolved').order('deadline_at').limit(boundedLimit)
    : supabase.from('clusters').select('id,issue_type,center,status,priority,priority_score,report_count,estimated_effort_minutes,recommended_task_type,created_at')
    .in('status',['prioritized','queued','monitoring']).order('priority_score',{ascending:false}).limit(boundedLimit);
  const {data,error}=await query;if(error) throw error;return data??[];
}
