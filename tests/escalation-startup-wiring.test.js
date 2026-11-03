import {readFileSync} from 'node:fs';
const read=file=>readFileSync(new URL(file,import.meta.url),'utf8').replace(/\r\n/g,'\n');
const index=read('../src/index.js'),app=read('../src/app.js');

test('the entry point registers the escalation schedule once at startup',()=>{
 expect(index).toMatch(/import \{startUnprocessedSchedule,stopUnprocessedSchedule\} from '\.\/jobs\/unprocessed-escalation\.js'/);
 expect(index.match(/startUnprocessedSchedule\(\)/g)).toHaveLength(1);
});
test('both termination signals stop the schedule before closing the server',()=>{
 for(const signal of ['SIGTERM','SIGINT']){
  const body=index.slice(index.indexOf(`process.on('${signal}'`));
  const block=body.slice(0,body.indexOf('server.close'));
  expect(block).toContain('stopUnprocessedSchedule()');
 }
});
test('the health endpoint publishes the job state without making it a health dependency',()=>{
 expect(app).toContain("import { getUnprocessedScheduleStatus } from './jobs/unprocessed-escalation.js'");
 expect(app).toMatch(/jobs: \{\s*unprocessed_escalation: getUnprocessedScheduleStatus\(\)\s*\}/);
});
test('the schedule is only registered when explicitly enabled, and the production guard is on the shared client',()=>{
 const job=read('../src/jobs/unprocessed-escalation.js'),client=read('../src/config/supabase.config.js');
 expect(job).toContain("env.UNPROCESSED_ESCALATION_ENABLED!=='true'");
 expect(client).toContain('assertSupabaseIsolation(NEXT_PUBLIC_SUPABASE_URL)');
 expect(job).toContain("from '../config/supabase.config.js'");
});
