import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
const container=`ecopin-cleanup-storage-${process.pid}-${Date.now()}`;
function docker(args,input){return execFileSync('docker',args,{input,encoding:'utf8',timeout:60000,maxBuffer:4*1024*1024});}
function sql(input,database='audit'){return docker(['exec','-i',container,'psql','-X','-qAt','-U','postgres','-d',database,'-v','ON_ERROR_STOP=1'],input);}
function file(name){return readFileSync(name,'utf8');}
function migrate(name){sql('BEGIN;\n'+file(name)+'\nCOMMIT;');}
const up='migrations/20261011141243_enforce_cleanup_storage_assignment_and_paths.sql';
const down='migrations/rollback/20261011141243_enforce_cleanup_storage_assignment_and_paths.sql';
const fingerprint="SELECT md5(jsonb_agg(to_jsonb(p) ORDER BY policyname)::text) FROM pg_policies p WHERE schemaname='storage' AND tablename='objects';";
function checks(){const rows=sql(file('tests/sql/cleanup-storage-regression.sql')).trim().split('\n').filter(Boolean).map(line=>line.split('|'));assert.equal(rows.length,44);assert.ok(rows.every(row=>row[1]==='PASS'),JSON.stringify(rows));}
let created=false;
try{
  docker(['run','--rm','--network','none','-d','--name',container,'-e','POSTGRES_HOST_AUTH_METHOD=trust','postgis/postgis:17-3.5']);created=true;
  let ready=false;
  for(let attempt=0;attempt<60;attempt++){
    try{if(sql("select current_setting('listen_addresses');",'postgres').trim()==='*'){ready=true;break;}}catch{}
    await new Promise(resolve=>setTimeout(resolve,500));
  }
  assert.ok(ready,'Fresh local PostGIS must become ready');
  sql('create database audit template template0;','postgres');
  sql(file('tests/sql/optimization-catalog-baseline.sql'));
  sql(file('tests/sql/optimization-synthetic-fixtures.sql'));
  const before=sql(fingerprint).trim();
  migrate(up);checks();
  const permissions=sql("SELECT prosecdef, proconfig, has_function_privilege('anon',oid,'EXECUTE'),has_function_privilege('authenticated',oid,'EXECUTE'),has_function_privilege('service_role',oid,'EXECUTE') FROM pg_proc WHERE oid='storage_authority.can_upload_cleanup_object(text,text)'::regprocedure;").trim();
  assert.equal(permissions,'t|{"search_path=\\"\\""}|f|t|f');
  migrate(down);
  assert.equal(sql(fingerprint).trim(),before,'Exact original policies must be restored');
  assert.equal(sql("select count(*) from pg_namespace where nspname='storage_authority';").trim(),'0');
  migrate(up);checks();
  console.log('Fresh isolated PostGIS: 44 cleanup Storage checks PASS after up/down/up; exact policy rollback and private helper privileges PASS');
}catch(error){if(created)console.error(docker(['logs',container]));throw error;}
finally{if(created)docker(['rm','-f',container]);}
