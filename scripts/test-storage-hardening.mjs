import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync} from 'node:fs';

const dockerPath = 'C:/Program Files/Docker/Docker/resources/bin/docker.exe';
const container = `ecopin-storage-${process.pid}-${Date.now()}`;
const docker = (args, input) => execFileSync(dockerPath, args, {input, encoding: 'utf8', timeout: 60000, maxBuffer: 4 * 1024 * 1024});
const sql = (input, database = 'audit') => docker(['exec', '-i', container, 'psql', '-X', '-qAt', '-U', 'postgres', '-d', database, '-v', 'ON_ERROR_STOP=1'], input);
const file = name => readFileSync(name, 'utf8');
const migrate = name => {
  const content = file(name).trim();
  if (content.toUpperCase().startsWith('BEGIN;') || content.toUpperCase().startsWith('BEGIN\n')) {
    return sql(content);
  }
  return sql('BEGIN;\n' + content + '\nCOMMIT;');
};

const migrations = [
  'migrations/20261011112818_bind_offline_request_identity_and_protect_conflicts.sql',
  'migrations/20261011114855_add_safe_public_reports_and_atomic_detail_access.sql',
  'migrations/20261011141243_enforce_cleanup_storage_assignment_and_paths.sql',
  'migrations/20261011143242_enforce_private_report_access_contract.sql',
  'migrations/20261011145237_authorize_and_bound_cleanup_task_reads.sql',
  'migrations/20261011152906_atomically_complete_email_verification.sql',
  'migrations/20261011154236_store_verification_digests_and_bound_issuance.sql',
  'migrations/20261011160011_bound_email_verification_user_lookup.sql',
  'migrations/20261011163533_enforce_verification_token_and_cron_history_retention.sql',
  'migrations/20261011190000_reconcile_crew_team_and_person_assignments.sql',
  'migrations/20261012020142_restore_person_scoped_task_authority_and_canonical_receipts.sql',
  'migrations/20261012034152_restore_private_report_contract_after_unrestricted_policy.sql',
  'migrations/20261012041041_make_manual_task_assignment_notifications_atomic.sql',
  'migrations/20261012093000_recover_expired_planning_jobs_in_watchdog.sql',
  'migrations/20261012100000_remove_redundant_fc_operation_log_index.sql',
  'migrations/20261012110000_bind_verification_email_and_atomic_profile_healing.sql',
  'migrations/20261012113000_guard_direct_task_and_notification_updates.sql',
  'migrations/20261012120000_harden_definer_routines_search_path_and_parameter_bounds.sql'
];

const newMigration = 'migrations/20261012130000_harden_storage_delivery_and_delete_matrix.sql';
const rollbackMigration = 'migrations/rollback/20261012130000_harden_storage_delivery_and_delete_matrix.sql';

let created = false;
try {
  docker(['run', '--rm', '--network', 'none', '-d', '--name', container, '-e', 'POSTGRES_HOST_AUTH_METHOD=trust', 'postgis/postgis:17-3.5']);
  created = true;
  let ready = false;
  for (let n = 0; n < 60; n++) {
    try {
      if (sql("select current_setting('listen_addresses');", 'postgres').trim() === '*') {
        ready = true;
        break;
      }
    } catch {}
    await new Promise(resolve => setTimeout(resolve, 500));
  }
  assert.ok(ready, 'PostGIS failed to boot');
  sql('create database audit template template0;', 'postgres');
  sql(file('tests/sql/optimization-catalog-baseline.sql'));
  sql(file('tests/sql/optimization-synthetic-fixtures.sql'));

  // Cron shim
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
    CREATE OR REPLACE FUNCTION cron.schedule(name text, schedule text, command text) RETURNS bigint LANGUAGE plpgsql AS $$
    BEGIN
      INSERT INTO cron.job (jobname, schedule, command) VALUES (name, schedule, command)
      ON CONFLICT (jobname) DO UPDATE SET schedule = EXCLUDED.schedule, command = EXCLUDED.command;
      RETURN 1;
    END; $$;
    CREATE OR REPLACE FUNCTION cron.unschedule(name text) RETURNS boolean LANGUAGE plpgsql AS $$
    BEGIN
      DELETE FROM cron.job WHERE jobname = name;
      RETURN true;
    END; $$;
    ALTER TABLE cron.job_run_details OWNER TO postgres;
    ALTER TABLE cron.job OWNER TO postgres;
    REVOKE ALL ON TABLE cron.job_run_details FROM PUBLIC, anon, authenticated, service_role;
    GRANT ALL ON TABLE cron.job_run_details TO postgres;
  `);

  console.log('Replaying baseline migrations...');
  for (const m of migrations) {
    migrate(m);
  }

  // 1. Verify failure before migration
  console.log('Verifying regression test fails before migration...');
  const beforeRes = sql(file('tests/sql/storage-delivery-and-delete-matrix-regression.sql'));
  const beforeFails = beforeRes.split('\n').filter(l => l.includes('|FAIL|'));
  assert.ok(beforeFails.length > 0, `Expected failures before migration, got 0`);
  console.log(`  Identified ${beforeFails.length} expected failures before fix:`);
  beforeFails.forEach(f => console.log('   -', f.split('|')[0].trim()));

  // 2. Apply new migration
  console.log('Applying new migration: ' + newMigration);
  migrate(newMigration);

  // 3. Verify all checks pass
  console.log('Verifying all regression checks pass after migration...');
  const afterRes = sql(file('tests/sql/storage-delivery-and-delete-matrix-regression.sql'));
  const afterFails = afterRes.split('\n').filter(l => l.includes('|FAIL|'));
  assert.equal(afterFails.length, 0, `Expected 0 failures, got: ${afterFails.join('\n')}`);
  const passLines = afterRes.split('\n').filter(l => l.includes('|PASS|'));
  console.log(`  All ${passLines.length} checks PASS!`);

  // 4. Verify rollback
  console.log('Verifying rollback...');
  migrate(rollbackMigration);
  const rollbackRes = sql(file('tests/sql/storage-delivery-and-delete-matrix-regression.sql'));
  const rollbackFails = rollbackRes.split('\n').filter(l => l.includes('|FAIL|'));
  assert.equal(rollbackFails.length, beforeFails.length, `Expected rollback to reproduce exactly ${beforeFails.length} failures`);

  // 5. Re-apply migration
  console.log('Re-applying migration...');
  migrate(newMigration);
  const reapplyRes = sql(file('tests/sql/storage-delivery-and-delete-matrix-regression.sql'));
  const reapplyFails = reapplyRes.split('\n').filter(l => l.includes('|FAIL|'));
  assert.equal(reapplyFails.length, 0, `Expected 0 failures after reapply, got: ${reapplyFails.join('\n')}`);

  console.log('S10 Verification: Storage Delivery and Delete Matrix migration successfully verified in fresh container (double-pass).');
} catch (error) {
  if (created) console.error(docker(['logs', container]));
  throw error;
} finally {
  if (created) docker(['rm', '-f', container]);
}
