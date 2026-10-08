import { supabaseAdmin as db } from '../../../config/supabase.config.js';
import { generateRouteForCrew } from './routeGenerator.service.js';

async function result(query) { const { data, error } = await query; if (error) throw error; return data; }

export async function commitAndRoutePlan(planId, actor) {
  const committed = await result(db.rpc('commit_dispatch_plan', { plan_id: planId, actor }));
  if (!committed.tasks.length) return { ...committed, run: null, routing_status: 'empty' };
  committed.tasks.sort((a,b)=>(b.priority_score??0)-(a.priority_score??0)||a.id.localeCompare(b.id));
  const lease = await result(db.rpc('begin_plan_routing', { plan_id: planId, actor }));
  if (lease.run_id) return { ...committed, run: { id: lease.run_id }, routing_status: 'ready' };
  if (!lease.token) return { ...committed, run: null, routing_status: lease.running ? 'routing' : 'needs_replan' };
  try {
    const [coordinates, crews, depotSetting, planSettings] = await Promise.all([
      result(db.rpc('task_coordinates', { task_ids: committed.tasks.map(task => task.id) })),
      result(db.from('field_crews').select('*').in('id', [...new Set(committed.tasks.map(task => task.assigned_field_crew_id))])),
      result(db.from('optimization_settings').select('value').eq('key','swmo_depot').single()),
      result(db.from('dispatch_plans').select('settings_snapshot').eq('id',planId).single())
    ]);
    const depot = depotSetting?.value;
    if (!depot || !Number.isFinite(depot.latitude) || !Number.isFinite(depot.longitude)) throw new Error('Configure the dispatch depot before publishing');
    const locations = new Map(coordinates.map(point => [point.id, point]));
    const signal = AbortSignal.timeout(20000);
    const routes = await Promise.all(crews.map(async crew => ({
      ...await generateRouteForCrew(crew.id, committed.tasks.filter(task => task.assigned_field_crew_id===crew.id).map(task=>task.id), depot,
        process.env.TOMTOM_API_KEY ? 'tomtom' : 'haversine', { locations, travelMode: planSettings.settings_snapshot.travel_mode, speedFactor: Number(crew.speed_factor), signal }),
      speed_factor: Number(crew.speed_factor), service_time_factor: Number(crew.service_time_factor)
    })));
    const published = await result(db.rpc('publish_dispatch_routes', { plan_id: planId, actor, token: lease.token, routes, depot }));
    const tasks = await result(db.from('cleanup_tasks').select('*').eq('source_plan_id',planId));
    return { ...committed, tasks, run: { id: published.run_id }, routing_status: 'ready' };
  } catch (error) {
    await result(db.rpc('finish_plan_routing', { plan_id: planId, actor, token: lease.token, failure: error.message }));
    return { ...committed, run: null, routing_status: 'needs_replan', warning: error.message };
  }
}
