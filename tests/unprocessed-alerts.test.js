import {jest} from '@jest/globals';
const abortSignal=jest.fn(),rpc=jest.fn(()=>({abortSignal}));
jest.unstable_mockModule('../src/config/supabase.config.js',()=>({supabaseAdmin:{rpc}}));
const {getUnprocessedAlerts}=await import('../src/controllers/unprocessed-alerts.controller.js');
const request=()=>({user:{id:'desk-user',role:'officer'},query:{actor:'forged'}});
const response=()=>({set:jest.fn(),status:jest.fn().mockReturnThis(),json:jest.fn()});
beforeEach(()=>jest.clearAllMocks());
test.each(['citizen','field_crew'])('denies %s before reading alerts',async role=>{
 const req=request(),res=response();req.user.role=role;await getUnprocessedAlerts(req,res);expect(res.status).toHaveBeenCalledWith(403);expect(rpc).not.toHaveBeenCalled();
});
test.each([{limit:['20']},{limit:'101'},{cursorId:'bad'},{cursorCreated:'bad',cursorId:'00000000-0000-0000-0000-000000000001'}])('rejects invalid pagination %j',async query=>{
 const req=request(),res=response();req.query=query;await getUnprocessedAlerts(req,res);expect(res.status).toHaveBeenCalledWith(400);expect(rpc).not.toHaveBeenCalled();
});
test('binds the authenticated actor and fails closed when migrations are unavailable',async()=>{
 const res=response();abortSignal.mockResolvedValueOnce({data:{version:'unprocessed-alerts-v1',reports:[]}});
 await getUnprocessedAlerts(request(),res);expect(rpc).toHaveBeenCalledWith('read_unprocessed_report_alerts',{actor:'desk-user',cursor_created:null,cursor_id:null,page_limit:20});expect(res.set).toHaveBeenCalledWith('Cache-Control','private, no-store');
 abortSignal.mockResolvedValueOnce({error:{code:'PGRST202'}});await getUnprocessedAlerts(request(),res);expect(res.status).toHaveBeenCalledWith(503);
});
