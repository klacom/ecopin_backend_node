// Development feature matrix: runs the release verifier against the isolated API (port 4102) with the synthetic role accounts.
// The isolated API runs from the working tree, not from a built artifact, so release identity is skipped here, and the local classifier is optional (both shown as skipped).
import {readFileSync} from 'node:fs';
import {verifyRelease,formatReport,ROLES} from './lib/release-verification.mjs';
const base=process.argv[2]||'http://127.0.0.1:4102',lenient=process.argv.includes('--lenient');
const fixtures=JSON.parse(readFileSync('.private/parity-fixtures.json','utf8'));
if(fixtures.url!=='http://127.0.0.1:54321'||!/^http:\/\/127\.0\.0\.1:/.test(base)){console.error('Only the isolated stack is permitted.');process.exit(2);}
const tokens={};
for(const role of ROLES){
 const user=fixtures.users.find(u=>u.role===role);
 const r=await fetch(base+'/api/auth/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email:user.email,password:fixtures.password})});
 const d=await r.json();tokens[role]=d.session?.access_token||d.access_token||d.token;
}
const report=await verifyRelease({base,tokens,skipIdentity:true,requireClassifier:false,strict:!lenient,requireEscalation:false});
console.log(formatReport(report));process.exit(report.ok?0:1);
