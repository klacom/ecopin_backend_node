import fs from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import { createClient } from '@supabase/supabase-js';

const root = 'C:/dev/App-Builders-Hackathon/.ecopin-optimization/.private/local-supabase-recovery';
const local = JSON.parse(await fs.readFile(root + '/status.private.json', 'utf8'));

if (new URL(local.API_URL).hostname !== '127.0.0.1') {
  throw new Error('Only the local recovery Supabase stack may be tested');
}

const adminClient = createClient(local.API_URL, local.SERVICE_ROLE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false }
});

// Create 1x1 transparent PNG buffer as real image bytes
const pngHeader = Buffer.from([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, // PNG signature
  0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, // IHDR header
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, // 1x1
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89,
  0x00, 0x00, 0x00, 0x0a, 0x49, 0x44, 0x41, 0x54, // IDAT
  0x78, 0x9c, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4,
  0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82 // IEND
]);

let mediaServer;
const results = [];
const createdUsers=[];let fixtureTask,fixtureReport;const fixturePaths=[];const additionalReports=[];
function record(testName, passed, detail = '') {
  results.push({ test: testName, status: passed ? 'PASS' : 'FAIL', detail });
  console.log(`[${passed ? 'PASS' : 'FAIL'}] ${testName}${detail ? ' - ' + detail : ''}`);
  if (!passed) throw new Error(`Assertion failed: ${testName} (${detail})`);
}

async function main() {
  console.log('--- Real Storage HTTP API & Image Bytes Verification ---');
  process.env.NEXT_PUBLIC_SUPABASE_URL=local.API_URL;
  process.env.NEXT_PUBLIC_SERVICE_ROLE_KEY=local.SERVICE_ROLE_KEY;
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY=local.ANON_KEY;
  const {default:express}=await import('express');
  const {default:mediaRoutes}=await import('../src/routes/media.routes.js');
  const app=express();app.use('/api/media',mediaRoutes);
  mediaServer=app.listen(0,'127.0.0.1');await new Promise(resolve=>mediaServer.once('listening',resolve));mediaServer.unref();

  // 1. Create test users and credentials in auth.users & public.profiles
  const crewId = randomUUID();
  const foreignCrewId = randomUUID();
  const citizenId = randomUUID();
  const foreignCitizenId = randomUUID();

  const crewEmail = `test-crew-${Date.now()}@ecopin.test`;
  const foreignCrewEmail = `test-fcrew-${Date.now()}@ecopin.test`;
  const citizenEmail = `test-citizen-${Date.now()}@ecopin.test`;
  const foreignCitizenEmail = `test-fcitizen-${Date.now()}@ecopin.test`;
  const defaultPassword = 'TestPassword123!';

  // Create users via admin auth API
  const { data: crewUser, error: crewErr } = await adminClient.auth.admin.createUser({
    email: crewEmail, password: defaultPassword, email_confirm: true,
    user_metadata: { role: 'field_crew' }
  });
  if (crewErr) throw crewErr;
  createdUsers.push(crewUser.user.id);

  const { data: fCrewUser, error: fCrewErr } = await adminClient.auth.admin.createUser({
    email: foreignCrewEmail, password: defaultPassword, email_confirm: true,
    user_metadata: { role: 'field_crew' }
  });
  if (fCrewErr) throw fCrewErr;
  createdUsers.push(fCrewUser.user.id);

  const { data: citizenUser, error: citErr } = await adminClient.auth.admin.createUser({
    email: citizenEmail, password: defaultPassword, email_confirm: true,
    user_metadata: { role: 'citizen' }
  });
  if (citErr) throw citErr;
  createdUsers.push(citizenUser.user.id);

  const { data: fCitizenUser, error: fCitErr } = await adminClient.auth.admin.createUser({
    email: foreignCitizenEmail, password: defaultPassword, email_confirm: true,
    user_metadata: { role: 'citizen' }
  });
  if (fCitErr) throw fCitErr;
  createdUsers.push(fCitizenUser.user.id);

  // Ensure profiles have correct roles
  await adminClient.from('profiles').upsert([
    { id: crewUser.user.id, full_name: 'Assigned Crew', role: 'field_crew' },
    { id: fCrewUser.user.id, full_name: 'Foreign Crew', role: 'field_crew' },
    { id: citizenUser.user.id, full_name: 'Report Citizen', role: 'citizen' },
    { id: fCitizenUser.user.id, full_name: 'Foreign Citizen', role: 'citizen' }
  ]);

  // Log in as each user to get their JWT bearer tokens
  async function login(email) {
    const res = await fetch(`${local.API_URL}/auth/v1/token?grant_type=password`, {
      method: 'POST',
      headers: { apikey: local.ANON_KEY, 'content-type': 'application/json' },
      body: JSON.stringify({ email, password: defaultPassword })
    });
    const json = await res.json();
    return json.access_token;
  }

  const crewToken = await login(crewEmail);
  const foreignCrewToken = await login(foreignCrewEmail);
  const citizenToken = await login(citizenEmail);
  const foreignCitizenToken = await login(foreignCitizenEmail);

  // Create clients for each user
  const crewClient = createClient(local.API_URL, local.ANON_KEY, {
    global: { headers: { Authorization: `Bearer ${crewToken}` } },
    auth: { autoRefreshToken: false, persistSession: false }
  });

  const foreignCrewClient = createClient(local.API_URL, local.ANON_KEY, {
    global: { headers: { Authorization: `Bearer ${foreignCrewToken}` } },
    auth: { autoRefreshToken: false, persistSession: false }
  });

  const citizenClient = createClient(local.API_URL, local.ANON_KEY, {
    global: { headers: { Authorization: `Bearer ${citizenToken}` } },
    auth: { autoRefreshToken: false, persistSession: false }
  });

  const foreignCitizenClient = createClient(local.API_URL, local.ANON_KEY, {
    global: { headers: { Authorization: `Bearer ${foreignCitizenToken}` } },
    auth: { autoRefreshToken: false, persistSession: false }
  });

  // 2. Create Task & Report fixtures
  const taskId = randomUUID();
  const reportId = randomUUID();
  fixtureTask=taskId;fixtureReport=reportId;

  const { error: taskInsertErr } = await adminClient.from('cleanup_tasks').insert({
    id: taskId,
    title: 'Storage Byte Test Task',
    status: 'in_progress',
    route_status: 'ready',
    assigned_crew_ids: [crewUser.user.id],
    report_ids: [reportId]
  });
  if (taskInsertErr) throw taskInsertErr;

  const { error: reportInsertErr } = await adminClient.from('reports').insert({
    id: reportId,
    user_id: citizenUser.user.id,
    title: 'Storage Byte Test Report',
    issue_type: 'waste',
    cleanup_task_id: taskId,
    location: 'POINT(121.05 14.55)',
    validation_status: 'approved'
  });
  if (reportInsertErr) throw reportInsertErr;

  // 3. Test Upload via Storage API
  const photoUuid = randomUUID();
  const filePath = `${taskId}/before/${photoUuid}.png`;
  fixturePaths.push(filePath);

  console.log('\n[Action] Uploading PNG bytes as assigned crew...');
  const { data: uploadData, error: uploadErr } = await crewClient.storage
    .from('Cleanup Task Photos')
    .upload(filePath, pngHeader, { contentType: 'image/png', upsert: false });

  record('Assigned crew can upload photo bytes', !uploadErr && uploadData?.path === filePath, uploadErr?.message);

  // Verify foreign crew upload is rejected with 403 / 42501
  const foreignUploadPath = `${taskId}/before/${randomUUID()}.png`;
  fixturePaths.push(foreignUploadPath);
  const { data: fUploadData, error: fUploadErr } = await foreignCrewClient.storage
    .from('Cleanup Task Photos')
    .upload(foreignUploadPath, pngHeader, { contentType: 'image/png', upsert: false });

  record('Unassigned crew upload is rejected', !!fUploadErr, fUploadErr?.message || 'Expected rejection');

  // 4. Test Public Download Endpoint for private bucket
  console.log('\n[Action] Testing anonymous public download from private bucket...');
  const publicUrl = `${local.API_URL}/storage/v1/object/public/Cleanup%20Task%20Photos/${filePath}`;
  const publicRes = await fetch(publicUrl);
  record(
    'Anonymous public download is rejected on private bucket',
    publicRes.status === 400 || publicRes.status === 404,
    `HTTP Status: ${publicRes.status}`
  );

  // 5. Test Short-Lived Signed URL Generation & Download
  console.log('\n[Action] Generating short-lived signed URL...');
  const { data: signedData, error: signedErr } = await adminClient.storage
    .from('Cleanup Task Photos')
    .createSignedUrl(filePath, 3600); // 1 hour

  record('Admin/backend can generate signed URL', !signedErr && !!signedData?.signedUrl, signedErr?.message);

  const signedUrl = signedData?.signedUrl?.startsWith('http')
    ? signedData.signedUrl
    : `${local.API_URL}${signedData.signedUrl}`;

  console.log('Signed URL generated (redacted)');
  // Anonymous fetch using signed URL
  const signedRes = await fetch(signedUrl);
  record('Signed URL anonymous fetch returns HTTP 200', signedRes.status === 200, `HTTP Status: ${signedRes.status}`);

  const signedBytes = Buffer.from(await signedRes.arrayBuffer());
  record(
    'Signed URL serves exact binary PNG bytes',
    signedBytes.equals(pngHeader),
    `Received ${signedBytes.length} bytes (expected ${pngHeader.length})`
  );

  // 6. Test Authenticated Download Endpoint (/storage/v1/object/authenticated/...)
  console.log('\n[Action] Testing authenticated download endpoint with user JWTs...');
  const authDownloadUrl = `${local.API_URL}/storage/v1/object/authenticated/Cleanup%20Task%20Photos/${filePath}`;

  // Assigned crew download
  const crewDownloadRes = await fetch(authDownloadUrl, {
    headers: { Authorization: `Bearer ${crewToken}` }
  });
  record(
    'Assigned crew authenticated download returns HTTP 200 with matching bytes',
    crewDownloadRes.status === 200,
    `HTTP Status: ${crewDownloadRes.status}`
  );
  if (crewDownloadRes.status === 200) {
    const bytes = Buffer.from(await crewDownloadRes.arrayBuffer());
    record('Assigned crew receives exact PNG bytes', bytes.equals(pngHeader), `Bytes match: ${bytes.length}`);
  }

  // Citizen owner of report download
  const citizenDownloadRes = await fetch(authDownloadUrl, {
    headers: { Authorization: `Bearer ${citizenToken}` }
  });
  record(
    'Citizen owner authenticated download returns HTTP 200',
    citizenDownloadRes.status === 200,
    `HTTP Status: ${citizenDownloadRes.status}`
  );

  // Unassigned / foreign crew download (should be denied)
  const fCrewDownloadRes = await fetch(authDownloadUrl, {
    headers: { Authorization: `Bearer ${foreignCrewToken}` }
  });
  record(
    'Unassigned crew authenticated download is rejected',
    fCrewDownloadRes.status === 400 || fCrewDownloadRes.status === 403 || fCrewDownloadRes.status === 404,
    `HTTP Status: ${fCrewDownloadRes.status}`
  );

  // Foreign citizen download (should be denied)
  const fCitizenDownloadRes = await fetch(authDownloadUrl, {
    headers: { Authorization: `Bearer ${foreignCitizenToken}` }
  });
  record(
    'Foreign citizen authenticated download is rejected',
    fCitizenDownloadRes.status === 400 || fCitizenDownloadRes.status === 403 || fCitizenDownloadRes.status === 404,
    `HTTP Status: ${fCitizenDownloadRes.status}`
  );

  const mixedReportId=randomUUID();
  const mixedInsert=await adminClient.from('reports').insert({id:mixedReportId,user_id:fCitizenUser.user.id,title:'Mixed-owner Storage Fixture',issue_type:'waste',cleanup_task_id:taskId,location:'POINT(121.05 14.55)',validation_status:'approved',on_private_property:true});
  if(mixedInsert.error) throw mixedInsert.error;additionalReports.push(mixedReportId);
  const mixedRead=await fetch(authDownloadUrl,{headers:{Authorization:`Bearer ${citizenToken}`}});
  record('Owning one report cannot expose mixed-owner task photos',mixedRead.status!==200);
  const removedReceipts=await adminClient.from('field_assignment_receipts').delete().eq('report_id',mixedReportId);
  if(removedReceipts.error) throw removedReceipts.error;
  const removedMixed=await adminClient.from('reports').delete().eq('id',mixedReportId);
  if(removedMixed.error) throw removedMixed.error;
  const readAs=async token=>(await fetch(authDownloadUrl,{headers:{Authorization:`Bearer ${token}`}})).status;
  {const updated=await adminClient.from('cleanup_tasks').update({route_status:'needs_replan'}).eq('id',taskId);if(updated.error)throw updated.error;}
  record('Unready crew cannot download private bytes',(await readAs(crewToken))!==200);
  {const updated=await adminClient.from('cleanup_tasks').update({route_status:'ready',status:'completed'}).eq('id',taskId);if(updated.error)throw updated.error;}
  record('Inactive crew cannot download private bytes',(await readAs(crewToken))!==200);
  {const updated=await adminClient.from('cleanup_tasks').update({status:'in_progress',assigned_crew_ids:[fCrewUser.user.id]}).eq('id',taskId);if(updated.error)throw updated.error;}
  record('Reassigned crew loses private-byte access',(await readAs(crewToken))!==200);
  {const updated=await adminClient.from('cleanup_tasks').update({assigned_crew_ids:[crewUser.user.id]}).eq('id',taskId);if(updated.error)throw updated.error;}
  // Recreate only this disposable report as an unclaimed legacy row. The task
  // keeps its historical report_ids, while canonical association is now absent.
  const removedOriginalReceipts=await adminClient.from('field_assignment_receipts').delete().eq('report_id',reportId);
  if(removedOriginalReceipts.error) throw removedOriginalReceipts.error;
  const removedOriginal=await adminClient.from('reports').delete().eq('id',reportId);
  if(removedOriginal.error) throw removedOriginal.error;
  const recreated=await adminClient.from('reports').insert({id:reportId,user_id:citizenUser.user.id,title:'Storage Byte Test Report',issue_type:'waste',location:'POINT(121.05 14.55)',validation_status:'approved'});
  if(recreated.error) throw recreated.error;
  record('Stale advisory report_ids cannot grant photo access',(await readAs(citizenToken))!==200);
  const canonical=`storage://${encodeURIComponent('Cleanup Task Photos')}/${filePath}`;
  const current=(await adminClient.from('cleanup_tasks').select('fc_version').eq('id',taskId).single()).data;
  const attached=await adminClient.rpc('set_task_photo',{task_id:taskId,actor:crewUser.user.id,slot:'before',url:canonical,photo_hash:createHash('sha256').update(pngHeader).digest('hex'),expected_version:current.fc_version});
  if(attached.error)throw attached.error;
  record('Actual photo RPC stores a stable reference without expiration',attached.data.status==='success'&&attached.data.server_record.before_photo_url===canonical);
  const mediaUrl=`http://127.0.0.1:${mediaServer.address().port}/api/media/storage?bucket=${encodeURIComponent('Cleanup Task Photos')}&path=${encodeURIComponent(filePath)}`;
  const proxy=await fetch(mediaUrl,{headers:{Authorization:`Bearer ${crewToken}`}});
  record('Actual backend media router serves authorized bytes',proxy.status===200&&Buffer.from(await proxy.arrayBuffer()).equals(pngHeader));
  record('Backend bytes prohibit browser caching',proxy.headers.get('cache-control')==='private, no-store');
  record('Backend media router denies anonymous callers',(await fetch(mediaUrl)).status===401);
  record('Backend media router denies unrelated crew',(await fetch(mediaUrl,{headers:{Authorization:`Bearer ${foreignCrewToken}`}})).status!==200);
  const readiness=await adminClient.from('cleanup_tasks').update({route_status:'needs_replan'}).eq('id',taskId);
  if(readiness.error)throw readiness.error;
  record('Backend media router rechecks current task readiness',(await fetch(mediaUrl,{headers:{Authorization:`Bearer ${crewToken}`}})).status!==200);
  const ready=await adminClient.from('cleanup_tasks').update({route_status:'ready'}).eq('id',taskId);if(ready.error)throw ready.error;
  const stored=(await adminClient.from('cleanup_tasks').select('fc_version').eq('id',taskId).single()).data;
  const detached=await adminClient.rpc('set_task_photo',{task_id:taskId,actor:crewUser.user.id,slot:'before',url:null,photo_hash:null,expected_version:stored.fc_version});
  if(detached.error||detached.data.status!=='success')throw new Error('Fixture photo detach failed');
  // 7. Test Deletion & Replacement
  console.log('\n[Action] Testing deletion authorization...');
  // Foreign crew delete rejected
  const { error: fDeleteErr } = await foreignCrewClient.storage
    .from('Cleanup Task Photos')
    .remove([filePath]);
  // Verify object still exists
  const checkRes = await fetch(authDownloadUrl, {
    headers: { Authorization: `Bearer ${crewToken}` }
  });
  record('Unassigned crew cannot delete photo object', checkRes.status === 200, 'Object still present');

  // Assigned crew delete succeeds
  const { error: deleteErr } = await crewClient.storage
    .from('Cleanup Task Photos')
    .remove([filePath]);
  record('Assigned crew can delete photo object', !deleteErr, deleteErr?.message);

  // Verify object is gone
  const afterDeleteRes = await fetch(authDownloadUrl, {
    headers: { Authorization: `Bearer ${crewToken}` }
  });
  record('Deleted photo returns HTTP 400/404 after removal', afterDeleteRes.status === 400 || afterDeleteRes.status === 404, `HTTP Status: ${afterDeleteRes.status}`);

  console.log('\n=== All Real Storage HTTP API Checks Completed Successfully! ===');

  // Save verification artifact
  const artifact = {
    timestamp: new Date().toISOString(),
    environment: 'Local Supabase (Gotrue v2.197.0, Storage v1.11.13, PostgreSQL 17.11)',
    results
  };
  await fs.writeFile(
    'C:/dev/App-Builders-Hackathon/.ecopin-optimization/REAL_STORAGE_HTTP_INTEGRATION_VERIFICATION.json',
    JSON.stringify(artifact, null, 2)
  );
}

try {await main();} finally {
  mediaServer?.close();
  const ensure=result=>{if(result.error) throw new Error(`Fixture cleanup failed: ${result.error.code??'UNKNOWN'}`)};
  ensure(await adminClient.storage.from('Cleanup Task Photos').remove(fixturePaths));
  for(const id of additionalReports){ensure(await adminClient.from('field_assignment_receipts').delete().eq('report_id',id));ensure(await adminClient.from('reports').delete().eq('id',id));}
  if(fixtureReport){ensure(await adminClient.from('field_assignment_receipts').delete().eq('report_id',fixtureReport));ensure(await adminClient.from('reports').delete().eq('id',fixtureReport));}
  if(fixtureTask)ensure(await adminClient.from('cleanup_tasks').delete().eq('id',fixtureTask));
  for(const id of createdUsers){ensure(await adminClient.from('profiles').delete().eq('id',id));ensure(await adminClient.auth.admin.deleteUser(id));}
}