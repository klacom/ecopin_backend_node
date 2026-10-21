import {crewLoadIssues,requireCrewLoads} from '../src/modules/optimization/services/crewLoadReadiness.js';
const crew={id:'alpha',name:'Alpha',member_profile_ids:['member'],max_volume_m3:10,max_weight_kg:1000,starting_volume_m3:0,starting_weight_kg:0};
test('zero starting loads and measured empty tasks are valid',()=>{
 expect(crewLoadIssues([crew],[{assigned_field_crew_id:'alpha',status:'pending',estimated_volume_m3:0,estimated_weight_kg:0}])).toEqual([]);
});
test('missing busy loads are identified before scheduling without inserting fallback values',()=>{
 const task={status:'in_progress',assigned_crew_ids:['member'],estimated_volume_m3:null,estimated_weight_kg:null};
 const issues=crewLoadIssues([crew],[task]);expect(issues[0].missing_task_load_count).toBe(1);
 expect(issues[0].message).toContain('enter volume/weight estimates');
 expect(task.estimated_volume_m3).toBeNull();
 expect(()=>requireCrewLoads([crew],[task])).toThrow('Load information required');
});
test('terminal and other crews tasks do not block a ready crew',()=>{
 expect(crewLoadIssues([crew],[{status:'completed',assigned_field_crew_id:'alpha'},{status:'cancelled',assigned_field_crew_id:'alpha'},{status:'pending',assigned_field_crew_id:'bravo'}])).toEqual([]);
});
test.each([null,undefined,-1,NaN,Infinity])('invalid crew load settings are not replaced by vehicle guesses: %s',value=>{
 const issues=crewLoadIssues([{...crew,max_weight_kg:value}]);expect(issues[0].missing_capacity_fields).toContain('max_weight_kg');
});
