// Release verification CLI.
//   node scripts/verify-release.mjs --base http://127.0.0.1:3002 --expect-sha <40-hex> [--lenient] [--require-escalation] [--json]
// Role sessions come from the environment, never argv: VERIFY_TOKEN_OFFICER, VERIFY_TOKEN_ADMIN, VERIFY_TOKEN_CITIZEN, VERIFY_TOKEN_FIELD_CREW.
// A missing token fails that feature instead of skipping it. --skip-identity exists for development stacks without a built artifact and is reported as skipped.
import {verifyRelease,formatReport,ROLES} from './lib/release-verification.mjs';
const args=process.argv.slice(2),flag=n=>args.includes(n),value=n=>{const i=args.indexOf(n);return i>=0?args[i+1]:null;};
const base=value('--base'),expectSha=value('--expect-sha');
if(!base){console.error('--base is required');process.exit(2);}
if(expectSha&&!/^[0-9a-f]{40}$/.test(expectSha)){console.error('--expect-sha must be a 40-character lowercase commit SHA');process.exit(2);}
const tokens=Object.fromEntries(ROLES.map(role=>[role,process.env[`VERIFY_TOKEN_${role.toUpperCase()}`]]).filter(([,t])=>t));
const report=await verifyRelease({base,tokens,expectSha,skipIdentity:flag('--skip-identity'),requireClassifier:!flag('--classifier-optional'),strict:!flag('--lenient'),requireEscalation:flag('--require-escalation')});
console.log(flag('--json')?JSON.stringify({ok:report.ok,total:report.total,passed:report.passed,failed:report.failed.map(({id,feature,role,outcome,detail})=>({id,feature,role,outcome,detail}))},null,1):formatReport(report));
process.exit(report.ok?0:1);
