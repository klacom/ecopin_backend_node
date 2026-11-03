import {jest} from "@jest/globals";
import {createClassifierProbe,dependencyFor,degradesHealth,PROBE_TIMEOUT_MS,WARMING_LIMIT_MS} from '../src/services/classifier-health.js';

// A controllable clock and a fetch that either answers or never does until its signal aborts (the cold-start shape).
function harness({answers=[]}={}){
 let t=1_700_000_000_000;const clock={now:()=>t,advance:ms=>{t+=ms;}};
 const queue=[...answers];
 const fetchImpl=jest.fn((url,{signal})=>{
  const next=queue.shift();
  if(next==='hang')return new Promise((_,reject)=>signal.addEventListener('abort',()=>reject(Object.assign(new Error('aborted'),{name:'AbortError'}))));
  if(next instanceof Error)return Promise.reject(next);
  return Promise.resolve(next);
 });
 return {clock,fetchImpl,queue};
}
const ok=()=>({ok:true,status:200}),http=status=>({ok:false,status});
beforeEach(()=>jest.useFakeTimers());
afterEach(()=>jest.useRealTimers());
async function run(probe,url,h,advance=0){const p=probe(url);if(advance){h.clock.advance(advance);await jest.advanceTimersByTimeAsync(advance);}return p;}

test('an unconfigured classifier is reported as such, without any request',async()=>{
 const h=harness();const probe=createClassifierProbe({fetchImpl:h.fetchImpl,now:h.clock.now});
 expect(await probe(undefined)).toMatchObject({outcome:'not_configured'});expect(h.fetchImpl).not.toHaveBeenCalled();
});
test('an answer within the budget is available and records its time',async()=>{
 const h=harness({answers:[ok()]});const probe=createClassifierProbe({fetchImpl:h.fetchImpl,now:h.clock.now});
 const r=await probe('https://classifier.example.invalid/classify');
 expect(r).toMatchObject({outcome:'available',consecutive_timeouts:0});expect(typeof r.last_ok_at).toBe('string');expect(dependencyFor(r.outcome)).toBe('available');expect(degradesHealth(r.outcome)).toBe(false);
});
test('no answer within the budget is a cold start (warming) and does not degrade health',async()=>{
 const h=harness({answers:['hang']});const probe=createClassifierProbe({fetchImpl:h.fetchImpl,now:h.clock.now});
 const r=await run(probe,'https://classifier.example.invalid/classify',h,PROBE_TIMEOUT_MS);
 expect(r).toMatchObject({outcome:'warming',consecutive_timeouts:1,detail:'no_answer_within_budget'});
 expect(dependencyFor(r.outcome)).toBe('warming');expect(degradesHealth(r.outcome)).toBe(false);
});
test('the observed pattern - two timed-out probes, then an answer - never reports an outage and then recovers',async()=>{
 const h=harness({answers:['hang','hang',ok(),ok()]});const probe=createClassifierProbe({fetchImpl:h.fetchImpl,now:h.clock.now});
 const outcomes=[];
 for(let i=0;i<2;i++){outcomes.push((await run(probe,'u',h,PROBE_TIMEOUT_MS)).outcome);h.clock.advance(5000);}
 outcomes.push((await probe('u')).outcome);outcomes.push((await probe('u')).outcome);
 expect(outcomes).toEqual(['warming','warming','available','available']);
});
test('a recovery resets the warming window',async()=>{
 const h=harness({answers:['hang',ok(),'hang']});const probe=createClassifierProbe({fetchImpl:h.fetchImpl,now:h.clock.now});
 await run(probe,'u',h,PROBE_TIMEOUT_MS);await probe('u');
 const r=await run(probe,'u',h,PROBE_TIMEOUT_MS);expect(r).toMatchObject({outcome:'warming',consecutive_timeouts:1});
});
test('silence that outlasts the longest observed cold start becomes an outage',async()=>{
 const h=harness({answers:Array(20).fill('hang')});const probe=createClassifierProbe({fetchImpl:h.fetchImpl,now:h.clock.now});
 let last,elapsed=0;
 while(elapsed<WARMING_LIMIT_MS+30000){last=await run(probe,'u',h,PROBE_TIMEOUT_MS);h.clock.advance(10000);elapsed+=PROBE_TIMEOUT_MS+10000;if(last.outcome==='unavailable')break;}
 expect(last).toMatchObject({outcome:'unavailable',detail:'no_answer_beyond_cold_start_range'});expect(degradesHealth(last.outcome)).toBe(true);
 expect(elapsed).toBeGreaterThan(60000);expect(elapsed).toBeLessThanOrEqual(WARMING_LIMIT_MS+30000);
});
test('too many consecutive silent probes also end the warming allowance',async()=>{
 const h=harness({answers:Array(10).fill('hang')});const probe=createClassifierProbe({fetchImpl:h.fetchImpl,now:h.clock.now,maxTimeouts:2,warmingLimitMs:10**9});
 const seen=[];for(let i=0;i<4;i++)seen.push((await run(probe,'u',h,PROBE_TIMEOUT_MS)).outcome);
 expect(seen).toEqual(['warming','warming','unavailable','unavailable']);
});
test.each([[500],[502],[503],[404]])('an error answer (HTTP %i) is an outage at once: the service is reachable but not serving',async status=>{
 const h=harness({answers:[http(status)]});const probe=createClassifierProbe({fetchImpl:h.fetchImpl,now:h.clock.now});
 const r=await probe('u');expect(r).toMatchObject({outcome:'unavailable',detail:`http_${status}`});expect(degradesHealth(r.outcome)).toBe(true);
});
test('a refused or unresolvable connection is an outage at once, not a cold start',async()=>{
 const h=harness({answers:[Object.assign(new TypeError('fetch failed'),{cause:{code:'ECONNREFUSED'}})]});const probe=createClassifierProbe({fetchImpl:h.fetchImpl,now:h.clock.now});
 const r=await probe('u');expect(r).toMatchObject({outcome:'unavailable',detail:'connection_failed',consecutive_timeouts:0});
});
test('an error answer in the middle of a warming window ends it',async()=>{
 const h=harness({answers:['hang',http(503),'hang']});const probe=createClassifierProbe({fetchImpl:h.fetchImpl,now:h.clock.now});
 await run(probe,'u',h,PROBE_TIMEOUT_MS);expect((await probe('u')).outcome).toBe('unavailable');
 expect((await run(probe,'u',h,PROBE_TIMEOUT_MS))).toMatchObject({outcome:'warming',consecutive_timeouts:1});
});
test('the snapshot carries no URL or response body',async()=>{
 const h=harness({answers:[http(500)]});const probe=createClassifierProbe({fetchImpl:h.fetchImpl,now:h.clock.now});
 const text=JSON.stringify(await probe('https://secret-gateway.example.invalid/prod/classify?key=abc'));
 expect(text).not.toContain('secret-gateway');expect(text).not.toContain('abc');
});
test('the probe budget is shorter than the observed cold start and the warming allowance longer than the slowest one',()=>{
 expect(PROBE_TIMEOUT_MS).toBeLessThan(18000);expect(WARMING_LIMIT_MS).toBeGreaterThan(79000);
});
