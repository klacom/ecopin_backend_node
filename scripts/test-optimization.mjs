import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
const container='ecopin-slice-a-postgis';
const database=`optimization_test_${process.pid}_${Date.now()}`;
function sql(db,input){return execFileSync('docker',['exec','-i',container,'psql','-X','-qAt','-U','postgres','-d',db,'-v','ON_ERROR_STOP=1'],{input,encoding:'utf8',timeout:60000,maxBuffer:4*1024*1024});}
function file(name){return readFileSync(name,'utf8');}
function migrate(name){return sql(database,'BEGIN;\n'+file(name)+'\nCOMMIT;');}
function results(name){const rows=sql(database,file(name)).trim().split('\n').filter(Boolean).map(line=>line.split('|'));return {pass:rows.filter(r=>r[1]==='PASS').length,fail:rows.filter(r=>r[1]==='FAIL').length,rows};}
const migration='migrations/20261011112818_bind_offline_request_identity_and_protect_conflicts.sql';
const rollback='migrations/rollback/20261011112818_bind_offline_request_identity_and_protect_conflicts.sql';
const fingerprint="select md5(pg_get_functiondef('public.apply_fc_operation(uuid,text,text,uuid,text,jsonb,bigint)'::regprocedure)),proacl::text,(select relrowsecurity from pg_class where oid='public.sync_conflicts'::regclass) from pg_proc where oid='public.apply_fc_operation(uuid,text,text,uuid,text,jsonb,bigint)'::regprocedure;";
let created=false;
try{
 sql('postgres',`create database ${database};`);created=true;
 sql(database,file('tests/sql/optimization-catalog-baseline.sql'));
 sql(database,file('tests/sql/optimization-synthetic-fixtures.sql'));
 const before=sql(database,fingerprint);
 assert.equal(results('tests/sql/offline-identity-regression.sql').fail,7,'Baseline must reproduce seven identity/RLS failures');
 migrate(migration);
 assert.equal(results('tests/sql/offline-identity-regression.sql').pass,14,'All identity/RLS contracts must pass');
 assert.equal(results('tests/sql/optimization-workflow-regression.sql').pass,12,'Existing workflow contracts must pass');
 migrate(rollback);
 assert.equal(sql(database,fingerprint),before,'Down must restore exact function, ACL and RLS state');
 assert.equal(results('tests/sql/offline-identity-regression.sql').fail,7,'Down must reproduce original behavior');
 migrate(migration);
 const after=results('tests/sql/offline-identity-regression.sql');
 assert.equal(after.pass,14);assert.equal(after.fail,0);
 console.log('Schema-only staging reconstruction and migration up/down/up: PASS');
 console.log('14 identity/RLS assertions and 12 existing workflow assertions: PASS');
 console.log('Auth/Storage are test shims; full platform/data/media restoration remains a separate gate.');
}finally{if(created)sql('postgres',`drop database ${database} with(force);`);}
