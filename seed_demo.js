import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile, access } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const MARKER = 'ecopin-citizen-demo-v2';
const DAY = 86400000;
const uuid = key => {
  const h = createHash('sha256').update(`${MARKER}:${key}`).digest('hex');
  return `${h.slice(0,8)}-${h.slice(8,12)}-${h.slice(12,16)}-${h.slice(16,20)}-${h.slice(20,32)}`;
};
// Barangay reference points, not surveyed incident addresses. Corrected northern anchors:
// https://www.philatlas.com/luzon/ncr/pasig/{manggahan,dela-paz,malinao}.html
const SITES = [
  ['San Miguel',14.5607,121.0851,2], ['Kapasigan',14.5609,121.0762,2],
  ['Caniogan',14.5757,121.0857,3], ['Rosario',14.5871,121.0928,4],
  ['Maybunga',14.5745,121.0953,7], ['Pinagbuhatan',14.5478,121.0945,7],
  ['Bagong Ilog',14.5648,121.0665,2], ['Santolan',14.6132,121.0843,2],
  ['Manggahan',14.5981,121.0913,7], ['Ugong',14.5790,121.0630,1],
  ['Bambang',14.5670,121.0820,2], ['Palatiw',14.5630,121.0730,2],
  ['Dela Paz',14.6137,121.0960,1], ['Kalawaan',14.5560,121.0860,3],
  ['Oranbo',14.5720,121.0610,1], ['Sumilang',14.5660,121.0810,2],
  ['Malinao',14.5580,121.0760,2],
];
const STREETS = {
  'San Miguel':'R. Jabson Street', Kapasigan:'A. Mabini Street', Caniogan:'C. Raymundo Avenue',
  Rosario:'Ortigas Avenue Extension', Maybunga:'Dr. Sixto Antonio Avenue', Pinagbuhatan:'Sandoval Avenue',
  'Bagong Ilog':'Pasig Boulevard', Santolan:'Evangelista Street', Manggahan:'Amang Rodriguez Avenue',
  Ugong:'C-5 corridor', Bambang:'Bambang Street', Palatiw:'F. Manalo Street',
  'Dela Paz':'Karangalan Village', Kalawaan:'Kalawaan riverside', Oranbo:'Oranbo Drive',
  Sumilang:'M. Concepcion Street', Malinao:'Plaza Rizal',
};
const SUBJECTS = {
  waste: ['Nakatambak na basura','Overflowing garbage bags','Plastic bottles and sachets','Hindi nakolektang household waste','Basurang galing sa tindahan','Scattered food packaging','Sirang foam at karton','Halo-halong kalat','Amoy nabubulok na basura','Itinapong lumang gamit'],
  flooding: ['Baradong kanal','Standing floodwater','Tubig na hindi humuhupa','Bahang may kasamang basura'],
  pollution: ['Maitim na tubig sa kanal','Mabahong wastewater','Usok na masakit sa mata','Chemical smell'],
  illegal_logging: ['Pinutol na puno','Freshly cut tree branches','Pagputol ng puno na walang nakapaskil na permit'],
  others: ['Sirang takip ng kanal','Nakaharang na construction debris','Abandonadong gulong'],
};
const TITLE_ENDINGS = ['sa {place}, {barangay}','malapit sa {place} sa {barangay}','near {place}, {barangay}','sa may {place} — {barangay}'];
export const TITLE_TEMPLATES = Object.entries(SUBJECTS).flatMap(([issue, subjects]) => subjects.flatMap(subject => TITLE_ENDINGS.map(ending => ({ issue, text: `${subject} ${ending}` }))));
const OBSERVATIONS = {
  waste: ['Tatlong araw na pong hindi nakokolekta yung basura rito.','May mga supot na napunit at kumalat sa daanan.','May nag-iiwan ng basura dito tuwing gabi.','The collection point is overflowing again.','May tira-tirang pagkain na nilalangaw na.','Puno ng sachet at plastic cups yung gilid.','May mga daga na sa bunton ng basura.','Natatangay ng hangin yung kalat papunta sa kanal.','May iniwang karton at styrofoam sa sidewalk.','Pabalik-balik po yung tambak kahit winalis kahapon.','The bins are full and people are leaving bags beside them.','Hindi na madaanan nang maayos yung sidewalk.','May itinapong sirang gamit sa gilid ng daan.','Basura mula sa mga tindahan naiwan pagkatapos magsara.','May diaper at food waste na halo-halo.'],
  flooding: ['Hindi bumababa yung tubig kahit tumigil na ang ulan.','Barado po yung kanal at bumabalik ang tubig sa kalsada.','Water has collected here and pedestrians have to walk in traffic.','May basura sa inlet kaya hindi makadaloy yung tubig.'],
  pollution: ['May maitim at mabahong tubig na umaagos sa kanal.','Masangsang yung hangin lalo na pag hapon.','May usok na pumapasok sa mga bahay.','The smell is strong enough to make our eyes sting.'],
  illegal_logging: ['May bagong putol na puno at naiwan yung mga sanga.','May nagpuputol po ng puno rito; hindi namin makita kung may permit.','Fresh tree stumps appeared here this morning.'],
  others: ['May iniwang debris na nakaharang sa lakaran.','May lumang gulong na naiipunan ng tubig.','The damaged drain cover is a hazard for pedestrians.'],
};
const REQUESTS = ['Pakitingnan po sa {place}, {barangay}; maraming bata ang dumadaan.','Please check {place} in {barangay} when a crew is available.','Paki-coordinate po sa barangay yung nasa {place}, {barangay}.'];
export const DESCRIPTION_TEMPLATES = Object.entries(OBSERVATIONS).flatMap(([issue, lines]) => lines.flatMap(line => REQUESTS.map(request => ({ issue, text: `${line} ${request}` }))));

export function parseOptions(args) {
  const { values: v } = parseArgs({ args, options: {
    count:{type:'string',default:'600'}, days:{type:'string',default:'75'}, seed:{type:'string',default:'42'},
    confirm:{type:'boolean',default:false}, 'dry-run':{type:'boolean',default:false}, help:{type:'boolean',default:false},
  }});
  const count=Number(v.count), days=Number(v.days), seed=Number(v.seed);
  if (!Number.isInteger(count)||count<500||count>700) throw new Error('--count must be 500..700');
  if (!Number.isInteger(days)||days<60||days>90) throw new Error('--days must be 60..90');
  if (!Number.isSafeInteger(seed)||seed<0||seed>0xffffffff) throw new Error('--seed must be a uint32');
  if (v.confirm&&v['dry-run']) throw new Error('Choose --confirm or --dry-run');
  return {...v,count,days,seed};
}
function rng(seed) {
  return () => { seed=(seed+0x6d2b79f5)|0; let t=Math.imul(seed^seed>>>15,1|seed); t^=t+Math.imul(t^t>>>7,61|t); return ((t^t>>>14)>>>0)/4294967296; };
}
function quota(count, weights) {
  const parts=Object.entries(weights).map(([key,w])=>({key,n:Math.floor(count*w),fraction:count*w%1}));
  let remaining=count-parts.reduce((sum,p)=>sum+p.n,0);
  for (const p of [...parts].sort((a,b)=>b.fraction-a.fraction)) if (remaining-->0) p.n++;
  return parts.flatMap(p=>Array(p.n).fill(p.key));
}
function shuffle(items, random) {
  for(let i=items.length-1;i>0;i--){const j=Math.floor(random()*(i+1)); [items[i],items[j]]=[items[j],items[i]];} return items;
}
export function buildReports({count,days,seed,now,citizens}) {
  parseOptions(['--count',String(count),'--days',String(days),'--seed',String(seed)]);
  if (!citizens?.length||new Set(citizens).size!==citizens.length||!Number.isFinite(+now)) throw new Error('Unique citizen IDs and valid reference time required');
  const random=rng(seed), pick=items=>items[Math.floor(random()*items.length)];
  const statuses=shuffle(quota(count,{unresolved:.25,in_progress:.15,resolved:.45,closed:.10,rejected:.05}),random);
  const issues=shuffle(quota(count,{waste:.70,flooding:.12,pollution:.10,illegal_logging:.03,others:.05}),random);
  const people=shuffle([...citizens],random), images=shuffle(Array.from({length:250},(_,i)=>i+1),random);
  const weighted=SITES.flatMap(s=>Array(s[3]).fill(s));
  const groups=[];
  // Repeated small neighbourhood hotspots plus single-report sites.
  while(groups.length<count){const site=pick(weighted), size=random()<.25?1:2+Math.floor(random()*4);
    const lat=site[1]+(random()-.5)*.002, lng=site[2]+(random()-.5)*.002;
    for(let j=0;j<size&&groups.length<count;j++) groups.push({site,lat:lat+(random()-.5)*.0006,lng:lng+(random()-.5)*.0006});
  }
  return statuses.map((status,i)=>{
    const issue=issues[i], {site,lat,lng}=groups[i], barangay=site[0];
    const place=pick([STREETS[barangay],`side street near ${STREETS[barangay]}`,`collection point near ${STREETS[barangay]}`]);
    const fill=t=>t.replaceAll('{place}',place).replaceAll('{barangay}',barangay);
    const age=status==='unresolved'?Math.pow(random(),2)*days:status==='in_progress'?1+random()*12:3+Math.pow(random(),1.3)*(days-3);
    const created=+now-age*DAY;
    const updated=Math.min(+now,created+(status==='unresolved'?random()*.05:1+random()*2)*DAY);
    const score=Math.floor(random()*101), confidence=Math.min(.99,Math.max(.55,.82+((random()+random()+random()+random()+random()+random())-3)*.08));
    const reportId=uuid(`${seed}:${i}`);
    return {id:reportId,user_id:people[i%people.length],title:fill(pick(TITLE_TEMPLATES.filter(t=>t.issue===issue)).text),
      description:fill(pick(DESCRIPTION_TEMPLATES.filter(t=>t.issue===issue)).text),issue_type:issue,
      location:`SRID=4326;POINT(${lng.toFixed(6)} ${lat.toFixed(6)})`,
      validation_status:status==='unresolved'?pick(['approved','approved','approved','approved','pending_ai_validation','manual_review']):'approved',status,
      ml_predicted_class:['waste','flooding','pollution'].includes(issue)?issue:'VALID',ml_confidence:Number(confidence.toFixed(4)),
      ra9003_category:issue==='waste'?'solid':null,severity_score:score,severity_level:score>=67?'High':score>=34?'Medium':'Low',
      urgency_score:score>=67?3:score>=34?2:1,hazard_class:'standard',
      hazard_confidence:Number((.7+random()*.29).toFixed(4)),
      hazard_model_version:'demo-fixture-v1',hazard_decision_source:'demo_seed',
      hazard_classified_at:new Date(created).toISOString(),
      created_at:new Date(created).toISOString(),updated_at:new Date(updated).toISOString(),
      idempotency_key:`${MARKER}:${seed}:${i}`,sample_image:`Datacluster Trash (${images[i%250]}).jpg`,barangay,
      lifecycle_state:['resolved','closed','rejected'].includes(status)?'closed':status==='in_progress'?'dispatched':'fresh',
      stage:status==='unresolved'?'submitted':status==='rejected'?'submitted':status,
      lgu_resolved_at:['resolved','closed'].includes(status)?new Date(updated).toISOString():null,
      citizen_closed_at:status==='closed'?new Date(updated).toISOString():null,
    };
  });
}

// Keep non-clock security/claim triggers active, matching the existing demo importer.
export function renderSql(reports, tasks) {
  const quote=s=>`'${s.replaceAll("'","''")}'`;
  const insert=(table,rows)=>{
    if(!rows.length)return '';
    const cols=Object.keys(rows[0]).map(k=>`"${k}"`).join(',');
    return `INSERT INTO public.${table} (${cols}) SELECT ${cols} FROM jsonb_populate_recordset(NULL::public.${table},${quote(JSON.stringify(rows))}::jsonb);\n`;
  };
  const cleaned=reports.map(({sample_image,barangay,...r})=>r);
  let sql=`-- DEMO ONLY: synthetic reports and explicitly labeled placeholder cleanup evidence.\nBEGIN;\nSET LOCAL lock_timeout='5s';\nSET LOCAL statement_timeout='120s';\nSELECT pg_advisory_xact_lock(72631016);\nLOCK TABLE public.reports, public.cleanup_tasks IN SHARE ROW EXCLUSIVE MODE;\nDO $$ BEGIN IF EXISTS (SELECT 1 FROM public.reports WHERE idempotency_key LIKE '${MARKER}:%') THEN RAISE EXCEPTION 'Citizen demo already exists; no rows inserted'; END IF; END $$;\nCREATE TEMP TABLE demo_clock_triggers ON COMMIT DROP AS SELECT t.tgrelid::regclass target,t.tgname,t.tgenabled FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid WHERE t.tgrelid IN ('public.reports'::regclass,'public.cleanup_tasks'::regclass) AND NOT t.tgisinternal AND t.tgenabled<>'D' AND p.proname IN ('apply_report_lifecycle','calculate_report_deadline','update_updated_at_column');\nDO $$ DECLARE t record; BEGIN FOR t IN SELECT * FROM demo_clock_triggers LOOP EXECUTE format('ALTER TABLE %s DISABLE TRIGGER %I',t.target,t.tgname); END LOOP; END $$;\n`;
  for(let i=0;i<cleaned.length;i+=100)sql+=insert('reports',cleaned.slice(i,i+100));
  sql+=insert('cleanup_tasks',tasks);
  const assignments=tasks.filter(t=>t.status==='in_progress').map(t=>({id:t.report_ids[0],cleanup_task_id:t.id}));
  if(assignments.length)sql+=`UPDATE public.reports r SET cleanup_task_id=s.cleanup_task_id FROM jsonb_populate_recordset(NULL::public.reports,${quote(JSON.stringify(assignments))}::jsonb) s WHERE r.id=s.id;\n`;
  const resolutions=tasks.filter(t=>t.status==='completed').map(t=>({id:uuid(`resolution:${t.id}`),report_id:t.report_ids[0],task_id:t.id,crew_id:t.completed_by,operation_id:`${MARKER}:resolution:${t.id}`,resolved_at:t.completed_at,report_fc_version:0,resolution_kind:'cleaned'}));
  sql+=insert('report_resolution_events',resolutions);
  sql+=`DO $$ DECLARE t record; BEGIN\nIF (SELECT count(*) FROM public.reports WHERE idempotency_key LIKE '${MARKER}:%') <> ${reports.length} THEN RAISE EXCEPTION 'Report count mismatch'; END IF;\nFOR t IN SELECT * FROM demo_clock_triggers LOOP EXECUTE format('ALTER TABLE %s ENABLE %s TRIGGER %I',t.target,CASE t.tgenabled WHEN 'A' THEN 'ALWAYS' WHEN 'R' THEN 'REPLICA' ELSE '' END,t.tgname); END LOOP; END $$;\nCOMMIT;\n`;
  return sql;
}

async function main() {
  const options=parseOptions(process.argv.slice(2));
  if(options.help){console.log('node seed_demo.js [--count 500..700] [--days 60..90] [--seed N] [--dry-run | --confirm]\nDefault: read-only preview. --confirm uploads demo media and writes .private/citizen-demo.sql. Run that whole file in Supabase SQL Editor as postgres.');return;}
  const {config}=await import('dotenv'); config({path:path.join(ROOT,'.env'),quiet:true});
  // Shared config also constructs an unused public client; use the admin credential for it if absent.
  process.env.SUPABASE_PUBLISHABLE_KEY ||= process.env.SUPABASE_SECRET_KEY || process.env.SUPABASE_SERVICE_ROLE_KEY || process.env.NEXT_PUBLIC_SERVICE_ROLE_KEY;
  const {supabaseAdmin:db}=await import('./src/config/supabase.config.js');
  const profiles=[];
  for(let offset=0;;offset+=1000){
    const {data,error}=await db.from('profiles').select('id,role,suspended_until').order('id').range(offset,offset+999);
    if(error)throw new Error(`Read profiles: ${error.message}`); profiles.push(...data); if(data.length<1000)break;
  }
  const now=new Date(), active=profiles.filter(p=>!p.suspended_until||Date.parse(p.suspended_until)<=+now);
  const citizens=profiles.filter(p=>p.role==='citizen').map(p=>p.id);
  const officer=active.find(p=>['officer','admin'].includes(p.role));
  const {data:crews,error:crewError}=await db.from('field_crews').select('id,team_lead_profile_id,member_profile_ids,availability_status');
  if(crewError)throw new Error(crewError.message);
  const personnel=new Set(active.filter(p=>p.role==='field_crew').map(p=>p.id));
  const staffed=crews.filter(c=>c.availability_status!=='disabled').map(c=>({...c,members:[...new Set([c.team_lead_profile_id,...(c.member_profile_ids??[])].filter(id=>personnel.has(id)))]})).filter(c=>c.members.length);
  if(!officer||!staffed.length)throw new Error('An active officer/admin and staffed field crew are required');
  const {count:existing,error:existingError}=await db.from('reports').select('id',{count:'exact',head:true}).like('idempotency_key',`${MARKER}:%`);
  if(existingError)throw new Error(existingError.message); if(existing)throw new Error('Citizen demo already exists; existing reports were preserved');
  const reports=buildReports({...options,now,citizens});
  const imagesDir=path.join(ROOT,'../sample_images');
  for(let i=1;i<=250;i++)await access(path.join(imagesDir,`Datacluster Trash (${i}).jpg`));
  console.log(`Target: ${new URL(process.env.SUPABASE_URL||process.env.NEXT_PUBLIC_SUPABASE_URL).host}`);
  console.log(JSON.stringify({reports:reports.length,days:options.days,citizens:citizens.length,images:250,counts:Object.fromEntries(['unresolved','in_progress','resolved','closed','rejected'].map(s=>[s,reports.filter(r=>r.status===s).length]))},null,2));
  if(!options.confirm){console.log('Preview only. --confirm uploads media and prepares the transactional SQL import.');return;}
  for(const name of ['CLOUDINARY_CLOUD_NAME','CLOUDINARY_API_KEY','CLOUDINARY_API_SECRET'])if(!process.env[name])throw new Error(`Missing ${name}`);
  const {uploadFromBuffer}=await import('./src/services/cloudinary.service.js');
  const sharp=(await import('sharp')).default;
  await mkdir(path.join(ROOT,'.private'),{recursive:true});
  const manifestPath=path.join(ROOT,'.private/citizen-demo-media.json');
  let manifest={}; try{manifest=JSON.parse(await readFile(manifestPath,'utf8'));}catch(e){if(e.code!=='ENOENT')throw e;}
  const save=()=>writeFile(manifestPath,JSON.stringify(manifest,null,2));
  const tasks=[];
  for(let i=0;i<reports.length;i++){
    const r=reports[i];
    if(!manifest[r.id]?.before){
      const result=await uploadFromBuffer(await readFile(path.join(imagesDir,r.sample_image)),MARKER,`${r.id}-before`);
      if(!result?.secure_url)throw new Error(`Missing Cloudinary URL for ${r.id}`);
      manifest[r.id]={...manifest[r.id],before:result.secure_url}; await save();
    }
    r.before_photo_url=manifest[r.id].before;
    if(['in_progress','resolved','closed'].includes(r.status)){
      const done=r.status!=='in_progress', crew=staffed[i%staffed.length], taskId=uuid(`task:${options.seed}:${i}`);
      let after=null;
      if(done){
        const objectPath=`${MARKER}/${taskId}/after-demo-placeholder.png`;
        if(!manifest[r.id].after){
          const svg='<svg width="960" height="640" xmlns="http://www.w3.org/2000/svg"><rect width="100%" height="100%" fill="#e6f2ec"/><text x="480" y="260" text-anchor="middle" font-family="sans-serif" font-size="42" fill="#163c30">DEMO CLEANUP PLACEHOLDER</text><text x="480" y="330" text-anchor="middle" font-family="sans-serif" font-size="26">Synthetic fixture — not a site photograph</text><text x="480" y="385" text-anchor="middle" font-family="sans-serif" font-size="22">No real cleanup is claimed</text></svg>';
          const buffer=await sharp(Buffer.from(svg)).png().toBuffer();
          const {error}=await db.storage.from('Report Evidence').upload(objectPath,buffer,{contentType:'image/png',upsert:true});
          if(error)throw new Error(`After placeholder: ${error.message}`);
          manifest[r.id].after=`storage://Report%20Evidence/${objectPath}`; await save();
        }
        after=manifest[r.id].after;
      }
      const assigned=new Date(Date.parse(r.created_at)+3600000).toISOString();
      tasks.push({id:taskId,title:`[DEMO] ${r.title}`,description:'Simulated assignment; attached after image is explicitly a demo placeholder.',
        status:done?'completed':'in_progress',task_type:'Cleanup',dispatch_kind:'standard',report_ids:[r.id],report_sequence:[r.id],
        assigned_field_crew_id:crew.id,assigned_crew_ids:crew.members,assignment_generation:1,created_by:officer.id,lgu_user_id:officer.id,
        assigned_by:officer.id,assigned_at:assigned,last_assigned_at:assigned,created_at:assigned,
        location:r.location,priority:r.severity_level.toLowerCase(),before_photo_url:r.before_photo_url,after_photo_url:after,
        completed_at:done?r.updated_at:null,completed_by:done?crew.members[0]:null,completion_result:done?'cleanup_completed':null,
        completion_notes:done?'[DEMO] Simulated cleanup. After evidence is a labeled placeholder, not a field photograph.':null});
    }
    if((i+1)%25===0)console.log(`Prepared ${i+1}/${reports.length} reports`);
  }
  const output=path.join(ROOT,'.private/citizen-demo.sql');
  await writeFile(output,renderSql(reports,tasks));
  console.log(`Prepared ${output}. Run the WHOLE file in Supabase SQL Editor as postgres. No database rows inserted; uploads remain available for retries.`);
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url))main().catch(e=>{console.error(`Seed failed: ${e.message}`);process.exitCode=1;});
