import {supabaseAdmin} from '../config/supabase.config.js';
import {parseAnalyticsMonths} from './barangay-analytics.controller.js';
import {readBudget,sendFailure} from '../services/request-budget.js';
export async function getBarangayExecutive(req,res){
 res.set('Cache-Control','private, no-store');
 if(!req.user?.id||!['officer','admin'].includes(req.user.role))return res.status(403).json({error:'Staff analytics access required.'});
 let month;
 try{if(typeof req.query.month!=='string')throw new Error('Choose one report month.');month=parseAnalyticsMonths({startMonth:req.query.month,endMonth:req.query.month}).start_month;}
 catch(error){return res.status(400).json({error:error.message});}
 try{
  const {data,error}=await supabaseAdmin.rpc('get_barangay_executive_analytics',{actor:req.user.id,report_month:month}).abortSignal(readBudget());
  if(error)return sendFailure(res,'executive',error,{missing_prerequisite:'The executive report could not load. Verify the required analytics migration and retry.',unavailable:'The executive report could not load. Please retry.'});
  if(data?.version!=='barangay-executive-v1'||!data.monthly||!data.comparison)return sendFailure(res,'executive',{code:'INCOMPLETE'},{unavailable:'The executive report returned incomplete data. Please retry.'});
  return res.json(data);
 }catch(error){return sendFailure(res,'executive',error,{unavailable:'The executive report is temporarily unavailable. Please retry.'});}
}
