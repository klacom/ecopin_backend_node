import cron from 'node-cron';
import {supabaseAdmin} from '../config/supabase.config.js';
let task=null,running=false;
export function startUnprocessedSchedule({env=process.env,scheduler=cron,db=supabaseAdmin,logger=console}={}){
 if(env.UNPROCESSED_ESCALATION_ENABLED!=='true'||task)return task;
 const schedule=env.UNPROCESSED_ESCALATION_CRON||'*/15 * * * *';
 if(!scheduler.validate(schedule))throw new Error('Invalid UNPROCESSED_ESCALATION_CRON');
 task=scheduler.schedule(schedule,async()=>{
  if(running)return;
  running=true;
  try{
   const {data,error}=await db.rpc('escalate_unprocessed_reports').abortSignal(AbortSignal.timeout(20000));
   if(error)throw new Error(error.code||'Database escalation failed');
   if(!Number.isSafeInteger(data?.notifications_created)||data.notifications_created<0||!Number.isSafeInteger(data?.reports_checked)||data.reports_checked<0||data.reports_checked>500)throw new Error('Invalid escalation response');
   logger.info('[UnprocessedEscalation] completed',data);
  }catch(error){logger.error('[UnprocessedEscalation] failed',{error:error.message});}
  finally{running=false;}
 },{timezone:'Asia/Manila'});
 logger.info('[UnprocessedEscalation] registered',{schedule,timezone:'Asia/Manila'});
 return task;
}
export function stopUnprocessedSchedule(){task?.stop();task=null;}
