import {supabaseAdmin} from '../config/supabase.config.js';
import {parseAnalyticsMonths} from './barangay-analytics.controller.js';
export async function getBarangayExecutive(req,res){
 res.set('Cache-Control','private, no-store');
 if(!req.user?.id||!['officer','admin'].includes(req.user.role))return res.status(403).json({error:'Staff analytics access required.'});
 let month;
 try{if(typeof req.query.month!=='string')throw new Error('Choose one report month.');month=parseAnalyticsMonths({startMonth:req.query.month,endMonth:req.query.month}).start_month;}
 catch(error){return res.status(400).json({error:error.message});}
 try{
  const {data,error}=await supabaseAdmin.rpc('get_barangay_executive_analytics',{actor:req.user.id,report_month:month}).abortSignal(AbortSignal.timeout(20000));
  if(error||data?.version!=='barangay-executive-v1'||!data.monthly||!data.comparison)return res.status(error?.code==='42501'?403:503).json({error:'The executive report could not load. Verify the required analytics migration and retry.'});
  return res.json(data);
 }catch{return res.status(503).json({error:'The executive report is temporarily unavailable. Please retry.'});}
}
