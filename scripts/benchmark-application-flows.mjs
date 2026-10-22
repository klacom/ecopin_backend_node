import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {createClient} from '@supabase/supabase-js';
import express from 'express';

export async function benchmarkApplicationFlows({local,citizenId,officerId,crewId,citizenJwt,officerJwt,crewJwt,runPsql}){
 if(new URL(local.API_URL).hostname!=='127.0.0.1')throw new Error('Local benchmark only');
 process.env.NEXT_PUBLIC_SUPABASE_URL=local.API_URL;
 process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY=local.ANON_KEY;
 process.env.NEXT_PUBLIC_SERVICE_ROLE_KEY=local.SERVICE_ROLE_KEY;
 process.env.SMTP_HOST='127.0.0.1';process.env.SMTP_PORT='54325';
 const admin=createClient(local.API_URL,local.SERVICE_ROLE_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
 const email=`load-admin-${randomUUID()}@ecopin.test`,password=randomUUID()+'aA1!';
 const created=await admin.auth.admin.createUser({email,password,email_confirm:true});
 if(created.error)throw created.error;
 const adminId=created.data.user.id;
 let server;
 const json=output=>JSON.parse(output.split(/\r?\n/).map(line=>line.trim()).find(line=>line.startsWith('{')));
 const metrics=async()=>json(await runPsql(`SELECT json_build_object('captured_at',clock_timestamp(),'connections',(SELECT count(*) FROM pg_stat_activity),'active_connections',(SELECT count(*) FROM pg_stat_activity WHERE state='active'),'waiting_locks',(SELECT count(*) FROM pg_locks WHERE NOT granted),'deadlocks',(SELECT deadlocks FROM pg_stat_database WHERE datname=current_database()),'transactions_committed',(SELECT xact_commit FROM pg_stat_database WHERE datname=current_database()),'transactions_rolled_back',(SELECT xact_rollback FROM pg_stat_database WHERE datname=current_database()),'wal_insert_lsn',pg_current_wal_insert_lsn(),'max_connections',current_setting('max_connections'),'statement_timeout',current_setting('statement_timeout'),'lock_timeout',current_setting('lock_timeout'));`));
 const summarize=rows=>{const times=rows.map(row=>row.ms).sort((a,b)=>a-b);const p=q=>times[Math.min(times.length-1,Math.ceil(times.length*q)-1)];return {samples:times.length,p50_ms:p(.5),p95_ms:p(.95),p99_ms:p(.99),response_bytes:rows.reduce((sum,row)=>sum+row.bytes,0),statuses:rows.reduce((counts,row)=>(counts[row.status]=(counts[row.status]??0)+1,counts),{})};};
 try{
  const profile=await admin.from('profiles').upsert({id:adminId,role:'admin',full_name:'Local load fixture'});if(profile.error)throw profile.error;
  const [{default:tasks},{default:adminRoutes},{default:reportRoutes},{rateLimiter},{errorHandler}]=await Promise.all([import('../src/routes/cleanup_task.routes.js'),import('../src/routes/admin.routes.js'),import('../src/routes/report.routes.js'),import('../src/middleware/rateLimit.middleware.js'),import('../src/middleware/errorHandler.middleware.js')]);
  const assigned=await admin.from('field_assignment_receipts').select('report_id,task_id').eq('crew_id',crewId).limit(1).single();if(assigned.error)throw assigned.error;
  const app=express();app.use(express.json());app.use(rateLimiter);app.use('/api/cleanup-tasks',tasks);app.use('/api/admin',adminRoutes);app.use('/api/reports',reportRoutes);app.use(errorHandler);
  server=app.listen(0,'127.0.0.1');await new Promise(resolve=>server.once('listening',resolve));server.unref();
  let active=0,peak=0;server.on('request',(_req,res)=>{active++;peak=Math.max(peak,active);res.once('finish',()=>active--);});
  const backend=`http://127.0.0.1:${server.address().port}`;
  const native=createClient(local.API_URL,local.ANON_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
  const signedIn=await native.auth.signInWithPassword({email,password});if(signedIn.error)throw signedIn.error;
  const adminJwt=signedIn.data.session.access_token;
  const rest=(table,query,bearer)=>({url:`${local.API_URL}/rest/v1/${table}?${query}`,bearer});
  const flows=[
   {name:'owner_feed',...rest('reports_view',`select=id,user_id,title,status,created_at&user_id=eq.${citizenId}&order=created_at.desc,id.desc&limit=20`,citizenJwt),validate:data=>{assert.equal(data.length,20);assert(data.every(row=>row.user_id===citizenId));}},
   {name:'moderation_queue',...rest('reports_view','select=id,status,validation_status,created_at&status=eq.unresolved&validation_status=eq.pending&order=created_at.asc,id.asc&limit=20',officerJwt),validate:data=>{assert.equal(data.length,20);assert(data.every(row=>row.validation_status==='pending'&&row.status==='unresolved'));}},
   {name:'dispatch_task_page',url:backend+'/api/cleanup-tasks?limit=50&page=1',bearer:officerJwt,validate:data=>assert.equal(data.length,50)},
   {name:'crew_assigned_report_detail',url:backend+`/api/reports/${assigned.data.report_id}`,bearer:crewJwt,validate:data=>{assert.equal(data.id,assigned.data.report_id);assert.equal(data.cleanup_task_id,assigned.data.task_id);}},
   {name:'unread_notifications',...rest('notifications',`select=id,user_id,is_read,created_at&user_id=eq.${citizenId}&is_read=eq.false&order=created_at.desc,id.desc&limit=20`,citizenJwt),validate:data=>{assert.equal(data.length,20);assert(data.every(row=>row.user_id===citizenId&&!row.is_read));}},
   {name:'public_map_viewport',...rest('public_reports','select=id,title,status,latitude,longitude,location_precision&latitude=gte.14.55&latitude=lte.14.70&longitude=gte.120.95&longitude=lte.121.10&order=created_at.desc,id.desc&limit=101',local.ANON_KEY),validate:data=>{assert(data.length>0&&data.length<=101);assert(data.every(row=>!('user_id' in row)));}},
   {name:'restrictive_parent_delete',url:backend+`/api/admin/users/${citizenId}`,bearer:adminJwt,method:'DELETE',expected:400,validate:data=>assert.equal(data.message,'Failed to delete user profile')}
  ];
  const request=async flow=>{const started=performance.now();const response=await fetch(flow.url,{method:flow.method??'GET',headers:{apikey:local.ANON_KEY,Authorization:`Bearer ${flow.bearer}`},signal:AbortSignal.timeout(30000)});const body=await response.text();assert.equal(response.status,flow.expected??200,`${flow.name}: unexpected HTTP ${response.status}`);flow.validate(JSON.parse(body));return {flow:flow.name,status:response.status,ms:performance.now()-started,bytes:Buffer.byteLength(body)};};
  const before=await metrics();const sequential={};
  for(const flow of flows){rateLimiter.resetKey('127.0.0.1');const samples=[];for(let n=0;n<20;n++)samples.push(await request(flow));sequential[flow.name]=summarize(samples);}
  // Reset only the fixture process' in-memory limiter between phases. The
  // production 100/IP/window limit stays enabled for the 100-request burst.
  rateLimiter.resetKey('127.0.0.1');peak=0;
  let offered=0,peakOffered=0;
  const started=performance.now();
  const pending=Array.from({length:100},async(_,index)=>{offered++;peakOffered=Math.max(peakOffered,offered);try{return await request(flows[index%flows.length]);}finally{offered--;}});
  const completed=Promise.allSettled(pending);const during=await metrics();const results=await completed;
  const rejected=results.filter(result=>result.status==='rejected');
  if(rejected.length)throw new AggregateError(rejected.map(result=>result.reason),'Concurrent application gate failed');
  const rows=results.map(result=>result.value);const after=await metrics();
  const invariants=await admin.from('reports').select('id',{count:'exact',head:true}).eq('user_id',citizenId);if(invariants.error)throw invariants.error;assert.equal(invariants.count,500);
  return {scope:'Supabase HTTP application query contracts plus production task/admin routers, auth/suspension/role/rate-limit/error middleware; not browser or all-app HTTP middleware',dataset:'10000 reports, 1000 tasks, 5000 explicit notifications plus native assignment notifications, 1000 native canonical receipts',query_limits:'20-row owner/moderation/receipt/notification pages; 50 tasks; 101 safe map rows',jwt_scope:'native local Auth users and password-login sessions; no hosted credentials',sequential,concurrent:{offered_clients:100,peak_offered:peakOffered,backend_peak_in_flight:peak,elapsed_ms:performance.now()-started,aggregate:summarize(rows),flows:Object.fromEntries(flows.map(flow=>[flow.name,summarize(rows.filter(row=>row.flow===flow.name))])),unexpected_errors:0},database:{before,during,after},parent_delete:'Expected HTTP 400 proves history protection; successful rich account deletion is not claimed; native cascades are measured separately',limitations:['one local 100-request burst; not sustained production capacity','initial bounded notification query; actual Realtime subscriber fanout is a separate gate','bounded query contracts; existing unbounded client lists require separate caller validation','no CPU<5% or pool-bound claim from connection snapshots']};
 }finally{
  server?.close();
  const logs=await admin.from('system_logs').delete().eq('user_id',adminId);if(logs.error)throw logs.error;
  const deleted=await admin.from('profiles').delete().eq('id',adminId);if(deleted.error)throw deleted.error;
  const removed=await admin.auth.admin.deleteUser(adminId);if(removed.error)throw removed.error;
 }
}
