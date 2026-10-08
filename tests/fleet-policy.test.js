import { fleetSettings } from '../src/modules/optimization/services/fleetPolicy.js';
test('new crews preserve standard dispatch and require explicit sweeper capability',()=>{
  expect(fleetSettings({name:'Crew'},true)).toMatchObject({supports_standard:true,supports_sweeper:false,speed_factor:1});
});
test.each([{supports_sweeper:'true'},{speed_factor:0},{service_time_factor:Infinity},{max_tasks_per_shift:2.2},{shift_start:'25:00'}])('reject invalid fleet settings %o',input=>{
  expect(()=>fleetSettings(input)).toThrow();
});
test('fleet updates cannot smuggle assignment members or identity',()=>{
  expect(fleetSettings({supports_sweeper:true,member_profile_ids:['foreign'],id:'foreign'})).toEqual({supports_sweeper:true});
});
test('measured capacity and starting load are accepted, but overfilled trucks are rejected',()=>{
  const measured = {load_measured_at:'2026-10-08T08:00:00Z'};
  expect(fleetSettings({max_volume_m3:5,max_weight_kg:800,starting_volume_m3:1,starting_weight_kg:100,...measured}))
    .toMatchObject({max_volume_m3:5,starting_volume_m3:1});
  expect(()=>fleetSettings({max_volume_m3:2,starting_volume_m3:3,...measured})).toThrow('exceeds capacity');
  expect(()=>fleetSettings({starting_volume_m3:1})).toThrow('measurement time');
  expect(()=>fleetSettings({starting_weight_kg:-1})).toThrow('Invalid starting_weight_kg');
});
test('a new hazmat unit has no dispatch capability until explicitly certified',()=>{
  expect(fleetSettings({name:'Hazmat',vehicle_type:'hazmat_unit'},true))
    .toMatchObject({supports_standard:false,supports_sweeper:false,hazmat_certified:false});
});
