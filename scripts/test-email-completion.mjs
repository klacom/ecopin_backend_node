import assert from 'node:assert/strict';
import {execFileSync,execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {readFileSync} from 'node:fs';
import {randomUUID} from 'node:crypto';
const dockerPath='C:/Program Files/Docker/Docker/resources/bin/docker.exe';
const container=`ecopin-email-completion-${process.pid}-${Date.now()}`;
const docker=(args,input)=>execFileSync(dockerPath,args,{input,encoding:'utf8',timeout:60000,maxBuffer:4*1024*1024});
const sql=(input,database='audit')=>docker(['exec','-i',container,'psql','-X','-qAt','-U','postgres','-d',database,'-v','ON_ERROR_STOP=1'],input);
const file=name=>readFileSync(name,'utf8');
const migrate=name=>sql('BEGIN;\n'+file(name)+'\nCOMMIT;');
const up=process.argv[2]??'migrations/20261011152906_atomically_complete_email_verification.sql';
const down=process.argv[3]??'migrations/rollback/20261011152906_atomically_complete_email_verification.sql';
const regression=process.argv[4]??'tests/sql/email-verification-completion-regression.sql';
assert.ok(up&&down&&regression,'Pass candidate up/down/regression paths');
const fingerprint="SELECT coalesce(to_regprocedure('public.complete_email_verification(uuid,uuid)')::text,'absent');";
function checks(){const rows=sql(file(regression)).trim().split(/\r?\n/).map(line=>line.split('|'));assert.equal(rows.length,14);assert.ok(rows.every(row=>row[1]==='PASS'),JSON.stringify(rows));}
let created=false;
try{
  docker(['run','--rm','--network','none','-d','--name',container,'-e','POSTGRES_HOST_AUTH_METHOD=trust','postgis/postgis:17-3.5']);created=true;
  let ready=false;
  for(let n=0;n<60;n++){try{if(sql("select current_setting('listen_addresses');",'postgres').trim()==='*'){ready=true;break;}}catch{}await new Promise(resolve=>setTimeout(resolve,500));}
  assert.ok(ready);sql('create database audit template template0;','postgres');
  sql(file('tests/sql/optimization-catalog-baseline.sql'));
  sql(file('tests/sql/optimization-synthetic-fixtures.sql'));
  assert.equal(sql(fingerprint).trim(),'absent');migrate(up);checks();
  // Only this disposable local database gets an Auth shim row, never live Auth.
  const actor=randomUUID(),token=randomUUID(),missing=randomUUID(),missingToken=randomUUID();
  sql(`INSERT INTO auth.users(id,email) VALUES('${actor}','concurrency@example.invalid'),('${missing}','missing@example.invalid');
       INSERT INTO public.profiles(id,role,is_email_verified) VALUES('${actor}','citizen',false);
       INSERT INTO public.email_verifications(id,user_id,expires_at) VALUES('${token}','${actor}',now()+interval '1 hour'),('${missingToken}','${missing}',now()+interval '1 hour');`);
  assert.equal(sql(`SET ROLE service_role; SELECT public.complete_email_verification('${missingToken}','${missing}');`).trim(),'f');
  assert.equal(sql(`SELECT used_at IS NULL FROM public.email_verifications WHERE id='${missingToken}';`).trim(),'t');
  const run=promisify(execFile);
  const runSql=command=>run(dockerPath,['exec',container,'psql','-X','-qAt','-U','postgres','-d','audit','-v','ON_ERROR_STOP=1','-c',command],{encoding:'utf8',timeout:30000});
  async function observed(condition){for(let attempt=0;attempt<20;attempt++){if(sql(`SELECT EXISTS(SELECT FROM pg_stat_activity WHERE ${condition});`).trim()==='t')return true;await new Promise(resolve=>setTimeout(resolve,100));}return false;}
  const first=runSql(`SET application_name='ecopin_first_redemption'; BEGIN; SET LOCAL ROLE service_role; SELECT public.complete_email_verification('${token}','${actor}'); SELECT pg_sleep(5); COMMIT;`);
  assert.ok(await observed("application_name='ecopin_first_redemption' AND wait_event='PgSleep'"),'First redemption must hold its transaction open');
  const second=runSql(`SET application_name='ecopin_second_redemption'; BEGIN; SET LOCAL ROLE service_role; SELECT public.complete_email_verification('${token}','${actor}'); COMMIT;`);
  assert.ok(await observed("application_name='ecopin_second_redemption' AND wait_event_type='Lock'"),'Second redemption must actually wait for the first transaction');
  const parallel=await Promise.all([first,second]);
  assert.deepEqual(parallel.map(r=>r.stdout.trim()).sort(),['f','t']);
  assert.equal(sql(`SELECT p.is_email_verified AND e.used_at IS NOT NULL FROM public.profiles p JOIN public.email_verifications e ON e.user_id=p.id WHERE e.id='${token}';`).trim(),'t');
  // A failed profile write rolls back both writes and keeps the link retryable.
  const failedToken=randomUUID();
  sql(`UPDATE public.profiles SET is_email_verified=false WHERE id='${actor}';
       INSERT INTO public.email_verifications(id,user_id,expires_at) VALUES('${failedToken}','${actor}',now()+interval '1 hour');
       CREATE FUNCTION public.audit_reject_verification() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RAISE EXCEPTION 'Synthetic profile failure'; END$$;
       CREATE TRIGGER reject_verification BEFORE UPDATE OF is_email_verified ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.audit_reject_verification();`);
  assert.throws(()=>sql(`SET ROLE service_role; SELECT public.complete_email_verification('${failedToken}','${actor}');`));
  assert.equal(sql(`SELECT NOT p.is_email_verified AND e.used_at IS NULL FROM public.profiles p JOIN public.email_verifications e ON e.user_id=p.id WHERE e.id='${failedToken}';`).trim(),'t');
  sql('DROP TRIGGER reject_verification ON public.profiles; DROP FUNCTION public.audit_reject_verification();');
  migrate(down);assert.equal(sql(fingerprint).trim(),'absent');migrate(up);checks();
  console.log('Fresh PostGIS: 14 SQL checks PASS twice; observed concurrent lock wait and exactly one redemption success; missing/failed profile leaves token unused; rollback restores function absence');
}catch(error){if(created)console.error(docker(['logs',container]));throw error;}
finally{if(created)docker(['rm','-f',container]);}
