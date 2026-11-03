import {beforeAll as before,afterAll as after,test} from '@jest/globals';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';
const db=new PGlite(),a='00000000-0000-0000-0000-00000000000a',b='00000000-0000-0000-0000-00000000000b',staff='00000000-0000-0000-0000-0000000000f1',crew='00000000-0000-0000-0000-0000000000c1',report='30000000-0000-0000-0000-000000000001';
before(async()=>{
 await db.exec(`CREATE ROLE anon;CREATE ROLE authenticated;CREATE ROLE service_role BYPASSRLS;
 CREATE TABLE profiles(id uuid PRIMARY KEY,role text,suspended_until timestamptz);
 CREATE TABLE reports(id uuid PRIMARY KEY,user_id uuid);
 INSERT INTO profiles VALUES('${a}','citizen',NULL),('${b}','citizen',NULL),('${staff}','officer',NULL),('${crew}','field_crew',NULL);
 INSERT INTO reports VALUES('${report}','${a}');
 GRANT SELECT ON ALL TABLES IN SCHEMA public TO service_role;`);
 await db.exec(await readFile(new URL('../migrations/20261030050000_support_tickets.sql',import.meta.url),'utf8'));
});
after(()=>db.close());
const one=async(sql,args)=>(await db.query(sql,args)).rows[0].r;
const create=(actor=a,rep=null,text='My report has not moved.')=>one('SELECT create_support_ticket($1,$2,$3,$4) r',[actor,'status_inquiry',text,rep]);
async function denied(fn,pattern){await db.exec('SAVEPOINT denied');try{await assert.rejects(fn,pattern);}finally{await db.exec('ROLLBACK TO SAVEPOINT denied');}}
test('a citizen creates and reads their own ticket; another citizen cannot',async()=>{
 await db.exec('BEGIN');try{
 const t=await create(a,report);assert.match(t.reference,/^TCK-\d{6}$/);assert.equal(t.status,'open');assert.ok(!('handler_id' in t));assert.ok(!JSON.stringify(t).includes(a));
 assert.equal((await one('SELECT read_my_support_ticket($1,$2) r',[a,t.reference.toLowerCase()])).id,t.id);
 await denied(()=>one('SELECT read_my_support_ticket($1,$2) r',[b,t.reference]),/not found/i);
 assert.equal((await one('SELECT read_my_support_tickets($1) r',[b])).tickets.length,0);
 assert.equal((await one('SELECT read_my_support_tickets($1) r',[a])).tickets.length,1);
 await denied(()=>create(b,report),/Report not found/);
 }finally{await db.exec('ROLLBACK');}
});
test('only active citizens create tickets and open tickets are capped per citizen',async()=>{
 await db.exec('BEGIN');try{
 await denied(()=>create(staff),/citizen/i);await denied(()=>create(crew),/citizen/i);
 for(let i=0;i<5;i++)await create(a);
 await denied(()=>create(a),/Too many open/);await create(b);
 await db.exec("UPDATE support_tickets SET status='resolved' WHERE citizen_id='"+a+"'");await create(a);
 await db.exec("UPDATE profiles SET suspended_until=statement_timestamp()+interval '1 day' WHERE id='"+b+"'");await denied(()=>create(b),/citizen/i);
 }finally{await db.exec('ROLLBACK');}
});
test('staff respond through the queue and the citizen sees the reply and status',async()=>{
 await db.exec('BEGIN');try{
 const t=await create(a);
 let q=await one('SELECT read_support_ticket_queue($1,$2) r',[staff,'open']);assert.equal(q.tickets.length,1);assert.equal(q.open_count,1);assert.ok(!JSON.stringify(q).includes(a));
 const r=await one('SELECT respond_support_ticket($1,$2,$3,$4) r',[staff,t.id,' We re-checked it. ','in_progress']);
 assert.equal(r.handler_id,staff);assert.equal(r.status,'in_progress');assert.equal(r.resolved_at,null);
 let mine=await one('SELECT read_my_support_ticket($1,$2) r',[a,t.reference]);assert.equal(mine.response,'We re-checked it.');assert.equal(mine.status,'in_progress');assert.ok(!('handler_id' in mine));
 await one('SELECT respond_support_ticket($1,$2,$3,$4) r',[staff,t.id,'Done.','resolved']);
 mine=await one('SELECT read_my_support_ticket($1,$2) r',[a,t.reference]);assert.equal(mine.status,'resolved');assert.ok(mine.resolved_at);
 assert.equal((await one('SELECT read_support_ticket_queue($1,$2) r',[staff,'open'])).tickets.length,0);
 }finally{await db.exec('ROLLBACK');}
});
test('citizens, crews, suspended staff and invalid replies cannot use the desk',async()=>{
 await db.exec('BEGIN');try{
 const t=await create(a);
 for(const actor of [a,crew]){await denied(()=>one('SELECT read_support_ticket_queue($1) r',[actor]),/staff/i);await denied(()=>one('SELECT respond_support_ticket($1,$2,$3,$4) r',[actor,t.id,'x','closed']),/staff/i);}
 await denied(()=>one('SELECT respond_support_ticket($1,$2,$3,$4) r',[staff,t.id,'x','open']),/Invalid/);
 await denied(()=>one('SELECT respond_support_ticket($1,$2,$3,$4) r',[staff,'99999999-9999-4999-8999-999999999999','x','closed']),/not found/i);
 await db.exec("UPDATE profiles SET suspended_until=statement_timestamp()+interval '1 day' WHERE id='"+staff+"'");
 await denied(()=>one('SELECT read_support_ticket_queue($1) r',[staff]),/staff/i);
 for(const role of ['anon','authenticated']){await db.exec('SET ROLE '+role);try{await denied(()=>create(),/permission/);}finally{await db.exec('RESET ROLE');}}
 }finally{await db.exec('ROLLBACK');}
});
test('keyset pages do not overlap in either direction',async()=>{
 await db.exec('BEGIN');try{
 for(let i=0;i<3;i++)await create(a);
 const first=await one('SELECT read_my_support_tickets($1,NULL,NULL,2) r',[a]),second=await one('SELECT read_my_support_tickets($1,$2,$3,2) r',[a,first.next_cursor.created_at,first.next_cursor.id]);
 assert.equal(first.tickets.length,2);assert.equal(second.tickets.length,1);assert.equal(second.next_cursor,null);
 assert.equal(new Set([...first.tickets,...second.tickets].map(t=>t.id)).size,3);
 const qa=await one('SELECT read_support_ticket_queue($1,NULL,NULL,NULL,2) r',[staff]),qb=await one('SELECT read_support_ticket_queue($1,NULL,$2,$3,2) r',[staff,qa.next_cursor.created_at,qa.next_cursor.id]);
 assert.equal(new Set([...qa.tickets,...qb.tickets].map(t=>t.id)).size,3);
 }finally{await db.exec('ROLLBACK');}
});
