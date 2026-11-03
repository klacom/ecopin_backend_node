// T12 integrated check on the isolated stack: real backend + real web proxy + real database/storage. No production access.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
const backend='http://127.0.0.1:4102',web='https://localhost:4101',supa='http://127.0.0.1:54321';
process.env.NODE_TLS_REJECT_UNAUTHORIZED='0'; // local self-signed certificate of the isolated web server
const fixtures=JSON.parse(readFileSync('.private/parity-fixtures.json','utf8'));assert.equal(fixtures.url,supa);
const container='supabase_db_parity-recovery-backend';
const psql=q=>execFileSync('docker',['exec','-i',container,'psql','-X','-qAt','-U','postgres','-d','postgres','-c',q],{encoding:'utf8'}).trim();
const results=[];const check=(n,ok)=>{assert.ok(ok,n);results.push(n);console.log('PASS '+n);};
const ID='a1200000-0000-4000-8000-000000000001';
// Synthetic completed report whose "originals" point at storage objects that do not exist (storage trouble, not a missing report).
psql(`INSERT INTO public.reports(id,title,description,user_id,location,created_at,status,validation_status,lgu_resolved_at,before_photo_url,after_photo_url,before_photo_hash,after_photo_hash,before_photos,after_photos)
 SELECT '${ID}','T12_SYNTHETIC_MISSING_MEDIA','T12',u.id,extensions.ST_SetSRID(extensions.ST_Point(121.08,14.6),4326)::extensions.geography,'2026-11-01 00:00:00Z','resolved','approved','2026-11-02 00:00:00Z',
 'storage://Cleanup%20Originals/${ID}/before/b1200000-0000-4000-8000-000000000001.jpg','storage://Cleanup%20Originals/${ID}/after/c1200000-0000-4000-8000-000000000001.jpg','t12b','t12a',
 '[{"url":"storage://Cleanup%20Originals/${ID}/before/b1200000-0000-4000-8000-000000000001.jpg"}]'::jsonb,'[{"url":"storage://Cleanup%20Originals/${ID}/after/c1200000-0000-4000-8000-000000000001.jpg"}]'::jsonb
 FROM auth.users u WHERE u.email='citizen-a@parity.ecopin.invalid' ON CONFLICT(id) DO NOTHING`);
const login=async role=>{const u=fixtures.users.find(x=>x.role===role);const r=await fetch(backend+'/api/auth/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email:u.email,password:fixtures.password})});const d=await r.json();return d.session?.access_token||d.access_token||d.token;};
const bearer=t=>({headers:{Authorization:'Bearer '+t}});
const tok={officer:await login('officer'),citizen:await login('citizen')};
// Web session for the proxy.
const webLogin=async role=>{const u=fixtures.users.find(x=>x.role===role);const r=await fetch(web+'/api/session/login',{method:'POST',headers:{Origin:web,'Content-Type':'application/json'},body:JSON.stringify({email:u.email,password:fixtures.password})});assert.equal(r.status,200);return r.headers.get('set-cookie').split(';',1)[0];};
const officerCookie=await webLogin('officer');
try{
 // Missing route vs missing record, at the backend.
 let r=await fetch(`${backend}/api/does-not-exist`,bearer(tok.officer));let b=await r.json();
 check('an unknown backend route is a 404 with the route_not_found category',r.status===404&&b.code==='route_not_found');
 r=await fetch(`${backend}/api/support/queue/not-a-ticket/respond`,{method:'POST',...bearer(tok.officer),headers:{Authorization:'Bearer '+tok.officer,'Content-Type':'application/json'},body:'{}'});
 check('a real route with bad input is a 400, not a missing-route answer',r.status===400&&(await r.json()).code!=='route_not_found');
 // Denied access (web sessions are staff-only, so the citizen case is exercised at the backend).
 r=await fetch(`${web}/api/backend/api/reports/${ID}/cleanup-proof`,{headers:{Cookie:officerCookie}});
 check('an officer may read the proof source for the synthetic report (200)',r.status===200);
 r=await fetch(`${backend}/api/reports/${ID}/cleanup-proof`,bearer(tok.citizen));
 check('a citizen reading the staff proof path is refused with a 403 at the backend (the proxy labels any 403 as denied; web sessions are staff-only)',r.status===403);
 // Unavailable storage through the real proxy.
 r=await fetch(`${web}/api/backend/api/reports/${ID}/cleanup-proof/original/before`,{headers:{Cookie:officerCookie}});b=await r.json();
 check('a missing stored original is labelled storage_unavailable and retryable, not shown as a missing report',r.status===404&&b.code==='storage_unavailable'&&b.retryable===true);
 r=await fetch(`${web}/api/backend/api/reports/a1200000-0000-4000-8000-0000000000ff/cleanup-proof/original/before`,{headers:{Cookie:officerCookie}});b=await r.json();
 check('an unknown report stays a plain not-found without a storage label',r.status===404&&b.code===undefined);
 r=await fetch(`${backend}/api/reports/${ID}/cleanup-proof/original/before`,bearer(tok.officer));
 check('the backend answers a failed original with JSON, not an image content type',r.status===404&&r.headers.get('content-type').startsWith('application/json'));
 // Controlled success and bounded reads on the real endpoints that now use the shared budget.
 const t0=Date.now();
 for(const path of ['/api/sweeper/operations-summary?from=2026-11-02&through=2026-11-02','/api/analytics/barangay/executive?month=2026-10','/api/reports/unprocessed-alerts?limit=5','/api/analytics/barangay?startMonth=2026-08&endMonth=2026-10']){
  const res=await fetch(web+'/api/backend'+path,{headers:{Cookie:officerCookie}});
  check(`${path.split('?')[0]} answers through the proxy within the budget (status ${res.status})`,[200,503].includes(res.status)&&(res.status===200||['missing_prerequisite','unavailable'].includes((await res.json()).code)));
 }
 check('the four reads together finish far inside the 10 second proxy deadline',Date.now()-t0<10000);
 // Signed-out and cancelled requests.
 r=await fetch(`${web}/api/backend/api/sweeper/operations-summary`);check('signed-out proxy request is a 401',r.status===401);
 const controller=new AbortController();const pending=fetch(`${web}/api/backend/api/sweeper/operations-summary?from=2026-11-02`,{headers:{Cookie:officerCookie},signal:controller.signal});controller.abort();
 await assert.rejects(pending,{name:'AbortError'});check('a cancelled browser request ends cleanly and the proxy keeps serving',(await fetch(`${web}/api/backend/api/sweeper/operations-summary?from=2026-11-02`,{headers:{Cookie:officerCookie}})).status===200);
}finally{
 psql(`DELETE FROM public.field_assignment_receipts WHERE report_id='${ID}'; DELETE FROM public.reports WHERE id='${ID}'`);
}
check('the synthetic report was removed',psql(`select count(*) from public.reports where id='${ID}'`)==='0');
console.log(`ALL ${results.length} CHECKS PASSED`);process.exit(0);
