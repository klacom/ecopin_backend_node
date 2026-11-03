import cron from 'node-cron';
import {supabaseAdmin} from '../config/supabase.config.js';
let task=null,running=false,lastRun=null,registeredAt=null,skippedOverlaps=0,consecutiveFailures=0,lastDurationMs=null;
const initialRun=()=>({at:null,outcome:null,reports_checked:null,notifications_created:null});
lastRun=initialRun();
export function startUnprocessedSchedule({env=process.env,scheduler=cron,db=supabaseAdmin,logger=console}={}){
 if(env.UNPROCESSED_ESCALATION_ENABLED!=='true'){
  logger.info?.('[UnprocessedEscalation] disabled: set UNPROCESSED_ESCALATION_ENABLED=true and restart to send 5-day escalation notices');
  return task;
 }
 if(task)return task;
 const schedule=env.UNPROCESSED_ESCALATION_CRON||'*/15 * * * *';
 if(!scheduler.validate(schedule))throw new Error('Invalid UNPROCESSED_ESCALATION_CRON');
 task=scheduler.schedule(schedule,async()=>{
  if(running){skippedOverlaps+=1;return;}
  running=true;const started=Date.now();
  try{
   const {data,error}=await db.rpc('escalate_unprocessed_reports').abortSignal(AbortSignal.timeout(20000));
   if(error)throw new Error(error.code||'Database escalation failed');
   if(!Number.isSafeInteger(data?.notifications_created)||data.notifications_created<0||!Number.isSafeInteger(data?.reports_checked)||data.reports_checked<0||data.reports_checked>500)throw new Error('Invalid escalation response');
   lastRun={at:new Date().toISOString(),outcome:'ok',reports_checked:data.reports_checked,notifications_created:data.notifications_created};consecutiveFailures=0;
   logger.info('[UnprocessedEscalation] completed',data);
  }catch(error){lastRun={...initialRun(),at:new Date().toISOString(),outcome:'failed'};consecutiveFailures+=1;logger.error('[UnprocessedEscalation] failed',{error:error.message});}
  finally{running=false;lastDurationMs=Date.now()-started;}
 },{timezone:'Asia/Manila'});
 registeredAt=new Date().toISOString();
 logger.info('[UnprocessedEscalation] registered',{schedule,timezone:'Asia/Manila'});
 return task;
}
export function stopUnprocessedSchedule(){task?.stop();task=null;lastRun=initialRun();registeredAt=null;skippedOverlaps=0;consecutiveFailures=0;lastDurationMs=null;}
// Safe to publish: no configuration values, only whether the job is registered in this process and how its last run ended.
export function getUnprocessedScheduleStatus(){return {enabled:task!==null,registered_at:registeredAt,last_run_at:lastRun.at,last_outcome:lastRun.outcome,last_reports_checked:lastRun.reports_checked,last_notifications_created:lastRun.notifications_created,last_duration_ms:lastDurationMs,consecutive_failures:consecutiveFailures,skipped_overlaps:skippedOverlaps};}
