import {supabaseAdmin as db} from '../config/supabase.config.js';
export function parseOperationsDays(query,now=new Date()){
 const today=new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Manila',year:'numeric',month:'2-digit',day:'2-digit'}).format(now);
 const start=query.from??today,end=query.through??start;
 const valid=s=>typeof s==='string'&&/^20\d{2}-\d{2}-\d{2}$/.test(s)&&Number.isFinite(Date.parse(s+'T00:00:00Z'))&&new Date(s+'T00:00:00Z').toISOString().slice(0,10)===s;
 if(!valid(start)||!valid(end)||start>end||end>today||(Date.parse(end)-Date.parse(start))/86400000>365)throw new Error('Choose 1-366 valid Manila calendar days ending no later than today.');
 return {start_day:start,end_day:end};
}
export async function getFieldCrewOperationsSummary(req,res){
 res.set('Cache-Control','private, no-store');
 if(!req.user?.id||!['officer','admin'].includes(req.user.role))return res.status(403).json({error:'Desk operations access required.'});
 let days;try{days=parseOperationsDays(req.query)}catch(error){return res.status(400).json({error:error.message})}
 try{
  const {data,error}=await db.rpc('get_field_crew_operations_summary',{actor:req.user.id,...days}).abortSignal(AbortSignal.timeout(20000));
  if(error)return res.status(error.code==='42501'?403:error.code==='54000'?422:503).json({error:error.code==='54000'?'Operations summary is too large. Narrow the dates; no partial export was produced.':'Operations summary is temporarily unavailable. Verify the required migrations and retry.'});
  if(data?.version!=='crew-operations-v1'||!['tasks','assignments','waypoints','verified','obstacles'].every(k=>Array.isArray(data[k])))return res.status(503).json({error:'Operations summary returned incomplete data.'});
  return res.json(data);
 }catch{return res.status(503).json({error:'Operations summary is temporarily unavailable. Please retry.'})}
}
