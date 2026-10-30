import {supabaseAdmin as db} from '../config/supabase.config.js';
export async function getLiveOperations(req,res){
 res.set('Cache-Control','private, no-store');
 if(!req.user?.id||!['officer','admin'].includes(req.user.role))return res.status(403).json({error:'Staff operations access required.'});
 const {before_id=null,limit='20'}=req.query||{};
 if(typeof limit!=='string'||!/^\d{1,3}$/.test(limit)||Number(limit)<1||Number(limit)>100||
  (before_id!==null&&(typeof before_id!=='string'||!/^\d{1,19}$/.test(before_id)||BigInt(before_id)<1n||BigInt(before_id)>9223372036854775807n)))return res.status(400).json({error:'Choose a valid operations page.'});
 try{
  const {data,error}=await db.rpc('read_live_operations',{actor:req.user.id,before_id,page_limit:Number(limit)}).abortSignal(AbortSignal.timeout(6000));
  if(error||data?.version!=='live-operations-v1'||!Array.isArray(data.events)||!Array.isArray(data.crews))return res.status(error?.code==='42501'?403:503).json({error:'Live operations are unavailable. Please refresh.'});
  return res.json(data);
 }catch{return res.status(503).json({error:'Live operations are unavailable. Please refresh.'});}
}
export async function postCrewPresence(req,res){
 res.set('Cache-Control','private, no-store');
 if(!req.user?.id||req.user.role!=='field_crew')return res.status(403).json({error:'Field crew session required.'});
 try{
  const {data,error}=await db.rpc('touch_crew_presence',{actor:req.user.id}).abortSignal(AbortSignal.timeout(6000));
  if(error||typeof data?.seen_at!=='string'||!Number.isFinite(Date.parse(data.seen_at)))return res.status(error?.code==='42501'?403:503).json({error:'Crew contact could not be recorded.'});
  return res.json(data);
 }catch{return res.status(503).json({error:'Crew contact could not be recorded.'});}
}
