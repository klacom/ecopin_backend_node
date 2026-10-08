import { generateMixedRoutesFromProposal } from './routeGenerator.service.js';

/**
 * Convert a saved, validated v5 proposal into publishable routes after the
 * database has returned its immutable per-group commit results. Optional
 * satellites missing at commit are removed from the proposal once; no solve or
 * greedy route reorder happens here.
 */
export function assignTasksToCrews(proposal, commitResults, crews, depot, maxDetourMinutes) {
  return generateMixedRoutesFromProposal(proposal, commitResults, crews, depot, maxDetourMinutes);
}
