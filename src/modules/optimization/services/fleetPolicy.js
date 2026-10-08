export function fleetSettings(input, creating = false) {
  const allowed = ['name','shift_start','shift_end','max_tasks_per_shift','supports_standard','supports_sweeper',
    'speed_factor','service_time_factor','availability_status','vehicle_type','hazmat_certified','certifications',
    'max_volume_m3','max_weight_kg','starting_volume_m3','starting_weight_kg','load_measured_at'];
  const result = creating ? {shift_start:'08:00:00',shift_end:'17:00:00',max_tasks_per_shift:10,supports_standard:true,supports_sweeper:false,speed_factor:1,service_time_factor:1,availability_status:'available',hazmat_certified:false} : {};
  const invalid = message => { const error=new Error(message);error.statusCode=400;throw error; };
  for (const key of allowed) if (input[key] !== undefined) result[key]=input[key];
  if (creating && result.vehicle_type === 'hazmat_unit') {
    if (input.supports_standard === undefined) result.supports_standard = false;
    if (input.supports_sweeper === undefined) result.supports_sweeper = false;
  }
  if (creating && (typeof result.name!=='string'||!result.name.trim())) invalid('Crew name required');
  for (const key of ['supports_standard','supports_sweeper','hazmat_certified'])
    if (result[key]!==undefined && typeof result[key]!=='boolean') invalid(`Invalid ${key}`);
  if (result.vehicle_type!==undefined && !['compactor','pickup','tricycle','motorcycle','hazmat_unit'].includes(result.vehicle_type))
    invalid('Invalid vehicle type');
  if (result.certifications!==undefined && (!Array.isArray(result.certifications) ||
    result.certifications.length>20 || result.certifications.some(value => typeof value!=='string' || value.length>80)))
    invalid('Invalid certifications');
  for (const key of ['max_volume_m3','max_weight_kg','starting_volume_m3','starting_weight_kg'])
    if (result[key]!==undefined && result[key]!==null &&
      (typeof result[key]!=='number' || !Number.isFinite(result[key]) ||
        result[key]<(key.startsWith('starting_')?0:0.001))) invalid(`Invalid ${key}`);
  if (result.load_measured_at!==undefined && result.load_measured_at!==null &&
    (typeof result.load_measured_at!=='string' || !Number.isFinite(Date.parse(result.load_measured_at))))
    invalid('Invalid load measurement time');
  if ((result.starting_volume_m3!=null || result.starting_weight_kg!=null) && !result.load_measured_at)
    invalid('Starting load requires a measurement time');
  if (result.starting_volume_m3!=null && result.max_volume_m3!=null && result.starting_volume_m3>result.max_volume_m3)
    invalid('Starting volume exceeds capacity');
  if (result.starting_weight_kg!=null && result.max_weight_kg!=null && result.starting_weight_kg>result.max_weight_kg)
    invalid('Starting weight exceeds capacity');
  for (const key of ['speed_factor','service_time_factor']) if (result[key]!==undefined && (typeof result[key]!=='number'||!Number.isFinite(result[key])||result[key]<=0||result[key]>3)) invalid(`Invalid ${key}`);
  if (result.max_tasks_per_shift!==undefined && (!Number.isInteger(result.max_tasks_per_shift)||result.max_tasks_per_shift<1||result.max_tasks_per_shift>100)) invalid('Invalid task capacity');
  for (const key of ['shift_start','shift_end']) if (result[key]!==undefined && !/^([01]\d|2[0-3]):[0-5]\d(?::[0-5]\d)?$/.test(result[key])) invalid('Invalid shift time');
  if (result.availability_status!==undefined && !['available','on_route','off_shift','disabled'].includes(result.availability_status)) invalid('Invalid availability');
  return result;
}
