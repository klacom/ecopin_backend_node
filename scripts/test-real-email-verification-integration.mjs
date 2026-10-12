import fs from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { createClient } from '@supabase/supabase-js';

const root = 'C:/dev/App-Builders-Hackathon/.ecopin-optimization/.private/local-supabase-recovery';
const local = JSON.parse(await fs.readFile(root + '/status.private.json', 'utf8'));
const syntheticFixture = JSON.parse(await fs.readFile(root + '/synthetic-auth-fixture.private.json', 'utf8'));

if (new URL(local.API_URL).hostname !== '127.0.0.1') {
  throw new Error('Only the local recovery Supabase stack may be tested');
}

const adminClient = createClient(local.API_URL, local.SERVICE_ROLE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false }
});

const anonClient = createClient(local.API_URL, local.ANON_KEY, {
  auth: { autoRefreshToken: false, persistSession: false }
});

// Login as ordinary synthetic citizen
const loginRes = await fetch(local.API_URL + '/auth/v1/token?grant_type=password', {
  method: 'POST',
  headers: { apikey: local.ANON_KEY, 'content-type': 'application/json' },
  body: JSON.stringify({ email: syntheticFixture.email, password: syntheticFixture.password })
});
if (!loginRes.ok) throw new Error('Citizen login failed for local integration test');
const citizenSession = await loginRes.json();
const citizenClient = createClient(local.API_URL, local.ANON_KEY, {
  global: { headers: { Authorization: `Bearer ${citizenSession.access_token}` } },
  auth: { autoRefreshToken: false, persistSession: false }
});

const results = [];
const createdUsers = [];
function record(testName, passed, detail = '') {
  results.push({ test: testName, status: passed ? 'PASS' : 'FAIL', detail });
  console.log(`[${passed ? 'PASS' : 'FAIL'}] ${testName}${detail ? ' - ' + detail : ''}`);
  if (!passed) throw new Error(`Assertion failed: ${testName} (${detail})`);
}

// Exercise the production handler over HTTP; no copied verification algorithm.
process.env.SMTP_HOST = '127.0.0.1';
process.env.SMTP_PORT = '54325';
process.env.SMTP_USER = '';
process.env.SMTP_PASS = '';
process.env.NEXT_PUBLIC_SUPABASE_URL = local.API_URL;
process.env.NEXT_PUBLIC_SERVICE_ROLE_KEY = local.SERVICE_ROLE_KEY;
process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY = local.ANON_KEY;
const { default: express } = await import('express');
const { default: authRouter } = await import('../src/routes/auth.routes.js');
const { supabaseAdmin: handlerClient } = await import('../src/config/supabase.config.js');
const app = express();
app.use(express.json());
app.use('/api/auth', authRouter);
const server = app.listen(0, '127.0.0.1');
await new Promise(resolve => server.once('listening', resolve));
server.unref();
const endpoint = `http://127.0.0.1:${server.address().port}/api/auth/verify-email`;
async function runVerifyEmail(token, { simulateAuthFailure = false, simulateDbFailure = false } = {}) {
  const update = handlerClient.auth.admin.getUserById;
  const rpc = handlerClient.rpc;
  if (simulateAuthFailure) handlerClient.auth.admin.getUserById = async () => ({data:null,error:{code:'injected_auth_failure'}});
  if (simulateDbFailure) handlerClient.rpc = async () => ({data:null,error:{code:'injected_db_failure'}});
  try {
    const response = await fetch(`${endpoint}?token=${encodeURIComponent(token)}`);
    return { status: response.status, message: await response.text() };
  } finally {
    handlerClient.auth.admin.getUserById = update;
    handlerClient.rpc = rpc;
  }
}
// Helper to create disposable auth user & token
async function createTestFixture(emailPrefix, issue = true) {
  const email = `${emailPrefix}_${Date.now()}@example.invalid`;
  const { data: authUser, error: createError } = await adminClient.auth.admin.createUser({
    email,
    password: 'TestPassword123!',
    email_confirm: false
  });
  if (createError) throw createError;
  const userId = authUser.user.id;
  createdUsers.push(userId);
  if (!issue) return {userId,email};

  const token = randomUUID();
  const tokenDigest = createHash('sha256').update(token.toLowerCase()).digest('hex');

  const { data: issuanceId, error: issueError } = await adminClient.rpc('issue_email_verification', {
    p_user_id: userId,
    p_token_digest: tokenDigest,
    p_ttl_hours: 24,
    p_email: email
  });
  if (issueError) throw issueError;

  return { userId, email, token, tokenDigest, issuanceId };
}

console.log('--- Starting Real Email Verification Integration Suite ---');

try {
  // Case 1: Matching email succeeds
  console.log('\nTesting Case 1: Matching email succeeds...');
  const f1 = await createTestFixture('case1_match');
  const res1 = await runVerifyEmail(f1.token);
  record('Case 1: HTTP status is 200', res1.status === 200, `Got ${res1.status}`);

  const user1 = (await adminClient.auth.admin.getUserById(f1.userId)).data.user;
  record('Case 1: Auth user is confirmed', !!user1.email_confirmed_at, `email_confirmed_at=${user1.email_confirmed_at}`);

  const profile1 = (await adminClient.from('profiles').select('is_email_verified').eq('id', f1.userId).single()).data;
  record('Case 1: Profile is_email_verified is true', profile1.is_email_verified === true, `is_email_verified=${profile1.is_email_verified}`);

  const token1 = (await adminClient.from('email_verifications').select('used_at').eq('id', f1.issuanceId).single()).data;
  record('Case 1: Token used_at is populated', !!token1.used_at, `used_at=${token1.used_at}`);

  // Case 2: Changed email rejects the old link
  console.log('\nTesting Case 2: Changed email rejects old link...');
  const f2 = await createTestFixture('case2_changed');
  const changedEmail = `changed_${Date.now()}@example.invalid`;
  await adminClient.auth.admin.updateUserById(f2.userId, { email: changedEmail, email_confirm: false });

  const res2 = await runVerifyEmail(f2.token);
  record('Case 2: HTTP status is 400 on email mismatch', res2.status === 400, `Got ${res2.status}`);

  const user2 = (await adminClient.auth.admin.getUserById(f2.userId)).data.user;
  record('Case 2: Auth user remains unconfirmed', !user2.email_confirmed_at, `email_confirmed_at=${user2.email_confirmed_at}`);

  const token2 = (await adminClient.from('email_verifications').select('used_at').eq('id', f2.issuanceId).single()).data;
  record('Case 2: Token used_at remains null', token2.used_at === null, `used_at=${token2.used_at}`);

  // Case 3: Expired and used tokens reject
  console.log('\nTesting Case 3: Expired and used tokens reject...');
  // 3a. Used token
  const res3a = await runVerifyEmail(f1.token);
  record('Case 3a: Re-using token rejects with 400', res3a.status === 400, `Got ${res3a.status}`);

  // 3b. Expired token
  const f3b = await createTestFixture('case3b_expired');
  // Backdate expires_at
  await adminClient.from('email_verifications').update({
    expires_at: new Date(Date.now() - 3600000).toISOString()
  }).eq('id', f3b.issuanceId);

  const res3b = await runVerifyEmail(f3b.token);
  record('Case 3b: Expired token rejects with 400', res3b.status === 400, `Got ${res3b.status}`);

  // Case 4: Two simultaneous redemptions produce one valid completion
  console.log('\nTesting Case 4: Two simultaneous redemptions produce one valid completion...');
  const f4 = await createTestFixture('case4_concurrent');
  const [cResA, cResB] = await Promise.all([
    runVerifyEmail(f4.token),
    runVerifyEmail(f4.token)
  ]);
  const statuses = [cResA.status, cResB.status].sort();
  record('Case 4: Exactly one concurrent request succeeds (200) and one receives 400', 
    statuses[0] === 200 && statuses[1] === 400, 
    `Results: [${cResA.status}, ${cResB.status}]`
  );

  const user4 = (await adminClient.auth.admin.getUserById(f4.userId)).data.user;
  record('Case 4: Auth user is confirmed exactly once', !!user4.email_confirmed_at, `email_confirmed_at=${user4.email_confirmed_at}`);

  const profile4 = (await adminClient.from('profiles').select('is_email_verified').eq('id', f4.userId).single()).data;
  record('Case 4: Profile is verified', profile4.is_email_verified === true);

  // Case 5: Auth failure leaves a safe retry path
  console.log('\nTesting Case 5: Auth failure leaves safe retry path...');
  const f5 = await createTestFixture('case5_auth_fail');
  const res5Failed = await runVerifyEmail(f5.token, { simulateAuthFailure: true });
  record('Case 5: Transient Auth failure returns 503', res5Failed.status === 503, `Got ${res5Failed.status}`);

  const token5Pre = (await adminClient.from('email_verifications').select('used_at').eq('id', f5.issuanceId).single()).data;
  record('Case 5: Token remains unconsumed on Auth failure', token5Pre.used_at === null);

  // Retry succeeds
  const res5Retry = await runVerifyEmail(f5.token);
  record('Case 5: Subsequent retry succeeds with 200', res5Retry.status === 200, `Got ${res5Retry.status}`);

  const user5 = (await adminClient.auth.admin.getUserById(f5.userId)).data.user;
  record('Case 5: Auth confirmed on retry', !!user5.email_confirmed_at);

  // Case 6: Database-boundary failure is recoverable without partial confirmation
  console.log('\nTesting Case 6: Database-boundary failure is recoverable without partial confirmation...');
  const f6 = await createTestFixture('case6_db_fail');
  const res6Failed = await runVerifyEmail(f6.token, { simulateDbFailure: true });
  record('Case 6: Transient DB failure returns 503', res6Failed.status === 503, `Got ${res6Failed.status}`);

  const token6Pre = (await adminClient.from('email_verifications').select('used_at').eq('id', f6.issuanceId).single()).data;
  record('Case 6: Token remains unconsumed during DB transient failure', token6Pre.used_at === null);

  // Retry succeeds
  const res6Retry = await runVerifyEmail(f6.token);
  record('Case 6: Retry converges on 200 success', res6Retry.status === 200, `Got ${res6Retry.status}`);

  const profile6 = (await adminClient.from('profiles').select('is_email_verified').eq('id', f6.userId).single()).data;
  record('Case 6: Profile is verified on retry', profile6.is_email_verified === true);

  // Case 7: A losing concurrent request does not undo the winner
  console.log('\nTesting Case 7: A losing concurrent request does not undo the winner...');
  const f7 = await createTestFixture('case7_preserve');
  const res7Winner = await runVerifyEmail(f7.token);
  record('Case 7: Winner redemption succeeds (200)', res7Winner.status === 200);

  // Loser request arrives next
  const res7Loser = await runVerifyEmail(f7.token);
  record('Case 7: Loser redemption returns 400', res7Loser.status === 400);

  const user7 = (await adminClient.auth.admin.getUserById(f7.userId)).data.user;
  record('Case 7: Winner Auth confirmation preserved (never unconfirmed)', !!user7.email_confirmed_at);

  const profile7 = (await adminClient.from('profiles').select('is_email_verified').eq('id', f7.userId).single()).data;
  record('Case 7: Winner profile is_email_verified preserved', profile7.is_email_verified === true);

  // Case 8: Missing-profile behavior creates only the intended default role
  console.log('\nTesting Case 8: Missing profile self-healing creates citizen role only...');
  const f8 = await createTestFixture('case8_missing_profile');
  // Remove profile row completely
  await adminClient.from('profiles').delete().eq('id', f8.userId);
  const profile8Check = await adminClient.from('profiles').select('id').eq('id', f8.userId).maybeSingle();
  record('Case 8: Profile confirmed deleted before redemption', profile8Check.data === null);

  const res8 = await runVerifyEmail(f8.token);
  record('Case 8: Redemption succeeds and self-heals profile', res8.status === 200);

  const profile8Healed = (await adminClient.from('profiles').select('id, role, is_email_verified').eq('id', f8.userId).single()).data;
  record('Case 8: Self-healed profile has role=citizen', profile8Healed.role === 'citizen', `role=${profile8Healed.role}`);
  record('Case 8: Self-healed profile has is_email_verified=true', profile8Healed.is_email_verified === true);

  // Case 9: Anonymous and ordinary authenticated callers cannot read tokens or invoke trusted routines
  console.log('\nTesting Case 9: Privileges & RLS boundary on verification objects...');
  // Anon read tokens
  const anonTokens = await anonClient.from('email_verifications').select('id');
  record('Case 9: Anon read tokens denied/empty', anonTokens.status === 401 || anonTokens.status === 403 || (Array.isArray(anonTokens.data) && anonTokens.data.length === 0));

  // Citizen read tokens
  const citizenTokens = await citizenClient.from('email_verifications').select('id');
  record('Case 9: Citizen read tokens denied/empty', citizenTokens.status === 403 || (Array.isArray(citizenTokens.data) && citizenTokens.data.length === 0));

  // Anon call complete_email_verification
  const anonRpc = await anonClient.rpc('complete_email_verification', {
    p_verification_id: f1.issuanceId,
    p_user_id: f1.userId,
    p_expected_email: f1.email
  });
  record('Case 9: Anon execution of complete_email_verification denied (42501)', anonRpc.error?.code === '42501' || anonRpc.status === 401 || anonRpc.status === 403);

  // Citizen call complete_email_verification
  const citizenRpc = await citizenClient.rpc('complete_email_verification', {
    p_verification_id: f1.issuanceId,
    p_user_id: f1.userId,
    p_expected_email: f1.email
  });
  record('Case 9: Citizen execution of complete_email_verification denied (42501)', citizenRpc.error?.code === '42501' || citizenRpc.status === 403);

  // Citizen call issue_email_verification
  const citizenIssueRpc = await citizenClient.rpc('issue_email_verification', {
    p_user_id: f1.userId,
    p_token_digest: f1.tokenDigest,
    p_ttl_hours: 24
  });
  record('Case 9: Citizen execution of issue_email_verification denied (42501)', citizenIssueRpc.error?.code === '42501' || citizenIssueRpc.status === 403);

  // Case 10: change the real Auth email after preflight, immediately before the RPC.
  const f10=await createTestFixture('case10_race');
  const originalRpc=handlerClient.rpc;
  handlerClient.rpc=async function(name,args){
    if(args.p_verification_id===f10.issuanceId){
      const changed=await adminClient.auth.admin.updateUserById(f10.userId,{email:`race_${Date.now()}@example.invalid`});
      if(changed.error) throw changed.error;
    }
    return originalRpc.call(this,name,args);
  };
  let race;
  try{race=await runVerifyEmail(f10.token)}finally{handlerClient.rpc=originalRpc}
  record('Case 10: Email changed after preflight rejects redemption',race.status===400,`HTTP ${race.status}`);
  const racedUser=(await adminClient.auth.admin.getUserById(f10.userId)).data.user;
  record('Case 10: Changed email is never confirmed',!racedUser.email_confirmed_at);
  // Case 11: historical Auth-success/database-failure remains recoverable after expiry.
  const f11=await createTestFixture('case11_expired_recovery');
  const confirmation=await adminClient.auth.admin.updateUserById(f11.userId,{email_confirm:true});
  if(confirmation.error) throw confirmation.error;
  await adminClient.from('email_verifications').update({expires_at:new Date(Date.now()+100).toISOString()}).eq('id',f11.issuanceId);
  await new Promise(resolve=>setTimeout(resolve,200));
  const recovery=await runVerifyEmail(f11.token);
  record('Case 11: Bound partial completion recovers after token expiry',recovery.status===200);
  record('Case 11: Recovery verifies the profile',(await adminClient.from('profiles').select('is_email_verified').eq('id',f11.userId).single()).data.is_email_verified===true);

  const f12=await createTestFixture('case12_legacy');
  await adminClient.from('email_verifications').update({issued_to_email:null}).eq('id',f12.issuanceId);
  record('Case 12: Unbound legacy tokens require a new link',(await runVerifyEmail(f12.token)).status===400);
  record('Case 12: Legacy rejection leaves Auth unconfirmed',!(await adminClient.auth.admin.getUserById(f12.userId)).data.user.email_confirmed_at);

  const f13=await createTestFixture('case13_login');
  const native=createClient(local.API_URL,local.ANON_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
  const before=await native.auth.signInWithPassword({email:f13.email,password:'TestPassword123!'});
  record('Case 13: Native Auth rejects login before confirmation',!!before.error);
  record('Case 13: Actual handler confirms the account',(await runVerifyEmail(f13.token)).status===200);
  const after=await native.auth.signInWithPassword({email:f13.email,password:'TestPassword123!'});
  record('Case 13: Native Auth accepts login after atomic confirmation',!after.error&&after.data.user?.id===f13.userId);
  await native.auth.signOut();
  for(const client of [anonClient,citizenClient]){
    const denied=await client.rpc('redeem_email_verification_atomic',{p_verification_id:f13.issuanceId,p_user_id:f13.userId,p_expected_email:f13.email});
    record('Atomic redemption denies an untrusted caller',!!denied.error);
  }
  // Case 14: real SQL failure after the Auth write rolls back the entire transaction.
  const f14=await createTestFixture('case14_atomic_failure');
  const sql=input=>execFileSync('C:/Program Files/Docker/Docker/resources/bin/docker.exe',['exec','-i','supabase_db_ecopin-recovery-20261012','psql','-X','-q','-v','ON_ERROR_STOP=1','-U','postgres','-d','postgres'],{input,encoding:'utf8',timeout:30000});
  sql(`CREATE FUNCTION verification_private.integration_failure() RETURNS trigger LANGUAGE plpgsql AS $test$ BEGIN IF NEW.id='${f14.userId}'::uuid AND NEW.is_email_verified THEN RAISE EXCEPTION 'fixture profile failure' USING ERRCODE='40001'; END IF; RETURN NEW; END $test$; CREATE TRIGGER ecopin_atomic_failure_test BEFORE INSERT OR UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION verification_private.integration_failure();`);
  try {
    const failure=await runVerifyEmail(f14.token);
    record('Case 14: Real database write failure returns retryable 503',failure.status===503);
    record('Case 14: Auth confirmation rolls back with profile failure',!(await adminClient.auth.admin.getUserById(f14.userId)).data.user.email_confirmed_at);
    record('Case 14: Token consumption also rolls back',(await adminClient.from('email_verifications').select('used_at').eq('id',f14.issuanceId).single()).data.used_at===null);
  }finally{sql('DROP TRIGGER ecopin_atomic_failure_test ON public.profiles; DROP FUNCTION verification_private.integration_failure();');}
  record('Case 14: Retry succeeds after the actual write fault is removed',(await runVerifyEmail(f14.token)).status===200);
  const f15=await createTestFixture('case15_issuance',false);
  const {transporter}=await import('../src/config/email.config.js');
  const send=transporter.sendMail;let delivered;
  transporter.sendMail=async message=>{delivered=message;return {messageId:'local-fixture',accepted:[message.to]}};
  let issuance;
  try{issuance=await fetch(endpoint.replace('/verify-email','/resend-verification'),{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({email:f15.email.toUpperCase()})})}finally{transporter.sendMail=send}
  record('Case 15: Actual issuance route succeeds',issuance.status===200);
  const deliveredToken=delivered?.html?.match(/verify-email\?token=([0-9a-f-]{36})/)?.[1];
  record('Case 15: Actual mail boundary receives a UUID link',!!deliveredToken);
  const issued=(await adminClient.from('email_verifications').select('token,token_digest,issued_to_email').eq('user_id',f15.userId).single()).data;
  record('Case 15: Issuance stores only digest and normalized email',issued?.token===null&&issued.token_digest===createHash('sha256').update(deliveredToken).digest('hex')&&issued.issued_to_email===f15.email);
  record('Case 15: Issued link redeems through actual router',(await runVerifyEmail(deliveredToken)).status===200);
  const f16=await createTestFixture('case16_schema_gate');
  sql(await fs.readFile('migrations/rollback/20261012143000_make_email_verification_atomic.sql','utf8'));
  try{
    record('Case 16: Missing atomic migration fails closed with 503',(await runVerifyEmail(f16.token)).status===503);
    record('Case 16: Missing migration never confirms Auth',!(await adminClient.auth.admin.getUserById(f16.userId)).data.user.email_confirmed_at);
    record('Case 16: Missing migration leaves token available',(await adminClient.from('email_verifications').select('used_at').eq('id',f16.issuanceId).single()).data.used_at===null);
  }finally{sql(await fs.readFile('migrations/20261012143000_make_email_verification_atomic.sql','utf8'));sql("NOTIFY pgrst, 'reload schema';");}
  let resumed;
  for(let attempt=0;attempt<10;attempt++){resumed=await runVerifyEmail(f16.token);if(resumed.status===200)break;await new Promise(resolve=>setTimeout(resolve,100))}
  record('Case 16: Reapplied migration restores the same link',resumed.status===200);
  console.log('\n=== ALL 16 CASES PASSED SUCCESSFULLY ===');
  
  const artifact = {
    gate: 'S02',
    description: 'Actual Express verifyEmail handler over HTTP against local Auth/PostgreSQL; boundary-injected failures',
    verified_at: new Date().toISOString(),
    environment: 'Private local Supabase; production Express handler over localhost HTTP',
    cases_passed: 16,
    assertions_passed: results.length,
    cases_failed: 0,
    results
  };

  await fs.writeFile(
    'C:/dev/App-Builders-Hackathon/.ecopin-optimization/REAL_EMAIL_VERIFICATION_INTEGRATION_VERIFICATION.json',
    JSON.stringify(artifact, null, 2),
    'utf8'
  );
  server.close();
  console.log('Artifact saved: .ecopin-optimization/REAL_EMAIL_VERIFICATION_INTEGRATION_VERIFICATION.json');

} catch (err) {
  console.error('\nIntegration test failed:', err);
  process.exitCode = 1;
} finally {
  server.close();
  for (const id of createdUsers) {
    const {error: profileError} = await adminClient.from('profiles').delete().eq('id', id);
    if (profileError) { console.error('Fixture profile cleanup failed:', profileError.code); process.exitCode = 1; continue; }
    const {error: authError} = await adminClient.auth.admin.deleteUser(id);
    if (authError) { console.error('Fixture Auth cleanup failed:', authError.code); process.exitCode = 1; }
  }
}
