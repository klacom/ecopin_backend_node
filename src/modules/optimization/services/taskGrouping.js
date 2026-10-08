import { metresBetween } from './geoTime.js';

function ranked(a, b) {
  return Number(b.lifecycle_state === 'sla_breached') - Number(a.lifecycle_state === 'sla_breached') ||
    (b.priority_score ?? b.base_priority_score ?? 0) - (a.priority_score ?? a.base_priority_score ?? 0) ||
    Date.parse(a.created_at ?? 0) - Date.parse(b.created_at ?? 0) || a.id.localeCompare(b.id);
}

export function groupClustersForTask(clusters, { radiusM = 200 } = {}) {
  const remaining = [...clusters].sort(ranked);
  const groups = [];
  while (remaining.length) {
    const seed = remaining.shift();
    const members = [seed];
    for (let i = remaining.length - 1; i >= 0; i--) {
      if (metresBetween(seed.centre, remaining[i].centre) <= radiusM) members.push(...remaining.splice(i, 1));
    }
    members.sort(ranked);
    groups.push({ group_key: `cluster:${seed.id}`, centre: seed.centre, members,
      clusterIds: members.map(member => member.id),
      reportIds: [...new Set(members.flatMap(member => member.reportIds ?? []))].sort(),
      effortMinutes: members.reduce((sum, member) => sum + Number(member.effortMinutes ?? 0), 0),
      priority: seed.priority_score ?? 0 });
  }
  return groups;
}

export function groupReportsForSweeper(reports, { radiusM = 100, maxPerTask = 5 } = {}) {
  if (!Number.isInteger(maxPerTask) || maxPerTask < 1) throw new Error('Invalid Sweeper group limit');
  const remaining = [...reports].sort(ranked);
  const groups = [];
  while (remaining.length) {
    const seed = remaining.shift();
    const members = [seed];
    for (let i = 0; i < remaining.length && members.length < maxPerTask;) {
      if (metresBetween(seed.location, remaining[i].location) <= radiusM) members.push(...remaining.splice(i, 1));
      else i++;
    }
    groups.push({ group_key: `sweeper:${seed.id}`, centre: seed.location, members,
      clusterIds: [], reportIds: members.map(member => member.id),
      effortMinutes: members.reduce((sum, member) => sum + Number(member.workMinutes ?? 0), 0),
      priority: seed.base_priority_score ?? 0 });
  }
  return groups;
}
