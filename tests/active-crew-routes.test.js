import {jest} from '@jest/globals';
import {readActiveCrewRoutes} from '../src/modules/optimization/services/activeCrewRoutes.service.js';
function fixture(error=null) {
 const routes=[{id:'old-alpha',crew_id:'alpha',optimization_run_id:'old-run',optimization_runs:{status:'approved'},cleanup_tasks:[{}]},
 {id:'other-alpha',crew_id:'alpha',optimization_run_id:'another-run'}];
 const query={select:jest.fn().mockReturnThis(),eq:jest.fn().mockReturnThis(),not:jest.fn().mockReturnThis(),in:jest.fn().mockReturnThis(),
 then:(resolve)=>resolve({data:routes,error})};
 const waypointQuery={select:jest.fn().mockReturnThis(),in:jest.fn().mockReturnThis(),order:jest.fn().mockResolvedValue({data:[{crew_route_id:'old-alpha',sequence_order:0},{crew_route_id:'other-alpha',sequence_order:0}],error:null})};
 const db={from:jest.fn(table=>table==='crew_routes'?query:waypointQuery)};
 return {db,query};
}
test('unfinished routes across approved runs are scoped to the crew, with batch waypoints',async()=>{
 const {db,query}=fixture();const routes=await readActiveCrewRoutes(db,['alpha']);
 expect(query.in).toHaveBeenCalledWith('crew_id',['alpha']);
 expect(query.eq).toHaveBeenCalledWith('optimization_runs.status','approved');
 expect(query.not).toHaveBeenCalledWith('cleanup_tasks.status','in','(completed,cancelled)');
 expect(db.from.mock.calls.map(c=>c[0])).toEqual(['crew_routes','route_waypoints']);
 expect(routes.map(r=>r.optimization_run_id)).toEqual(['old-run','another-run']);
 expect(routes[0].waypoints).toEqual([{crew_route_id:'old-alpha',sequence_order:0}]);
 expect(routes[0].cleanup_tasks).toBeUndefined();
});
test('users with no crew membership receive no routes or database reads',async()=>{
 const {db}=fixture();expect(await readActiveCrewRoutes(db,[])).toEqual([]);expect(db.from).not.toHaveBeenCalled();
});
test('query failures propagate instead of claiming there is no active route',async()=>{
 const error=new Error('unavailable');const {db}=fixture(error);
 await expect(readActiveCrewRoutes(db,['alpha'])).rejects.toBe(error);
});
