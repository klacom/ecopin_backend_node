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
 * Generates an automated dispatch plan based on current backlog and crew capacity
 */
export async function generateDispatchPlan(userId) {
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
    const mins = getShiftMinutes(crew.shift_start, crew.shift_end);
    totalCapacityMinutes += mins;
  }

  // 2. Fetch Backlog (we fetch top 200 to ensure we have enough to fill capacity and store 100 omitted)
  const { data: backlog } = await supabase
    .from('clusters')
    .select('id, priority_score, estimated_effort_minutes, recommended_task_type')
    .in('status', ['prioritized', 'monitoring'])
    .order('priority_score', { ascending: false })
    .limit(200);

  if (!backlog || backlog.length === 0) {
    throw new Error('Work queue is empty.');
  }

  // 3. Selection Logic
  let remainingCapacity = totalCapacityMinutes;
  const selectedItems = [];
  const omittedItems = [];
  const TRAVEL_ESTIMATE_MIN = 20; // Heuristic: average 20 mins travel between operations

  for (const cluster of backlog) {
    const requiredEffort = (cluster.estimated_effort_minutes || 60) + TRAVEL_ESTIMATE_MIN;
    
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
