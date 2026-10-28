import { supabaseAdmin as db } from '../config/supabase.config.js';

const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function fail(res,error,next) {
  const status={'42501':403,'23505':409,'22023':400,P0002:404,PGRST202:503}[error.code];
  if (!status) return next(error);
  return res.status(status).json({message:status===503 ? 'Urgency verification is temporarily unavailable. Please try again later.' : error.message});
}
export async function getUrgencyQueue(req,res,next) {
  const status=req.query.status ?? 'pending';
  const limit=req.query.limit===undefined ? 50 : Number(req.query.limit);
  if (!['pending','approved','declined'].includes(status) || !Number.isInteger(limit) || limit<1 || limit>100)
    return res.status(400).json({message:'Provide a valid urgency status and a limit from 1 to 100.'});
  try {
    const {data,error}=await db.rpc('read_report_urgency_queue',{actor:req.user.id,queue_status:status,page_limit:limit});
    if (error) return fail(res,error,next);
    res.set('Cache-Control','no-store');
    return res.json(data);
  } catch(error) { return next(error); }
}
export async function decideReportUrgency(req,res,next) {
  const {outcome,reason,operation_id,expected_decision_id}=req.body ?? {};
  if (!UUID.test(req.params.id) || !UUID.test(operation_id) || !['approved','declined'].includes(outcome)
    || typeof reason!=='string' || reason.trim().length<3 || reason.length>1000
    || (expected_decision_id!=null && !UUID.test(expected_decision_id)))
    return res.status(400).json({message:'Choose an urgency outcome, give a reason (3-1000 characters), and supply valid report/operation IDs.'});
  try {
    const {data,error}=await db.rpc('record_report_urgency_decision',{
      actor:req.user.id,report_id:req.params.id,outcome,reason:reason.trim(),operation_id,expected_decision_id:expected_decision_id ?? null,
    });
    if (error) return fail(res,error,next);
    return res.json({report:data});
  } catch(error) { return next(error); }
}
