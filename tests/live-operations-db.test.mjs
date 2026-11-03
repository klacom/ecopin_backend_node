import {beforeAll as before,afterAll as after,test} from '@jest/globals';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';
const db=new PGlite(),desk='00000000-0000-0000-0000-000000000001',crew='00000000-0000-0000-0000-000000000002',task='10000000-0000-0000-0000-000000000001';
before(async()=>{
 await db.exec(`CREATE ROLE anon;CREATE ROLE authenticated;CREATE ROLE service_role BYPASSRLS;
 CREATE TABLE profiles(id uuid PRIMARY KEY,role text,suspended_until timestamptz,full_name text);
 CREATE TABLE cleanup_tasks(id uuid PRIMARY KEY,status text,assignment_generation bigint DEFAULT 0);
 CREATE TABLE field_crews(id uuid PRIMARY KEY,name text,member_profile_ids uuid[],team_lead_profile_id uuid);
 INSERT INTO profiles VALUES('${desk}','officer',NULL,'Desk private name'),('${crew}','field_crew',NULL,'SECRET_REPORTER_NAME');
 INSERT INTO field_crews VALUES('20000000-0000-0000-0000-000000000001','Crew 1',ARRAY['${crew}'::uuid],'${crew}');
 GRANT SELECT ON ALL TABLES IN SCHEMA public TO service_role;`);
 const journal=await readFile(new URL('../migrations/20261029150000_operational_event_journal.sql',import.meta.url),'utf8');
 await db.exec(journal.slice(journal.indexOf('CREATE SCHEMA'),journal.indexOf('-- These input-only')));
 await db.exec(journal.match(/CREATE FUNCTION operational_private\.emit\([\s\S]+?\$\$;/)[0]);
 await db.exec(await readFile(new URL('../migrations/20261030040000_live_operations_feed.sql',import.meta.url),'utf8'));
});
after(()=>db.close());
const read=async(id=desk,before=null)=>(await db.query('SELECT read_live_operations($1,$2,2) r',[id,before])).rows[0].r;
const beat=async(id=crew)=>(await db.query('SELECT touch_crew_presence($1) r',[id])).rows[0].r;
async function denied(fn,pattern){await db.exec('SAVEPOINT denied');try{await assert.rejects(fn,pattern);}finally{await db.exec('ROLLBACK TO SAVEPOINT denied');}}
test('task transitions enter the append-only journal once per real status change',async()=>{
 await db.exec('BEGIN');try{
 await db.query("SELECT set_config('ecopin.operational_actor',$1,true)",[crew]);
 await db.query("INSERT INTO cleanup_tasks(id,status) VALUES($1,'pending')",[task]);
 await db.exec("UPDATE cleanup_tasks SET status='en_route';UPDATE cleanup_tasks SET status='in_progress';UPDATE cleanup_tasks SET status='in_progress'");
 const q=await read();assert.equal(q.events.length,2);assert.equal(q.has_more,true);assert.ok(q.next_cursor);
 assert.equal(q.events[0].details.to_status,'in_progress');assert.equal(q.events[0].details.from_status,'en_route');
 assert.equal((await read(desk,q.next_cursor)).events.length,1);
 assert.equal((await db.query('SELECT count(*)::int n FROM operational_events')).rows[0].n,3);
 assert.ok(!JSON.stringify(q).includes(crew));assert.ok(!JSON.stringify(q).includes('SECRET_REPORTER_NAME'));
 await denied(()=>db.exec("UPDATE operational_events SET details='{}'"),/append-only/);
 }finally{await db.exec('ROLLBACK');}
});
test('server-time heartbeats distinguish unknown, recently connected and no recent contact',async()=>{
 await db.exec('BEGIN');try{
 let q=await read();assert.equal(q.crews[0].unknown_members,1);assert.equal(q.crews[0].member_count,1);
 await beat();q=await read();assert.equal(q.crews[0].recent_members,1);assert.equal(q.crews[0].unknown_members,0);assert.ok(q.crews[0].last_seen_at);
 await db.exec("UPDATE operational_private.crew_presence SET last_seen_at=statement_timestamp()-interval '91 seconds'");
 q=await read();assert.equal(q.crews[0].quiet_members,1);assert.equal(q.crews[0].recent_members,0);
 await beat();assert.equal((await read()).crews[0].recent_members,1);
 }finally{await db.exec('ROLLBACK');}
});
test('crew presence cannot be forged by desk roles, citizens, suspended accounts or direct public access',async()=>{
 await db.exec('BEGIN');try{
 await denied(()=>beat(desk),/crew/i);await denied(()=>read(crew),/staff/i);
 await db.exec("UPDATE profiles SET suspended_until=statement_timestamp()+interval '1 day' WHERE role='field_crew'");await denied(()=>beat(),/crew/i);
 for(const role of ['anon','authenticated']){await db.exec('SET ROLE '+role);try{await denied(()=>read(),/permission/);await denied(()=>beat(),/permission/);}finally{await db.exec('RESET ROLE');}}
 await db.exec('SET ROLE service_role');try{assert.equal((await read()).version,'live-operations-v1');}finally{await db.exec('RESET ROLE');}
 }finally{await db.exec('ROLLBACK');}
});
test('empty teams and unrostered staff stay explicit; bigint event cursors retain precision',async()=>{
 await db.exec('BEGIN');try{
 await db.exec("INSERT INTO field_crews VALUES('20000000-0000-0000-0000-000000000002','Crew 2','{}',NULL)");
 const q=await read();assert.equal(q.crews.find(c=>c.name==='Crew 2').member_count,0);
 await db.exec("ALTER SEQUENCE operational_events_id_seq RESTART WITH 9007199254740993");
 await db.query("INSERT INTO cleanup_tasks(id,status) VALUES($1,'pending')",[task]);
 const next=await read();assert.equal(next.events[0].event_id,'9007199254740993');
 assert.equal(next.latest_event_id,'9007199254740993');
 }finally{await db.exec('ROLLBACK');}
});

test('team overlaps do not inflate the overall headcount and rosterless members remain visible',async()=>{
 await db.exec('BEGIN');try{
 await db.query("INSERT INTO field_crews VALUES('20000000-0000-0000-0000-000000000003','Shared crew',ARRAY[$1::uuid],$1)",[crew]);
 await db.exec("INSERT INTO profiles VALUES('00000000-0000-0000-0000-000000000003','field_crew',NULL,'Another private name')");
 const q=await read();assert.equal(q.crew_count,2);assert.equal(q.unknown_members,2);
 assert.equal(q.crews.find(g=>g.name==='Other field crew').member_count,1);
 assert.ok(!JSON.stringify(q).includes('Another private name'));
 }finally{await db.exec('ROLLBACK');}
});
