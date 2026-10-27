import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';

// Isolated PostgreSQL fixture; never connects to a deployed project.
const { PGlite } = createRequire(import.meta.url)(process.env.ECOPIN_PGLITE_PATH || '@electric-sql/pglite');
const db = new PGlite();
try {
  await db.exec(`
    create role anon; create role authenticated; create role service_role;
    create role ecopin_public_map_reader nologin noinherit nobypassrls;
    grant usage on schema public to anon,authenticated,service_role,ecopin_public_map_reader;
    create table public.reports (
      id text primary key, user_id text, title text, notes text,
      validation_status text, on_private_property boolean, property_owner_consent_status text,
      sla_started_at timestamptz, deadline_at timestamptz
    );
    alter table public.reports enable row level security;
    grant select (id,title,validation_status,on_private_property,property_owner_consent_status)
      on public.reports to ecopin_public_map_reader;
    create policy public_map_reader_approved_consent on public.reports for select to ecopin_public_map_reader
      using (validation_status='approved' and (not on_private_property or property_owner_consent_status='obtained'));
    create view public.public_reports with (security_barrier=true,security_invoker=false) as
      select id,title,case when on_private_property then 'approximate' else 'exact' end as location_precision
      from public.reports where validation_status='approved'
        and (not on_private_property or property_owner_consent_status='obtained');
    alter view public.public_reports owner to ecopin_public_map_reader;
    grant select on public.public_reports to anon,authenticated,service_role;
    create view public.reports_view with (security_invoker=true) as
      select id,user_id,title,deadline_at from public.reports;
    grant select on public.reports_view to authenticated,service_role;
    grant select on public.reports to authenticated;
    create policy own_reports on public.reports for select to authenticated
      using (user_id=current_setting('test.viewer',true));
    insert into public.reports values
      ('public','owner','Public concern','private note','approved',false,'not_required','2026-10-27','2026-10-28'),
      ('consented','other','Approximate concern','private note','approved',true,'obtained','2026-10-27','2026-10-28'),
      ('hidden','other','No consent','private note','approved',true,'pending','2026-10-27','2026-10-28'),
      ('pending','other','Unreviewed','private note','pending',false,'not_required','2026-10-27','2026-10-28');
  `);
  const metadata = async () => (await db.query(`
    select c.relname,c.relowner,c.relacl::text,c.reloptions from pg_class c
    where c.oid in ('public.public_reports'::regclass,'public.reports_view'::regclass) order by c.relname
  `)).rows;
  const before = await metadata();
  const migration = await readFile(new URL('../migrations/20261027005142_add_response_deadline_projection.sql', import.meta.url), 'utf8');
  await db.exec(migration);
  await db.exec(migration);
  assert.deepEqual(await metadata(), before, 'Owners, grants and security options must remain intact');
  await db.exec('set role anon');
  const { rows } = await db.query('select * from public.public_reports order by id');
  assert.deepEqual(rows.map(row => row.id), ['consented', 'public']);
  assert.equal(rows[0].location_precision, 'approximate');
  assert.equal(new Date(rows[0].deadline_at).toISOString(), '2026-10-28T00:00:00.000Z');
  assert.equal(new Date(rows[0].sla_started_at).toISOString(), '2026-10-27T00:00:00.000Z');
  for (const row of rows) {
    assert.equal(Object.hasOwn(row, 'user_id'), false);
    assert.equal(Object.hasOwn(row, 'notes'), false);
  }
  await assert.rejects(db.query('select user_id from public.reports'), /permission denied/);
  await db.exec("reset role; set test.viewer='owner'; set role authenticated");
  const own = (await db.query('select * from public.reports_view')).rows;
  assert.deepEqual(own.map(row => row.id), ['public'], 'Staff projection must still obey invoker RLS');
  assert.ok(own[0].sla_started_at);
  console.log('Passed: public deadlines, consent filtering, invoker RLS, column privacy, ownership, grants and repeat application');
} finally {
  await db.close();
}
