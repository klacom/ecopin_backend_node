import {supabaseAdmin} from '../config/supabase.config.js';
const monthIndex=value=>Number(value.slice(0,4))*12+Number(value.slice(5))-1;
const monthString=index=>`${Math.floor(index/12)}-${String(index%12+1).padStart(2,'0')}`;
export function parseAnalyticsMonths(query={},now=new Date()) {
 const current=new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Manila',year:'numeric',month:'2-digit'}).formatToParts(now);
 const latest=`${current.find(p=>p.type==='year').value}-${current.find(p=>p.type==='month').value}`;
 const valid=value=>typeof value==='string'&&/^(20\d{2}|[3-9]\d{3})-(0[1-9]|1[0-2])$/.test(value);
 const end=query.endMonth??latest;
 if(!valid(end))throw new Error('Choose valid calendar months.');
 const start=query.startMonth??monthString(monthIndex(end)-5);
 if(!valid(start)||start>end||end>latest||monthIndex(end)-monthIndex(start)>=24)throw new Error('Choose 1–24 calendar months, ending no later than this month.');
 return {start_month:start+'-01',end_month:end+'-01'};
}
export async function getBarangayAnalytics(req,res) {
 res.set('Cache-Control','no-store');
 if(!req.user?.id||!['admin','officer'].includes(req.user.role))return res.status(403).json({error:'Staff analytics access required'});
 let range;
 try{range=parseAnalyticsMonths(req.query);}catch(error){return res.status(400).json({error:error.message});}
 try{
  const {data,error}=await supabaseAdmin.rpc('get_barangay_operational_analytics',{actor:req.user.id,...range}).abortSignal(AbortSignal.timeout(20000));
  if(error){
   const unavailable=['PGRST202','42703','42P01','55000'].includes(error.code);
   console.error('[barangay-analytics] Aggregate unavailable',error.code);
   return res.status(error.code==='42501'?403:unavailable?503:500).json({error:unavailable?'Barangay analytics is not ready. Required data migrations must be applied.':'Analytics could not load. Please retry.'});
  }
  if(!data?.total||!Array.isArray(data.groups)||data.groups.length!==31)return res.status(503).json({error:'Analytics returned incomplete coverage. Please retry.'});
  return res.json(data);
 }catch{
  console.error('[barangay-analytics] Aggregate request failed');
  return res.status(503).json({error:'Analytics is temporarily unavailable. Please retry.'});
 }
}
