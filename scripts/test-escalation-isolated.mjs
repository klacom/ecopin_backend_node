// T11: real escalate_unprocessed_reports() behaviour on the isolated local database only.
// Eligible, ineligible, retry-after-failure, repeat-run and competing-run cases. Fixture rows use reserved a1100000-* IDs and are removed at the end;
// notifications/ledger rows created by this script are deleted by timestamp. Nothing here can reach production: the container and project are checked first.
import assert from 'node:assert/strict';
import {execFileSync,spawn} from 'node:child_process';
const container='supabase_db_parity-recovery-backend';
const info=JSON.parse(execFileSync('docker',['inspect',container],{encoding:'utf8'}))[0];
assert.equal(info.Config.Labels['com.supabase.cli.project'],'parity-recovery-backend','Only the isolated parity database is permitted.');
const run=(sql,input)=>execFileSync('docker',['exec','-i',container,'psql','-X','-qAt','-v','ON_ERROR_STOP=1','-U','postgres','-d','postgres',...(input?[]:['-c',sql])],{encoding:'utf8',input}).trim();
const results=[];const check=(name,ok)=>{assert.ok(ok,name);results.push(name);console.log('PASS '+name);};
const R=n=>`a1100000-0000-4000-8000-0000000000${String(n).padStart(2,'0')}`;
const reports={E_UNACK:R(1),E_UNASSIGNED:R(2),I_YOUNG:R(3),I_RESOLVED:R(4),I_HANDLED:R(5),I_BEFORE_BASELINE:R(6),I_REJECTED:R(7),E_NEXT_DAY:R(8)};
const SUSPENDED='a1100000-0000-4000-8000-0000000000f1',TASK=R(90);
const days=(n,extra="")=>`now() - interval '${n} days' ${extra}`;
const start=run("select clock_timestamp()");
function cleanup(){
 run(`DELETE FROM public.notifications WHERE created_at>='${start}' AND title IN ('5-day incident escalation','Unprocessed incident reminder');
  DELETE FROM workflow_private.unprocessed_alert_deliveries WHERE delivered_at>='${start}';
  DELETE FROM public.field_assignment_receipts WHERE report_id::text LIKE 'a1100000-%' OR task_id='${TASK}';
  DELETE FROM public.reports WHERE id::text LIKE 'a1100000-%';
  DELETE FROM public.cleanup_tasks WHERE id='${TASK}';
  DELETE FROM public.profiles WHERE id='${SUSPENDED}';
  DELETE FROM auth.users WHERE id='${SUSPENDED}';`);
}
cleanup();
try{
 run(`INSERT INTO auth.users(id,instance_id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
   VALUES('${SUSPENDED}','00000000-0000-0000-0000-000000000000','authenticated','authenticated','t11-suspended@parity.ecopin.invalid','{"fixture":"ecopin-parity-local"}','{}',now(),now());
  UPDATE public.profiles SET role='officer',suspended_until=now()+interval '1 day' WHERE id='${SUSPENDED}';`);
 const staff=run("select count(*) from public.profiles where role::text in ('officer','admin') and (suspended_until is null or suspended_until<=statement_timestamp())");
 assert.ok(Number(staff)>=2);
 check('a suspended officer exists as a non-recipient and active staff recipients exist',run(`select suspended_until>now() from public.profiles where id='${SUSPENDED}'`)==='t');
 // Synthetic task with an assigned crew for the "already handled" report.
 run(`INSERT INTO public.cleanup_tasks(id,title,description,status,assigned_crew_ids,created_by,operational_actor_id)
  SELECT '${TASK}','T11_SYNTHETIC_TASK','T11','pending',ARRAY[c.id],o.id,o.id FROM auth.users o CROSS JOIN auth.users c
  WHERE o.email='officer@parity.ecopin.invalid' AND c.email='crew@parity.ecopin.invalid'`);
 const insert=(id,age,status,validation,extra={})=>`INSERT INTO public.reports(id,title,description,user_id,location,created_at,status,validation_status${extra.cols||''})
  SELECT '${id}','T11_SYNTHETIC_${id.slice(-2)}','T11 synthetic',u.id,extensions.ST_SetSRID(extensions.ST_Point(121.08,14.60),4326)::extensions.geography,${age},'${status}','${validation}'${extra.vals||''}
  FROM auth.users u WHERE u.email='citizen-a@parity.ecopin.invalid';`;
 run([
  insert(reports.E_UNACK,days(6),'unresolved','approved'),
  insert(reports.E_UNASSIGNED,days(6),'in_progress','approved'),               // acknowledged, but nobody assigned
  insert(reports.I_YOUNG,days(3),'unresolved','approved'),                    // not yet five days
  insert(reports.I_RESOLVED,days(6),'resolved','approved'),
  insert(reports.I_HANDLED,days(6),'in_progress','approved',{cols:',cleanup_task_id',vals:`,'${TASK}'`}),
  insert(reports.I_BEFORE_BASELINE,`timestamptz '2026-08-15 00:00:00Z'`,'unresolved','approved'), // submitted before the go-live baseline
  insert(reports.I_REJECTED,days(6),'unresolved','rejected'),
  insert(reports.E_NEXT_DAY,days(6),'unresolved','approved'),
 ].join('\n'));
 const recipients=Number(staff);
 const baselineEligible=['E_UNACK','E_UNASSIGNED','E_NEXT_DAY'].map(k=>reports[k]);
 const asService=sql=>`BEGIN;SET LOCAL ROLE service_role;${sql};ROLLBACK;`;
 const notifFor=(ids)=>`select count(*) from public.notifications where created_at>='${start}' and report_id in (${ids.map(i=>`'${i}'`).join(',')})`;
 const t11=Object.values(reports);
 // 1. Eligible vs ineligible in a rolled-back run.
 const first=run(null,asService(`SELECT 'RESULT '||public.escalate_unprocessed_reports()::text;
  SELECT 'ELIGIBLE '||count(*) FROM workflow_private.unprocessed_alert_deliveries WHERE report_id IN (${baselineEligible.map(i=>`'${i}'`).join(',')});
  SELECT 'INELIGIBLE '||count(*) FROM workflow_private.unprocessed_alert_deliveries WHERE report_id IN (${t11.filter(i=>!baselineEligible.includes(i)).map(i=>`'${i}'`).join(',')});
  SELECT 'SUSPENDED '||count(*) FROM workflow_private.unprocessed_alert_deliveries WHERE recipient_id='${SUSPENDED}';
  SELECT 'TITLES '||string_agg(DISTINCT n.title,'|') FROM public.notifications n WHERE n.report_id IN (${baselineEligible.map(i=>`'${i}'`).join(',')}) AND n.created_at>='${start}';
  SELECT 'BODY '||n.body FROM public.notifications n WHERE n.report_id='${reports.E_UNASSIGNED}' AND n.created_at>='${start}' LIMIT 1;
  SELECT 'REPORTERLEAK '||count(*) FROM public.notifications n WHERE n.report_id IN (${baselineEligible.map(i=>`'${i}'`).join(',')}) AND n.created_at>='${start}' AND (n.body ILIKE '%T11_SYNTHETIC%' OR n.body ILIKE '%citizen-a%');`));
 const line=k=>(first.split('\n').find(l=>l.startsWith(k+' '))||'').slice(k.length+1);
 check('eligible reports (unacknowledged, or acknowledged but unassigned) are notified once per active staff recipient',Number(line('ELIGIBLE'))===3*recipients);
 check('ineligible reports (under five days, resolved, already handled, before the baseline, rejected) get nothing',Number(line('INELIGIBLE'))===0);
 check('suspended staff are not recipients',Number(line('SUSPENDED'))===0);
 check('the first notice is the 5-day escalation and the body names what is missing without reporter data',line('TITLES')==='5-day incident escalation'&&/acknowledgement|crew assignment/.test(line('BODY'))&&Number(line('REPORTERLEAK'))===0);
 check('the run result reports the checked reports and notifications created',JSON.parse(line('RESULT')).notifications_created>=3*recipients&&JSON.parse(line('RESULT')).reports_checked>=3);
 // 2. Repeating the run in the same age band creates nothing new.
 const repeat=run(null,asService(`SELECT 'A '||(public.escalate_unprocessed_reports()->>'notifications_created');SELECT 'B '||(public.escalate_unprocessed_reports()->>'notifications_created');SELECT 'C '||count(*) FROM public.notifications WHERE report_id IN (${baselineEligible.map(i=>`'${i}'`).join(',')}) AND created_at>='${start}'`));
 const rl=k=>Number((repeat.split('\n').find(l=>l.startsWith(k+' '))||'').slice(2));
 check('an immediate second run is idempotent (zero new notifications, no duplicates)',rl('B')===0&&rl('C')===3*recipients&&rl('A')>=3*recipients);
 // 3. Retry after a failure: a failing notification insert leaves no ledger claim, and the next run delivers.
 const retry=run(null,`BEGIN;SET LOCAL ROLE postgres;
  CREATE FUNCTION pg_temp.fail_notice() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'synthetic notification failure'; END $$;
  SAVEPOINT broken;
  CREATE TRIGGER t11_fail BEFORE INSERT ON public.notifications FOR EACH ROW EXECUTE FUNCTION pg_temp.fail_notice();
  DO $$ BEGIN PERFORM public.escalate_unprocessed_reports(); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'failed as expected'; END $$;
  ROLLBACK TO SAVEPOINT broken;
  SELECT 'CLAIMS_AFTER_FAILURE '||count(*) FROM workflow_private.unprocessed_alert_deliveries WHERE report_id IN (${baselineEligible.map(i=>`'${i}'`).join(',')});
  SELECT 'RETRY '||(public.escalate_unprocessed_reports()->>'notifications_created');
  SELECT 'AFTER_RETRY '||count(*) FROM public.notifications WHERE report_id IN (${baselineEligible.map(i=>`'${i}'`).join(',')}) AND created_at>='${start}';
  ROLLBACK;`);
 const ry=k=>Number((retry.split('\n').find(l=>l.startsWith(k+' '))||'').slice(k.length+1));
 check('a failed run leaves no delivery claim and the retry delivers every notice exactly once',ry('CLAIMS_AFTER_FAILURE')===0&&ry('RETRY')>=3*recipients&&ry('AFTER_RETRY')===3*recipients);
 // 4. Competing workers: two sessions at once, committed, must not duplicate.
 const session=(sql)=>new Promise((resolve,reject)=>{const p=spawn('docker',['exec','-i',container,'psql','-X','-qAt','-v','ON_ERROR_STOP=1','-U','postgres','-d','postgres']);let out='',err='';
  p.stdout.on('data',d=>out+=d);p.stderr.on('data',d=>err+=d);p.on('close',c=>c===0?resolve(out.trim()):reject(new Error(err||'session failed')));p.stdin.end(sql);});
 const a=session(`BEGIN;SET LOCAL ROLE service_role;SELECT 'RES '||(public.escalate_unprocessed_reports()->>'notifications_created');SELECT pg_sleep(4);COMMIT;`);
 await new Promise(r=>setTimeout(r,1500));
 const b=session(`BEGIN;SET LOCAL ROLE service_role;SELECT 'RES '||(public.escalate_unprocessed_reports()->>'notifications_created');COMMIT;`);
 const [ra,rb]=await Promise.all([a,b]);const na=Number(ra.split(' ')[1]),nb=Number(rb.split(' ')[1]);
 const total=Number(run(notifFor(baselineEligible)));
 check('two workers running at once create each notice once (the second skips locked reports)',nb===0&&na>=3*recipients&&total===3*recipients);
 const third=Number(run(null,asService(`SELECT public.escalate_unprocessed_reports()->>'notifications_created'`)).split('\n').pop());
 check('a later run after the competing runs creates nothing',third===0&&Number(run(notifFor(baselineEligible)))===3*recipients);
 check('the delivery ledger holds one claim per report, recipient and age day',run(`select count(*)-count(distinct (report_id,recipient_id,age_day)) from workflow_private.unprocessed_alert_deliveries where report_id in (${baselineEligible.map(i=>`'${i}'`).join(',')})`)==='0');
 // 5. A new age day produces a reminder, not another first escalation.
 run(`UPDATE public.reports SET created_at=created_at-interval '1 day' WHERE id='${reports.E_NEXT_DAY}'`);
 const nextDay=run(null,asService(`SELECT public.escalate_unprocessed_reports();SELECT 'R '||count(*) FROM public.notifications WHERE report_id='${reports.E_NEXT_DAY}' AND created_at>='${start}' AND title='Unprocessed incident reminder';SELECT 'F '||count(*) FROM public.notifications WHERE report_id='${reports.E_NEXT_DAY}' AND created_at>='${start}' AND title='5-day incident escalation'`));
 const nd=k=>Number((nextDay.split(/\r?\n/).find(l=>l.startsWith(k+' '))||'').slice(2));
 check('the next elapsed day sends one reminder per recipient, in addition to the earlier first escalation',nd('R')===recipients&&nd('F')===recipients);
 // 6. Access: the function is not callable by the public roles.
 let denied=0;for(const role of ['anon','authenticated']){try{run(null,`BEGIN;SET LOCAL ROLE ${role};SELECT public.escalate_unprocessed_reports();ROLLBACK;`);}catch{denied++;}}
 check('anonymous and authenticated roles cannot trigger an escalation',denied===2);
}finally{cleanup();}
check('fixture reports, synthetic task/user, notices and ledger rows were removed',run("select (select count(*) from public.reports where id::text like 'a1100000-%')+(select count(*) from auth.users where id='"+SUSPENDED+"')+(select count(*) from public.notifications where created_at>='"+start+"' and title in ('5-day incident escalation','Unprocessed incident reminder'))+(select count(*) from workflow_private.unprocessed_alert_deliveries where delivered_at>='"+start+"')")==='0');
console.log(`ALL ${results.length} CHECKS PASSED`);
