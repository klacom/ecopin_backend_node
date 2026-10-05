import { supabaseAdmin as supabase } from '../../../config/supabase.config.js';

/**
 * Creates an audit log entry
 * @param {string} eventType 
 * @param {string} entityType 
 * @param {string} entityId 
 * @param {string} userId 
 * @param {Object} eventData 
 */
export async function createAuditLog(eventType, entityType, entityId, userId, eventData) {
  const { data, error } = await supabase
    .from('sweeper_audit_log')
    .insert({
      event_type: eventType,
      entity_type: entityType,
      entity_id: entityId,
      user_id: userId,
      event_data: eventData
    })
    .select()
    .single();

  if (error) {
    console.error('Failed to create audit log:', error);
    throw new Error(`Audit log creation failed: ${error.message}`);
  }

  return data;
}

export async function logSlaBreachDetection(reportId, breachDuration) {
  return createAuditLog('SLA_BREACH_DETECTED', 'REPORT', reportId, 'system', { breach_duration_hours: breachDuration });
}

export async function logOutlierClusterCreation(clusterId, reportId) {
  return createAuditLog('OUTLIER_CLUSTER_CREATED', 'CLUSTER', clusterId, 'system', { source_report_id: reportId });
}

export async function logSweeperTaskCreation(taskId, clusterIds) {
  return createAuditLog('SWEEPER_TASK_CREATED', 'TASK', taskId, 'system', { cluster_ids: clusterIds });
}

export async function logTaskAssignment(taskId, officerId, crewId) {
  return createAuditLog('SWEEPER_TASK_ASSIGNED', 'TASK', taskId, officerId, { assigned_crew_id: crewId });
}

export async function logTaskCompletion(taskId, completionTime, status) {
  return createAuditLog('SWEEPER_TASK_COMPLETED', 'TASK', taskId, 'system', { completion_time: completionTime, status });
}

export async function logConfigurationChange(parameterName, oldValue, newValue, adminId) {
  return createAuditLog('CONFIGURATION_UPDATED', 'CONFIGURATION', parameterName, adminId, { old_value: oldValue, new_value: newValue });
}
