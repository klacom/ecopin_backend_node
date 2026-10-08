import assert from 'node:assert/strict';
import {execFileSync,spawn} from 'node:child_process';
import {readFileSync} from 'node:fs';
const container='ecopin-slice-a-postgis';
const database=`dispatch_test_${process.pid}_${Date.now()}`;
function sql(db,s){return execFileSync('docker',['exec','-i',container,'psql','-X','-qAt','-U','postgres','-d',db,'-v','ON_ERROR_STOP=1'],{input:s,encoding:'utf8',timeout:30000});}
let created=false;
try {
 sql('postgres',`create database ${database};`);created=true;
 for(const file of ['tests/sql/lifecycle-bootstrap.sql','tests/sql/dispatch-bootstrap.sql','migrations/20261008064832_report_lifecycle_foundation.sql','migrations/20261008071533_slice_a_dispatch_claims.sql','migrations/20261008072440_slice_a_fleet_and_failures.sql','migrations/20261008073726_slice_a_route_publication.sql','migrations/20261008075500_slice_a_mobile_authority.sql','migrations/20261008083500_slice_a_report_photo_authority.sql','migrations/20261008085000_slice_a_mobile_view_version.sql','migrations/20261008101500_slice_a_manual_task_compatibility.sql','migrations/20261008134000_slice_b_enums.sql','migrations/20261008134500_slice_b_schema.sql','migrations/20261008135000_slice_b_jobs.sql','migrations/20261008135500_slice_b_snapshot.sql','migrations/20261008140000_slice_b_mixed_draft.sql','migrations/20261008141000_slice_b_mixed_commit.sql','migrations/20261008142000_slice_b_mixed_routes.sql'])sql(database,readFileSync(file,'utf8'));
 console.log('All migration definitions compile');
 sql(database,readFileSync('tests/sql/dispatch-regression.sql','utf8'));
 console.log('Dispatch and authority regression assertions passed');
 sql(database,readFileSync('tests/sql/mixed-dispatch-regression.sql','utf8'));
 console.log('Mixed job and optional-satellite database assertions passed');
 sql(database,`
 insert into field_crews(id,name,member_profile_ids,shift_start,shift_end,max_tasks_per_shift) values('00000000-0000-0000-0000-000000000020','Second crew',array['00000000-0000-0000-0000-000000000003'::uuid],'08:00','17:00',10);
 insert into clusters(id,center,report_count) values('00000000-0000-0000-0000-000000000100',extensions.st_setsrid(extensions.st_makepoint(121,14),4326),1);
 insert into reports(id,cluster_id,location) values('00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000100',extensions.st_setsrid(extensions.st_makepoint(121,14),4326)::extensions.geography);
 insert into dispatch_plans(id,created_by) values('00000000-0000-0000-0000-000000000102','00000000-0000-0000-0000-000000000001'),('00000000-0000-0000-0000-000000000103','00000000-0000-0000-0000-000000000001');
 insert into dispatch_plan_items(dispatch_plan_id,cluster_id,report_ids,group_key,planned_crew_id,is_selected,estimated_duration_minutes,estimated_work_minutes,crew_snapshot)
 select p,'00000000-0000-0000-0000-000000000100',array['00000000-0000-0000-0000-000000000101'::uuid],'race',c,true,45,30,'{"speed_factor":1,"service_time_factor":1}' from (values
 ('00000000-0000-0000-0000-000000000102'::uuid,'00000000-0000-0000-0000-000000000010'::uuid),('00000000-0000-0000-0000-000000000103'::uuid,'00000000-0000-0000-0000-000000000020'::uuid)) v(p,c);
 `);
 async function hold(statement) {
   const child=spawn('docker',['exec','-i',container,'psql','-X','-qAt','-U','postgres','-d',database,'-v','ON_ERROR_STOP=1'],{stdio:['pipe','pipe','pipe']});
   let output='',errors='';
   const done=new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',code=>code===0?resolve(output):reject(new Error(errors)));});done.catch(()=>{});
   child.stderr.on('data',chunk=>{errors+=chunk;});
   await new Promise((resolve,reject)=>{
     const timer=setTimeout(()=>{child.kill();reject(new Error('Concurrent test session timed out'));},10000);
     child.stdout.on('data',chunk=>{output+=chunk;if(output.includes('SESSION_READY')){clearTimeout(timer);resolve();}});
     child.once('error',error=>{clearTimeout(timer);reject(error);});
     child.once('exit',code=>{clearTimeout(timer);reject(new Error(`Concurrent session ended ${code}: ${errors}`));});
     child.stdin.write(`begin; ${statement};\n\\echo SESSION_READY\n`);
   });
   return {child,done,finish(){child.stdin.end('commit;\n\\q\n');return done;}};
 }
 let first=await hold("select public.commit_dispatch_plan('00000000-0000-0000-0000-000000000102','00000000-0000-0000-0000-000000000001')");
 try {
   const second=JSON.parse(sql(database,"select public.commit_dispatch_plan('00000000-0000-0000-0000-000000000103','00000000-0000-0000-0000-000000000001');").trim());
   assert.equal(second.results[0].reason,'stale_anchor');await first.finish();first=null;
   assert.equal(sql(database,"select count(*) from cleanup_tasks where '00000000-0000-0000-0000-000000000101'::uuid=any(report_ids);").trim(),'1');
 }finally{first?.child.kill();}
 console.log('Two concurrent plans cannot double-claim a report: passed');
 const manualReport='00000000-0000-0000-0000-000000000110';
 sql(database,`insert into reports(id,location) values('${manualReport}',extensions.st_setsrid(extensions.st_makepoint(121,14),4326)::extensions.geography);`);
 const manualCall=`select public.create_manual_cleanup_task('00000000-0000-0000-0000-000000000001',array['${manualReport}'::uuid],'Manual race',null,array['00000000-0000-0000-0000-000000000002'::uuid],null)`;
 first=await hold(manualCall);
 try {
   const second=JSON.parse(sql(database,`${manualCall};`).trim());
   assert.equal(second.status,'conflict');
   await first.finish();first=null;
   assert.equal(sql(database,`select count(*) from cleanup_tasks where '${manualReport}'::uuid=any(report_ids);`).trim(),'1');
 }finally{first?.child.kill();}
 console.log('Concurrent manual tasks cannot double-claim a report: passed');
 sql(database,"update cleanup_tasks set route_status='ready',assigned_crew_ids=array['00000000-0000-0000-0000-000000000002'::uuid,'00000000-0000-0000-0000-000000000003'::uuid],assigned_at=now() where source_plan_id='00000000-0000-0000-0000-000000000102';");
 const version=Number(sql(database,"select fc_version from reports where id='00000000-0000-0000-0000-000000000101';").trim());
 first=await hold(`select public.apply_fc_operation('00000000-0000-0000-0000-000000000002','race-first','fc.report.update_details','00000000-0000-0000-0000-000000000101','report','{"notes":"first"}',${version})`);
 try {
   const second=spawn('docker',['exec','-i',container,'psql','-X','-qAt','-U','postgres','-d',database,'-v','ON_ERROR_STOP=1'],{stdio:['pipe','pipe','pipe']});
   let output='',errors='';second.stdout.on('data',chunk=>{output+=chunk;});second.stderr.on('data',chunk=>{errors+=chunk;});
   const done=new Promise((resolve,reject)=>{second.once('error',reject);second.once('exit',code=>code===0?resolve():reject(new Error(errors)));});done.catch(()=>{});
   second.stdin.end(`select public.apply_fc_operation('00000000-0000-0000-0000-000000000003','race-second','fc.report.update_details','00000000-0000-0000-0000-000000000101','report','{"notes":"second"}',${version});`);
   await first.finish();first=null;await done;
   assert.equal(JSON.parse(output.trim()).status,'conflict');
   assert.equal(sql(database,"select notes from reports where id='00000000-0000-0000-0000-000000000101';").trim(),'first');
 }finally{first?.child.kill();}
 console.log('Concurrent mobile writes compare version under the row lock: passed');

}finally{if(created)sql('postgres',`drop database ${database} with(force);`);}
