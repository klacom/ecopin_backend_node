export function fleetSettings(input, creating = false) {
  const allowed = ['name','shift_start','shift_end','max_tasks_per_shift','supports_standard','supports_sweeper','speed_factor','service_time_factor','availability_status'];
  const result = creating ? {shift_start:'08:00:00',shift_end:'17:00:00',max_tasks_per_shift:10,supports_standard:true,supports_sweeper:false,speed_factor:1,service_time_factor:1,availability_status:'available'} : {};
  const invalid = message => { const error=new Error(message);error.statusCode=400;throw error; };
  for (const key of allowed) if (input[key] !== undefined) result[key]=input[key];
  if (creating && (typeof result.name!=='string'||!result.name.trim())) invalid('Crew name required');
  for (const key of ['supports_standard','supports_sweeper']) if (result[key]!==undefined && typeof result[key]!=='boolean') invalid(`Invalid ${key}`);
  for (const key of ['speed_factor','service_time_factor']) if (result[key]!==undefined && (typeof result[key]!=='number'||!Number.isFinite(result[key])||result[key]<=0||result[key]>3)) invalid(`Invalid ${key}`);
  if (result.max_tasks_per_shift!==undefined && (!Number.isInteger(result.max_tasks_per_shift)||result.max_tasks_per_shift<1||result.max_tasks_per_shift>100)) invalid('Invalid task capacity');
  for (const key of ['shift_start','shift_end']) if (result[key]!==undefined && !/^([01]\d|2[0-3]):[0-5]\d(?::[0-5]\d)?$/.test(result[key])) invalid('Invalid shift time');
  if (result.availability_status!==undefined && !['available','on_route','off_shift','disabled'].includes(result.availability_status)) invalid('Invalid availability');
  return result;
}
