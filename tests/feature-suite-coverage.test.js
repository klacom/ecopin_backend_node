import {readdirSync,existsSync,readFileSync} from 'node:fs';

// `npm test` runs every jest suite under tests/ by default. This guard keeps the release gate from silently losing a feature suite
// (a deleted, renamed or emptied file would otherwise just shrink the run) and keeps the database scripts from being mistaken for gate coverage.
const dir=new URL('../tests/',import.meta.url);
const required={
 'T04 executive/analytics':['barangay-executive.test.js','barangay-analytics-api.test.js'],
 'T05 operational history and live feed':['operational-events.test.js','live-operations.test.js','live-operations-db.test.mjs'],
 'T06 support':['support-tickets.test.js','support-tickets-db.test.mjs'],
 'T07 directions':['routing-directions.test.js'],
 'T08 case record':['incident-case-record.test.js'],
 'T09 cleanup proof':['cleanup-proof.test.js'],
 'T10 crew summary':['field-crew-operations.test.js'],
 'T11 escalation':['unprocessed-escalation-job.test.js','escalation-startup-wiring.test.js','unprocessed-alerts.test.js'],
 'T12 budgets and diagnostics':['request-budget.test.js'],
 'T14 release verification':['release-identity.test.js','release-verification.test.js'],
 'T13 classifier':['classifier-health.test.js','classifier-recovery.test.js'],
 'T02 isolation':['development-isolation.test.js'],
};
test.each(Object.entries(required).flatMap(([feature,files])=>files.map(file=>[feature,file])))('%s: tests/%s exists and contains tests',(feature,file)=>{
 // A suite name that no longer exists is reported by name so the gap is visible.
 if(!existsSync(new URL(file,dir))){
  const alternatives=readdirSync(dir).filter(f=>f.includes(file.split('.')[0].split('-')[0]));
  throw new Error(`Missing suite ${file} for ${feature}. Similar files: ${alternatives.join(', ')||'none'}`);
 }
 expect(readFileSync(new URL(file,dir),'utf8')).toMatch(/\b(test|it)(\.each\([\s\S]*?\))?\(/);
});
test('the package test command runs jest over the whole tests directory',()=>{
 const pkg=JSON.parse(readFileSync(new URL('../package.json',import.meta.url),'utf8'));
 expect(pkg.scripts.test).toMatch(/jest\.js\s*$/);
 expect(pkg.scripts.test).not.toMatch(/runTestsByPath|--testPathPattern|--testNamePattern/);
});
