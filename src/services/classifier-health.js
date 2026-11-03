// Classifier health probe that tells a cold start from an outage.
// Production uses an AWS container Lambda (3 GB, no provisioned concurrency). After idle time its first request pays a model load: the 10 s init
// limit is exceeded and initialisation is repeated inside the first invocation, so the first answer takes about 18-20 s (up to ~80 s in a burst of
// concurrent cold starts on 2 Nov 2026) while warm answers take 0.2-0.4 s. A 5 s probe therefore reported "unavailable" for one or two probes after
// every idle period and then recovered by itself, and the probe itself started the cold start.
//
// A probe that gets no answer within its budget is "warming" while that stays plausible; it becomes "unavailable" once it has persisted past the
// observed cold-start range. Connection failures and error responses are unavailable immediately. Reachability and warmth are reported separately
// from correct inference output, which only a real classification can show (see docs/classifier-health.md).
export const PROBE_TIMEOUT_MS=5000;
export const WARMING_LIMIT_MS=90000;      // longer than the slowest cold start seen (79 s), shorter than the 120 s function timeout
export const WARMING_MAX_TIMEOUTS=6;      // at 5-10 s probe spacing this is roughly the same window

export function createClassifierProbe({fetchImpl=fetch,now=Date.now,timeoutMs=PROBE_TIMEOUT_MS,warmingLimitMs=WARMING_LIMIT_MS,maxTimeouts=WARMING_MAX_TIMEOUTS}={}){
 let firstTimeoutAt=null,consecutiveTimeouts=0,lastOk=null;
 const snapshot=(outcome,latency_ms,detail)=>({outcome,latency_ms,consecutive_timeouts:consecutiveTimeouts,last_ok_at:lastOk,...(detail?{detail}:{})});
 return async function probe(url){
  if(!url)return snapshot('not_configured',null);
  const started=now();
  const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),timeoutMs);
  try{
   const response=await fetchImpl(url,{signal:controller.signal});
   const latency=now()-started;
   if(response?.ok){firstTimeoutAt=null;consecutiveTimeouts=0;lastOk=new Date(now()).toISOString();return snapshot('available',latency);}
   // The service answered, so it is not cold: an error answer is an outage of the service itself.
   firstTimeoutAt=null;consecutiveTimeouts=0;
   return snapshot('unavailable',latency,`http_${Number.isInteger(response?.status)?response.status:'unknown'}`);
  }catch(error){
   const latency=now()-started,timedOut=controller.signal.aborted||error?.name==='AbortError'||error?.name==='TimeoutError';
   if(!timedOut){firstTimeoutAt=null;consecutiveTimeouts=0;return snapshot('unavailable',latency,'connection_failed');}
   consecutiveTimeouts+=1;if(firstTimeoutAt===null)firstTimeoutAt=started;
   const stillPlausible=consecutiveTimeouts<=maxTimeouts&&now()-firstTimeoutAt<=warmingLimitMs;
   return snapshot(stillPlausible?'warming':'unavailable',latency,stillPlausible?'no_answer_within_budget':'no_answer_beyond_cold_start_range');
  }finally{clearTimeout(timer);}
 };
}
// Mapping to the existing /health fields: warming keeps the overall status OK (the dependency recovers by itself and requests still succeed, only slower).
export function dependencyFor(outcome){return outcome==='available'?'available':outcome==='warming'?'warming':outcome==='not_configured'?'not_configured':'unavailable';}
export const degradesHealth=outcome=>outcome==='unavailable';
