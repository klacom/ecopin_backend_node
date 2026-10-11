import assert from 'node:assert/strict';
import {execFileSync,execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {readFileSync} from 'node:fs';
import {randomUUID} from 'node:crypto';
const dockerPath='C:/Program Files/Docker/Docker/resources/bin/docker.exe';
const container=`ecopin-email-issuance-${process.pid}-${Date.now()}`;
const docker=(args,input)=>execFileSync(dockerPath,args,{input,encoding:'utf8',timeout:60000,maxBuffer:4*1024*1024});
const sql=(input,database='audit')=>docker(['exec','-i',container,'psql','-X','-qAt','-U','postgres','-d',database,'-v','ON_ERROR_STOP=1'],input);
const file=name=>readFileSync(name,'utf8');
const migrate=name=>sql('BEGIN;\n'+file(name)+'\nCOMMIT;');
const up=process.argv[2]??'migrations/20261011154236_store_verification_digests_and_bound_issuance.sql';
const down=process.argv[3]??'migrations/rollback/20261011154236_store_verification_digests_and_bound_issuance.sql';
const regression=process.argv[4]??'tests/sql/email-verification-issuance-regression.sql';
assert.ok(up&&down&&regression,'Pass up/down/regression paths');
const absent="SELECT to_regprocedure('public.issue_email_verification(uuid,text,integer)') IS NULL;";
function checks(path,count){const rows=sql(file(path)).trim().split(/\r?\n/).map(line=>line.split('|'));assert.equal(rows.length,count);assert.ok(rows.every(row=>row[1]==='PASS'),JSON.stringify(rows));}
let created=false;
try{
 docker(['run','--rm','--network','none','-d','--name',container,'-e','POSTGRES_HOST_AUTH_METHOD=trust','postgis/postgis:17-3.5']);created=true;
 let ready=false;
 for(let n=0;n<60;n++){try{if(sql("select current_setting('listen_addresses');",'postgres').trim()==='*'){ready=true;break;}}catch{}await new Promise(resolve=>setTimeout(resolve,500));}
 assert.ok(ready);sql('create database audit template template0;','postgres');
 sql(file('tests/sql/optimization-catalog-baseline.sql'));sql(file('tests/sql/optimization-synthetic-fixtures.sql'));
 migrate('migrations/20261011152906_atomically_complete_email_verification.sql');
 assert.equal(sql(absent).trim(),'t');migrate(up);
 checks(regression,21);checks('tests/sql/email-verification-completion-regression.sql',14);
 const actor=randomUUID(),digestA='a'.repeat(64),digestB='b'.repeat(64);
 sql(`INSERT INTO auth.users(id,email) VALUES('${actor}','issuance@example.invalid'); INSERT INTO public.profiles(id,role,is_email_verified) VALUES('${actor}','citizen',false);`);
 const run=promisify(execFile);
 const runSql=command=>run(dockerPath,['exec',container,'psql','-X','-qAt','-U','postgres','-d','audit','-v','ON_ERROR_STOP=1','-c',command],{encoding:'utf8',timeout:30000});
 async function observed(condition){for(let n=0;n<20;n++){if(sql(`SELECT EXISTS(SELECT FROM pg_stat_activity WHERE ${condition});`).trim()==='t')return true;await new Promise(resolve=>setTimeout(resolve,100));}return false;}
 const first=runSql(`SET application_name='ecopin_first_issuance'; BEGIN; SET LOCAL ROLE service_role; SELECT public.issue_email_verification('${actor}','${digestA}',24); SELECT pg_sleep(5); COMMIT;`);
 assert.ok(await observed("application_name='ecopin_first_issuance' AND wait_event='PgSleep'"));
 const second=runSql(`SET application_name='ecopin_second_issuance'; BEGIN; SET LOCAL ROLE service_role; SELECT public.issue_email_verification('${actor}','${digestB}',24); COMMIT;`);
 assert.ok(await observed("application_name='ecopin_second_issuance' AND wait_event_type='Lock'"));
 const results=await Promise.all([first,second]);
 assert.match(results[0].stdout.trim(),/^[0-9a-f-]{36}$/);assert.equal(results[1].stdout.trim(),'');
 assert.equal(sql(`SELECT count(*)=1 AND bool_and(token IS NULL) FROM public.email_verifications WHERE user_id='${actor}';`).trim(),'t');
 sql(`UPDATE public.email_verifications SET created_at=clock_timestamp()-interval '61 seconds' WHERE user_id='${actor}';`);
 assert.match(sql(`SET ROLE service_role; SELECT public.issue_email_verification('${actor}','${digestB}',24);`).trim(),/^[0-9a-f-]{36}$/);
 const fingerprint="SELECT md5(jsonb_agg(to_jsonb(e) ORDER BY id)::text) FROM public.email_verifications e;";
 const before=sql(fingerprint).trim();migrate(down);assert.equal(sql(absent).trim(),'t');assert.equal(sql(fingerprint).trim(),before);
 migrate(up);checks(regression,21);checks('tests/sql/email-verification-completion-regression.sql',14);
 console.log('Fresh PostGIS: 35 SQL checks PASS twice; observed concurrent issuance lock wait with exactly one issuance; cooldown allows later resend; rollback preserves digest rows and source reapplication passes');
}catch(error){if(created)console.error(docker(['logs',container]));throw error;}
finally{if(created)docker(['rm','-f',container]);}
