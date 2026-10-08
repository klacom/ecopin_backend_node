import { bestSatelliteOrder, metresBetween, travelMinutes } from './geoTime.js';

function tier(report, breachedFirst) { return breachedFirst && report.lifecycle_state === 'sla_breached' ? 1 : 0; }
function unsafe(report) { return ['suspected_hazard', 'hazmat_required', 'hazard_review'].includes(report.hazard_class); }

export function bundleReports({ groups, candidates, settings, workMinutes, remainingMinutes }) {
  const buffer = settings.mixed_spatial_buffer_meters ?? 1500;
  const maxPerAnchor = settings.mixed_max_reports_per_anchor ?? 5;
  const maxDetour = settings.mixed_max_detour_minutes ?? 30;
  const maxNodes = settings.solver_max_candidate_nodes ?? 200;
  const bonusMax = settings.bundle_proximity_bonus_max ?? 15;
  const planning = { speedKmh: settings.planning_speed_kmh ?? 20, circuityFactor: settings.planning_circuity_factor ?? 1.3 };
  if (![buffer, maxDetour, maxNodes, bonusMax, remainingMinutes].every(Number.isFinite) || maxPerAnchor < 0 || maxPerAnchor > 5) throw new Error('Invalid Mixed bounds');
  const assignments = new Map(groups.map(group => [group.group_key, []]));
  const rejected = [];
  const ranked = candidates.map(report => {
    const nearest = Math.min(...groups.map(group => metresBetween(group.centre, report.location)));
    return { ...report, bundle_rank_score: (report.base_priority_score ?? 0) + bonusMax * Math.max(0, 1 - nearest / buffer) };
  });
  const ordered = ranked.sort((a, b) => tier(b, settings.breached_first !== false) - tier(a, settings.breached_first !== false) ||
    b.bundle_rank_score - a.bundle_rank_score ||
    Date.parse(a.created_at) - Date.parse(b.created_at) || a.id.localeCompare(b.id));
  const allowed = Math.max(0, maxNodes - groups.length);
  for (const [candidateIndex, report] of ordered.entries()) {
    if (candidateIndex >= allowed) { rejected.push({ report_id: report.id, reason: 'deferred_by_compute_limit' }); continue; }
    if (report.blocked) { rejected.push({ report_id: report.id, reason: 'blocked_site' }); continue; }
    if (unsafe(report)) { rejected.push({ report_id: report.id, reason: 'hazard_review' }); continue; }
    const nearby = groups.map(group => ({ group, distance: metresBetween(group.centre, report.location) }))
      .filter(item => item.distance <= buffer)
      .sort((a, b) => a.distance - b.distance || a.group.group_key.localeCompare(b.group.group_key));
    if (!nearby.length) { rejected.push({ report_id: report.id, reason: 'outside_buffer' }); continue; }
    let reason = 'cap_reports';
    for (const { group, distance } of nearby) {
      const existing = assignments.get(group.group_key);
      if (existing.length >= maxPerAnchor) continue;
      const successor = group.successorCentre ?? settings.depot;
      if (!successor) throw new Error('Successor or depot required for open-path estimate');
      const estimate = bestSatelliteOrder(group.centre, [...existing.map(item => item.report), report], successor,
        (a, b) => travelMinutes(a.location ?? a.centre ?? a, b.location ?? b.centre ?? b, planning));
      if (estimate.detourMinutes > maxDetour) { reason = 'cap_detour'; continue; }
      const previousDetour = existing.at(-1)?.provisionalDetourMinutes ?? 0;
      const marginalDetour = Math.max(0, estimate.detourMinutes - previousDetour);
      const work = Number(workMinutes(report));
      if (!Number.isFinite(work) || work < 0 || work + marginalDetour > remainingMinutes) { reason = 'cap_time'; continue; }
      const crew = group.crew;
      if (report.estimated_volume_m3 == null || report.estimated_weight_kg == null ||
          group.estimated_volume_m3 == null || group.estimated_weight_kg == null ||
          !crew || crew.max_volume_m3 == null || crew.max_weight_kg == null ||
          crew.starting_volume_m3 == null || crew.starting_weight_kg == null) { reason = 'unknown_load'; continue; }
      const volume = Number(group.estimated_volume_m3) + existing.reduce((sum, item) => sum + Number(item.report.estimated_volume_m3), 0) + Number(report.estimated_volume_m3);
      const weight = Number(group.estimated_weight_kg) + existing.reduce((sum, item) => sum + Number(item.report.estimated_weight_kg), 0) + Number(report.estimated_weight_kg);
      if (Number(crew.starting_volume_m3) + volume > Number(crew.max_volume_m3)) { reason = 'cap_volume'; continue; }
      if (Number(crew.starting_weight_kg) + weight > Number(crew.max_weight_kg)) { reason = 'cap_weight'; continue; }
      const bonus = bonusMax * Math.max(0, 1 - distance / buffer);
      existing.push({ report, distanceMeters: distance, bundleRankScore: (report.base_priority_score ?? 0) + bonus,
        provisionalDetourMinutes: estimate.detourMinutes });
      remainingMinutes -= work + marginalDetour;
      reason = null;
      break;
    }
    if (reason) rejected.push({ report_id: report.id, reason });
  }
  return { assignments: [...assignments].map(([group_key, satellites]) => ({ group_key, satellites })), rejected,
    remainingMinutes };
}
