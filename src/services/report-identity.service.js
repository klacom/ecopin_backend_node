export function parseHideIdentity(value) {
  if (value === undefined || value === false || value === 'false') return false;
  if (value === true || value === 'true') return true;
  throw Object.assign(new Error('hide_identity must be a boolean.'), {statusCode:400});
}

export function publisherDisclosure(report) {
  const disclosed = report?.hide_identity === false && report?.profiles?.data_consent === true && Boolean(report.profiles.full_name);
  return {publisher_name:disclosed ? report.profiles.full_name : 'Anonymous',publisher_disclosed:disclosed};
}

// Authorization and ownership checks run against internal records before this output boundary.
export function maskReportIdentity(report,viewer) {
  if (!report) return report;
  const output={...report,...publisherDisclosure(report)};
  if (report.hide_identity === false || (viewer?.id && report.user_id === viewer.id)) return output;
  for (const key of ['user_id','profiles','reporter_id','reporter_name','reporter_email','reporter_phone','user_full_name','user_email','user_phone','idempotency_key','photo_lat','photo_lng','photo_accuracy','photo_captured_at','photo_source','is_mocked']) {
    if (key in output) output[key]=null;
  }
  return output;
}

const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PRIVATE_FIELDS=new Set(['profiles','profile','reporter','citizen','citizen_trust','trust_snapshot','publisher','user_id','citizen_id','reporter_id','owner_id','reporter_name','reporter_email','reporter_phone','user_full_name','full_name','email','phone','phone_number','user_email','user_phone','idempotency_key','photo_lat','photo_lng','photo_accuracy','photo_captured_at','photo_source','is_mocked','ip_address','user_agent','device_id','auth_user_id','uploaded_by','submitted_by']);
export function collectReportReferences(payload,routeId) {
  const ids=new Set();
  const add=value=>{if(typeof value==='string'&&UUID.test(value))ids.add(value.toLowerCase());};
  add(routeId);
  function walk(value){
    if(!value||typeof value!=='object')return;
    for(const [key,child] of Object.entries(value)){
      add(key);
      if(['id','entity_id'].includes(key)||key.endsWith('report_id')||key.endsWith('report_ids')){
        if(Array.isArray(child))child.forEach(add);else add(child);
      }
      walk(child);
    }
  }
  walk(payload);
  if(ids.size>2000)throw new Error('Privacy context limit exceeded');
  return [...ids];
}

export function sanitizeReportPayload(payload,contexts,viewer,routeId) {
  const map=new Map(contexts.map(c=>[c.id.toLowerCase(),c]));
  const hiddenOwners=new Set(contexts.filter(c=>c.hide_identity===true&&c.user_id!==viewer?.id).map(c=>c.user_id).filter(Boolean));
  function walk(value,context,privateActor=false){
    if(typeof value==='string'){
      if(hiddenOwners.has(value))return null;
      return value.replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi,id=>hiddenOwners.has(id.toLowerCase())?'[hidden]':id);
    }
    if(!value||typeof value!=='object')return value;
    if(Array.isArray(value))return value.map(v=>walk(v,context,privateActor));
    const ref=[...Object.entries(value).filter(([key])=>key.endsWith('report_id')).map(([,v])=>v),value.id,value.entity_id].find(id=>typeof id==='string'&&map.has(id.toLowerCase()));
    const current=ref?map.get(ref.toLowerCase()):context;
    const hidden=current?.hide_identity===true&&!(viewer?.id&&current.user_id===viewer.id);
    const actor=privateActor||hiddenOwners.has(value.id)||hiddenOwners.has(value.user_id);
    const staffActivity=hidden&&!actor&&typeof current.user_id==='string'&&UUID.test(current.user_id)&&value.user_id&&value.user_id!==current.user_id&&('action_type' in value||'event_type' in value);
    const result={};
    for(const [key,child] of Object.entries(value)){
      if(staffActivity&&['user_id','profiles'].includes(key)){result[key]=walk(child,undefined,false);continue;}
      if(hiddenOwners.has(key))continue;
      if((hidden||actor)&&PRIVATE_FIELDS.has(key)){result[key]=null;continue;}
      if(hidden&&['publisher_name','publisher_disclosed','has_consent'].includes(key)){
        result[key]=key==='publisher_name'?'Anonymous':false;continue;
      }
      if(hidden&&(key==='metadata'||(key==='action_details'&&actor))){result[key]=null;continue;}
      const keyed=map.get(key.toLowerCase());
      result[key]=walk(child,keyed??current,actor);
    }
    // Account-wide trust state can correlate reports; staff need the report decision only.
    if(hidden&&result.trust!==undefined)delete result.trust;
    return result;
  }
  return walk(payload,typeof routeId==='string'?map.get(routeId.toLowerCase()):undefined);
}

export async function protectReportPayload(db,payload,viewer,routeId) {
  const ids=collectReportReferences(payload,routeId);
  if(!ids.length)return payload;
  const contexts=[];
  for(let i=0;i<ids.length;i+=200){
    const {data,error}=await db.rpc('read_report_identity_context',{report_ids:ids.slice(i,i+200)});
    if(error||!Array.isArray(data)||data.some(c=>!UUID.test(c.id)||typeof c.hide_identity!=='boolean'||!Object.hasOwn(c,'user_id')||(c.user_id!==null&&!UUID.test(c.user_id))))throw new Error('Privacy context unavailable');
    contexts.push(...data);
  }
  return sanitizeReportPayload(payload,contexts,viewer,routeId);
}
