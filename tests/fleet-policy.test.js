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
