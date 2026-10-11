import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
const container=`ecopin-task-read-${process.pid}-${Date.now()}`;
function docker(args,input){return execFileSync('docker',args,{input,encoding:'utf8',timeout:60000,maxBuffer:4*1024*1024});}
function sql(input,database='audit'){return docker(['exec','-i',container,'psql','-X','-qAt','-U','postgres','-d',database,'-v','ON_ERROR_STOP=1'],input);}
function file(name){return readFileSync(name,'utf8');}
function migrate(name){sql('BEGIN;\n'+file(name)+'\nCOMMIT;');}
const up='migrations/20261011145237_authorize_and_bound_cleanup_task_reads.sql';
const down='migrations/rollback/20261011145237_authorize_and_bound_cleanup_task_reads.sql';
const fingerprint="SELECT coalesce(to_regprocedure('public.read_authorized_cleanup_tasks(uuid,uuid,uuid,boolean,integer,integer)')::text,'absent');";
function checks(name,count){const rows=sql(file('tests/sql/'+name)).trim().split(/\r?\n/).filter(Boolean).map(line=>line.split('|'));assert.equal(rows.length,count);assert.ok(rows.every(row=>row[1]==='PASS'),JSON.stringify(rows));}
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
  sql(file('tests/sql/optimization-platform-extension-acls.sql'));
  sql(file('tests/sql/optimization-synthetic-fixtures.sql'));
  migrate('migrations/20261011112818_bind_offline_request_identity_and_protect_conflicts.sql');
  migrate('migrations/20261011114855_add_safe_public_reports_and_atomic_detail_access.sql');
  migrate('migrations/20261011141243_enforce_cleanup_storage_assignment_and_paths.sql');
  sql(file('tests/sql/report-privacy-live-baseline-acls.sql'));
  migrate('migrations/20261011143242_enforce_private_report_access_contract.sql');
  const before=sql(fingerprint).trim();
  assert.equal(before,'absent');
  migrate(up);
  checks('task-read-authority-regression.sql',29);
  checks('report-privacy-contract-regression.sql',28);
  checks('public-projection-regression.sql',13);
  checks('report-detail-access-regression.sql',12);
  checks('cleanup-storage-regression.sql',44);
  checks('offline-identity-regression.sql',14);
  migrate(down);
  assert.equal(sql(fingerprint).trim(),before,'Task read function absence must be restored');
  migrate(up);
  checks('task-read-authority-regression.sql',29);
  checks('report-privacy-contract-regression.sql',28);
  console.log('Fresh isolated PostGIS: 140 checks PASS; task RPC absence restored on rollback; 29 task and 28 privacy checks PASS after second up');
}catch(error){if(created)console.error(docker(['logs',container]));throw error;}
finally{if(created)docker(['rm','-f',container]);}
