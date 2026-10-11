import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync,writeFileSync} from 'node:fs';
import {randomUUID} from 'node:crypto';
const dockerPath='C:/Program Files/Docker/Docker/resources/bin/docker.exe';
const container=`ecopin-resend-lookup-${process.pid}-${Date.now()}`;
const docker=(args,input)=>execFileSync(dockerPath,args,{input,encoding:'utf8',timeout:60000,maxBuffer:4*1024*1024});
const sql=(input,database='audit')=>docker(['exec','-i',container,'psql','-X','-qAt','-U','postgres','-d',database,'-v','ON_ERROR_STOP=1'],input);
const file=name=>readFileSync(name,'utf8');
const migrate=name=>sql('BEGIN;\n'+file(name)+'\nCOMMIT;');
const [up,down,regression]=process.argv.slice(2);
assert.ok(up&&down&&regression,'Pass exact up/down/regression sources');
const absent="SELECT to_regprocedure('public.find_email_verification_user(text)') IS NULL AND to_regprocedure('workflow_private.find_email_verification_user(text)') IS NULL;";
const fingerprint="SELECT md5(jsonb_build_object('users',(SELECT jsonb_agg(to_jsonb(u) ORDER BY id) FROM auth.users u),'profiles',(SELECT jsonb_agg(to_jsonb(p) ORDER BY id) FROM public.profiles p),'auth_acl',(SELECT relacl::text FROM pg_class WHERE oid='auth.users'::regclass),'profile_acl',(SELECT relacl::text FROM pg_class WHERE oid='public.profiles'::regclass))::text);";
function checks(){const rows=sql(file(regression)).trim().split(/\r?\n/).map(line=>line.split('|'));assert.equal(rows.length,19);assert.ok(rows.every(row=>row[1]==='PASS'),JSON.stringify(rows));}
let created=false;
try{
 docker(['run','--rm','--network','none','-d','--name',container,'-e','POSTGRES_HOST_AUTH_METHOD=trust','postgis/postgis:17-3.5']);created=true;
 let ready=false;
 for(let n=0;n<60;n++){try{if(sql("SELECT current_setting('listen_addresses');",'postgres').trim()==='*'){ready=true;break;}}catch{}await new Promise(resolve=>setTimeout(resolve,500));}
 assert.ok(ready);sql('CREATE DATABASE audit TEMPLATE template0;','postgres');
 sql(file('tests/sql/optimization-catalog-baseline.sql'));sql(file('tests/sql/optimization-synthetic-fixtures.sql'));
 // The captured baseline has a limited Auth shim. Recreate the inspected live
 // email index here only; the production migration never edits managed Auth.
 sql("CREATE INDEX idx_users_email ON auth.users(email); INSERT INTO auth.users(id,email) SELECT gen_random_uuid(),'fixture-'||n||'@example.invalid' FROM generate_series(1,10000)n;");
 const target=randomUUID(),missingProfile=randomUUID(),duplicateA=randomUUID(),duplicateB=randomUUID();
 const targetEmail='later-citizen@example.invalid',duplicateEmail='duplicate@example.invalid';
 sql(`INSERT INTO auth.users(id,email) VALUES('${target}','${targetEmail}'),('${missingProfile}','missing-profile@example.invalid'),('${duplicateA}','${duplicateEmail}'),('${duplicateB}','${duplicateEmail}');
 INSERT INTO public.profiles(id,role,is_email_verified) VALUES('${target}','citizen',false),('${duplicateA}','citizen',false),('${duplicateB}','citizen',true); ANALYZE auth.users; ANALYZE public.profiles;`);
 assert.equal(sql(absent).trim(),'t');
 const before=sql(fingerprint).trim();migrate(up);checks();
 assert.equal(sql(`SET ROLE service_role; SELECT public.find_email_verification_user('${targetEmail}')='${target}';`).trim(),'t');
 assert.equal(sql(`SET ROLE service_role; SELECT public.find_email_verification_user('${duplicateEmail}') IS NULL;`).trim(),'t');
 assert.equal(sql("SET ROLE service_role; SELECT public.find_email_verification_user('missing-profile@example.invalid') IS NULL;").trim(),'t');
 assert.equal(sql(`CREATE TEMP TABLE profiles(id uuid,is_email_verified boolean); SET ROLE service_role; SET search_path=pg_temp,public; SELECT public.find_email_verification_user('${targetEmail}')='${target}';`).trim(),'t');
 const plan=JSON.parse(sql(`EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) SELECT u.id FROM auth.users u WHERE u.email='${targetEmail}' LIMIT 2;`))[0];
 assert.equal(plan.Plan['Node Type'],'Limit');
 assert.ok(JSON.stringify(plan.Plan).includes('idx_users_email'),'Existing email index must support bounded lookup at scale');
 assert.equal(plan.Plan['Actual Rows'],1);
 assert.equal(sql(fingerprint).trim(),before,'Lookup must not change users, profiles or ACLs');
 migrate(down);assert.equal(sql(absent).trim(),'t');assert.equal(sql(fingerprint).trim(),before);
 migrate(up);checks();assert.equal(sql(fingerprint).trim(),before);
 const result={verified_at:new Date().toISOString(),fresh_sql_checks:19,reapply_sql_checks:19,synthetic_auth_rows:10009,extra_checks:['target found among 10009 Auth rows','ambiguous email including verified duplicate denied','missing profile denied','caller search path cannot shadow profiles','read-only state preserved','rollback removes both functions','reapplication preserves state'],bounded_query_plan:{node:plan.Plan['Node Type'],rows:plan.Plan['Actual Rows'],index:'idx_users_email',execution_ms:plan['Execution Time'],shared_hit_blocks:plan.Plan['Shared Hit Blocks']},scope:'Isolated disposable Auth shim; no real Auth or SMTP requests'};
 if(process.env.ECOPIN_LOOKUP_EVIDENCE_PATH)writeFileSync(process.env.ECOPIN_LOOKUP_EVIDENCE_PATH,JSON.stringify(result,null,2));
 console.log(JSON.stringify(result));
}catch(error){if(created)console.error(docker(['logs',container]));throw error;}
finally{if(created)docker(['rm','-f',container]);}
