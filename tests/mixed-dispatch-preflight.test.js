import {jest} from '@jest/globals';
const rpc=jest.fn();const from=jest.fn();
jest.unstable_mockModule('../src/config/supabase.config.js',()=>({supabaseAdmin:{rpc,from}}));
jest.unstable_mockModule('../src/modules/optimization/services/routeGenerator.service.js',()=>({generateRouteForCrew:jest.fn()}));
jest.unstable_mockModule('../src/modules/optimization/services/crewAssigner.service.js',()=>({assignTasksToCrews:jest.fn()}));
jest.unstable_mockModule('../src/modules/optimization/services/planDisassembly.service.js',()=>({disassemblePlan:jest.fn()}));
const {commitAndRoutePlan}=await import('../src/modules/optimization/services/dispatchCommit.service.js');
test('an old draft with incomplete active loads fails before committing claims or routing',async()=>{
 const crew={id:'alpha',name:'Alpha',max_volume_m3:10,max_weight_kg:1000,starting_volume_m3:0,starting_weight_kg:0};
 from.mockImplementation(table=>{
   const data=table==='dispatch_plans'?{mode:'mixed',settings_snapshot:{}}:
     table==='dispatch_plan_items'?[{planned_crew_id:'alpha'}]:
     table==='field_crews'?[crew]:[{assigned_field_crew_id:'alpha',status:'pending',estimated_volume_m3:null,estimated_weight_kg:null}];
   const q={select:jest.fn().mockReturnThis(),eq:jest.fn().mockReturnThis(),in:jest.fn().mockReturnThis(),not:jest.fn().mockReturnThis(),neq:jest.fn().mockReturnThis(),or:jest.fn().mockReturnThis(),single:jest.fn().mockResolvedValue({data,error:null}),then:resolve=>resolve({data,error:null,count:1})};return q;
 });
 await expect(commitAndRoutePlan('plan','officer')).rejects.toThrow('enter volume/weight estimates');
 expect(rpc).not.toHaveBeenCalled();
});
