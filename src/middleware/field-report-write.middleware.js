import { randomUUID } from 'node:crypto';
import { supabaseAdmin as db } from '../config/supabase.config.js';

// Older mobile REST entry points share the versioned sync transaction.
export async function fieldReportWrite(req,res,next) {
  if(req.user.role!=='field_crew'||req.method==='GET') return next();
  if(/^\/[0-9a-f-]{36}\/photo$/i.test(req.path)) return next();
  const match=req.path.match(/^\/([0-9a-f-]{36})\/(status|validation|lifecycle|details|notes|agency-responses)$/i);
  if(!match) return res.status(409).json({message:'Use versioned field sync or the assigned task photo/outcome endpoint for this operation.'});
  const [ ,id,kind]=match;
  if(kind!=='notes' && kind!=='agency-responses' && (!Number.isSafeInteger(req.body.base_version)||req.body.base_version<0)) return res.status(409).json({message:'base_version is required; refresh the report before submitting.'});
  const types={status:'update_status',validation:'update_validation',lifecycle:'update_lifecycle_stage',details:'update_details',notes:'add'};
  const noteKind=kind==='notes'||kind==='agency-responses';
  const payload=kind==='status'?{status:req.body.status}:kind==='validation'?{validation_status:req.body.validation_status}:
    kind==='lifecycle'?{stage:req.body.stage}:noteKind?{action:req.body.note??req.body.action??req.body.action_details}:req.body.payload??{notes:req.body.notes};
  const {data,error}=await db.rpc('apply_fc_operation',{actor:req.user.id,operation_id:req.body.operation_id??randomUUID(),
    operation_type:noteKind?'fc.note.add':`fc.report.${types[kind]}`,entity_id:id,entity_type:'report',payload,base_version:req.body.base_version??0});
  if(error) return res.status(error.code==='42501'?403:400).json({message:error.message});
  return res.status(data.status==='conflict'?409:200).json({...data,report:data.server_record});
}
