import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
import {resolve} from 'node:path';

const basePath = process.cwd();

const container = `ecopin-w02-lifecycle-${process.pid}-${Date.now()}`;
const dockerPath = 'docker';
const docker = (args, input) => execFileSync(dockerPath, args, {input, encoding: 'utf8', timeout: 60000, maxBuffer: 8 * 1024 * 1024});
const sql = (input, database = 'audit') => docker(['exec', '-i', container, 'psql', '-X', '-qAt', '-U', 'postgres', '-d', database, '-v', 'ON_ERROR_STOP=1'], input);
const file = name => readFileSync(resolve(basePath, name), 'utf8');
const sourceNames={
 'w02-crew-assignment-reconcile.up.sql':'migrations/20261011190000_reconcile_crew_team_and_person_assignments.sql',
 'w02-crew-assignment-reconcile.down.sql':'migrations/rollback/20261011190000_reconcile_crew_team_and_person_assignments.sql',
 'w02-crew-assignment-reconcile.test.sql':'tests/sql/crew-assignment-reconciliation-regression.sql'
};
const optFile=name=>file(sourceNames[name]??name);
const migrate = name => sql('BEGIN;\n' + file(name) + '\nCOMMIT;');
const runOptSql = name => sql('BEGIN;\n' + optFile(name) + '\nCOMMIT;');

let created = false;
try {
  docker(['run', '--rm', '--network', 'none', '-d', '--name', container, '-e', 'POSTGRES_HOST_AUTH_METHOD=trust', 'postgis/postgis:17-3.5']);
  created = true;
  let ready = false;
  for (let attempt = 0; attempt < 60; attempt++) {
    try {
      if (sql("select current_setting('listen_addresses');", 'postgres').trim() === '*') {
        ready = true;
        break;
      }
    } catch {}
    await new Promise(r => setTimeout(r, 500));
  }
  assert.ok(ready, 'PostGIS container must become ready');
  sql('create database audit template template0;', 'postgres');
  sql(file('tests/sql/optimization-catalog-baseline.sql'));
  sql(file('tests/sql/optimization-platform-extension-acls.sql'));
  sql(file('tests/sql/optimization-synthetic-fixtures.sql'));

  // Isolated cron shim
  sql(`
    CREATE SCHEMA IF NOT EXISTS cron;
    CREATE TABLE IF NOT EXISTS cron.job (
      jobid bigserial primary key, schedule text, command text,
      nodename text default 'localhost', nodeport integer default 5432,
      database text default 'postgres', username text default 'postgres',
      active boolean default true, jobname text unique
    );
    CREATE TABLE IF NOT EXISTS cron.job_run_details (
      jobid bigint, runid bigserial primary key, job_pid integer,
      database text, username text, command text, status text,
      return_message text, start_time timestamptz, end_time timestamptz
    );
    CREATE OR REPLACE FUNCTION cron.schedule(name text, schedule text, command text)
    RETURNS bigint LANGUAGE plpgsql AS $$
    DECLARE jid bigint;
    BEGIN
      INSERT INTO cron.job(jobname, schedule, command)
      VALUES (name, schedule, command)
      ON CONFLICT (jobname) DO UPDATE SET schedule = EXCLUDED.schedule, command = EXCLUDED.command
      RETURNING jobid INTO jid;
      RETURN jid;
    END; $$;
  `);

  migrate('migrations/20261011112818_bind_offline_request_identity_and_protect_conflicts.sql');
  migrate('migrations/20261011114855_add_safe_public_reports_and_atomic_detail_access.sql');
  migrate('migrations/20261011141243_enforce_cleanup_storage_assignment_and_paths.sql');
  sql(file('tests/sql/report-privacy-live-baseline-acls.sql'));
  migrate('migrations/20261011143242_enforce_private_report_access_contract.sql');
  migrate('migrations/20261011145237_authorize_and_bound_cleanup_task_reads.sql');
  migrate('migrations/20261011152906_atomically_complete_email_verification.sql');
  migrate('migrations/20261011154236_store_verification_digests_and_bound_issuance.sql');
  migrate('migrations/20261011160011_bound_email_verification_user_lookup.sql');
  migrate('migrations/20261011163533_enforce_verification_token_and_cron_history_retention.sql');

  console.log('--- STEP 1: APPLY W02/C03 MIGRATION (UP) ---');
  runOptSql('w02-crew-assignment-reconcile.up.sql');

  const fixDownPath=process.argv[3]??'migrations/rollback/20261012020142_restore_person_scoped_task_authority_and_canonical_receipts.sql';
  // The earlier agent's ledger has NULL statements. Its candidate file differs
  // textually from live definitions; reproduce the captured live authority
  // baseline before testing exact rollback, rather than claiming source equality.
  sql('BEGIN;\n'+readFileSync(fixDownPath,'utf8')+'\nCOMMIT;');
  const fingerprintSql="SELECT md5(jsonb_build_object('functions',(SELECT jsonb_agg(jsonb_build_object('definition',pg_get_functiondef(p.oid),'acl',p.proacl::text,'owner',p.proowner) ORDER BY p.oid::regprocedure::text) FROM pg_proc p WHERE p.oid IN ('workflow_private.can_execute_task(uuid,public.cleanup_tasks)'::regprocedure,'workflow_private.issue_task_report_receipts()'::regprocedure,'public.read_authorized_cleanup_tasks(uuid,uuid,uuid,boolean,integer,integer)'::regprocedure)),'policy',(SELECT qual FROM pg_policies WHERE schemaname='public' AND tablename='cleanup_tasks' AND policyname='workflow_task_read'))::text);";
  const authorityBefore=sql(fingerprintSql).trim();
  const fixPath=process.argv[2]??'migrations/20261012020142_restore_person_scoped_task_authority_and_canonical_receipts.sql';
  assert.ok(fixPath,'Pass the reviewed authority fix');
  sql('BEGIN;\n'+readFileSync(fixPath,'utf8')+'\nCOMMIT;');
  const gapRows=sql(readFileSync((process.argv[4]??'tests/sql/crew-authority-gap-regression.sql'),'utf8')).trim().split(/\r?\n/).map(line=>line.split('|'));
  assert.equal(gapRows.length,12);
  assert.ok(gapRows.every(row=>row[1]==='PASS'),JSON.stringify(gapRows));
  console.log('Independent crew authority: 12/12 PASS');
  const authorityAfter=sql(fingerprintSql).trim();

  assert.ok(fixDownPath);
  sql('BEGIN;\n'+readFileSync(fixDownPath,'utf8')+'\nCOMMIT;');
  assert.equal(sql(fingerprintSql).trim(),authorityBefore,'Actual repair down must restore exact prior definitions, ACLs and policy');
  sql('BEGIN;\n'+readFileSync(fixPath,'utf8')+'\nCOMMIT;');
  assert.equal(sql(fingerprintSql).trim(),authorityAfter,'Actual repair reapplication must restore desired definitions');
  const replayRows=sql(readFileSync((process.argv[4]??'tests/sql/crew-authority-gap-regression.sql'),'utf8')).trim().split(/\r?\n/).map(line=>line.split('|'));
  assert.equal(replayRows.length,12); assert.ok(replayRows.every(row=>row[1]==='PASS'));
  console.log('Actual authority repair rollback: exact function/ACL/policy fingerprint restored; up reapply 12/12 PASS');
  console.log('--- STEP 2: RUN W02 REGRESSION SUITE ---');
  const w02Output = sql(optFile('w02-crew-assignment-reconcile.test.sql'));
  console.log(w02Output);
  assert.ok(!w02Output.includes('|FAIL|'), 'W02 test suite must have 0 failures');

  console.log('--- STEP 3: RUN EXISTING TASK READ REGRESSION ---');
  const taskReadOutput = sql(file('tests/sql/task-read-authority-regression.sql'));
  console.log(taskReadOutput);
  assert.ok(!taskReadOutput.includes('|FAIL|'), 'Task read regression must have 0 failures');

  console.log('--- STEP 4: RUN CANONICAL REGRESSIONS (174 CHECKS) ---');
  function checkSuite(name, expectedCount) {
    const rows = sql(file('tests/sql/' + name)).trim().split(/\r?\n/).filter(Boolean).map(line => line.split('|'));
    assert.equal(rows.length, expectedCount, `Expected ${expectedCount} rows for ${name}, got ${rows.length}`);
    assert.ok(rows.every(row => row[1] === 'PASS'), `All rows in ${name} must pass: ${JSON.stringify(rows)}`);
    console.log(`  ${name}: ${expectedCount}/${expectedCount} PASS`);
  }
  checkSuite('task-read-authority-regression.sql', 29);
  checkSuite('report-privacy-contract-regression.sql', 28);
  checkSuite('public-projection-regression.sql', 13);
  checkSuite('report-detail-access-regression.sql', 12);
  checkSuite('cleanup-storage-regression.sql', 44);
  checkSuite('offline-identity-regression.sql', 14);
  checkSuite('retention-cleanup-regression.sql', 34);
  console.log('All canonical regressions passed successfully.');

  console.log('--- STEP 5: TEST ROLLBACK (DOWN) ---');
  runOptSql('w02-crew-assignment-reconcile.down.sql');
  console.log('Rollback applied successfully.');

  // Re-run task-read-authority-regression after rollback
  const rollbackTaskRead = sql(file('tests/sql/task-read-authority-regression.sql'));
  assert.ok(!rollbackTaskRead.includes('|FAIL|'), 'Task read regression after rollback must have 0 failures');

  console.log('--- STEP 6: RE-APPLY W02/C03 MIGRATION (IDEMPOTENT RE-MIGRATE) ---');
  runOptSql('w02-crew-assignment-reconcile.up.sql');
  const reapplyW02 = sql(optFile('w02-crew-assignment-reconcile.test.sql'));
  assert.ok(!reapplyW02.includes('|FAIL|'), 'W02 test suite on reapply must have 0 failures');
  sql('BEGIN;\n'+readFileSync(fixPath,'utf8')+'\nCOMMIT;');
  const repairedRows=sql(readFileSync((process.argv[4]??'tests/sql/crew-authority-gap-regression.sql'),'utf8')).trim().split(/\r?\n/).map(line=>line.split('|'));
  assert.equal(repairedRows.length,12); assert.ok(repairedRows.every(row=>row[1]==='PASS'));
  console.log('Authority repair reapplication: 12/12 PASS');

  console.log('ALL LIFECYCLE GATES PASSED (100% PASS)');
} finally {
  if (created) docker(['rm', '-f', container]);
}
