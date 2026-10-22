import assert from 'node:assert/strict';
import {execFileSync,execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {readFileSync,writeFileSync} from 'node:fs';
import {randomUUID} from 'node:crypto';
const dockerPath='C:/Program Files/Docker/Docker/resources/bin/docker.exe';
const container=`ecopin-worker-fencing-${process.pid}-${Date.now()}`;
const docker=(args,input)=>execFileSync(dockerPath,args,{input,encoding:'utf8',timeout:60000,maxBuffer:4*1024*1024});
const sql=(input,database='audit')=>docker(['exec','-i',container,'psql','-X','-qAt','-U','postgres','-d',database,'-v','ON_ERROR_STOP=1'],input);
const run=promisify(execFile);
const read=name=>readFileSync(name,'utf8');
const asyncSql=input=>run(dockerPath,['exec',container,'psql','-X','-qAt','-U','postgres','-d','audit','-v','ON_ERROR_STOP=1','-c',input],{encoding:'utf8',timeout:20000});
let created=false;
try{
 docker(['run','--rm','--network','none','-d','--name',container,'-e','POSTGRES_HOST_AUTH_METHOD=trust','postgis/postgis:17-3.5']);created=true;
 let ready=false;
 for(let n=0;n<60;n++){try{if(sql("SELECT current_setting('listen_addresses');",'postgres').trim()==='*'){ready=true;break;}}catch{}await new Promise(resolve=>setTimeout(resolve,500));}
 assert.ok(ready);sql('CREATE DATABASE audit TEMPLATE template0;','postgres');
 sql(read('tests/sql/optimization-catalog-baseline.sql'));sql(read('tests/sql/optimization-synthetic-fixtures.sql'));
 sql('BEGIN;\n'+read('migrations/20261012093000_recover_expired_planning_jobs_in_watchdog.sql')+'\nCOMMIT;');
 const actor=sql("SELECT id FROM public.profiles WHERE role::text='admin' LIMIT 1;").trim();
 const a=randomUUID(),b=randomUUID(),stranger=randomUUID();
 const enqueue=key=>JSON.parse(sql(`SET ROLE service_role; SELECT public.enqueue_plan_generation('${actor}','standard','{"mode":"standard"}'::jsonb,'${key}');`)).jobId;
 const firstId=enqueue('real-concurrency-first-'+randomUUID());
 const secondId=enqueue('real-concurrency-second-'+randomUUID());
 async function held(){for(let n=0;n<30;n++){if(sql("SELECT EXISTS(SELECT FROM pg_stat_activity WHERE application_name='ecopin_worker_a' AND wait_event='PgSleep');").trim()==='t')return true;await new Promise(resolve=>setTimeout(resolve,100));}return false;}
 const first=asyncSql(`SET application_name='ecopin_worker_a'; BEGIN; SET LOCAL ROLE service_role; SELECT public.claim_plan_generation('${a}'); SELECT pg_sleep(5); COMMIT;`);
 assert.ok(await held(),'First real connection must hold its claim transaction');
 const second=await asyncSql(`SET application_name='ecopin_worker_b'; BEGIN; SET LOCAL statement_timeout='2s'; SET LOCAL ROLE service_role; SELECT public.claim_plan_generation('${b}'); COMMIT;`);
 const secondClaim=JSON.parse(second.stdout.trim());
 assert.equal(secondClaim.id,secondId);assert.equal(secondClaim.worker_token,b);
 assert.ok(await held(),'Second claim must finish while first connection still holds its row');
 const firstResult=await first;
 const firstClaim=JSON.parse(firstResult.stdout.trim());assert.equal(firstClaim.id,firstId);assert.equal(firstClaim.worker_token,a);
 assert.equal(sql(`SELECT count(*)=2 AND count(DISTINCT worker_token)=2 FROM public.plan_generation_jobs WHERE id IN ('${firstId}','${secondId}') AND status='running';`).trim(),'t');
 assert.equal(sql(`SET ROLE service_role; SELECT public.claim_plan_generation('${stranger}') IS NULL;`).trim(),'t');
 const fenced=id=>`DO $$ BEGIN BEGIN PERFORM public.finish_plan_generation('${id}','${stranger}',NULL,'unexpected_finish'); RAISE EXCEPTION 'Incorrect worker was accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'Planning job lease expired' THEN RAISE; END IF; END; END $$;`;
 sql('SET ROLE service_role; '+fenced(firstId));
 sql(`UPDATE public.plan_generation_jobs SET lease_until=clock_timestamp()-interval '1 second' WHERE id='${firstId}';`);
 const recovery=JSON.parse(sql('SET ROLE service_role; SELECT public.expire_unpublished_dispatch_claims();'));
 assert.equal(recovery.recoveredPlanningJobs,1);
 assert.equal(sql(`SELECT status='failed' AND error_code='worker_lease_expired' FROM public.plan_generation_jobs WHERE id='${firstId}';`).trim(),'t');
 sql(`SET ROLE service_role; DO $$ BEGIN BEGIN PERFORM public.finish_plan_generation('${firstId}','${a}',NULL,'stale_finish'); RAISE EXCEPTION 'Stale worker accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'Planning job lease expired' THEN RAISE; END IF; END; END $$;`);
 const finished=JSON.parse(sql(`SET ROLE service_role; SELECT public.finish_plan_generation('${secondId}','${b}',NULL,'synthetic_expected_failure');`));
 assert.equal(finished.status,'failed');assert.equal(finished.error_code,'synthetic_expected_failure');
 const result={verified_at:new Date().toISOString(),checks:['two physical connections claim different queued jobs','second connection completes while first holds its row','two distinct worker tokens persisted','empty queue returns null','stranger worker cannot finish active claim','watchdog recovers expired worker lease','stale worker cannot overwrite recovered job','correct worker can finish its own remaining job'],scope:'Disposable isolated database; synthetic jobs only; no production workers or queues touched'};
 if(process.env.ECOPIN_WORKER_EVIDENCE_PATH)writeFileSync(process.env.ECOPIN_WORKER_EVIDENCE_PATH,JSON.stringify(result,null,2));
 console.log(JSON.stringify(result));
}catch(error){if(created)console.error(docker(['logs',container]));throw error;}
finally{if(created)docker(['rm','-f',container]);}
