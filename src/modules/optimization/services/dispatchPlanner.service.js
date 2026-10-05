import { supabaseAdmin as supabase } from '../../../config/supabase.config.js';
import { prioritizeBacklog } from './workQueue.service.js';

/**
 * Helper to calculate minutes between two TIME strings ('HH:MM:SS')
 */
function getShiftMinutes(startStr, endStr) {
  if (!startStr || !endStr) return 480; // Default 8 hours
  const [sH, sM] = startStr.split(':').map(Number);
  const [eH, eM] = endStr.split(':').map(Number);
  
  let totalMin = (eH * 60 + eM) - (sH * 60 + sM);
  if (totalMin < 0) totalMin += 24 * 60; // Handle overnight shifts
  return totalMin;
}

/**
 * Generates an automated dispatch plan based on current backlog and crew capacity.
 * @param {string} userId - The ID of the officer generating the plan.
 * @param {Object} settings - Officer-configured settings to override defaults.
 */
export async function generateDispatchPlan(userId, settings = {}) {
  const {
    travel_mode = 'DRIVING',
    break_duration_min = 60,
    overtime_tolerance_min = 15,
    priority_age_weight = 50,   // 0 = Age (oldest first), 100 = Priority score only
    included_task_types = [],   // Empty array = all task types
    density_focus = false,
    zone_ids = [],              // Empty array = all geographic zones
    max_tasks_per_shift = 15,
  } = settings;

  // Derive travel buffer from travel mode:
  // Vehicles need a parking/approach buffer; walkers do not.
  const TRAVEL_ESTIMATE_MIN =
    travel_mode === 'DRIVING' ? 25 :
    travel_mode === 'BICYCLE' ? 15 :
    10; // WALKING

  // 0. Just-In-Time Prioritization
  // Ensure the backlog is freshly prioritized right before we select tasks for dispatch
  await prioritizeBacklog();

  // 1. Calculate Capacity
  const { data: crews } = await supabase
    .from('field_crews')
    .select('*')
    .eq('availability_status', 'available');
    
  if (!crews || crews.length === 0) {
    throw new Error('No available crews found to generate a dispatch plan.');
  }

  let totalCapacityMinutes = 0;
  for (const crew of crews) {
    const shiftMins = getShiftMinutes(crew.shift_start, crew.shift_end);
    // Subtract break time per crew, then add the officer-permitted overtime buffer
    totalCapacityMinutes += (shiftMins - break_duration_min + overtime_tolerance_min);
  }


  // 2. Fetch Backlog with settings-driven filters
  // We fetch top 200 to ensure enough to fill capacity and log omitted items
  let backlogQuery = supabase
    .from('clusters')
    .select('id, priority_score, estimated_effort_minutes, recommended_task_type, created_at')
    .in('status', ['prioritized', 'monitoring']);

  // Apply Task Type filter only if the officer specified types to include
  if (included_task_types.length > 0) {
    backlogQuery = backlogQuery.in('recommended_task_type', included_task_types);
  }

  // Apply Geographic Zone filter only if the officer restricted to specific zones
  if (zone_ids.length > 0) {
    backlogQuery = backlogQuery.in('zone_id', zone_ids);
  }

  // Blend sort order based on priority_age_weight slider:
  // weight > 50 → sort by priority_score descending (priority wins)
  // weight <= 50 → sort by created_at ascending (oldest tasks first)
  const sortByPriority = priority_age_weight > 50;
  backlogQuery = backlogQuery
    .order('priority_score', { ascending: !sortByPriority })
    .order('created_at', { ascending: sortByPriority })
    .limit(200);

  const { data: backlog } = await backlogQuery;

  if (!backlog || backlog.length === 0) {
    return {
      plan: null,
      selectedCount: 0,
      omittedLoggedCount: 0,
      capacityUtilized: 0,
      message: 'Work queue is empty. No tasks available to optimize.'
    };
  }

  // 3. Selection Logic
  let remainingCapacity = totalCapacityMinutes;
  const totalMaxTasks = max_tasks_per_shift * crews.length;
  const selectedItems = [];
  const omittedItems = [];

  for (const cluster of backlog) {
    const requiredEffort = (cluster.estimated_effort_minutes || 60) + TRAVEL_ESTIMATE_MIN;

    // Enforce hard max-tasks-per-shift cap before capacity check
    if (selectedItems.length >= totalMaxTasks) {
      omittedItems.push({
        cluster_id: cluster.id,
        is_selected: false,
        reason: 'Deferred: maximum task cap per shift reached',
        estimated_duration_minutes: requiredEffort
      });
      if (omittedItems.length >= 100) break;
      continue;
    }
    
    if (remainingCapacity >= requiredEffort) {
      selectedItems.push({
        cluster_id: cluster.id,
        is_selected: true,
        reason: 'Selected due to high priority and available capacity',
        estimated_duration_minutes: requiredEffort
      });
      remainingCapacity -= requiredEffort;
    } else {
      if (remainingCapacity > 0 && omittedItems.length < 5) {
        // Just barely didn't fit
        omittedItems.push({
          cluster_id: cluster.id,
          is_selected: false,
          reason: `Insufficient crew capacity (Requires ${requiredEffort}m, ${remainingCapacity}m remaining)`,
          estimated_duration_minutes: requiredEffort
        });
      } else {
        // Out of capacity
        omittedItems.push({
          cluster_id: cluster.id,
          is_selected: false,
          reason: 'Deferred due to low priority compared to available capacity',
          estimated_duration_minutes: requiredEffort
        });
      }
    }
    
    // As per user's instruction to prevent DB bloat, cap the omitted items we explicitly log
    if (omittedItems.length >= 100) break; 
  }

  // 4. Save to Database
  const { data: plan, error: planError } = await supabase
    .from('dispatch_plans')
    .insert({
      planned_date: new Date().toISOString().split('T')[0],
      total_crews_available: crews.length,
      total_capacity_minutes: totalCapacityMinutes,
      status: 'draft',
      created_by: userId
    })
    .select()
    .single();

  if (planError || !plan) {
    throw new Error('Failed to create dispatch plan record: ' + (planError?.message || ''));
  }

  // Insert items
  const allItems = [...selectedItems, ...omittedItems].map(item => ({
    ...item,
    dispatch_plan_id: plan.id
  }));

  const { error: itemsError } = await supabase
    .from('dispatch_plan_items')
    .insert(allItems);

  if (itemsError) {
    console.error('Error inserting plan items:', itemsError);
  }

  return {
    plan,
    selectedCount: selectedItems.length,
    omittedLoggedCount: omittedItems.length,
    capacityUtilized: totalCapacityMinutes - remainingCapacity
  };
}
