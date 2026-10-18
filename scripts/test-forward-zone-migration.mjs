import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { buildHistory, renderSql } from './seed_historical_timeseries.mjs';

// Disposable PostGIS only: never loads .env or connects to the configured Supabase project.
const dockerPath = process.env.DOCKER_PATH || 'C:/Program Files/Docker/Docker/resources/bin/docker.exe';
const name = `ecopin-forward-zones-${process.pid}-${Date.now()}`;
const docker = (args, input) => execFileSync(dockerPath, args, {
  input, encoding: 'utf8', timeout: 60000, maxBuffer: 8 * 1024 * 1024,
});
const sql = (input, database = 'forecast') => docker(['exec', '-i', name, 'psql', '-X', '-qAt', '-U', 'postgres', '-d', database, '-v', 'ON_ERROR_STOP=1'], input).trim();
const migration = readFileSync(new URL('../migrations/20261018120000_forward_zone_forecasting.sql', import.meta.url), 'utf8');
const rollback = readFileSync(new URL('../migrations/rollback/20261018120000_forward_zone_forecasting.sql', import.meta.url), 'utf8');
let created = false;
try {
  docker(['run', '--rm', '--network', 'none', '-d', '--name', name,
    '-e', 'POSTGRES_HOST_AUTH_METHOD=trust', 'postgis/postgis:17-3.5']);
  created = true;
  let ready = false;
  for (let n = 0; n < 60; n++) {
    try { if (sql('SELECT 1', 'postgres') === '1') { ready = true; break; } } catch {}
    await new Promise(resolve => setTimeout(resolve, 500));
  }
  assert.ok(ready, 'PostGIS did not start');
  sql('CREATE DATABASE forecast TEMPLATE template0', 'postgres');
  sql(`CREATE SCHEMA extensions;
    CREATE EXTENSION postgis WITH SCHEMA extensions;
    CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role BYPASSRLS;
    CREATE TYPE public.report_status AS ENUM ('unresolved','in_progress','resolved','closed','completed','rejected');
    CREATE TABLE public.reports (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid, title text NOT NULL,
      description text, issue_type text, location extensions.geography(Point,4326) NOT NULL,
      validation_status text, status public.report_status, flagged_severe boolean DEFAULT false,
      severity_score smallint CHECK (severity_score BETWEEN 0 AND 100), severity_level text,
      stage text, lifecycle_state text, created_at timestamptz DEFAULT now(), updated_at timestamptz,
      idempotency_key text UNIQUE);
    ALTER TABLE public.reports ENABLE ROW LEVEL SECURITY;
    GRANT USAGE ON SCHEMA public, extensions TO service_role;
    GRANT SELECT ON public.reports TO service_role;
    CREATE TABLE public.hotspot_predictions (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(), region_id varchar(255) NOT NULL,
      time_horizon varchar(50) NOT NULL, prediction_date date NOT NULL,
      risk_score numeric NOT NULL, report_count integer NOT NULL, risk_level varchar(20) NOT NULL,
      region_center_lat numeric NOT NULL, region_center_lng numeric NOT NULL);
    CREATE UNIQUE INDEX idx_hotspot_predictions_unique ON public.hotspot_predictions(region_id,prediction_date,time_horizon);
    INSERT INTO public.hotspot_predictions(region_id,time_horizon,prediction_date,risk_score,report_count,risk_level,region_center_lat,region_center_lng)
    VALUES ('legacy','daily','2026-09-01',0.5,4,'medium',14.56,121.08);`);
  sql(migration);
  assert.equal(sql('SELECT count(*) FROM public.spatial_zones'), '122');
  assert.equal(sql(`SELECT bool_and(extensions.ST_IsValid(boundary) AND extensions.ST_Area(boundary)>0
    AND extensions.ST_Covers(boundary,extensions.ST_SetSRID(extensions.ST_Point(centroid_lng,centroid_lat),4326))) FROM public.spatial_zones`), 't');
  assert.equal(sql("SELECT model_version IS NULL FROM public.hotspot_predictions WHERE region_id='legacy'"), 't');
  sql(`SET TIME ZONE 'Asia/Manila';
    INSERT INTO public.reports(title,location,validation_status,status,severity_score,created_at,flagged_severe)
    SELECT fixture.title, extensions.ST_SetSRID(extensions.ST_Point(z.centroid_lng,z.centroid_lat),4326)::extensions.geography,
      fixture.validation,fixture.status::public.report_status,50,fixture.created,fixture.flagged
    FROM (SELECT * FROM public.spatial_zones ORDER BY id LIMIT 1) z CROSS JOIN (VALUES
      ('eligible-open','approved','unresolved','2026-09-07 23:30:00+00'::timestamptz,false),
      ('eligible-resolved','approved','resolved','2026-09-07 23:30:00+00'::timestamptz,false),
      ('eligible-closed','approved','closed','2026-09-07 23:30:00+00'::timestamptz,false),
      ('pending','pending','unresolved','2026-09-07 23:30:00+00'::timestamptz,false),
      ('rejected','approved','rejected','2026-09-07 23:30:00+00'::timestamptz,false),
      ('flagged','approved','unresolved','2026-09-07 23:30:00+00'::timestamptz,true),
      ('future','approved','unresolved',now()+interval '1 day',false)
    ) fixture(title,validation,status,created,flagged);`);
  assert.equal(sql("SELECT report_count||':'||avg_severity::double precision||':'||to_char(week_start AT TIME ZONE 'UTC','YYYY-MM-DD HH24:MI') FROM public.zone_weekly_report_history"), '3:50:2026-09-07 00:00');
  assert.equal(sql('SET ROLE service_role; SELECT sum(report_count) FROM public.zone_weekly_report_history'), '3');
  for (const role of ['anon', 'authenticated']) {
    for (const table of ['spatial_zones', 'zone_weekly_report_history', 'hotspot_predictions']) {
      assert.equal(sql(`SELECT has_table_privilege('${role}','public.${table}','SELECT')`), 'f');
    }
  }
  sql(`INSERT INTO public.reports(title,location,validation_status,status,created_at)
    SELECT 'shared-edge',extensions.ST_PointOnSurface(extensions.ST_Intersection(a.boundary,b.boundary))::extensions.geography,
      'approved','closed','2026-08-31 23:30:00+00'
    FROM public.spatial_zones a JOIN public.spatial_zones b ON a.id<b.id AND extensions.ST_Touches(a.boundary,b.boundary)
    LIMIT 1;`);
  assert.equal(sql("SELECT count(*) FROM public.reports WHERE title='shared-edge'"), '1');
  assert.equal(sql('SELECT sum(report_count) FROM public.zone_weekly_report_history'), '4', 'edge counted once');
  assert.equal(sql(`SELECT h.zone_id = (SELECT min(z.id) FROM public.spatial_zones z
      CROSS JOIN public.reports r WHERE r.title='shared-edge'
      AND extensions.ST_Covers(z.boundary,r.location::extensions.geometry))
    FROM public.zone_weekly_report_history h WHERE h.week_start='2026-08-31 00:00:00+00'`), 't', 'lowest stable id owns shared edge');
  sql("UPDATE public.reports SET validation_status='approved' WHERE title='pending'");
  assert.equal(sql('SELECT sum(report_count) FROM public.zone_weekly_report_history'), '5', 'live aggregate updates without refresh');
  const catalog = JSON.parse(readFileSync(new URL('../data/pasig-h3-r8.geojson', import.meta.url)));
  const seed = buildHistory({ weeks: 26, seed: 2, asOf: '2026-10-18' }, catalog).slice(0, 20);
  sql(renderSql(seed)); sql(renderSql(seed));
  assert.equal(sql("SELECT count(*) FROM public.reports WHERE idempotency_key LIKE 'ecopin-forecast-history-v1:%'"), '20');
  assert.equal(sql(`SELECT created_at='${seed[0].created_at}'::timestamptz FROM public.reports WHERE id='${seed[0].id}'`), 't');
  const forwardInsert = `INSERT INTO public.hotspot_predictions(region_id,time_horizon,prediction_date,risk_score,report_count,risk_level,
    region_center_lat,region_center_lng,zone_id,horizon_days,forecast_date_start,forecast_date_end,predicted_count,predicted_lower_bound,predicted_upper_bound)
    SELECT id,'7d','2026-10-18',0.5,5,'medium',centroid_lat,centroid_lng,id,7,'2026-10-18','2026-10-25',5,2,8
    FROM public.spatial_zones ORDER BY id LIMIT 1;`;
  sql(forwardInsert);
  assert.throws(() => sql(forwardInsert), /duplicate key/);
  assert.throws(() => sql("UPDATE public.hotspot_predictions SET predicted_upper_bound=1 WHERE zone_id IS NOT NULL"), /forward_counts/);
  assert.throws(() => sql("UPDATE public.hotspot_predictions SET forecast_date_end='2026-10-26' WHERE zone_id IS NOT NULL"), /forward_dates/);
  sql(rollback);
  assert.equal(sql('SELECT count(*) FROM public.hotspot_predictions'), '2', 'rollback keeps legacy and forward rows');
  sql(migration);
  assert.equal(sql('SELECT count(*) FROM public.spatial_zones'), '122');
  console.log('PASS: catalog geometry, live UTC aggregates, eligibility, shared edges, grants, additive seed, bounds, rollback/reapply.');
} finally {
  if (created) docker(['rm', '-f', name]);
}
