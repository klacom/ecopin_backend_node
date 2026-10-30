import {supabaseAdmin as db} from '../config/supabase.config.js';
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export async function getUnprocessedAlerts(req,res){
 res.set('Cache-Control','private, no-store');
 if(!req.user?.id||!['officer','admin'].includes(req.user.role))return res.status(403).json({error:'Staff alerts access required.'});
 const {cursorCreated=null,cursorId=null,limit='20'}=req.query||{};
 const size=typeof limit==='string'&&/^\d+$/.test(limit)?Number(limit):NaN;
 if(!Number.isInteger(size)||size<1||size>100||(cursorCreated===null)!==(cursorId===null)||
  (cursorId!==null&&(typeof cursorId!=='string'||!uuid.test(cursorId)||typeof cursorCreated!=='string'||!/^\d{4}-\d{2}-\d{2}T/.test(cursorCreated)||!Number.isFinite(Date.parse(cursorCreated)))))
  return res.status(400).json({error:'Choose a valid alert page and limit from 1 to 100.'});
 try{
  const {data,error}=await db.rpc('read_unprocessed_report_alerts',{actor:req.user.id,cursor_created:cursorCreated,cursor_id:cursorId,page_limit:size}).abortSignal(AbortSignal.timeout(20000));
  if(error||data?.version!=='unprocessed-alerts-v1'||!Array.isArray(data.reports))return res.status(error?.code==='42501'?403:503).json({error:'Incident alerts could not load. Verify the escalation migration and retry.'});
  return res.json(data);
 }catch{return res.status(503).json({error:'Incident alerts are temporarily unavailable. Please retry.'});}
}
