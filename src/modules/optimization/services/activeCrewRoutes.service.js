// Approved routes stay active while their assigned tasks remain unfinished.
export async function readActiveCrewRoutes(db, crewIds) {
  if (crewIds && !crewIds.length) return [];
  let query = db.from('crew_routes').select('*,field_crews(name),optimization_runs!inner(status,approved_at),cleanup_tasks!inner(id,status)')
    .eq('optimization_runs.status', 'approved').not('optimization_runs.approved_at', 'is', null)
    .not('cleanup_tasks.status', 'in', '(completed,cancelled)');
  if (crewIds) query = query.in('crew_id', crewIds);
  const {data:routes,error} = await query;
  if (error) throw error;
  if (!routes?.length) return [];
  const {data:waypoints,error:waypointError} = await db.from('route_waypoints')
    .select('*,cleanup_tasks(id,task_type)').in('crew_route_id', routes.map(r=>r.id)).order('sequence_order');
  if (waypointError) throw waypointError;
  return routes.map(({optimization_runs,cleanup_tasks,...route}) => ({...route,
    waypoints:(waypoints||[]).filter(w=>w.crew_route_id===route.id)}));
}
