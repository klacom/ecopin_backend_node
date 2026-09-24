import { supabaseAdmin as supabase } from '../../../config/supabase.config.js';

/**
 * DEPRECATED: Phase 2 Environmental Work Queue
 * Tasks are no longer automatically generated from clusters.
 * Clusters remain in the backlog until explicitly dispatched via dispatch.service.js
 */
export async function mapClustersToTasks(prioritizedClusters) {
  console.warn('DEPRECATED: mapClustersToTasks called. No tasks will be auto-generated.');
  return [];
}
