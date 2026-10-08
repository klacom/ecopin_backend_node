import { generateDispatchPlan } from './dispatchPlanner.service.js';
import { commitAndRoutePlan } from './dispatchCommit.service.js';
export async function dispatchClusters(clusterIds, userId) {
  if (!Array.isArray(clusterIds) || !clusterIds.length) throw new Error('Select at least one cluster');
  const { plan } = await generateDispatchPlan(userId, { mode: 'standard', cluster_ids: clusterIds });
  return commitAndRoutePlan(plan.id, userId);
}
