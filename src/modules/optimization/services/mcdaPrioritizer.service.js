import { supabaseAdmin as supabase } from '../../../config/supabase.config.js';
import { OPTIMIZATION_CONFIG } from '../config/optimization.config.js';

/**
 * Calculates priority scores for clusters using MCDA
 * @param {Array<string>} clusterIds - Array of cluster UUIDs to prioritize
 * @param {string} weatherCondition - 'normal', 'heavy_rain', 'storm'
 * @param {Object} weights - Custom weights or defaults
 * @returns {Array} Sorted array of prioritized clusters
 */
export async function calculateClusterPriorities(clusterIds, weatherCondition = 'normal', weights = OPTIMIZATION_CONFIG.mcda.weights) {
  if (!clusterIds || clusterIds.length === 0) return [];

  // Weather scores
  const weatherScores = {
    normal: 0,
    heavy_rain: 50,
    storm: 100,
  };
  const weatherBaseScore = weatherScores[weatherCondition] || 0;

  const results = [];

  for (const clusterId of clusterIds) {
    // 1. Fetch cluster and its reports
    const { data: cluster } = await supabase
      .from('clusters')
      .select('id, issue_type, severity, reports(severity_score, urgency_score, created_at)')
      .eq('id', clusterId)
      .single();

    if (!cluster) continue;

    // 2. Aggregate factors
    const reports = cluster.reports || [];
    
    // a. Severity
    let maxSeverity = 0;
    if (reports.length > 0 && reports.some(r => r.severity_score !== null)) {
      maxSeverity = Math.max(...reports.filter(r => r.severity_score !== null).map(r => r.severity_score));
    } else {
      // Fallback based on cluster severity
      const fallbacks = { high: 80, medium: 50, low: 25 };
      maxSeverity = fallbacks[cluster.severity] || 50;
    }

    // b. Urgency
    let maxUrgency = 50; // default
    if (reports.length > 0 && reports.some(r => r.urgency_score !== null)) {
      maxUrgency = Math.max(...reports.filter(r => r.urgency_score !== null).map(r => r.urgency_score));
    }

    // c. Report count (normalized max 10)
    const reportCountNorm = Math.min(reports.length / 10, 1.0) * 100;

    // d. Waiting time (normalized max 7 days = 168 hours)
    let oldestDate = new Date();
    if (reports.length > 0) {
      oldestDate = new Date(Math.min(...reports.map(r => new Date(r.created_at))));
    }
    const hoursWaiting = (new Date() - oldestDate) / (1000 * 60 * 60);
    const waitingTimeNorm = Math.min(hoursWaiting / 168, 1.0) * 100;

    // e. Weather (adjust for flood-prone)
    let weatherNorm = weatherBaseScore;
    const isFloodProne = cluster.issue_type === 'flooding' || cluster.issue_type === 'pollution';
    if (isFloodProne && weatherCondition === 'heavy_rain') {
      weatherNorm = 70; // extra penalty
    } else if (isFloodProne && weatherCondition === 'storm') {
      weatherNorm = 100;
    }

    // 3. Calculate weighted score
    const rawScore = 
      (maxSeverity * weights.severity) +
      (maxUrgency * weights.urgency) +
      (reportCountNorm * weights.report_count) +
      (waitingTimeNorm * weights.waiting_time) +
      (weatherNorm * weights.weather);

    const priorityScore = Math.round(rawScore * 10) / 10;

    // 4. Assign bucket
    let priorityBucket = 'low';
    if (priorityScore >= OPTIMIZATION_CONFIG.mcda.buckets.urgent) priorityBucket = 'urgent';
    else if (priorityScore >= OPTIMIZATION_CONFIG.mcda.buckets.high) priorityBucket = 'high';
    else if (priorityScore >= OPTIMIZATION_CONFIG.mcda.buckets.medium) priorityBucket = 'medium';

    results.push({
      id: cluster.id,
      priority_score: priorityScore,
      priority: priorityBucket,
      factors: {
        severity: maxSeverity,
        urgency: maxUrgency,
        reportCount: reportCountNorm,
        waitingTime: waitingTimeNorm,
        weather: weatherNorm
      }
    });

    // 5. Update database
    await supabase
      .from('clusters')
      .update({
        priority_score: priorityScore,
        priority: priorityBucket
      })
      .eq('id', cluster.id);
  }

  // Return sorted highest priority first
  return results.sort((a, b) => b.priority_score - a.priority_score);
}
