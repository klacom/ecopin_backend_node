import {supabaseAdmin as db} from '../config/supabase.config.js';
import {readBudget,sendFailure} from '../services/request-budget.js';
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
  const {data,error}=await db.rpc('get_field_crew_operations_summary',{actor:req.user.id,...days}).abortSignal(readBudget());
  if(error)return sendFailure(res,'crew-summary',error,{too_large:'Operations summary is too large. Narrow the dates; no partial export was produced.',missing_prerequisite:'Operations summary is not ready. Verify the required migrations and retry.',unavailable:'Operations summary is temporarily unavailable. Please retry.'});
  if(data?.version!=='crew-operations-v1'||!['tasks','assignments','waypoints','verified','obstacles'].every(k=>Array.isArray(data[k])))return sendFailure(res,'crew-summary',{code:'INCOMPLETE'},{unavailable:'Operations summary returned incomplete data.'});
  return res.json(data);
 }catch(error){return sendFailure(res,'crew-summary',error,{unavailable:'Operations summary is temporarily unavailable. Please retry.'})}
}
