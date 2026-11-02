import assert from 'node:assert/strict';
import {randomBytes} from 'node:crypto';
import {mkdir, writeFile} from 'node:fs/promises';
import dotenv from 'dotenv';
import {createClient} from '@supabase/supabase-js';

dotenv.config({quiet: true});
// This fixture command never accepts a hosted target, including production mode overrides.
assert.equal(process.env.SUPABASE_URL, 'http://127.0.0.1:54321', 'Fixtures require the dedicated loopback Supabase stack.');
const options = {auth: {persistSession: false, autoRefreshToken: false}};
const admin = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SECRET_KEY, options);
const anonymous = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_PUBLISHABLE_KEY, options);
const fixture = 'ecopin-parity-local';
const password = randomBytes(24).toString('base64url');
const {data: listed, error: listError} = await admin.auth.admin.listUsers({page: 1, perPage: 1000});
assert.ifError(listError);
const users = [];
for (const [name, role] of [['citizen-a', 'citizen'], ['citizen-b', 'citizen'], ['officer', 'officer'], ['admin', 'admin'], ['crew', 'field_crew']]) {
  const email = `${name}@parity.ecopin.invalid`;
  const existing = listed.users.find(user => user.email === email);
  if (existing) assert.equal(existing.app_metadata.fixture, fixture, 'Refusing to modify an account not owned by these fixtures.');
  const attributes = {password, email_confirm: true, app_metadata: {fixture, role}};
  const {data, error} = existing
    ? await admin.auth.admin.updateUserById(existing.id, attributes)
    : await admin.auth.admin.createUser({email, ...attributes});
  assert.ifError(error);
  users.push({id: data.user.id, email, role});
}
const {data: buckets, error: bucketError} = await admin.storage.listBuckets();
assert.ifError(bucketError);
const bucket = 'parity-fixtures';
if (!buckets.some(item => item.id === bucket)) {
  const {error} = await admin.storage.createBucket(bucket, {public: false});
  assert.ifError(error);
} else {
  assert.equal(buckets.find(item => item.id === bucket).public, false, 'Fixture originals must remain private.');
}
const image = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=', 'base64');
const object = `${fixture}/synthetic.png`;
const {error: uploadError} = await admin.storage.from(bucket).upload(object, image, {contentType: 'image/png', upsert: true});
assert.ifError(uploadError);
const {data: downloaded, error: downloadError} = await admin.storage.from(bucket).download(object);
assert.ifError(downloadError);
assert.deepEqual(Buffer.from(await downloaded.arrayBuffer()), image);
const denied = await anonymous.storage.from(bucket).download(object);
assert.ok(denied.error && !denied.data, 'Anonymous callers must not receive private fixture bytes.');
for (const user of users) {
  const {data: signedIn, error: signInError} = await anonymous.auth.signInWithPassword({email: user.email, password});
  assert.ifError(signInError);
  assert.equal(signedIn.user.id, user.id);
  const claims = JSON.parse(Buffer.from(signedIn.session.access_token.split('.')[1], 'base64url'));
  assert.ok(['http://127.0.0.1:54321/auth/v1', 'http://localhost:54321/auth/v1'].includes(claims.iss), 'Fixture session issuer must be local.');
}
await mkdir('.private', {recursive: true});
await writeFile('.private/parity-fixtures.json', JSON.stringify({fixture, url: process.env.SUPABASE_URL, password, users, storage: {bucket, object}}, null, 2) + '\n', {mode: 0o600});
console.log(JSON.stringify({fixture, users: users.length, local_sign_in: true, private_image_roundtrip: true, anonymous_image_denied: true}));
