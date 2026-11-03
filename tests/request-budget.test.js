import {jest} from '@jest/globals';
const abortSignal=jest.fn(),rpc=jest.fn(()=>({abortSignal}));
jest.unstable_mockModule('../src/config/supabase.config.js',()=>({supabaseAdmin:{rpc}}));
const budget=await import('../src/services/request-budget.js');
const executive=await import('../src/controllers/barangay-executive.controller.js');
const analytics=await import('../src/controllers/barangay-analytics.controller.js');
const alerts=await import('../src/controllers/unprocessed-alerts.controller.js');
const crew=await import('../src/controllers/field-crew-operations.controller.js');
const response=()=>({status:jest.fn().mockReturnThis(),json:jest.fn(),set:jest.fn()});
const staff={id:'staff',role:'officer'};
// Real shapes observed from the supabase client against the isolated database (T12 probe).
const TIMEOUT={code:'',message:'TimeoutError: The operation was aborted due to timeout'},ABORT={code:'',message:'AbortError: This operation was aborted'};
const MISSING={code:'PGRST202',message:'Could not find the function public.x without parameters in the schema cache'},DENIED={code:'42501',message:'Active staff access required'};
const calls={
 executive:(res)=>executive.getBarangayExecutive({user:staff,query:{month:'2026-10'}},res),
 analytics:(res)=>analytics.getBarangayAnalytics({user:staff,query:{startMonth:'2026-08',endMonth:'2026-10'}},res),
 alerts:(res)=>alerts.getUnprocessedAlerts({user:staff,query:{}},res),
 'crew-summary':(res)=>crew.getFieldCrewOperationsSummary({user:staff,query:{from:'2026-11-01'}},res),
};
let spy;
beforeEach(()=>{jest.clearAllMocks();spy=jest.spyOn(console,'warn').mockImplementation(()=>{});jest.spyOn(console,'error').mockImplementation(()=>{});});
afterEach(()=>jest.restoreAllMocks());

test('the interactive read budget is below the web proxy deadline with room for the response',()=>{
 expect(budget.INTERACTIVE_READ_BUDGET_MS).toBeLessThan(budget.WEB_PROXY_BUDGET_MS);
 expect(budget.WEB_PROXY_BUDGET_MS-budget.INTERACTIVE_READ_BUDGET_MS).toBeGreaterThanOrEqual(1000);
});
test.each([[TIMEOUT,'timeout'],[ABORT,'timeout'],[{code:'57014',message:'canceling statement due to statement timeout'},'timeout'],[Object.assign(new Error('x'),{name:'TimeoutError'}),'timeout'],
 [DENIED,'denied'],[MISSING,'missing_prerequisite'],[{code:'42P01'},'missing_prerequisite'],[{code:'P0002'},'not_found'],[{code:'PGRST116'},'not_found'],[{code:'22023'},'invalid_request'],
 [{code:'54000'},'too_large'],[{code:'XX000',message:'boom'},'unavailable'],[new Error('socket hang up'),'unavailable'],[undefined,'unavailable'],[null,'unavailable']])('failure %j is categorised as %s',(error,category)=>{
 expect(budget.classifyFailure(error)).toBe(category);
});
test.each(Object.keys(calls))('%s: the upstream read uses the shared budget, never the old 20 second deadline',async name=>{
 const used=[];jest.spyOn(AbortSignal,'timeout').mockImplementation(ms=>{used.push(ms);return new AbortController().signal;});
 abortSignal.mockResolvedValue({data:null,error:TIMEOUT});await calls[name](response());
 expect(used).toEqual([budget.INTERACTIVE_READ_BUDGET_MS]);expect(used[0]).toBeLessThan(budget.WEB_PROXY_BUDGET_MS);
});
test.each(Object.keys(calls))('%s: a delayed upstream is cut off by the budget and answered 504 as retryable, within the proxy deadline',async name=>{
 const controller=new AbortController();jest.spyOn(AbortSignal,'timeout').mockImplementation(()=>controller.signal);
 abortSignal.mockImplementation(signal=>new Promise(resolve=>signal.addEventListener('abort',()=>resolve({data:null,error:TIMEOUT}))));
 const res=response(),pending=calls[name](res);
 expect(res.status).not.toHaveBeenCalled(); // still waiting for the upstream
 controller.abort();await pending;
 expect(res.status).toHaveBeenCalledWith(504);expect(res.json).toHaveBeenCalledWith(expect.objectContaining({code:'timeout',retryable:true}));
});
test.each(Object.keys(calls))('%s: a thrown abort or network error is a controlled retryable failure',async name=>{
 abortSignal.mockRejectedValueOnce(Object.assign(new Error('The operation was aborted due to timeout'),{name:'TimeoutError'}));
 let res=response();await calls[name](res);expect(res.status).toHaveBeenCalledWith(504);
 abortSignal.mockRejectedValueOnce(new Error('fetch failed'));res=response();await calls[name](res);
 expect(res.status).toHaveBeenCalledWith(503);expect(res.json).toHaveBeenCalledWith(expect.objectContaining({code:'unavailable',retryable:true}));
});
test.each(Object.keys(calls))('%s: missing migration, denied access and incomplete data are distinct, with the right retry hint',async name=>{
 abortSignal.mockResolvedValueOnce({data:null,error:MISSING});let res=response();await calls[name](res);
 expect(res.status).toHaveBeenCalledWith(503);expect(res.json).toHaveBeenCalledWith(expect.objectContaining({code:'missing_prerequisite',retryable:false}));
 abortSignal.mockResolvedValueOnce({data:null,error:DENIED});res=response();await calls[name](res);
 expect(res.status).toHaveBeenCalledWith(403);expect(res.json).toHaveBeenCalledWith(expect.objectContaining({code:'denied',retryable:false}));
 abortSignal.mockResolvedValueOnce({data:{version:'wrong'},error:null});res=response();await calls[name](res);
 expect(res.status).toHaveBeenCalledWith(503);expect(res.json).toHaveBeenCalledWith(expect.objectContaining({code:'unavailable',retryable:true}));
});
test('failure logs carry the area, category and code only, never messages or row values',()=>{
 const res=response();
 budget.sendFailure(res,'executive',{code:'23514',message:'Failing row contains (secret-name, 555-0100)',details:'private payload'});
 const logged=JSON.stringify(spy.mock.calls);expect(logged).toContain('invalid_request');expect(logged).toContain('23514');
 for(const secret of ['secret-name','555-0100','private payload','Failing row'])expect(logged).not.toContain(secret);
 expect(JSON.stringify(res.json.mock.calls)).not.toContain('secret-name');
});
test('a code that is not a short SQLSTATE-style token is not logged',()=>{
 budget.sendFailure(response(),'alerts',{code:'a very long arbitrary text that could hold a secret'});
 expect(JSON.stringify(spy.mock.calls)).not.toContain('arbitrary');
});
test('successful reads are unchanged',async()=>{
 abortSignal.mockResolvedValueOnce({data:{version:'unprocessed-alerts-v1',reports:[]},error:null});const res=response();await calls.alerts(res);
 expect(res.json).toHaveBeenCalledWith({version:'unprocessed-alerts-v1',reports:[]});expect(res.status).not.toHaveBeenCalled();
});
