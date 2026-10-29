import {supabaseAdmin as db} from '../config/supabase.config.js';
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export async function getIncidentCaseRecord(req,res,next){try{
 if(!['officer','admin'].includes(req.user?.role))return res.status(403).json({message:'Desk case record access required.'});
 if(!UUID.test(req.params.id||''))return res.status(400).json({message:'Provide a valid incident ID.'});
 const {data,error}=await db.rpc('read_incident_case_record',{actor:req.user.id,incident_id:req.params.id});
 if(error)throw Object.assign(new Error(error.code==='54000'?'Case history is too large for one printable record; no partial record was produced.':'Case record is temporarily unavailable.'),{statusCode:error.code==='42501'?403:error.code==='54000'?422:503});
 if(!data)return res.status(404).json({message:'Incident not found.'});
 if(data.version!=='case-record-v1'||data.report?.id?.toLowerCase()!==req.params.id.toLowerCase()||!Array.isArray(data.events)||!Array.isArray(data.activity))throw Object.assign(new Error('Case record is incomplete.'),{statusCode:503});
 res.set('Cache-Control','private, no-store');return res.json(data);
}catch(error){next(error);}}
