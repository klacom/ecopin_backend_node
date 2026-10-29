import {supabaseAdmin as db} from '../config/supabase.config.js';
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function fail(res,error,next){
 const status={'42501':403,'23505':409,'22023':400,P0002:404,PGRST202:503}[error.code];
 if(!status)return next(error);
 return res.status(status).json({message:status===503?'Crew urgency review is temporarily unavailable.':error.message});
}
export async function getCrewUrgencyObservations(req,res,next){
 if(!UUID.test(req.params.id))return res.status(400).json({message:'Invalid report ID.'});
 try{
  const {data,error}=await db.rpc('read_crew_urgency_observations',{actor:req.user.id,report_id:req.params.id});
  if(error)return fail(res,error,next);
  res.set('Cache-Control','no-store');return res.json(data);
 }catch(error){return next(error);}
}
export async function reviewCrewUrgencyObservation(req,res,next){
 const {reason,operation_id}=req.body??{};
 if(!UUID.test(req.params.id)||!UUID.test(operation_id)||!/^[-a-zA-Z0-9_]{1,200}$/.test(req.params.observationId??'')
  ||typeof reason!=='string'||reason.trim().length<3||reason.length>1500)return res.status(400).json({message:'Provide valid IDs and a review reason (3-1500 characters).'});
 try{
  const {data,error}=await db.rpc('review_crew_urgency_observation',{actor:req.user.id,report_id:req.params.id,observation_id:req.params.observationId,reason:reason.trim(),operation_id});
  if(error)return fail(res,error,next);
  return res.json({review:data});
 }catch(error){return next(error);}
}
