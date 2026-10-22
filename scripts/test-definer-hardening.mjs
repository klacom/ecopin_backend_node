import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync} from 'node:fs';

const dockerPath = 'C:/Program Files/Docker/Docker/resources/bin/docker.exe';
const container = `ecopin-definer-harden-${process.pid}-${Date.now()}`;
const docker = (args, input) => execFileSync(dockerPath, args, {input, encoding: 'utf8', timeout: 60000, maxBuffer: 4 * 1024 * 1024});
const sql = (input, database = 'audit') => docker(['exec', '-i', container, 'psql', '-X', '-qAt', '-U', 'postgres', '-d', database, '-v', 'ON_ERROR_STOP=1'], input);
const file = name => readFileSync(name, 'utf8');
const migrate = name => sql('BEGIN;\n' + file(name) + '\nCOMMIT;');

const up = process.argv[2] ?? 'migrations/20261012120000_harden_definer_routines_search_path_and_parameter_bounds.sql';
const down = process.argv[3] ?? 'migrations/rollback/20261012120000_harden_definer_routines_search_path_and_parameter_bounds.sql';
const regression = process.argv[4] ?? 'tests/sql/definer-routines-and-bounds-regression.sql';

assert.ok(up && down && regression, 'Pass candidate up/down/regression paths');

function checks() {
  const output = sql(file(regression)).trim();
  const rows = output.split(/\r?\n/).map(line => line.split('|')).filter(parts => parts.length >= 2);
  assert.equal(rows.length, 21, `Expected 21 test rows, got ${rows.length}: ${JSON.stringify(rows)}`);
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

  // Ensure triggers on auth.users and public.reports exist for tests
  sql(`
    DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
    CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

    DROP TRIGGER IF EXISTS on_report_status_change ON public.reports;
    CREATE TRIGGER on_report_status_change AFTER UPDATE ON public.reports FOR EACH ROW EXECUTE FUNCTION public.handle_report_status_change();
  `);

  // Apply candidate migration
  migrate(up);
  checks();

  // Test rollback
  migrate(down);
  const revertedSearchPaths = sql(`
    SELECT count(*) FROM pg_proc
    WHERE proname IN ('handle_new_user', 'handle_report_status_change', 'nextval', 'count_recent_nearby_reports')
      AND proconfig IS NOT NULL
      AND ('search_path=""' = ANY(proconfig) OR 'search_path=' = ANY(proconfig));
  `).trim();
  assert.equal(revertedSearchPaths, '0', `Expected 0 empty search_path functions after rollback, found ${revertedSearchPaths}`);

  // Reapply candidate migration and re-verify
  migrate(up);
  checks();

  console.log('Fresh PostGIS: 21 definer hardening and bounds checks PASS twice; empty search path, parameter bounds, safe sequence validation and immutable role defaults verified; rollback restores baseline and reapplication succeeds.');
} catch (error) {
  if (created) console.error(docker(['logs', container]));
  throw error;
} finally {
  if (created) docker(['rm', '-f', container]);
}
