import {jest} from '@jest/globals';
const abortSignal=jest.fn(),rpc=jest.fn(()=>({abortSignal}));
jest.unstable_mockModule('../src/config/supabase.config.js',()=>({supabaseAdmin:{rpc}}));
const {getFieldCrewOperationsSummary,parseOperationsDays}=await import('../src/controllers/field-crew-operations.controller.js');
const now=new Date('2026-11-03T02:00:00Z'); // 10:00 on 3 November in Manila
const response=()=>({status:jest.fn().mockReturnThis(),json:jest.fn(),set:jest.fn()});
const good=()=>({version:'crew-operations-v1',tasks:[],assignments:[],waypoints:[],verified:[],obstacles:[]});
const run=async(query,user={id:'officer',role:'officer'})=>{const res=response();await getFieldCrewOperationsSummary({query,user},res);return res;};
beforeEach(()=>{jest.clearAllMocks();abortSignal.mockResolvedValue({data:good(),error:null});});

test('dates default to today in Manila time, not UTC',()=>{
 expect(parseOperationsDays({},new Date('2026-11-02T17:00:00Z'))).toEqual({start_day:'2026-11-03',end_day:'2026-11-03'});
 expect(parseOperationsDays({from:'2026-11-01'},now)).toEqual({start_day:'2026-11-01',end_day:'2026-11-01'});
 expect(parseOperationsDays({from:'2026-10-01',through:'2026-11-03'},now)).toEqual({start_day:'2026-10-01',end_day:'2026-11-03'});
});
test.each([[{from:'2026-11-04'}],[{from:'2026-11-03',through:'2026-11-02'}],[{from:'2026-02-30'}],[{from:'nope'}],[{from:'2026-1-1'}],[{from:['2026-11-01','2026-11-02']}],
 [{from:'2025-10-01',through:'2026-11-03'}],[{from:'1999-01-01',through:'2000-01-02'}]])('invalid or oversized range is refused: %j',query=>{
 expect(()=>parseOperationsDays(query,now)).toThrow(/valid Manila calendar days/);
});
test('a full 366-day inclusive range is the largest accepted',()=>{
 expect(()=>parseOperationsDays({from:'2025-11-03',through:'2026-11-03'},now)).not.toThrow();
});
test.each(['citizen','field_crew',undefined])('role %s is refused before any read',async role=>{
 const res=await run({},role?{id:'u',role}:null);expect(res.status).toHaveBeenCalledWith(403);expect(rpc).not.toHaveBeenCalled();
});
test('a bad period is a 400 with no read',async()=>{
 const res=await run({from:'2999-01-01'});expect(res.status).toHaveBeenCalledWith(400);expect(rpc).not.toHaveBeenCalled();
});
test.each(['officer','admin'])('%s reads through their own actor, private no-store',async role=>{
 const res=await run({from:'2026-11-01',through:'2026-11-01'},{id:'actor-'+role,role});
 expect(rpc).toHaveBeenCalledWith('get_field_crew_operations_summary',{actor:'actor-'+role,start_day:'2026-11-01',end_day:'2026-11-01'});
 expect(res.set).toHaveBeenCalledWith('Cache-Control','private, no-store');expect(res.json).toHaveBeenCalledWith(good());
});
test.each([[{code:'42501'},403],[{code:'54000'},422],[{code:'PGRST202'},503]])('storage error %j is %i without data',async(error,status)=>{
 abortSignal.mockResolvedValueOnce({data:null,error});const res=await run({from:'2026-11-01'});
 expect(res.status).toHaveBeenCalledWith(status);expect(res.json).toHaveBeenCalledWith(expect.objectContaining({error:expect.any(String)}));
});
test('an oversized period says no partial export was produced',async()=>{
 abortSignal.mockResolvedValueOnce({data:null,error:{code:'54000'}});const res=await run({from:'2026-11-01'});
 expect(res.json.mock.calls[0][0].error).toMatch(/no partial export/i);
});
test.each([[{}],[{...good(),version:'old'}],[{...good(),obstacles:null}],[null]])('an incomplete result is an error, not data: %j',async data=>{
 abortSignal.mockResolvedValueOnce({data,error:null});const res=await run({from:'2026-11-01'});
 expect(res.status).toHaveBeenCalledWith(503);expect(res.json).toHaveBeenCalledWith(expect.objectContaining({error:expect.stringMatching(/incomplete/)}));
});
test('a read timeout is a retryable 503',async()=>{
 abortSignal.mockRejectedValueOnce(new Error('timeout'));const res=await run({from:'2026-11-01'});expect(res.status).toHaveBeenCalledWith(503);
});
