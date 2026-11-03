// T14b negative proofs against the REAL application on the isolated stack: the verifier must pass a complete release and must fail when
// a feature route is genuinely unregistered, when the running release reports no identity, and when it reports a different one.
//   node scripts/verify-release-negative-isolated.mjs            runs every case (parent)
//   node scripts/verify-release-negative-isolated.mjs --child <case>   one real app instance on port 4204 (used by the parent)
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,rmSync,existsSync} from 'node:fs';
import {execFileSync,spawnSync} from 'node:child_process';
import {verifyRelease,formatReport,ROLES} from './lib/release-verification.mjs';
const fixtures=JSON.parse(readFileSync('.private/parity-fixtures.json','utf8'));
assert.equal(fixtures.url,'http://127.0.0.1:54321','Only the isolated stack is permitted.');
const SHA=execFileSync('git',['rev-parse','HEAD'],{encoding:'utf8'}).trim(),OTHER='75f056735be0c8d07e73d114eb8f59601d1311fc';
const base='http://127.0.0.1:4204';

if(process.argv[2]==='--child'){
 const which=process.argv[3];
 const {default:app}=await import('../src/app.js');
 const stack=(app.router??app._router).stack;
 // Genuinely unregister the router that serves a probe path: the layers whose matcher accepts it are removed from the running application.
 const unregister=path=>{for(let i=stack.length-1;i>=0;i--){const l=stack[i];if(l.name==='router'&&l.matchers?.some(m=>m(path)))stack.splice(i,1);}};
 if(which==='omit-support')unregister('/api/support/queue');
 if(which==='omit-sweeper')unregister('/api/sweeper/operations-summary');
 const server=app.listen(4204,'127.0.0.1');await new Promise(r=>server.once('listening',r));
 const tokens={};
 for(const role of ROLES){const user=fixtures.users.find(u=>u.role===role);
  // Sessions come from the real isolated authority (4102): the instance under test shares the same database and JWT settings.
  const r=await fetch('http://127.0.0.1:4102/api/auth/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email:user.email,password:fixtures.password})});
  const d=await r.json();tokens[role]=d.session?.access_token||d.access_token||d.token;}
 const report=await verifyRelease({base,tokens,expectSha:SHA,requireClassifier:false});
 console.log('REPORT '+JSON.stringify({ok:report.ok,failed:report.failed.map(({id,feature,role,outcome,detail})=>({id,feature,role,outcome,detail})),text:formatReport(report)}));
 server.close();process.exit(0);
}

const results=[];const check=(n,ok)=>{assert.ok(ok,n);results.push(n);console.log('PASS '+n);};
const writeRelease=sha=>sha===null?rmSync('RELEASE',{force:true}):writeFileSync('RELEASE',sha+'\n');
function runCase(name,releaseFile){
 writeRelease(releaseFile);
 try{
  const r=spawnSync(process.execPath,['scripts/verify-release-negative-isolated.mjs','--child',name],{encoding:'utf8',timeout:120000});
  const line=(r.stdout||'').split('\n').find(l=>l.startsWith('REPORT '));
  assert.ok(line,`no report from ${name}: ${(r.stderr||'').slice(-300)}`);return JSON.parse(line.slice(7));
 }finally{writeRelease(null);}
}
assert.ok(!existsSync('RELEASE'),'Refusing to overwrite an existing RELEASE file');
try{
 const good=runCase('complete',SHA);
 check('a complete release (identity file present, every route registered) passes the real-app verification',good.ok&&good.failed.length===0);
 const support=runCase('omit-support',SHA);
 check('with the support router genuinely unregistered, verification FAILS on T06 with missing_route',!support.ok&&support.failed.length>0&&support.failed.every(f=>f.outcome==='missing_route'&&f.feature.startsWith('T06')));
 check('the failure lists exactly the four T06 support probes (two authorised, two role-gate) and nothing else',support.failed.some(f=>f.feature==='T06 staff support queue')&&support.failed.length===4);
 const sweeper=runCase('omit-sweeper',SHA);
 check('with the crew summary router unregistered, verification FAILS on T10 with missing_route',!sweeper.ok&&sweeper.failed.length>0&&sweeper.failed.every(f=>f.outcome==='missing_route'&&f.feature.startsWith('T10')));
 const noId=runCase('no-release',null);
 check('a release that reports no identity FAILS even though health is green and every route works',!noId.ok&&noId.failed.length===1&&noId.failed[0].outcome==='release_unreported');
 const wrong=runCase('wrong-release',OTHER);
 check('a different release answering FAILS with a mismatch naming both SHAs',!wrong.ok&&wrong.failed.length===1&&wrong.failed[0].outcome==='release_mismatch'&&wrong.failed[0].detail.includes(OTHER)&&wrong.failed[0].detail.includes(SHA));
 console.log('\n'+support.text.split('\n').slice(0,4).join('\n'));
}finally{writeRelease(null);}
check('the temporary RELEASE file was removed',!existsSync('RELEASE'));
console.log(`ALL ${results.length} CHECKS PASSED`);process.exit(0);
