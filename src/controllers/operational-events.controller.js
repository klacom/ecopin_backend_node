import {supabaseAdmin as db} from '../config/supabase.config.js';
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export async function getOperationalEvents(req,res,next){
 try{
  const {task_id,report_id,before_id,limit='50'}=req.query;
  if((task_id!==undefined&&(typeof task_id!=='string'||!UUID.test(task_id)))||
   (report_id!==undefined&&(typeof report_id!=='string'||!UUID.test(report_id)))||
   (before_id!==undefined&&(typeof before_id!=='string'||!/^\d{1,19}$/.test(before_id)||BigInt(before_id)<1n||BigInt(before_id)>9223372036854775807n))||
   typeof limit!=='string'||!/^\d{1,3}$/.test(limit)||Number(limit)<1||Number(limit)>100){
   return res.status(400).json({message:'Provide valid task/report IDs, cursor and limit (1–100).'});
  }
  const {data,error}=await db.rpc('read_operational_events',{actor:req.user.id,p_task_id:task_id??null,p_report_id:report_id??null,p_before_id:before_id??null,p_limit:Number(limit)});
  if(error)throw Object.assign(new Error('Operational events are temporarily unavailable.'),{statusCode:error.code==='42501'?403:503});
  if(!data||!Array.isArray(data.events)||typeof data.has_more!=='boolean')throw Object.assign(new Error('Operational events are temporarily unavailable.'),{statusCode:503});
  res.set('Cache-Control','private, no-store');return res.json(data);
 }catch(error){next(error);}
}
