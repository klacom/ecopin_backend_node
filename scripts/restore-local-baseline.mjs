import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync, realpathSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import path from 'node:path';

const root = realpathSync(fileURLToPath(new URL('..', import.meta.url)));
const container = 'supabase_db_parity-recovery-backend';
assert.ok(process.argv.slice(2).length === 0 || process.argv.slice(2).join() === '--seed-only', 'Only --seed-only is supported.');
const target = JSON.parse(execFileSync('docker', ['inspect', container], {encoding: 'utf8'}))[0];
assert.equal(target.Config.Labels['com.supabase.cli.project'], 'parity-recovery-backend');
assert.equal(realpathSync(target.Config.Labels['com.supabase.cli.workdir']), root, 'Refusing a different local project.');
const endpoint = execFileSync('docker', ['context', 'inspect', '--format', '{{.Endpoints.docker.Host}}'], {encoding: 'utf8'}).trim();
assert.equal(endpoint, 'npipe:////./pipe/dockerDesktopLinuxEngine', 'Use the verified local Windows engine.');
const sql = input => execFileSync('docker', ['exec', '-i', container, 'psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-U', 'supabase_admin', '-d', 'postgres'],
  {input, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024});
if (!process.argv.includes('--seed-only')) sql(readFileSync(path.join(root, 'supabase/baseline/application.sql')));
assert.equal(sql("select to_regclass('public.profiles') is not null;").trim(), 't', 'Restore the application catalog before seeding.');
sql(readFileSync(path.join(root, 'supabase/seed.local.sql')));
console.log('Isolated application baseline and synthetic actor/reference fixtures are ready; no hosted connection is used.');
