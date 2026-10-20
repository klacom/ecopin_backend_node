import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
const container=`ecopin-public-access-${process.pid}-${Date.now()}`;
function docker(args,input){return execFileSync('docker',args,{input,encoding:'utf8',timeout:60000,maxBuffer:4*1024*1024});}
function sql(input,database='audit'){return docker(['exec','-i',container,'psql','-X','-qAt','-U','postgres','-d',database,'-v','ON_ERROR_STOP=1'],input);}
function file(name){return readFileSync(name,'utf8');}
function migrate(name){sql('BEGIN;\n'+file(name)+'\nCOMMIT;');}
function checks(name,passes){const rows=sql(file(name)).trim().split('\n').filter(Boolean).map(line=>line.split('|'));assert.equal(rows.length,passes);assert.ok(rows.every(r=>r[1]==='PASS'),JSON.stringify(rows));}
let created=false;
try{
 docker(['run','--rm','--network','none','-d','--name',container,'-e','POSTGRES_HOST_AUTH_METHOD=trust','postgis/postgis:17-3.5']);created=true;
 let ready=false;
 for(let attempt=0;attempt<60;attempt++){
  try{
   // The image starts a temporary server during initialization. Wait for the final server.
   if(sql("select current_setting('listen_addresses');",'postgres').trim()==='*'){ready=true;break;}
  }catch{}
  await new Promise(resolve=>setTimeout(resolve,500));
 }
 assert.ok(ready,'Fresh local PostGIS must become ready');
 sql('create database audit template template0;','postgres');
 sql(file('tests/sql/optimization-catalog-baseline.sql'));
 sql(file('tests/sql/optimization-synthetic-fixtures.sql'));
 const up='migrations/20261011114855_add_safe_public_reports_and_atomic_detail_access.sql';
 const down='migrations/rollback/20261011114855_add_safe_public_reports_and_atomic_detail_access.sql';
 const batchUp='migrations/20261020062209_batch_report_evidence_authorization.sql';
 const batchDown='migrations/rollback/20261020062209_batch_report_evidence_authorization.sql';
 assert.ok(sql(file('tests/sql/public-projection-regression.sql')).includes('|FAIL|'));
 migrate(up);
 checks('tests/sql/public-projection-regression.sql',13);
 checks('tests/sql/report-detail-access-regression.sql',12);
 migrate(batchUp);
 checks('tests/sql/batch-evidence-access-regression.sql',16);
 migrate(batchDown);
 assert.equal(sql("select to_regprocedure('public.read_authorized_report_evidence_ids(uuid,uuid[])') is null;").trim(),'t');
 migrate(down);
 assert.equal(sql("select to_regclass('public.public_reports') is null, to_regprocedure('public.read_authorized_report_detail(uuid,uuid)') is null;").trim(),'t|t');
 assert.equal(sql("select count(*) from pg_roles where rolname='ecopin_public_map_reader';").trim(),'0');
 migrate(up);
 checks('tests/sql/public-projection-regression.sql',13);
 checks('tests/sql/report-detail-access-regression.sql',12);
 migrate(batchUp);
 checks('tests/sql/batch-evidence-access-regression.sql',16);
 console.log('Fresh PostGIS container: additive public access migration up/down/up PASS');
 console.log('13 safe-projection and 12 atomic detail-access contracts PASS');
 console.log('16 batch evidence access contracts and batch migration up/down/up PASS');
}catch(error){if(created)console.error(docker(['logs',container]));throw error;}
finally{if(created)docker(['rm','-f',container]);}
