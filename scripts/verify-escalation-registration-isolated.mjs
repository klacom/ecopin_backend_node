// T11: real cron registration, health observability and shutdown against the isolated database only (port 4202).
// The isolation guard in supabase.config.js refuses a non-isolated project; notices created by the real run are removed by timestamp.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
const container='supabase_db_parity-recovery-backend';
assert.equal(JSON.parse(execFileSync('docker',['inspect',container],{encoding:'utf8'}))[0].Config.Labels['com.supabase.cli.project'],'parity-recovery-backend');
const psql=q=>execFileSync('docker',['exec','-i',container,'psql','-X','-qAt','-U','postgres','-d','postgres','-c',q],{encoding:'utf8'}).trim();
const results=[];const check=(n,ok)=>{assert.ok(ok,n);results.push(n);console.log('PASS '+n);};
assert.equal(process.env.SUPABASE_URL||'http://127.0.0.1:54321','http://127.0.0.1:54321');
const start=psql('select clock_timestamp()');
const {default:app}=await import('../src/app.js');
const {startUnprocessedSchedule,stopUnprocessedSchedule,getUnprocessedScheduleStatus}=await import('../src/jobs/unprocessed-escalation.js');
const server=app.listen(4202,'127.0.0.1');await new Promise(r=>server.once('listening',r));
const health=async()=>(await (await fetch('http://127.0.0.1:4202/health')).json());
try{
 let h=await health();
 check('before registration health reports the job as not registered and stays non-degraded because of it',h.jobs.unprocessed_escalation.enabled===false&&h.jobs.unprocessed_escalation.registered_at===null&&h.jobs.unprocessed_escalation.last_run_at===null);
 startUnprocessedSchedule({env:{UNPROCESSED_ESCALATION_ENABLED:'true',UNPROCESSED_ESCALATION_CRON:'* * * * *'}});
 h=await health();const j0=h.jobs.unprocessed_escalation;
 check('registration is immediately visible with a registration time and no run yet',j0.enabled===true&&Date.parse(j0.registered_at)>0&&j0.last_run_at===null&&j0.consecutive_failures===0);
 const deadline=Date.now()+90000;let j;
 while(Date.now()<deadline){j=(await health()).jobs.unprocessed_escalation;if(j.last_run_at)break;await new Promise(r=>setTimeout(r,2000));}
 check('the real scheduler ran against the database and recorded a successful run with counts and duration',j.last_outcome==='ok'&&Number.isSafeInteger(j.last_reports_checked)&&Number.isSafeInteger(j.last_notifications_created)&&j.last_duration_ms>=0&&j.consecutive_failures===0);
 check('the published status exposes no configuration values',!JSON.stringify(j).includes('* * * * *')&&!JSON.stringify(h).toLowerCase().includes('secret'));
 stopUnprocessedSchedule();
 h=await health();
 check('after shutdown health reports the job stopped and cleared',h.jobs.unprocessed_escalation.enabled===false&&h.jobs.unprocessed_escalation.last_run_at===null);
 const runAfter=getUnprocessedScheduleStatus();await new Promise(r=>setTimeout(r,65000));
 check('a stopped schedule does not run again',getUnprocessedScheduleStatus().last_run_at===runAfter.last_run_at&&getUnprocessedScheduleStatus().last_run_at===null);
}finally{
 stopUnprocessedSchedule();server.close();
 psql(`DELETE FROM public.notifications WHERE created_at>='${start}' AND title IN ('5-day incident escalation','Unprocessed incident reminder'); DELETE FROM workflow_private.unprocessed_alert_deliveries WHERE delivered_at>='${start}'`);
}
check('notices created by this isolated run were removed',psql(`select (select count(*) from public.notifications where created_at>='${start}' and title in ('5-day incident escalation','Unprocessed incident reminder'))+(select count(*) from workflow_private.unprocessed_alert_deliveries where delivered_at>='${start}')`)==='0');
console.log(`ALL ${results.length} CHECKS PASSED`);process.exit(0);
