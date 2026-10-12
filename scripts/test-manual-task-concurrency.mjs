import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import {spawn,execFileSync} from 'node:child_process';
import {writeFileSync} from 'node:fs';
const docker='C:/Program Files/Docker/Docker/resources/bin/docker.exe';
const container='supabase_db_ecopin-recovery-20261012';
const inspected=JSON.parse(execFileSync(docker,['inspect',container],{encoding:'utf8'}))[0];
assert.ok(Object.values(inspected.Config.Labels??{}).includes('ecopin-recovery-20261012'));
function sql(input,name='ecopin_manual_verifier'){
 const p=spawn(docker,['exec','-i','-e','PGAPPNAME='+name,container,'psql','-U','postgres','-d','postgres','-X','-q','-t','-A','-v','ON_ERROR_STOP=1'],{stdio:['pipe','pipe','pipe']});
 let out='',err='';p.stdout.on('data',d=>out+=d);p.stderr.on('data',d=>err+=d);
 const done=new Promise((resolve,reject)=>p.on('close',code=>{if(code){writeFileSync('C:/dev/App-Builders-Hackathon/.ecopin-optimization/.private/local-supabase-recovery/manual-concurrency-error.private.log',err);reject(Error('Local manual-concurrency SQL failed; diagnostic saved privately'));}else resolve(out.trim());}));p.stdin.end(input);return {done,p};
}
const actor=await sql("SELECT id FROM public.profiles WHERE role::text='admin' LIMIT 1;").done;
const member=await sql("SELECT id FROM public.profiles WHERE role::text='field_crew' LIMIT 1;").done;
assert.match(actor,/^[a-f0-9-]{36}$/);assert.match(member,/^[a-f0-9-]{36}$/);
const report=crypto.randomUUID();let holder;
try{
 await sql(`INSERT INTO public.reports(id,user_id,title,description,issue_type,validation_status,status,location) VALUES('${report}','${actor}','Local concurrent manual fixture','Owned local test only','waste','approved','unresolved',extensions.st_setsrid(extensions.st_makepoint(121.05,14.55),4326)::extensions.geography);`).done;
 const call=`public.create_manual_cleanup_task('${actor}',ARRAY['${report}'::uuid],'Local concurrent assignment',NULL,ARRAY['${member}'::uuid],NULL)`;
 holder=sql(`BEGIN; SELECT ${call}; SELECT pg_sleep(5); COMMIT;`,'ecopin_manual_holder');
 let held=false;
 for(let i=0;i<30;i++){held=(await sql("SELECT EXISTS(SELECT FROM pg_stat_activity WHERE application_name='ecopin_manual_holder' AND wait_event='PgSleep');").done)==='t';if(held)break;await new Promise(r=>setTimeout(r,50));}
 assert.ok(held,'First physical connection must hold the claim');
 const contender=JSON.parse(await sql(`BEGIN; SET LOCAL statement_timeout='2s'; SELECT ${call}; COMMIT;`,'ecopin_manual_contender').done);
 assert.equal(contender.status,'conflict');
 assert.equal((await sql("SELECT EXISTS(SELECT FROM pg_stat_activity WHERE application_name='ecopin_manual_holder' AND wait_event='PgSleep');").done),'t');
 const first=JSON.parse((await holder.done).split('\n').find(x=>x.startsWith('{')));assert.equal(first.status,'created');
 assert.equal(await sql(`SELECT count(*) FROM public.notifications WHERE report_id='${report}' AND user_id='${member}' AND type='general' AND title='New Task Assigned';`).done,'1');
 assert.equal(await sql(`SELECT count(*) FROM public.cleanup_tasks WHERE id=(SELECT cleanup_task_id FROM public.reports WHERE id='${report}');`).done,'1');
 const evidence={at:new Date().toISOString(),twoPhysicalConnections:true,secondClaimConflictsWhileFirstHeld:true,oneCommittedTask:true,oneAssignmentNotification:true,scope:'Owned local Supabase stack; synthetic report/task only; no hosted writes'};
 writeFileSync('C:/dev/App-Builders-Hackathon/.ecopin-optimization/MANUAL_TASK_REAL_CONCURRENCY_RECHECK.json',JSON.stringify(evidence,null,2));console.log(JSON.stringify(evidence));
}finally{
 if(holder)await holder.done.catch(()=>{});
 await sql(`BEGIN; DO $$ DECLARE task uuid; BEGIN SELECT cleanup_task_id INTO task FROM public.reports WHERE id='${report}'; DELETE FROM public.field_assignment_receipts WHERE report_id='${report}'; DELETE FROM public.dispatch_access_blocks WHERE report_id='${report}'; DELETE FROM public.sweeper_audit_log WHERE (entity_type='REPORT' AND entity_id='${report}') OR (entity_type='TASK' AND entity_id=task::text); DELETE FROM public.reports WHERE id='${report}'; IF task IS NOT NULL THEN DELETE FROM public.cleanup_tasks WHERE id=task; END IF; END $$; COMMIT;`).done;
}
