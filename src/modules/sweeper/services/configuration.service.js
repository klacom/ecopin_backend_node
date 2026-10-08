import { supabaseAdmin as supabase } from '../../../config/supabase.config.js';
import { logConfigurationChange } from './audit-log.service.js';

export async function getConfigurationValue(parameterName, defaultValue = null) {
  const { data, error } = await supabase
    .from('sweeper_configuration')
    .select('parameter_value')
    .eq('parameter_name', parameterName)
    .single();
    
  if (error || !data) {
    if (error && error.code !== 'PGRST116') throw new Error(`Configuration unavailable: ${parameterName}`);
    return defaultValue;
  }
  return data.parameter_value;
}

export async function updateConfigurationValue(parameterName, value, adminId) {
  const oldValue = await getConfigurationValue(parameterName);
  
  const { data, error } = await supabase
    .from('sweeper_configuration')
    .upsert({
      parameter_name: parameterName,
      parameter_value: value,
      updated_by: adminId,
      updated_at: new Date().toISOString()
    })
    .select()
    .single();
    
  if (error) {
    throw new Error(`Failed to update configuration ${parameterName}: ${error.message}`);
  }
  
  // Log the change
  await logConfigurationChange(parameterName, oldValue, value, adminId);
  
  return data.parameter_value;
}

export async function getSlaThreshold() {
  const config = await getConfigurationValue('sla_threshold', { hours: 48 });
  return config.hours;
}

export async function updateSlaThreshold(hours, adminId) {
  if (!hours || typeof hours !== 'number' || hours < 1 || hours > 168) {
    throw new Error('SLA threshold must be between 1 and 168 hours');
  }
  return updateConfigurationValue('sla_threshold', { hours }, adminId);
}

export async function getShiftDuration(crewId) {
  // Currently supports a global default shift duration, could be extended to be per-crew
  const config = await getConfigurationValue('shift_duration', { hours: 8 });
  return config.hours;
}

export async function updateShiftDuration(crewId, hours, adminId) {
  if (!hours || typeof hours !== 'number' || hours < 4 || hours > 12) {
    throw new Error('Shift duration must be between 4 and 12 hours');
  }
  // Ignore crewId for now, update the global setting
  return updateConfigurationValue('shift_duration', { hours }, adminId);
}

export async function getTimeBuffer() {
  const config = await getConfigurationValue('time_buffer', { percent: 10 });
  return config.percent;
}

export async function updateTimeBuffer(percent, adminId) {
  if (typeof percent !== 'number' || percent < 0 || percent > 50) {
    throw new Error('Time buffer must be between 0 and 50 percent');
  }
  return updateConfigurationValue('time_buffer', { percent }, adminId);
}

export async function getWorkTime(reportType) {
  const { data, error } = await supabase
    .from('work_time_configuration')
    .select('work_time_minutes')
    .eq('report_type', reportType)
    .single();
    
  if (error || !data) {
    return 30; // Default fallback to 30 minutes
  }
  return data.work_time_minutes;
}

export async function getAllWorkTimes() {
  const { data, error } = await supabase
    .from('work_time_configuration')
    .select('*');
    
  if (error) {
    throw new Error(`Failed to get work times: ${error.message}`);
  }
  
  return data || [];
}

export async function updateWorkTime(reportType, minutes, adminId) {
  if (!minutes || typeof minutes !== 'number' || minutes < 5 || minutes > 120) {
    throw new Error('Work time must be between 5 and 120 minutes');
  }
  
  const oldMinutes = await getWorkTime(reportType);
  
  const { data, error } = await supabase
    .from('work_time_configuration')
    .upsert({
      report_type: reportType,
      work_time_minutes: minutes,
      updated_at: new Date().toISOString()
    })
    .select()
    .single();
    
  if (error) {
    throw new Error(`Failed to update work time for ${reportType}: ${error.message}`);
  }
  
  // Log the change
  await logConfigurationChange(`work_time_${reportType}`, oldMinutes, minutes, adminId);
  
  return data.work_time_minutes;
}
