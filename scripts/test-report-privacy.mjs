import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
const container=`ecopin-report-privacy-${process.pid}-${Date.now()}`;
function docker(args,input){return execFileSync('docker',args,{input,encoding:'utf8',timeout:60000,maxBuffer:4*1024*1024});}
function sql(input,database='audit'){return docker(['exec','-i',container,'psql','-X','-qAt','-U','postgres','-d',database,'-v','ON_ERROR_STOP=1'],input);}
function file(name){return readFileSync(name,'utf8');}
function migrate(name){sql('BEGIN;\n'+file(name)+'\nCOMMIT;');}
const up='migrations/20261011143242_enforce_private_report_access_contract.sql';
const down='migrations/rollback/20261011143242_enforce_private_report_access_contract.sql';
const fingerprint=`WITH privileges AS (
 SELECT c.oid::regclass::text AS object,''::text AS column_name,a.grantor,a.grantee,a.privilege_type,a.is_grantable FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a WHERE c.oid IN ('public.reports'::regclass,'public.reports_view'::regclass)
 UNION ALL SELECT c.oid::regclass::text,att.attname,a.grantor,a.grantee,a.privilege_type,a.is_grantable FROM pg_class c JOIN pg_attribute att ON att.attrelid=c.oid CROSS JOIN LATERAL aclexplode(att.attacl) a WHERE c.oid IN ('public.reports'::regclass,'public.reports_view'::regclass) AND att.attnum>0 AND NOT att.attisdropped
) SELECT md5(jsonb_build_object('privileges',(SELECT jsonb_agg(to_jsonb(p) ORDER BY object,column_name,grantor,grantee,privilege_type,is_grantable) FROM privileges p),'policies',(SELECT jsonb_agg(to_jsonb(p) ORDER BY policyname) FROM pg_policies p WHERE schemaname='public' AND tablename='reports'))::text);`;
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
  sql(file('tests/sql/optimization-synthetic-fixtures.sql'));
  migrate('migrations/20261011112818_bind_offline_request_identity_and_protect_conflicts.sql');
  migrate('migrations/20261011114855_add_safe_public_reports_and_atomic_detail_access.sql');
  migrate('migrations/20261011141243_enforce_cleanup_storage_assignment_and_paths.sql');
  sql(file('tests/sql/report-privacy-live-baseline-acls.sql'));
  const before=sql(fingerprint).trim();
  migrate(up);
  checks('report-privacy-contract-regression.sql',28);
  checks('public-projection-regression.sql',13);
  checks('report-detail-access-regression.sql',12);
  checks('cleanup-storage-regression.sql',44);
  checks('offline-identity-regression.sql',14);
  migrate(down);
  assert.equal(sql(fingerprint).trim(),before,'Exact original report policies and effective table/column grants must be restored');
  migrate(up);
  checks('report-privacy-contract-regression.sql',28);
  console.log('Fresh isolated PostGIS: 111 checks PASS; exact report policy/ACL rollback; 28 privacy checks PASS after second up');
}catch(error){if(created)console.error(docker(['logs',container]));throw error;}
finally{if(created)docker(['rm','-f',container]);}
