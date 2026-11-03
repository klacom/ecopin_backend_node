import {buildManifest,verifyRelease,formatReport,isMissingRoute,FEATURES,ROLES} from '../scripts/lib/release-verification.mjs';

const TODAY='2026-11-03',SHA='5fc531deda5fcb6678e5f870da3e405fecbc3819',OTHER='75f056735be0c8d07e73d114eb8f59601d1311fc';
const TOKENS=Object.fromEntries(ROLES.map(r=>[r,'token-'+r]));
const manifest=buildManifest({today:TODAY});

// A stand-in backend built from the manifest itself. Shared authentication answers 401 before any route lookup inside a router,
// exactly as the real routers do; a route that is not registered falls through to the 404 handler.
function release({sha=SHA,missing=[],openTo={},health={},legacyHealth=false}={}){
 const routes=new Map();
 for(const p of manifest){const path=p.path.split('?')[0];const entry=routes.get(path)??{roles:new Set(),status:p.allow[0],anonymous:p.role==='anonymous'};if(!p.denied)entry.roles.add(p.role);routes.set(path,entry);}
 const calls=[];
 const fetchImpl=async(url,{headers={}}={})=>{
  const u=new URL(url),path=u.pathname,auth=headers.Authorization;calls.push({path,auth});
  const reply=(status,body)=>({status,json:async()=>body});
  if(path==='/health')return reply(200,legacyHealth?{status:'OK',dependencies:{database:'available',classifier:'available'}}:{status:'OK',dependencies:{database:'available',classifier:'available'},release:{sha,source:'artifact'},jobs:{unprocessed_escalation:{enabled:true,last_outcome:'ok'}},...health});
  const route=routes.get(path);
  const role=auth?auth.replace('Bearer token-',''):null;
  if(route&&!route.anonymous&&!role)return reply(401,{error:'Unauthorized'});
  if(!route||missing.includes(path))return reply(404,{error:'Route not found',code:'route_not_found'});
  if(route.anonymous)return reply(route.status,{});
  if(openTo[path]?.includes(role))return reply(200,{});
  return route.roles.has(role)?reply(route.status,{}):reply(403,{error:'Authorized accounts only'});
 };
 return {fetchImpl,calls,routes};
}
const run=(r,options={})=>verifyRelease({base:'https://backend.example.invalid',fetchImpl:r.fetchImpl,tokens:TOKENS,expectSha:SHA,today:TODAY,...options});

test('the manifest covers every recovered feature, each with an authorised and (where staff-only) an unauthorised probe',()=>{
 expect(FEATURES(TODAY).sort()).toEqual(['T04','T05','T06','T07','T08','T09','T10','T11']);
 for(const feature of ['T04','T05','T06','T07','T08','T10'])expect(manifest.some(p=>p.feature.startsWith(feature)&&p.denied)).toBe(true);
 expect(new Set(manifest.map(p=>p.id)).size).toBe(manifest.length);
 expect(manifest.filter(p=>!p.denied&&p.role!=='anonymous').length).toBeGreaterThanOrEqual(12);
});
test('only the backend 404 handler answer means "route missing"',()=>{
 expect(isMissingRoute(404,{error:'Route not found',code:'route_not_found'})).toBe(true);
 expect(isMissingRoute(404,{error:'Route not found'})).toBe(true); // releases that predate the code
 expect(isMissingRoute(404,{error:'Incident not found.'})).toBe(false);
 expect(isMissingRoute(401,{code:'route_not_found'})).toBe(false);
});

describe('a correct release',()=>{
 test('passes: identity, health and every role-aware feature probe',async()=>{
  const report=await run(release());
  expect(report.ok).toBe(true);expect(report.failed).toEqual([]);expect(formatReport(report)).toContain('PASSED');
 });
 test('classifier warming is reachable, an unreachable classifier is not',async()=>{
  expect((await run(release({health:{dependencies:{database:'available',classifier:'warming'}}}))).ok).toBe(true);
  const bad=await run(release({health:{dependencies:{database:'available',classifier:'unavailable'}}}));
  expect(bad.ok).toBe(false);expect(bad.failed.map(f=>f.id)).toContain('health classifier');
  expect((await run(release({health:{dependencies:{database:'available',classifier:'unavailable'}}}),{requireClassifier:false})).ok).toBe(true);
 });
 test('escalation registration can be required for production',async()=>{
  expect((await run(release(),{requireEscalation:true})).ok).toBe(true);
  const off=await run(release({health:{jobs:{unprocessed_escalation:{enabled:false}}}}),{requireEscalation:true});
  expect(off.ok).toBe(false);expect(off.failed[0].id).toBe('T11 escalation job');
 });
});

describe('a release that omits a feature route fails, even though shared authentication still answers',()=>{
 test.each([
  ['T06 staff support queue','/api/support/queue'],['T08 incident case record',`/api/reports/00000000-0000-4000-8000-000000000000/case-record`],
  ['T10 crew operations summary','/api/sweeper/operations-summary'],['T07 field directions','/api/routing/directions'],['T04 executive report','/api/analytics/barangay/executive'],
 ])('%s',async(feature,path)=>{
  const r=release({missing:[path]}),report=await run(r);
  expect(report.ok).toBe(false);
  const missing=report.failed.filter(f=>f.outcome==='missing_route');
  expect(missing.length).toBeGreaterThan(0);expect(missing.every(f=>f.feature.startsWith(feature.split(' ')[0]))).toBe(true);
  expect(formatReport(report)).toContain('MISSING_ROUTE');
  expect(report.failed.every(f=>f.outcome==='missing_route')).toBe(true); // nothing else is wrong with the release
 });
 test('an unauthenticated-only check cannot see the gap: the same omission looks like 401 without a session',async()=>{
  const r=release({missing:['/api/support/queue']});
  // Shared auth answers first when no session is sent: the stand-in only reveals the missing route to an authenticated caller when the route exists in its table.
  const anonymous=await r.fetchImpl('https://x.invalid/api/support/queue?limit=1');
  const authed=await r.fetchImpl('https://x.invalid/api/support/queue?limit=1',{headers:{Authorization:'Bearer token-officer'}});
  expect(anonymous.status).toBe(401);expect(authed.status).toBe(404);
 });
 test('a missing role session fails the feature instead of skipping it',async()=>{
  const {citizen,...withoutCitizen}=TOKENS;const report=await run(release(),{tokens:withoutCitizen});
  expect(report.ok).toBe(false);expect(report.failed.every(f=>f.outcome==='no_credentials'&&f.role==='citizen')).toBe(true);
 });
 test('a green health endpoint alone does not pass: no sessions means every feature is unverified',async()=>{
  const report=await run(release(),{tokens:{}});
  expect(report.ok).toBe(false);expect(report.results.find(r=>r.id==='release identity').outcome).toBe('pass');
  expect(report.failed.length).toBeGreaterThanOrEqual(manifest.filter(p=>p.role!=='anonymous').length);
 });
 test('a release that registers nothing behind a healthy answer fails every authenticated feature',async()=>{
  const r=release({missing:[...new Set(manifest.map(p=>p.path.split('?')[0]))]});const report=await run(r);
  expect(report.ok).toBe(false);expect(report.failed.filter(f=>f.outcome==='missing_route').length).toBe(manifest.length);
 });
});

describe('release identity',()=>{
 test('a different release answering healthily fails',async()=>{
  const report=await run(release({sha:OTHER}));
  expect(report.ok).toBe(false);expect(report.failed).toEqual([expect.objectContaining({id:'release identity',outcome:'release_mismatch'})]);
  expect(report.failed[0].detail).toContain(OTHER);expect(report.failed[0].detail).toContain(SHA);
 });
 test('a release that reports no identity fails',async()=>{
  const report=await run(release({legacyHealth:true}));
  expect(report.ok).toBe(false);expect(report.failed[0]).toMatchObject({id:'release identity',outcome:'release_unreported'});
 });
 test('no expected SHA is an error, and skipping identity is explicit and visible',async()=>{
  expect((await run(release(),{expectSha:null})).failed[0]).toMatchObject({id:'release identity',outcome:'error'});
  const skipped=await run(release({legacyHealth:true}),{expectSha:null,skipIdentity:true});
  expect(skipped.ok).toBe(true);expect(formatReport(skipped)).toContain('SKIPPED');expect(formatReport(skipped)).toContain('identity skipped');
 });
 test('an unreachable service fails with the reason',async()=>{
  const report=await verifyRelease({base:'https://backend.example.invalid',fetchImpl:async()=>{throw new Error('connect ECONNREFUSED');},tokens:TOKENS,expectSha:SHA,today:TODAY});
  expect(report.ok).toBe(false);expect(report.results[0]).toMatchObject({id:'health',outcome:'error'});
 });
});

describe('role gates',()=>{
 test('an unauthorised role that gets through is an access leak, not a pass',async()=>{
  const report=await run(release({openTo:{'/api/support/queue':['citizen']}}));
  expect(report.ok).toBe(false);expect(report.failed).toEqual([expect.objectContaining({feature:'T06 staff support queue',role:'citizen',outcome:'access_leak'})]);
 });
 test('strict acceptance requires the real answer; lenient registration checks accept any non-missing answer',async()=>{
  const r=release();const original=r.fetchImpl;
  const degraded=async(url,options)=>{const u=new URL(url);if(u.pathname==='/api/sweeper/operations-summary'&&options?.headers?.Authorization==='Bearer token-officer')return {status:503,json:async()=>({code:'missing_prerequisite'})};return original(url,options);};
  const strict=await run({fetchImpl:degraded});
  expect(strict.ok).toBe(false);expect(strict.failed[0]).toMatchObject({feature:'T10 crew operations summary',outcome:'unexpected_status'});expect(strict.failed[0].detail).toContain('missing_prerequisite');
  expect((await run({fetchImpl:degraded},{strict:false})).ok).toBe(true);
 });
 test('probes never send an identity the verifier was not given and never use request bodies',async()=>{
  const r=release();await run(r);
  expect(r.calls.filter(c=>c.path!=='/health'&&c.auth).every(c=>/^Bearer token-(officer|admin|citizen|field_crew)$/.test(c.auth))).toBe(true);
  expect(manifest.every(p=>p.method==='GET')).toBe(true);
 });
});
