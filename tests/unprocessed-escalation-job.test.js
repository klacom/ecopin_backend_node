import {jest} from '@jest/globals';
jest.unstable_mockModule('../src/config/supabase.config.js',()=>({supabaseAdmin:{rpc:jest.fn()}}));
const {startUnprocessedSchedule,stopUnprocessedSchedule,getUnprocessedScheduleStatus}=await import('../src/jobs/unprocessed-escalation.js');
const logger=()=>({info:jest.fn(),error:jest.fn()});
function fake(){const stop=jest.fn(),handlers=[];
 return {stop,handlers,validate:jest.fn(expr=>typeof expr==='string'&&expr.trim().split(/\s+/).length===5),
  schedule:jest.fn((expr,fn,opts)=>{handlers.push(fn);return {stop};})};}
const rpcOf=result=>{const abortSignal=jest.fn().mockResolvedValue(result);return {db:{rpc:jest.fn(()=>({abortSignal}))},abortSignal};};
const on={UNPROCESSED_ESCALATION_ENABLED:'true'};
beforeEach(()=>stopUnprocessedSchedule());

test.each([[{}],[{UNPROCESSED_ESCALATION_ENABLED:'false'}],[{UNPROCESSED_ESCALATION_ENABLED:'TRUE'}],[{UNPROCESSED_ESCALATION_ENABLED:'1'}]])('only the exact opt-in flag registers the job: %j',env=>{
 const s=fake(),log=logger();expect(startUnprocessedSchedule({env,scheduler:s,db:{},logger:log})).toBeNull();
 expect(s.schedule).not.toHaveBeenCalled();expect(getUnprocessedScheduleStatus().enabled).toBe(false);expect(getUnprocessedScheduleStatus().registered_at).toBeNull();
});
test('registration uses the default 15-minute Manila schedule and is visible in the status',()=>{
 const s=fake(),log=logger();startUnprocessedSchedule({env:on,scheduler:s,db:{},logger:log});
 expect(s.schedule).toHaveBeenCalledWith('*/15 * * * *',expect.any(Function),{timezone:'Asia/Manila'});
 const status=getUnprocessedScheduleStatus();expect(status.enabled).toBe(true);expect(Date.parse(status.registered_at)).not.toBeNaN();
 expect(status.last_run_at).toBeNull();expect(status.last_outcome).toBeNull();expect(log.info).toHaveBeenCalledWith('[UnprocessedEscalation] registered',expect.any(Object));
});
test('a configured schedule is used and an invalid one fails startup instead of silently not running',()=>{
 const s=fake();startUnprocessedSchedule({env:{...on,UNPROCESSED_ESCALATION_CRON:'*/5 * * * *'},scheduler:s,db:{},logger:logger()});expect(s.schedule.mock.calls[0][0]).toBe('*/5 * * * *');
 stopUnprocessedSchedule();expect(()=>startUnprocessedSchedule({env:{...on,UNPROCESSED_ESCALATION_CRON:'not a cron'},scheduler:fake(),db:{},logger:logger()})).toThrow('Invalid UNPROCESSED_ESCALATION_CRON');
 expect(getUnprocessedScheduleStatus().enabled).toBe(false);
});
test('starting twice in one process registers once',()=>{
 const s=fake();const a=startUnprocessedSchedule({env:on,scheduler:s,db:{},logger:logger()}),b=startUnprocessedSchedule({env:on,scheduler:s,db:{},logger:logger()});
 expect(a).toBe(b);expect(s.schedule).toHaveBeenCalledTimes(1);
});
test('an eligible run records its counts and calls only the database function',async()=>{
 const s=fake(),{db,abortSignal}=rpcOf({data:{reports_checked:3,notifications_created:9},error:null});startUnprocessedSchedule({env:on,scheduler:s,db,logger:logger()});
 await s.handlers[0]();expect(db.rpc).toHaveBeenCalledWith('escalate_unprocessed_reports');expect(abortSignal).toHaveBeenCalledTimes(1);
 expect(getUnprocessedScheduleStatus()).toMatchObject({last_outcome:'ok',last_reports_checked:3,last_notifications_created:9,consecutive_failures:0});
 expect(Date.parse(getUnprocessedScheduleStatus().last_run_at)).not.toBeNaN();expect(getUnprocessedScheduleStatus().last_duration_ms).toBeGreaterThanOrEqual(0);
});
test('an ineligible run (nothing to notify) is a successful zero-count run',async()=>{
 const s=fake(),{db}=rpcOf({data:{reports_checked:0,notifications_created:0},error:null});startUnprocessedSchedule({env:on,scheduler:s,db,logger:logger()});
 await s.handlers[0]();expect(getUnprocessedScheduleStatus()).toMatchObject({last_outcome:'ok',last_reports_checked:0,last_notifications_created:0});
});
test.each([[{data:null,error:{code:'PGRST202'}}],[{data:{reports_checked:-1,notifications_created:0},error:null}],[{data:{reports_checked:501,notifications_created:0},error:null}],
 [{data:{reports_checked:1.5,notifications_created:0},error:null}],[{data:{notifications_created:1},error:null}],[{data:null,error:null}]])('a database error or implausible answer is a failed run, not a success: %j',async result=>{
 const s=fake(),{db}=rpcOf(result),log=logger();startUnprocessedSchedule({env:on,scheduler:s,db,logger:log});await s.handlers[0]();
 expect(getUnprocessedScheduleStatus()).toMatchObject({last_outcome:'failed',last_reports_checked:null,last_notifications_created:null,consecutive_failures:1});expect(log.error).toHaveBeenCalled();
});
test('a failed run is retried on the next tick and recovery resets the failure count',async()=>{
 const s=fake(),abortSignal=jest.fn().mockRejectedValueOnce(new Error('timeout')).mockRejectedValueOnce(new Error('timeout')).mockResolvedValueOnce({data:{reports_checked:1,notifications_created:3},error:null});
 const db={rpc:jest.fn(()=>({abortSignal}))};startUnprocessedSchedule({env:on,scheduler:s,db,logger:logger()});
 await s.handlers[0]();await s.handlers[0]();expect(getUnprocessedScheduleStatus().consecutive_failures).toBe(2);
 await s.handlers[0]();expect(getUnprocessedScheduleStatus()).toMatchObject({last_outcome:'ok',consecutive_failures:0,last_notifications_created:3});expect(db.rpc).toHaveBeenCalledTimes(3);
});
test('overlapping ticks in one process do not start a competing run and are counted',async()=>{
 const s=fake();let release;const abortSignal=jest.fn(()=>new Promise(resolve=>{release=()=>resolve({data:{reports_checked:1,notifications_created:2},error:null});}));
 const db={rpc:jest.fn(()=>({abortSignal}))};startUnprocessedSchedule({env:on,scheduler:s,db,logger:logger()});
 const first=s.handlers[0](),second=s.handlers[0](),third=s.handlers[0]();await second;await third;
 expect(db.rpc).toHaveBeenCalledTimes(1);expect(getUnprocessedScheduleStatus().skipped_overlaps).toBe(2);
 release();await first;expect(getUnprocessedScheduleStatus().last_outcome).toBe('ok');
 abortSignal.mockResolvedValueOnce({data:{reports_checked:0,notifications_created:0},error:null});await s.handlers[0]();expect(db.rpc).toHaveBeenCalledTimes(2);
});
test('shutdown stops the schedule, clears the status and allows a clean restart',async()=>{
 const s=fake(),{db}=rpcOf({data:{reports_checked:1,notifications_created:1},error:null});startUnprocessedSchedule({env:on,scheduler:s,db,logger:logger()});await s.handlers[0]();
 stopUnprocessedSchedule();expect(s.stop).toHaveBeenCalledTimes(1);
 expect(getUnprocessedScheduleStatus()).toEqual({enabled:false,registered_at:null,last_run_at:null,last_outcome:null,last_reports_checked:null,last_notifications_created:null,last_duration_ms:null,consecutive_failures:0,skipped_overlaps:0});
 startUnprocessedSchedule({env:on,scheduler:s,db,logger:logger()});expect(s.schedule).toHaveBeenCalledTimes(2);
});
test('stopping when never started is harmless',()=>{expect(()=>stopUnprocessedSchedule()).not.toThrow();});
test('the published status holds no configuration values',()=>{
 const s=fake();startUnprocessedSchedule({env:{...on,UNPROCESSED_ESCALATION_CRON:'*/7 * * * *',SUPABASE_SECRET_KEY:'secret-value'},scheduler:s,db:{},logger:logger()});
 const text=JSON.stringify(getUnprocessedScheduleStatus());expect(text).not.toContain('secret-value');expect(text).not.toContain('*/7');
});
