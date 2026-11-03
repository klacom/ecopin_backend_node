import {jest,beforeEach,test,expect} from '@jest/globals';
const rpc=jest.fn();jest.unstable_mockModule('../src/config/supabase.config.js',()=>({supabaseAdmin:{rpc}}));
const {getBarangayAnalytics,parseAnalyticsMonths}=await import('../src/controllers/barangay-analytics.controller.js');
const res=()=>({status:jest.fn().mockReturnThis(),json:jest.fn().mockReturnThis(),set:jest.fn().mockReturnThis()});
beforeEach(()=>rpc.mockReset());
test('month defaults follow Manila rather than the host calendar date',()=>{
 expect(parseAnalyticsMonths({},new Date('2026-09-30T16:01:00Z'))).toEqual({start_month:'2026-05-01',end_month:'2026-10-01'});
});
test.each([{startMonth:'2026-13'},{startMonth:['2026-01']},{startMonth:'2024-01',endMonth:'2026-10'},{startMonth:'2026-11',endMonth:'2026-10'},{endMonth:'2099-01'}])('rejects invalid ranges %j',(q)=>{
 expect(()=>parseAnalyticsMonths(q,new Date('2026-10-29'))).toThrow();
});
test('calls aggregate RPC only with verified actor and sanitized dates',async()=>{
 rpc.mockReturnValue({abortSignal:()=>Promise.resolve({data:{groups:Array(31).fill({}),total:{}}})});
 const response=res();await getBarangayAnalytics({user:{id:'staff',role:'officer'},query:{startMonth:'2026-01',endMonth:'2026-03',actor:'forged'}},response);
 expect(rpc).toHaveBeenCalledWith('get_barangay_operational_analytics',{actor:'staff',start_month:'2026-01-01',end_month:'2026-03-01'});
 expect(response.set).toHaveBeenCalledWith('Cache-Control','no-store');expect(response.json).toHaveBeenCalled();
});
test.each([undefined,'citizen','field_crew'])('denies non-staff %s before querying',async(role)=>{
 const response=res();await getBarangayAnalytics({user:{id:'user',role},query:{}},response);
 expect(response.status).toHaveBeenCalledWith(403);expect(rpc).not.toHaveBeenCalled();
});
test('missing database migration is an explicit unavailable result, not empty analytics',async()=>{
 rpc.mockReturnValue({abortSignal:()=>Promise.resolve({error:{code:'PGRST202'}})});
 const response=res();await getBarangayAnalytics({user:{id:'staff',role:'admin'},query:{}},response);
 expect(response.status).toHaveBeenCalledWith(503);
});
