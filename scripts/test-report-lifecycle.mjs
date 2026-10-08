import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';

// Local Docker only. No Supabase URL, API key or deployment credentials are used.
const container = 'ecopin-slice-a-postgres';
const database = `lifecycle_test_${process.pid}_${Date.now()}`;
const args = db => ['exec', '-i', container, 'psql', '-X', '-qAt', '-U', 'postgres', '-d', db, '-v', 'ON_ERROR_STOP=1'];
function sql(db, input) {
  return execFileSync('docker', args(db), { input, encoding: 'utf8', timeout: 30000 });
}
function file(path) { return readFileSync(new URL(path, import.meta.url), 'utf8'); }

let locker;
let created = false;
try {
  sql('postgres', `create database ${database};`);
  created = true;
  sql(database, file('../tests/sql/lifecycle-bootstrap.sql'));
  sql(database, file('../migrations/20261008064832_report_lifecycle_foundation.sql'));
  const regressions = file('../tests/sql/report-lifecycle.sql');
  sql(database, regressions);
  console.log(`PostgreSQL lifecycle regression assertions passed: ${(regressions.match(/select pg_temp\.assert_true\(/g) || []).length}`);

  // Hold the same transaction advisory lock from another connection.
  locker = spawn('docker', args(database), { stdio: ['pipe', 'pipe', 'pipe'] });
  const exited = new Promise((resolve, reject) => {
    locker.once('error', reject);
    locker.once('exit', code => code === 0 ? resolve() : reject(new Error(`Lock session exited ${code}`)));
  });
  // Attach immediately so an early connection failure is not an unhandled rejection.
  exited.catch(() => {});
  await new Promise((resolve, reject) => {
    let output = '';
    const timer = setTimeout(() => reject(new Error('Lock session timed out')), 10000);
    locker.stdout.on('data', chunk => {
      output += chunk;
      if (output.includes('LOCK_READY')) { clearTimeout(timer); resolve(); }
    });
    locker.once('error', error => { clearTimeout(timer); reject(error); });
    locker.once('exit', code => { clearTimeout(timer); reject(new Error(`Lock session ended early: ${code}`)); });
    locker.stdin.write("begin; select pg_advisory_xact_lock(72631008);\n\\echo LOCK_READY\n");
  });
  const result = JSON.parse(sql(database, 'select public.advance_report_lifecycle();').trim());
  assert.equal(result.skipped, true);
  assert.equal(result.changedCount, 0);
  locker.stdin.end('commit;\n\\q\n');
  await exited;
  locker = null;
  console.log('Concurrent lifecycle worker skips while another transaction owns the lock: passed');
} finally {
  locker?.kill();
  if (created) {
    assert.match(database, /^lifecycle_test_\d+_\d+$/);
    sql('postgres', `drop database ${database} with (force);`);
  }
}
