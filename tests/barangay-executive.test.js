import {jest} from '@jest/globals';
const abortSignal=jest.fn(),rpc=jest.fn(()=>({abortSignal}));
jest.unstable_mockModule('../src/config/supabase.config.js',()=>({supabaseAdmin:{rpc}}));
const {getBarangayExecutive}=await import('../src/controllers/barangay-executive.controller.js');
const req=()=>({user:{id:'officer',role:'officer'},query:{month:'2026-09',actor:'forged'}});
const res=()=>({set:jest.fn(),status:jest.fn().mockReturnThis(),json:jest.fn()});
beforeEach(()=>jest.clearAllMocks());
test.each([undefined,'invalid','2099-01',['2026-09']])('requires one valid nonfuture month: %j',async month=>{const r=req();r.query.month=month;const s=res();await getBarangayExecutive(r,s);expect(s.status).toHaveBeenCalledWith(400);expect(rpc).not.toHaveBeenCalled();});
test.each(['citizen','field_crew'])('denies %s before reading',async role=>{const r=req();r.user.role=role;const s=res();await getBarangayExecutive(r,s);expect(s.status).toHaveBeenCalledWith(403);expect(rpc).not.toHaveBeenCalled();});
test('uses authenticated actor and an unavailable state rather than partial analytics',async()=>{
 const s=res();abortSignal.mockResolvedValueOnce({data:{version:'barangay-executive-v1',monthly:{},comparison:{}}});await getBarangayExecutive(req(),s);expect(rpc).toHaveBeenCalledWith('get_barangay_executive_analytics',{actor:'officer',report_month:'2026-09-01'});expect(s.set).toHaveBeenCalledWith('Cache-Control','private, no-store');
 abortSignal.mockResolvedValueOnce({error:{code:'PGRST202'}});await getBarangayExecutive(req(),s);expect(s.status).toHaveBeenCalledWith(503);
});
