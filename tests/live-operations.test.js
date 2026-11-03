import {jest} from '@jest/globals';
const abortSignal=jest.fn(),rpc=jest.fn(()=>({abortSignal}));
jest.unstable_mockModule('../src/config/supabase.config.js',()=>({supabaseAdmin:{rpc}}));
const {getLiveOperations,postCrewPresence}=await import('../src/controllers/live-operations.controller.js');
const res=()=>({set:jest.fn(),status:jest.fn().mockReturnThis(),json:jest.fn()});
beforeEach(()=>jest.clearAllMocks());
test.each(['citizen','field_crew'])('feed refuses %s',async role=>{const s=res();await getLiveOperations({user:{id:'user',role},query:{}},s);expect(s.status).toHaveBeenCalledWith(403);expect(rpc).not.toHaveBeenCalled()});
test.each(['citizen','officer','admin'])('heartbeat refuses %s',async role=>{const s=res();await postCrewPresence({user:{id:'user',role}},s);expect(s.status).toHaveBeenCalledWith(403);expect(rpc).not.toHaveBeenCalled()});
test.each([{before_id:'0'},{before_id:'9223372036854775808'},{before_id:['1']},{limit:'101'}])('invalid feed page %j',async query=>{const s=res();await getLiveOperations({user:{id:'desk',role:'officer'},query},s);expect(s.status).toHaveBeenCalledWith(400);expect(rpc).not.toHaveBeenCalled()});
test('feed binds the desk actor, preserves bigint cursor and fails closed',async()=>{
 const s=res();abortSignal.mockResolvedValueOnce({data:{version:'live-operations-v1',events:[],crews:[]}});
 await getLiveOperations({user:{id:'desk',role:'officer'},query:{before_id:'9007199254740993',actor:'forged'}},s);
 expect(rpc).toHaveBeenCalledWith('read_live_operations',{actor:'desk',before_id:'9007199254740993',page_limit:20});
 expect(s.set).toHaveBeenCalledWith('Cache-Control','private, no-store');
 abortSignal.mockResolvedValueOnce({error:{code:'PGRST202'}});await getLiveOperations({user:{id:'desk',role:'admin'},query:{}},s);expect(s.status).toHaveBeenCalledWith(503);
});
test('heartbeat ignores supplied identity and clock and uses only the crew session',async()=>{
 const s=res();abortSignal.mockResolvedValueOnce({data:{seen_at:'2026-10-30T04:00:00Z'}});
 await postCrewPresence({user:{id:'crew',role:'field_crew'},body:{actor:'forged',seen_at:'2099-01-01'}},s);
 expect(rpc).toHaveBeenCalledWith('touch_crew_presence',{actor:'crew'});
 abortSignal.mockResolvedValueOnce({error:{code:'42501'}});await postCrewPresence({user:{id:'crew',role:'field_crew'}},s);expect(s.status).toHaveBeenCalledWith(403);
});
