import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {readFileSync,writeFileSync} from 'node:fs';
const docker='C:/Program Files/Docker/Docker/resources/bin/docker.exe';
const container='supabase_db_ecopin-recovery-20261012';
const inspected=JSON.parse(execFileSync(docker,['inspect',container],{encoding:'utf8'}))[0];
assert.ok(Object.values(inspected.Config.Labels??{}).includes('ecopin-recovery-20261012'),'This verifier requires the owned local recovery stack');
function query(input,user='postgres',name='ecopin_schedule_verifier'){
 const p=spawn(docker,['exec','-i','-e','PGAPPNAME='+name,container,'psql','-U',user,'-d','postgres','-X','-q','-t','-A','-v','ON_ERROR_STOP=1'],{stdio:['pipe','pipe','pipe']});
 let stdout='',stderr='';p.stdout.on('data',d=>stdout+=d);p.stderr.on('data',d=>stderr+=d);
 const done=new Promise((resolve,reject)=>{p.on('error',reject);p.on('close',code=>{
  if(code){try{writeFileSync('C:/dev/App-Builders-Hackathon/.ecopin-optimization/.private/local-supabase-recovery/scheduler-error.private.log',stderr);}catch{}reject(Error('Scheduler verification failed; diagnostic saved privately when folder access permits'));}
  else resolve(stdout.trim());
 });});p.stdin.end(input);return {p,done};
}
const checks=JSON.parse(await query(readFileSync('tests/sql/scheduled-jobs-and-recovery-regression.sql','utf8'),'supabase_admin').done);
for(const [lock,call] of [[72631008,'public.advance_report_lifecycle()'],[72631017,'workflow_private.run_retention_maintenance(500)']]){
 const name='ecopin_schedule_holder_'+lock;
 const holder=query(`BEGIN; SELECT pg_advisory_xact_lock(${lock}); SELECT pg_sleep(4); ROLLBACK;`,'postgres',name);
 const completed=holder.done;let observed=false;
 try{
  for(let i=0;i<30;i++){
   observed=(await query(`SELECT EXISTS(SELECT FROM pg_stat_activity WHERE application_name='${name}' AND wait_event='PgSleep');`).done)==='t';
   if(observed)break;await new Promise(r=>setTimeout(r,50));
  }
  assert.ok(observed,'First physical connection must hold the lock');
  const second=JSON.parse(await query(`BEGIN; SET LOCAL statement_timeout='2s'; SELECT ${call}; ROLLBACK;`).done);
  assert.equal(second.skipped,true,'Second physical connection must skip overlapping maintenance');
  assert.equal((await query(`SELECT EXISTS(SELECT FROM pg_stat_activity WHERE application_name='${name}' AND wait_event='PgSleep');`).done),'t','Second call must finish before the holder releases');
  checks.push({test:'separate-connection overlap fenced for '+lock,status:'PASS'});
 }finally{await completed;}
}
const evidence={verified_at:new Date().toISOString(),checks,sourceOriginalDefects:['same-transaction advisory locks are reentrant','invalid report_issue_type Trash','original COMMIT could retain the first fixture'],scope:'Owned local Supabase recovery stack; all fixture row changes roll back; two real physical connections for fencing',doesNotCertify:'operational lag alert delivery or production downtime recovery'};
if(process.env.ECOPIN_SCHEDULE_EVIDENCE_PATH)writeFileSync(process.env.ECOPIN_SCHEDULE_EVIDENCE_PATH,JSON.stringify(evidence,null,2));
console.log(JSON.stringify(evidence));
