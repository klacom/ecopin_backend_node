import { supabaseAdmin as supabase } from '../../../config/supabase.config.js';

/**
 * Handle a field crew completing a task and automatically update the corresponding clusters.
 * 
 * @param {string} taskId 
 * @param {string} outcome - The field completion result (e.g. 'completed', 'partially_completed', 'escalated')
 * @param {string} notes - Free text notes/feedback from the field crew
 * @param {string} userId - ID of the user submitting the feedback
 */
export async function processTaskFeedback(taskId, outcome, notes, userId) {
  // 1. Map outcomes to valid task statuses
  const taskStatusMap = {
    'completed': 'completed',
    'cleanup_completed': 'completed',
    'report_incorrect': 'completed',
    'issue_not_found': 'completed',
    
    'partially_completed': 'partially_completed',
    
    'unable_to_complete': 'unable_to_complete',
    
    'issue_still_exists': 'requires_follow_up',
    'requires_follow_up': 'requires_follow_up',
    'needs_another_inspection': 'requires_follow_up',
    
    'escalated': 'escalated',
    'requires_institutional_action': 'escalated'
  };

  const finalStatus = taskStatusMap[outcome] || 'completed';

  // 2. Update the task
  const { data: task, error: taskError } = await supabase
    .from('cleanup_tasks')
    .update({
      status: finalStatus,
      completion_result: outcome,
      completion_notes: notes,
      completed_at: new Date().toISOString()
    })
    .eq('id', taskId)
    .select('*')
    .single();

  if (taskError) throw taskError;

  // 3. Fetch associated clusters directly from the array we added in Phase 4
  const clusterIds = task.cluster_ids || (task.cluster_id ? [task.cluster_id] : []);
  if (clusterIds.length === 0) return task;

  // 4. Determine state machine action for clusters based on the field outcome
  let clusterUpdate = {};
  
  switch (outcome) {
    case 'completed':
    case 'cleanup_completed':
      // The task was a success. Resolve the clusters completely.
      clusterUpdate = { status: 'resolved' };
      break;

    case 'report_incorrect':
    case 'issue_not_found':
      // The task was completed but there was no issue. Mark resolved/invalid.
      clusterUpdate = { status: 'resolved' };
      // Note: Ideally, we'd add 'Verified incorrect or not found' to resolution notes if it existed on clusters
      break;

    case 'issue_still_exists':
    case 'partially_completed':
    case 'unable_to_complete':
      // The crew couldn't finish it. Throw back into the work queue (prioritized).
      // We manually bump priority_score so it is heavily favored in the next dispatch plan.
      clusterUpdate = { status: 'prioritized', priority_score: 1.0 }; 
      break;

    case 'requires_institutional_action':
    case 'escalated':
      // Needs management intervention beyond standard field crews
      clusterUpdate = { status: 'escalated' };
      break;

    case 'needs_another_inspection':
    case 'requires_follow_up':
      // Back into the queue specifically marked for reinspection
      clusterUpdate = { status: 'needs_verification' };
      break;
      
    default:
      clusterUpdate = { status: 'monitoring' };
  }

  // 5. Update the clusters
  if (Object.keys(clusterUpdate).length > 0) {
    const { error: clusterError } = await supabase
      .from('clusters')
      .update(clusterUpdate)
      .in('id', clusterIds);
      
    if (clusterError) throw clusterError;
  }

  return task;
}
