import { fleetSettings } from '../services/fleetPolicy.js';
import { supabaseAdmin as supabase } from '../../../config/supabase.config.js';

import { prioritizeBacklog, getWorkQueue } from '../services/workQueue.service.js';
import { dispatchClusters } from '../services/dispatch.service.js';
import { commitAndRoutePlan } from '../services/dispatchCommit.service.js';
import { generateDispatchPlan } from '../services/dispatchPlanner.service.js';
import { processTaskFeedback } from '../services/taskFeedback.service.js';

// Phase 2: Work Queue Endpoints
export const prioritizeQueue = async (req, res, next) => {
  try {
    const updated = await prioritizeBacklog(req.body.weather_condition);
    res.status(200).json({ message: `Prioritized ${updated.length} clusters`, clusters: updated });
  } catch (error) { next(error); }
};

export const fetchWorkQueue = async (req, res, next) => {
  try {
    await prioritizeBacklog();
    
    // Parse the query parameter (it comes in as a string 'true' or 'false')
    const targetOutliersOnly = req.query.target_outliers_only === 'true'; 
    
    // Pass both parameters
    const queue = await getWorkQueue(parseInt(req.query.limit) || 100, targetOutliersOnly);
    res.status(200).json(queue);
  } catch (error) { next(error); }
};

export const explicitDispatch = async (req, res, next) => {
  try {
    const { cluster_ids } = req.body;
    if (!cluster_ids || !Array.isArray(cluster_ids)) {
      return res.status(400).json({ message: 'cluster_ids array is required' });
    }
    const result = await dispatchClusters(cluster_ids, req.user.id);
    res.status(result.routing_status === 'needs_replan' ? 202 : 201).json(result);
  } catch (error) { next(error); }
};

// Phase 3: Capacity-Aware Planning Endpoints
export const generatePlan = async (req, res, next) => {
  try {
    // Accept officer-configured settings from the request body
    const { settings = {} } = req.body;
    const result = await generateDispatchPlan(req.user.id, settings);
    res.status(201).json({ message: 'Dispatch plan generated successfully', ...result });
  } catch (error) { next(error); }
};

// ── Optimization Templates ─────────────────────────────────────────────

/**
 * GET /api/optimization/templates
 * Returns all system-level presets (created_by = null) plus the current officer's saved templates.
 */
export const getTemplates = async (req, res, next) => {
  try {
    const { data, error } = await supabase
      .from('optimization_templates')
      .select('*')
      .or(`created_by.is.null,created_by.eq.${req.user.id}`)
      .order('is_default', { ascending: false })
      .order('created_at', { ascending: true });

    if (error) return res.status(400).json({ message: 'Failed to fetch templates', error: error.message });
    res.status(200).json(data);
  } catch (error) { next(error); }
};

/**
 * POST /api/optimization/templates
 * Saves the current officer's settings as a new named template.
 */
export const createTemplate = async (req, res, next) => {
  try {
    const { name, description, settings } = req.body;
    if (!name || typeof name !== 'string' || name.trim() === '') {
      return res.status(400).json({ message: 'Template name is required' });
    }
    if (!settings || typeof settings !== 'object') {
      return res.status(400).json({ message: 'Template settings payload is required' });
    }

    const { data, error } = await supabase
      .from('optimization_templates')
      .insert({
        name: name.trim(),
        description: description?.trim() || null,
        created_by: req.user.id,
        is_default: false,
        settings
      })
      .select()
      .single();

    if (error) return res.status(400).json({ message: 'Failed to save template', error: error.message });
    res.status(201).json({ message: 'Template saved successfully', template: data });
  } catch (error) { next(error); }
};

/**
 * DELETE /api/optimization/templates/:id
 * Deletes one of the officer's own custom templates. System presets (is_default) cannot be deleted.
 */
export const deleteTemplate = async (req, res, next) => {
  try {
    const { id } = req.params;

    // Verify ownership and that this is not a system preset
    const { data: existing, error: fetchError } = await supabase
      .from('optimization_templates')
      .select('id, created_by, is_default')
      .eq('id', id)
      .single();

    if (fetchError || !existing) return res.status(404).json({ message: 'Template not found' });
    if (existing.is_default) return res.status(403).json({ message: 'System preset templates cannot be deleted' });
    if (existing.created_by !== req.user.id) return res.status(403).json({ message: 'You can only delete your own templates' });

    const { error } = await supabase.from('optimization_templates').delete().eq('id', id);
    if (error) return res.status(400).json({ message: 'Failed to delete template', error: error.message });
    res.status(200).json({ message: 'Template deleted successfully' });
  } catch (error) { next(error); }
};

export const getPlanItems = async (req, res, next) => {
  try {
    const { id } = req.params;
    const { data, error } = await supabase
      .from('dispatch_plan_items')
      .select('*, clusters(issue_type, priority_score, recommended_task_type), reports!dispatch_plan_items_report_id_fkey(issue_type, severity_score)')
      .eq('dispatch_plan_id', id)
      .order('is_selected', { ascending: false });

    if (error) return res.status(400).json({ message: 'Failed to fetch plan items', error: error.message });
    res.status(200).json(data);
  } catch (error) { next(error); }
};

export const commitPlan = async (req, res, next) => {
  try {
    const result = await commitAndRoutePlan(req.params.id, req.user.id);
    res.status(result.routing_status === 'needs_replan' || result.routing_status === 'routing' ? 202 : 200).json(result);
  } catch (error) { next(error); }
};

export const runOptimization = async (req, res, next) => {
  try {
    const generated = await generateDispatchPlan(req.user.id, req.body.settings ?? {});
    const result = await commitAndRoutePlan(generated.plan.id, req.user.id);
    res.status(result.routing_status === 'needs_replan' ? 202 : 200).json({ ...generated, ...result });
  } catch (error) { next(error); }
};

export const approveOptimization = async (req, res, next) => {
  try {
    const { data, error } = await supabase.from('dispatch_plans').select('id').eq('optimization_run_id',req.params.id).maybeSingle();
    if (error) throw error;
    if (!data) return res.status(409).json({ message: 'Legacy runs cannot claim reports. Generate a new dispatch plan.' });
    res.json(await commitAndRoutePlan(data.id, req.user.id));
  } catch (error) { next(error); }
};

export const discardOptimization = async (req, res, next) => {
  const { id } = req.params;
  
  try {
    const { data: run, error: runError } = await supabase
      .from('optimization_runs')
      .select('status')
      .eq('id', id)
      .single();
      
    if (runError) throw runError;
    if (run.status !== 'proposed') {
      return res.status(400).json({ message: 'Can only discard proposed optimization runs' });
    }
    
    // 1. Discard run
    const { data: discardedRun, error: updateError } = await supabase
      .from('optimization_runs')
      .update({
        status: 'discarded'
      })
      .eq('id', id)
      .select()
      .single();
      
    if (updateError) throw updateError;
    
    res.status(200).json({ message: 'Optimization discarded', run: discardedRun });
  } catch (error) { next(error); }
};

// List all optimization runs
export const getOptimizationRuns = async (req, res, next) => {
  try {
    const { data, error } = await supabase
      .from('optimization_runs')
      .select('*')
      .order('created_at', { ascending: false });

    if (error) return res.status(400).json({ message: 'Failed to fetch runs', error: error.message });
    res.json(data);
  } catch (error) { next(error); }
};

// Get single optimization run with routes
export const getOptimizationRunById = async (req, res, next) => {
  try {
    const { id } = req.params;
    const { data: run, error } = await supabase
      .from('optimization_runs')
      .select('*')
      .eq('id', id)
      .single();

    if (error) return res.status(404).json({ message: 'Run not found', error: error.message });

    const { data: routes } = await supabase
      .from('crew_routes')
      .select('*, field_crews(name)')
      .eq('optimization_run_id', id);

      if (routes && routes.length > 0) {
        const routeIds = routes.map(r => r.id);
        const { data: waypoints } = await supabase
          .from('route_waypoints')
          .select('*, cleanup_tasks(id, task_type, report_ids)')
          .in('crew_route_id', routeIds)
          .order('sequence_order', { ascending: true });
        
      for (const route of routes) {
        route.waypoints = (waypoints || []).filter(w => w.crew_route_id === route.id);
      }
    }

    res.json({ ...run, routes: routes || [] });
  } catch (error) { next(error); }
};

async function visibleCrewIds(req) {
  if (req.user.role !== 'field_crew') return null;
  const { data, error } = await supabase.from('field_crews').select('id, member_profile_ids, team_lead_profile_id');
  if (error) throw error;
  return (data ?? []).filter(crew => crew.team_lead_profile_id === req.user.id || crew.member_profile_ids?.includes(req.user.id)).map(crew => crew.id);
}

async function canReadCrewRoute(req, routeId) {
  const ids = await visibleCrewIds(req);
  if (ids === null) return true;
  const { data, error } = await supabase.from('crew_routes').select('crew_id').eq('id', routeId).maybeSingle();
  if (error) throw error;
  return Boolean(data && ids.includes(data.crew_id));
}

// Get active (approved) routes
export const getActiveRoutes = async (req, res, next) => {
  try {
    // Find the most recent approved run
    const { data: run } = await supabase
      .from('optimization_runs')
      .select('id')
      .eq('status', 'approved')
      .not('approved_at', 'is', null)
      .order('approved_at', { ascending: false })
      .limit(1)
      .single();

    if (!run) return res.json({ routes: [] });

    const ids = await visibleCrewIds(req);
    if (ids && !ids.length) return res.json({ optimization_run_id: run.id, routes: [] });
    let query = supabase.from('crew_routes').select('*, field_crews(name)').eq('optimization_run_id', run.id);
    if (ids) query = query.in('crew_id', ids);
    const { data: routes, error } = await query;
    if (error) throw error;

    for (const route of (routes || [])) {
      const { data: waypoints } = await supabase
        .from('route_waypoints')
        .select('*, cleanup_tasks(id, task_type)')
        .eq('crew_route_id', route.id)
        .order('sequence_order');
      route.waypoints = waypoints || [];
    }

    res.json({ optimization_run_id: run.id, routes });
  } catch (error) { next(error); }
};

export const getRouteById = async (req, res, next) => {
  try {
    const { routeId } = req.params;
    if (!await canReadCrewRoute(req, routeId)) return res.status(403).json({ message: 'Route is not assigned to your crew' });
    const { data, error } = await supabase
      .from('crew_routes')
      .select('*, field_crews(name)')
      .eq('id', routeId)
      .single();

    if (error) return res.status(404).json({ message: 'Route not found' });

    const { data: waypoints } = await supabase
      .from('route_waypoints')
      .select('*')
      .eq('crew_route_id', routeId)
      .order('sequence_order');

    res.json({ ...data, waypoints: waypoints || [] });
  } catch (error) { next(error); }
};

export const getRouteWaypoints = async (req, res, next) => {
  try {
    const { routeId } = req.params;
    if (!await canReadCrewRoute(req, routeId)) return res.status(403).json({ message: 'Route is not assigned to your crew' });
    const { data, error } = await supabase
      .from('route_waypoints')
      .select('*')
      .eq('crew_route_id', routeId)
      .order('sequence_order');

    if (error) return res.status(400).json({ message: 'Failed to fetch waypoints' });
    res.json(data || []);
  } catch (error) { next(error); }
};

export const getFieldCrews = async (req, res, next) => {
  try {
    const { data: crews, error } = await supabase
      .from('field_crews')
      .select('*')
      .order('name');

    if (error) return res.status(400).json({ message: 'Failed to fetch crews' });

    // Enrich each crew with member profile data
    const enriched = await Promise.all(
      crews.map(async (crew) => {
        const memberIds = crew.member_profile_ids || [];
        if (memberIds.length === 0) return { ...crew, members: [] };

        const { data: profiles } = await supabase
          .from('profiles')
          .select('id, full_name, avatar_url')
          .in('id', memberIds);

        return { ...crew, members: profiles || [] };
      })
    );

    res.json(enriched);
  } catch (error) { next(error); }
};

export const updateCrewMembers = async (req,res,next) => {
  try {
    const {data,error}=await supabase.rpc('change_field_crew_member',{crew_id:req.params.id,actor:req.user.id,member_id:req.body.user_id,action:req.body.action});
    if(error) throw error;res.json(data);
  } catch(error){next(error);}
};

export const getUnassignedMembers = async (req, res, next) => {
  try {
    // Get all field_crew role users
    const { data: fcUsers, error: profilesError } = await supabase
      .from('profiles')
      .select('id, full_name, avatar_url, role')
      .eq('role', 'field_crew')
      .order('full_name');

    if (profilesError) return res.status(400).json({ message: 'Failed to fetch field crew users' });

    // Get all assigned member IDs across all crews
    const { data: crews } = await supabase
      .from('field_crews')
      .select('member_profile_ids');

    const assignedIds = new Set(
      (crews || []).flatMap(c => c.member_profile_ids || [])
    );

    const unassigned = (fcUsers || []).filter(u => !assignedIds.has(u.id));
    res.json(unassigned);
  } catch (error) { next(error); }
};

export const getOptimizationSettings = async (req, res, next) => {
  try {
    const { data, error } = await supabase
      .from('optimization_settings')
      .select('*')
      .order('key');

    if (error) return res.status(400).json({ message: 'Failed to fetch settings' });
    res.json(data);
  } catch (error) { next(error); }
};

export const updateOptimizationSettings = async (req, res, next) => {
  try {
    const { key, value } = req.body;
    const { data, error } = await supabase
      .from('optimization_settings')
      .update({ value, updated_by: req.user.id, updated_at: new Date().toISOString() })
      .eq('key', key)
      .select()
      .single();

    if (error) return res.status(400).json({ message: 'Failed to update setting', error: error.message });
    res.json(data);
  } catch (error) { next(error); }
};

// Phase 15: Admin crew management
export const createFieldCrew = async (req,res,next) => {
  try {
    const {data,error}=await supabase.from('field_crews').insert(fleetSettings(req.body,true)).select().single();
    if(error) throw error;res.status(201).json(data);
  } catch(error){next(error);}
};
export const updateFieldCrew = async (req,res,next) => {
  try {
    const {data,error}=await supabase.from('field_crews').update({...fleetSettings(req.body),updated_at:new Date().toISOString()}).eq('id',req.params.id).select().single();
    if(error) throw error;res.json(data);
  } catch(error){next(error);}
};

// Phase 6: Field Feedback Loop
export const completeTask = async (req, res, next) => {
  const { id } = req.params;
  const { outcome, notes } = req.body;
  
  if (!outcome) {
    return res.status(400).json({ message: 'Outcome is required' });
  }

  try {
    const updatedTask = await processTaskFeedback(id, outcome, notes, req.user.id, req.body);
    res.status(200).json({ 
      message: 'Task completed and clusters updated successfully', 
      task: updatedTask 
    });
  } catch (error) { next(error); }
};

export const generateSweeperRoutes = async (req, res, next) => {
  try {
    if (req.body.clusterIds?.length || req.body.crewId) return res.status(400).json({ message: 'Sweeper dispatch uses eligible report IDs and fleet capabilities. Use settings.report_ids.' });
    const generated = await generateDispatchPlan(req.user.id, { ...req.body.settings, mode: 'sweeper' });
    const result = await commitAndRoutePlan(generated.plan.id, req.user.id);
    res.status(result.routing_status === 'needs_replan' ? 202 : 200).json({ ...generated, ...result });
  } catch (error) { next(error); }
};

export const getUnassignedOutlierClusters = async (req, res, next) => {
  try {
    const { data, error } = await supabase.from('reports').select('id,issue_type,severity_score,deadline_at,lifecycle_state')
      .is('cluster_id',null).is('cleanup_task_id',null).in('lifecycle_state',['maturing','sla_breached']).eq('status','unresolved')
      .order('deadline_at').limit(200);
    if (error) throw error;
    res.json({ reports: data, count: data.length });
  } catch (error) { next(error); }
};

export const getDispatchBlocks = async (req,res,next) => {
  try {
    const {data,error}=await supabase.from('dispatch_access_blocks').select('*').is('cleared_at',null).order('blocked_at').limit(200);
    if(error) throw error;res.json(data);
  } catch(error){next(error);}
};
export const clearDispatchBlock = async (req,res,next) => {
  try {
    const {data,error}=await supabase.rpc('clear_dispatch_block',{block_id:req.params.id,actor:req.user.id,notes:req.body.notes});
    if(error) throw error;res.json(data);
  } catch(error){next(error);}
};
