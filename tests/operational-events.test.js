import {jest} from '@jest/globals';
const rpc=jest.fn();
jest.unstable_mockModule('../src/config/supabase.config.js',()=>({supabaseAdmin:{rpc}}));
const {getOperationalEvents}=await import('../src/controllers/operational-events.controller.js');
const response=()=>({status:jest.fn().mockReturnThis(),json:jest.fn(),set:jest.fn()});
beforeEach(()=>jest.clearAllMocks());
test.each([{task_id:'bad'},{report_id:['not','scalar']},{before_id:'0'},{before_id:'9223372036854775808'},{limit:'101'},{limit:'NaN'}])('invalid audit scope is rejected before querying: %j',async query=>{
 const res=response();await getOperationalEvents({query,user:{id:'officer'}},res,jest.fn());expect(res.status).toHaveBeenCalledWith(400);expect(rpc).not.toHaveBeenCalled();
});
test('timeline reads bind the actor and use a bigint-safe keyset cursor',async()=>{
 rpc.mockResolvedValueOnce({data:{events:[],has_more:false,next_cursor:null}});
 const res=response(),next=jest.fn();await getOperationalEvents({query:{before_id:'9007199254740993'},user:{id:'officer'}},res,next);
 expect(next).not.toHaveBeenCalled();expect(rpc).toHaveBeenCalledWith('read_operational_events',{actor:'officer',p_task_id:null,p_report_id:null,p_before_id:'9007199254740993',p_limit:50});
 expect(res.set).toHaveBeenCalledWith('Cache-Control','private, no-store');
});
test('unavailable audit storage is an error rather than a fabricated empty history',async()=>{
 rpc.mockResolvedValueOnce({error:{code:'PGRST202'}});const next=jest.fn(),res=response();await getOperationalEvents({query:{},user:{id:'officer'}},res,next);
 expect(res.json).not.toHaveBeenCalled();expect(next).toHaveBeenCalledWith(expect.objectContaining({statusCode:503}));
});
