import {jest} from '@jest/globals';
const rpc=jest.fn();
jest.unstable_mockModule('../src/config/supabase.config.js',()=>({supabaseAdmin:{rpc}}));
const {getIncidentCaseRecord}=await import('../src/controllers/incident-case-record.controller.js');
const id='a0400000-0000-4000-8000-000000000003';
const record=(over={})=>({version:'case-record-v1',report:{id},events:[],activity:[],proof:null,...over});
const response=()=>({status:jest.fn().mockReturnThis(),json:jest.fn(),set:jest.fn()});
const run=async(req)=>{const res=response(),next=jest.fn();await getIncidentCaseRecord({params:{id},user:{id:'u',role:'officer'},...req},res,next);return {res,next};};
beforeEach(()=>jest.resetAllMocks());

test.each(['citizen','field_crew',undefined])('role %s is refused before any read',async role=>{
 const {res}=await run({user:role?{id:'u',role}:undefined});
 expect(res.status).toHaveBeenCalledWith(403);expect(rpc).not.toHaveBeenCalled();
});
test.each(['bad','','1234',"a0400000-0000-4000-8000-000000000003'--"])('invalid incident id %j is refused',async bad=>{
 const {res}=await run({params:{id:bad}});expect(res.status).toHaveBeenCalledWith(400);expect(rpc).not.toHaveBeenCalled();
});
test.each(['officer','admin'])('%s reads the snapshot bound to their own actor, uncached',async role=>{
 rpc.mockResolvedValueOnce({data:record(),error:null});
 const {res,next}=await run({user:{id:'actor-'+role,role}});
 expect(rpc).toHaveBeenCalledWith('read_incident_case_record',{actor:'actor-'+role,incident_id:id});
 expect(res.set).toHaveBeenCalledWith('Cache-Control','private, no-store');expect(res.json).toHaveBeenCalledWith(record());expect(next).not.toHaveBeenCalled();
});
test('an unknown incident is a 404',async()=>{
 rpc.mockResolvedValueOnce({data:null,error:null});const {res}=await run();expect(res.status).toHaveBeenCalledWith(404);
});
test.each([[{code:'42501'},403],[{code:'54000'},422],[{code:'PGRST202'},503],[{code:'57014'},503]])('storage error %j becomes %i through the error handler',async(error,status)=>{
 rpc.mockResolvedValueOnce({data:null,error});const {res,next}=await run();
 expect(res.json).not.toHaveBeenCalled();expect(next).toHaveBeenCalledWith(expect.objectContaining({statusCode:status}));
});
test('an oversized history is reported, never truncated into a partial record',async()=>{
 rpc.mockResolvedValueOnce({data:null,error:{code:'54000'}});const {next}=await run();
 expect(next.mock.calls[0][0].message).toMatch(/too large.*no partial record/i);
});
test.each([[record({version:'old'})],[record({report:{id:'other'}})],[record({events:null})],[record({activity:'x'})],[{}]])('an incomplete snapshot is an error, not a record: %j',async data=>{
 rpc.mockResolvedValueOnce({data,error:null});const {res,next}=await run();
 expect(res.json).not.toHaveBeenCalled();expect(next).toHaveBeenCalledWith(expect.objectContaining({statusCode:503}));
});
