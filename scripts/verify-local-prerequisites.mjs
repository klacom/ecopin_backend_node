import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFile, writeFile} from 'node:fs/promises';
import dotenv from 'dotenv';
import sharp from 'sharp';
import {createClient} from '@supabase/supabase-js';

dotenv.config({quiet:true});
assert.equal(process.env.SUPABASE_URL,'http://127.0.0.1:54321','Prerequisite checks require the isolated local stack.');
const fixtures=JSON.parse(await readFile('.private/parity-fixtures.json','utf8'));
assert.equal(fixtures.url,process.env.SUPABASE_URL);
const options={auth:{persistSession:false,autoRefreshToken:false}};
const db=createClient(process.env.SUPABASE_URL,process.env.SUPABASE_SECRET_KEY,options);
const anon=createClient(process.env.SUPABASE_URL,process.env.SUPABASE_PUBLISHABLE_KEY,options);
const citizen=createClient(process.env.SUPABASE_URL,process.env.SUPABASE_PUBLISHABLE_KEY,options);
const actor=role=>fixtures.users.find(user=>user.role===role).id;
const results=[];
function check(name,condition){assert.ok(condition,name);results.push({name,passed:true});}
async function rpc(name,args){const response=await db.rpc(name,args);assert.ifError(response.error);return response.data;}
const month='2026-10-01';
check('executive prerequisite', (await rpc('get_barangay_executive_analytics',{actor:actor('officer'),report_month:month})).version==='barangay-executive-v1');
const denied=await db.rpc('get_barangay_executive_analytics',{actor:actor('citizen'),report_month:month});
check('executive denies citizen actor',denied.error?.code==='42501');
check('event journal prerequisite',Array.isArray((await rpc('read_operational_events',{actor:actor('officer'),p_limit:20})).events));
check('live feed prerequisite',(await rpc('read_live_operations',{actor:actor('officer'),page_limit:20})).version==='live-operations-v1');
check('citizen support prerequisite',Array.isArray((await rpc('read_my_support_tickets',{actor:actor('citizen'),page_limit:20})).tickets));
check('staff support prerequisite',Array.isArray((await rpc('read_support_ticket_queue',{actor:actor('officer'),page_limit:20})).tickets));
const queueDenied=await db.rpc('read_support_ticket_queue',{actor:actor('citizen'),page_limit:20});
check('support queue denies citizen actor',queueDenied.error?.code==='42501');
const missing='00000000-0000-4000-8000-000000000003';
check('case record safely handles absent fixture',await rpc('read_incident_case_record',{actor:actor('officer'),incident_id:missing})===null);
check('proof source prerequisite',await rpc('read_cleanup_proof_source',{report_id:missing})===null);
check('public proof prerequisite',await rpc('read_cleanup_proof',{report_id:missing})===null);
check('identity context prerequisite',Array.isArray(await rpc('read_report_identity_context',{report_ids:[]})));
check('crew summary prerequisite',(await rpc('get_field_crew_operations_summary',{actor:actor('officer'),start_day:month,end_day:'2026-10-31'})).version==='crew-operations-v1');
check('escalation read prerequisite',(await rpc('read_unprocessed_report_alerts',{actor:actor('officer'),page_limit:20})).version==='unprocessed-alerts-v1');

const container='supabase_db_parity-recovery-backend';
const target=JSON.parse(execFileSync('docker',['inspect',container],{encoding:'utf8'}))[0];
assert.equal(target.Config.Labels['com.supabase.cli.project'],'parity-recovery-backend');
const functions=['get_barangay_executive_analytics','get_barangay_operational_analytics','read_operational_events','read_live_operations','touch_crew_presence','create_support_ticket','read_my_support_tickets','read_my_support_ticket','read_support_ticket_queue','respond_support_ticket','read_incident_case_record','read_cleanup_proof_source','read_cleanup_proof','publish_cleanup_proof_photos','read_report_identity_context','get_field_crew_operations_summary','escalate_unprocessed_reports','read_unprocessed_report_alerts'];
const names=functions.map(value=>`'${value}'`).join(',');
const query=`select count(*)=18 and bool_and(has_function_privilege('service_role',p.oid,'EXECUTE') and not has_function_privilege('anon',p.oid,'EXECUTE') and not has_function_privilege('authenticated',p.oid,'EXECUTE')) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in (${names});`;
const grants=execFileSync('docker',['exec',container,'psql','-X','-qAt','-v','ON_ERROR_STOP=1','-U','postgres','-d','postgres','-c',query],{encoding:'utf8'}).trim();
check('all 18 RPC grants restrict direct callers',grants==='t');
const signedIn=await citizen.auth.signInWithPassword({email:fixtures.users.find(user=>user.role==='citizen').email,password:fixtures.password});
assert.ifError(signedIn.error);
const bytes=await sharp({create:{width:16,height:16,channels:3,background:'#245b7a'}}).jpeg().toBuffer();
for(const bucket of ['Cleanup Originals','Cleanup Proof']){
  const object='parity-prerequisites/sentinel.jpg';
  try{
    assert.ifError((await db.storage.from(bucket).upload(object,bytes,{contentType:'image/jpeg',upsert:true})).error);
    const downloaded=await db.storage.from(bucket).download(object);assert.ifError(downloaded.error);
    check(`${bucket} service byte round trip`,Buffer.from(await downloaded.data.arrayBuffer()).equals(bytes));
    for(const [label,client] of [['anonymous',anon],['citizen',citizen]]){
      const response=await client.storage.from(bucket).download(object);
      check(`${bucket} denies ${label} bytes`,Boolean(response.error)&&!response.data);
    }
  }finally{assert.ifError((await db.storage.from(bucket).remove([object])).error);}
}
await writeFile('.private/prerequisite-results.json',JSON.stringify({scope:'isolated prerequisites, not full feature acceptance',results},null,2)+'\n');
console.log(JSON.stringify({checks:results.length,passed:results.length,scope:'local prerequisite smoke and role/storage checks'}));
