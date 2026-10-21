const valid = (value, positive = false) => value != null && Number.isFinite(Number(value)) && (positive ? Number(value)>0 : Number(value)>=0);
export function crewLoadIssues(crews, activeTasks = []) {
  return crews.flatMap(crew => {
    const missingCapacity = ['max_volume_m3','max_weight_kg','starting_volume_m3','starting_weight_kg']
      .filter(key => !valid(crew[key], key.startsWith('max_')));
    const members = [...(crew.member_profile_ids || []),crew.team_lead_profile_id].filter(Boolean);
    const missingTasks = activeTasks.filter(task => !['completed','cancelled'].includes(task.status) &&
      (task.assigned_field_crew_id===crew.id || task.assigned_crew_ids?.some(id=>members.includes(id))) &&
      (!valid(task.estimated_volume_m3) || !valid(task.estimated_weight_kg)));
    if (!missingCapacity.length && !missingTasks.length) return [];
    return [{crew_id:crew.id,crew_name:crew.name||crew.id,missing_capacity_fields:missingCapacity,
      missing_task_load_count:missingTasks.length,
      message:`${crew.name||crew.id}: ${[missingCapacity.length ? 'configure vehicle capacity and starting load' : null,
        missingTasks.length ? `enter volume/weight estimates for ${missingTasks.length} unfinished tasks` : null].filter(Boolean).join('; ')}`}];
  });
}
export function requireCrewLoads(crews, activeTasks) {
  const issues = crewLoadIssues(crews, activeTasks);
  if (issues.length) {
    const error = new Error(`Load information required before dispatch. ${issues.map(i=>i.message).join('. ')}.`);
    error.statusCode = 409;
    throw error;
  }
}
