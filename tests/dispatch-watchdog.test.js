import { jest } from '@jest/globals';
jest.unstable_mockModule('../src/config/supabase.config.js',()=>({supabaseAdmin:{rpc:jest.fn()}}));
const {startDispatchWatchdog,stopDispatchWatchdog}=await import('../src/jobs/dispatch-watchdog.js');
afterEach(()=>stopDispatchWatchdog());
test('watchdog is opt-in and registers only once',()=>{
  const scheduler={schedule:jest.fn(()=>({stop:jest.fn()}))};
  expect(startDispatchWatchdog({env:{},scheduler})).toBeNull();
  startDispatchWatchdog({env:{REPORT_LIFECYCLE_ENABLED:'true'},scheduler,logger:{info:jest.fn()}});
  startDispatchWatchdog({env:{REPORT_LIFECYCLE_ENABLED:'true'},scheduler});
  expect(scheduler.schedule).toHaveBeenCalledTimes(1);
  expect(scheduler.schedule).toHaveBeenCalledWith('*/5 * * * *',expect.any(Function),{timezone:'Asia/Manila'});
});
test('database failure is visible and does not prevent the next recovery tick',async()=>{
  const scheduler={schedule:jest.fn(()=>({stop:jest.fn()}))};
  const client={rpc:jest.fn().mockResolvedValueOnce({error:{message:'offline'}}).mockResolvedValueOnce({data:{expiredCount:1}})};
  const logger={info:jest.fn(),error:jest.fn()};
  startDispatchWatchdog({env:{REPORT_LIFECYCLE_ENABLED:'true'},scheduler,client,logger});
  const tick=scheduler.schedule.mock.calls[0][1];await tick();await tick();
  expect(logger.error).toHaveBeenCalledWith('[DispatchWatchdog] failed',{error:'offline'});
  expect(logger.info).toHaveBeenCalledWith('[DispatchWatchdog] completed',{expiredCount:1});
});
