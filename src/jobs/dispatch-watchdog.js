import cron from 'node-cron';
import { supabaseAdmin as db } from '../config/supabase.config.js';
let task;
let running=false;
export function startDispatchWatchdog({env=process.env,scheduler=cron,client=db,logger=console}={}) {
  if(env.REPORT_LIFECYCLE_ENABLED!=='true'||task) return task??null;
  task=scheduler.schedule('*/5 * * * *',async()=>{
    if(running) return;
    running=true;
    try {
      const {data,error}=await client.rpc('expire_unpublished_dispatch_claims');
      if(error) throw error;
      logger.info('[DispatchWatchdog] completed',data);
    } catch(error){logger.error('[DispatchWatchdog] failed',{error:error.message});}
    finally{running=false;}
  },{timezone:'Asia/Manila'});
  logger.info('[DispatchWatchdog] registered',{schedule:'*/5 * * * *'});
  return task;
}
export function stopDispatchWatchdog(){task?.stop();task=null;}
