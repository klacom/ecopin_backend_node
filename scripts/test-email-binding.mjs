import assert from 'node:assert/strict';
import {execFileSync, execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {readFileSync} from 'node:fs';
import {randomUUID} from 'node:crypto';

const dockerPath = 'C:/Program Files/Docker/Docker/resources/bin/docker.exe';
const container = `ecopin-email-binding-${process.pid}-${Date.now()}`;
const docker = (args, input) => execFileSync(dockerPath, args, {input, encoding: 'utf8', timeout: 60000, maxBuffer: 4 * 1024 * 1024});
const sql = (input, database = 'audit') => docker(['exec', '-i', container, 'psql', '-X', '-qAt', '-U', 'postgres', '-d', database, '-v', 'ON_ERROR_STOP=1'], input);
const file = name => readFileSync(name, 'utf8');
const migrate = name => sql('BEGIN;\n' + file(name) + '\nCOMMIT;');

const up = process.argv[2] ?? 'migrations/20261012110000_bind_verification_email_and_atomic_profile_healing.sql';
const down = process.argv[3] ?? 'migrations/rollback/20261012110000_bind_verification_email_and_atomic_profile_healing.sql';
const regression = process.argv[4] ?? 'tests/sql/email-verification-binding-regression.sql';

assert.ok(up && down && regression, 'Pass candidate up/down/regression paths');

const fingerprint = "SELECT coalesce(to_regprocedure('public.complete_email_verification(uuid,uuid,text)')::text,'absent');";

function checks() {
  const rows = sql(file(regression)).trim().split(/\r?\n/).map(line => line.split('|'));
  assert.equal(rows.length, 19, `Expected 19 test rows, got ${rows.length}: ${JSON.stringify(rows)}`);
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
  
  // Apply prior email migrations
  migrate('migrations/20261011152906_atomically_complete_email_verification.sql');
  migrate('migrations/20261011154236_store_verification_digests_and_bound_issuance.sql');

  assert.equal(sql(fingerprint).trim(), 'absent');
  
  // Apply candidate migration
  migrate(up);
  checks();

  // Test rollback
  migrate(down);
  assert.equal(sql(fingerprint).trim(), 'absent');
  assert.equal(sql("SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='email_verifications' AND column_name='issued_to_email';").trim(), '0');

  // Reapply candidate migration and re-verify
  migrate(up);
  checks();

  console.log('Fresh PostGIS: 16 email binding checks PASS twice; email normalization, mismatch rejection, self-healing profile and backward compatibility verified; rollback restores absence and reapplication succeeds.');
} catch (error) {
  if (created) console.error(docker(['logs', container]));
  throw error;
} finally {
  if (created) docker(['rm', '-f', container]);
}
