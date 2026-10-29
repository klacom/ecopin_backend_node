import {supabaseAdmin} from '../config/supabase.config.js';
import {OFFICIAL_PASIG_BARANGAYS,PASIG_BARANGAYS,isOrtigasDistrict} from './pasig-barangay-catalog.js';
const statuses=new Set(['resolved','border','overlap','unresolved','dataset_incomplete','invalid_coordinates']);
export async function resolveBarangay(lat,lng) {
 const unavailable={barangay:null,barangay_resolution_status:'unavailable',barangay_candidates:[]};
 try{
  const {data,error}=await supabaseAdmin.rpc('resolve_report_barangay',{lat,lng});
  if(error||!data||!statuses.has(data.status)||!Array.isArray(data.candidates)||data.candidates.some(name=>!OFFICIAL_PASIG_BARANGAYS.has(name)))return unavailable;
  if(data.status==='resolved'&&(!OFFICIAL_PASIG_BARANGAYS.has(data.barangay)||data.candidates.length!==1||data.candidates[0]!==data.barangay||!PASIG_BARANGAYS.some(row=>row.name===data.barangay&&row.psgc_code===data.psgc_code)))return unavailable;
  return {barangay:data.status==='resolved'?data.barangay:null,barangay_resolution_status:data.status,barangay_candidates:[...new Set(data.candidates)]};
 }catch{return unavailable;}
}
export async function applyBarangayResolution(address,lat,lng){
 const administrative=await resolveBarangay(lat,lng);
 const result={...address,...administrative,location_district:isOrtigasDistrict(address.barangay)?'Ortigas Center':address.location_district??null};
 if(administrative.barangay)result.city='Pasig City';
 result.display_name=[result.street_address,result.barangay,result.city].filter(Boolean).join(', ')||null;
 return result;
}
