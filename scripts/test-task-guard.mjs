import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync} from 'node:fs';

const dockerPath = 'C:/Program Files/Docker/Docker/resources/bin/docker.exe';
const container = `ecopin-task-guard-${process.pid}-${Date.now()}`;
const docker = (args, input) => execFileSync(dockerPath, args, {input, encoding: 'utf8', timeout: 60000, maxBuffer: 4 * 1024 * 1024});
const sql = (input, database = 'audit') => docker(['exec', '-i', container, 'psql', '-X', '-qAt', '-U', 'postgres', '-d', database, '-v', 'ON_ERROR_STOP=1'], input);
const file = name => readFileSync(name, 'utf8');
const migrate = name => sql('BEGIN;\n' + file(name) + '\nCOMMIT;');

const up = process.argv[2] ?? 'migrations/20261012113000_guard_direct_task_and_notification_updates.sql';
const down = process.argv[3] ?? 'migrations/rollback/20261012113000_guard_direct_task_and_notification_updates.sql';
const regression = process.argv[4] ?? 'tests/sql/task-and-notification-write-protection-regression.sql';

assert.ok(up && down && regression, 'Pass candidate up/down/regression paths');

function checks() {
  const output = sql(file(regression)).trim();
  const rows = output.split(/\r?\n/).map(line => line.split('|')).filter(parts => parts.length >= 2);
  assert.equal(rows.length, 11, `Expected 11 test rows, got ${rows.length}: ${JSON.stringify(rows)}`);
  assert.ok(rows.every(row => row[1] === 'PASS'), `Failed assertions: ${JSON.stringify(rows.filter(r => r[1] !== 'PASS'))}`);
}

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

  // Ensure prerequisite triggers/setup for tasks
  sql(`
    -- Prerequisite grants for test fixture execution
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO postgres, authenticated;
    GRANT USAGE ON SCHEMA public, workflow_private TO authenticated, anon;
  `);

  // Apply candidate migration
  migrate(up);
  checks();

  // Test rollback
  migrate(down);
  const triggerCount = sql("SELECT count(*) FROM pg_trigger WHERE tgname IN ('guard_task_direct_update', 'guard_notification_update');").trim();
  assert.equal(triggerCount, '0', `Expected 0 guard triggers after rollback, found ${triggerCount}`);

  // Reapply candidate migration and re-verify
  migrate(up);
  checks();

  console.log('Fresh PostGIS: 11 task and notification write protection checks PASS twice; direct task and notification guards verified; rollback restores baseline and reapplication succeeds.');
} catch (error) {
  if (created) console.error(docker(['logs', container]));
  throw error;
} finally {
  if (created) docker(['rm', '-f', container]);
}
