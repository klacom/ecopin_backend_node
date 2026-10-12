import { execSync, spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import {createClient} from '@supabase/supabase-js';
import {benchmarkApplicationFlows} from './benchmark-application-flows.mjs';

const ROOT_PATH = 'C:/dev/App-Builders-Hackathon/.ecopin-optimization';
const STATUS_PATH = `${ROOT_PATH}/.private/local-supabase-recovery/status.private.json`;

async function runPsql(sql) {
  const child = spawn('docker', ['exec', '-i', 'supabase_db_ecopin-recovery-20261012', 'psql', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', 'postgres'], {
    stdio: ['pipe', 'pipe', 'pipe']
  });

  let stdout = '';
  let stderr = '';

  child.stdout.on('data', chunk => stdout += chunk.toString());
  child.stderr.on('data', chunk => stderr += chunk.toString());

  return new Promise((resolve, reject) => {
    child.on('close', code => {
      if (code !== 0) {
        reject(new Error(`psql failed (exit ${code}): ${stderr || stdout}`));
      } else {
        resolve(stdout);
      }
    });
    child.stdin.write(sql);
    child.stdin.end();
  });
}

async function main() {
  console.log('=== EcoPin Representative Scale Performance Benchmark ===');
  console.log('Measurement conditions: PostgreSQL 17.11 / PostGIS 3.3.7 container, PostgREST/Kong API');

  const local = JSON.parse(await fs.readFile(STATUS_PATH, 'utf8'));
  const apiUrl = local.API_URL;

  if(new URL(apiUrl).hostname!=='127.0.0.1')throw new Error('Benchmark only the private local stack');
  const authAdmin=createClient(apiUrl,local.SERVICE_ROLE_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
  const provisioned=[];
  async function provision(role){
    const email=`load-${role}-${randomUUID()}@ecopin.test`,password=randomUUID()+'aA1!';
    try {
      const result=await authAdmin.auth.admin.createUser({email,password,email_confirm:true});if(result.error)throw result.error;
      provisioned.push(result.data.user.id);
      const profile=await authAdmin.from('profiles').upsert({id:result.data.user.id,role,full_name:`Native benchmark ${role}`});if(profile.error)throw profile.error;
      const client=createClient(apiUrl,local.ANON_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
      const login=await client.auth.signInWithPassword({email,password});if(login.error)throw login.error;
      return {id:result.data.user.id,token:login.data.session.access_token};
    }catch(error){for(const id of provisioned){await authAdmin.from('profiles').delete().eq('id',id);await authAdmin.auth.admin.deleteUser(id);}throw error;}
  }
  const citizen=await provision('citizen'),officer=await provision('officer'),crew=await provision('field_crew');
  const citizenId=citizen.id,officerId=officer.id,crewId=crew.id;
  const citizenJwt=citizen.token,officerJwt=officer.token,crewJwt=crew.token;
  const benchmarkTag = `BENCHMARK_${Date.now()}`;
  const telemetry = {
    benchmark_id: benchmarkTag,
    timestamp: new Date().toISOString(),
    engine: 'PostgreSQL 17.11 (Debian 17.11-1.pgdg120+1) with PostGIS 3.3.7',
    scale_parameters: {
      total_reports_injected: 10000,
      total_tasks_injected: 1000,
      total_notifications_injected: 5000,
      total_receipts_injected: 1000,
      citizen_reports: 500,
      citizen_notifications: 500,
      unread_notifications_citizen: 100
    },
    benchmarks: {}
  };

  try {
    console.log('\n[1/7] Injecting benchmark users and representative scale dataset...');

    // 1. Setup users in auth.users and public.profiles
    await runPsql(`
      BEGIN;
      UPDATE public.profiles SET role = 'citizen', full_name = 'Benchmark Citizen' WHERE id = '${citizenId}';
      UPDATE public.profiles SET role = 'officer', full_name = 'Benchmark Officer' WHERE id = '${officerId}';
      UPDATE public.profiles SET role = 'field_crew', full_name = 'Benchmark Crew Worker' WHERE id = '${crewId}';
      COMMIT;
    `);

    // 2. Bulk inject 10,000 reports
    console.log('   -> Generating 10,000 reports across Metro Manila...');
    const insertReportsStart = Date.now();
    await runPsql(`
      INSERT INTO public.reports (
        id, user_id, title, description, issue_type, location,
        validation_status, status, severity_score, urgency_score,
        ra9003_category, lifecycle_state, hazard_class, created_at
      )
      SELECT
        gen_random_uuid(),
        CASE WHEN s <= 500 THEN '${citizenId}'::uuid ELSE '${officerId}'::uuid END,
        'Benchmark Report #' || s,
        '[${benchmarkTag}] Crowdsourced waste observation #' || s,
        (ARRAY['waste'::report_issue_type, 'flooding'::report_issue_type, 'pollution'::report_issue_type, 'infrastructure'::report_issue_type])[1 + (s % 4)],
        ST_SetSRID(ST_MakePoint(120.95 + (random() * 0.15), 14.55 + (random() * 0.15)), 4326)::geography,
        CASE WHEN s % 10 = 0 THEN 'pending'::report_validation_status ELSE 'approved'::report_validation_status END,
        CASE WHEN s % 10 = 0 THEN 'unresolved'::report_status WHEN s % 3 = 0 THEN 'resolved'::report_status ELSE 'in_progress'::report_status END,
        (10 + (s % 85))::numeric,
        (1 + (s % 3)),
        'solid',
        CASE WHEN s % 5 = 0 THEN 'fresh' WHEN s % 2 = 0 THEN 'maturing' ELSE 'closed' END,
        'unknown',
        now() - ((s % 30) || ' days')::interval - ((s % 86400) || ' seconds')::interval
      FROM generate_series(1, 10000) s;
    `);
    console.log(`   -> Reports injected in ${Date.now() - insertReportsStart}ms`);

    // 3. Bulk inject 1,000 cleanup tasks
    console.log('   -> Generating 1,000 cleanup tasks...');
    await runPsql(`
      INSERT INTO public.cleanup_tasks (
        id, created_by, title, description, status, route_status, priority,
        dispatch_kind, estimated_work_minutes, assigned_crew_ids, created_at
      )
      SELECT
        gen_random_uuid(),
        '${officerId}',
        'Benchmark Task #' || s,
        '[${benchmarkTag}] Automated cleanup dispatch item #' || s,
        CASE WHEN s <= 200 THEN 'created'::cleanup_task_status WHEN s <= 400 THEN 'pending'::cleanup_task_status WHEN s <= 700 THEN 'in_progress'::cleanup_task_status ELSE 'completed'::cleanup_task_status END,
        CASE WHEN s <= 500 THEN 'ready' ELSE 'needs_replan' END,
        (ARRAY['urgent', 'high', 'medium', 'low'])[1 + (s % 4)],
        'standard',
        (15 + (s % 60)),
        ARRAY['${crewId}'::uuid],
        now() - ((s % 14) || ' days')::interval
      FROM generate_series(1, 1000) s;
    `);

    // 4. Bulk inject 1,000 receipts linking tasks to reports
    console.log('   -> Generating 1,000 field assignment receipts...');
    await runPsql(`
      WITH sample_tasks AS (
        SELECT id task_id,row_number() OVER (ORDER BY id) rn FROM public.cleanup_tasks
        WHERE description LIKE '%${benchmarkTag}%' AND route_status='ready'
          AND status::text IN ('created','pending','in_progress')
      ), sample_reports AS (
        SELECT id report_id,row_number() OVER (ORDER BY id) rn FROM public.reports
        WHERE description LIKE '%${benchmarkTag}%' AND validation_status='approved'
          AND status::text IN ('unresolved','in_progress') ORDER BY id LIMIT 1000
      )
      UPDATE public.reports r SET cleanup_task_id=t.task_id FROM sample_reports sr
      JOIN sample_tasks t ON t.rn=(sr.rn+1)/2 WHERE r.id=sr.report_id;
      DO $$BEGIN IF (SELECT count(*) FROM public.field_assignment_receipts WHERE crew_id='${crewId}')<>1000
        THEN RAISE EXCEPTION 'Expected 1000 native canonical assignment receipts'; END IF; END $$;
    `);

    // 5. Bulk inject 5,000 notifications
    console.log('   -> Generating 5,000 notifications...');
    await runPsql(`
      INSERT INTO public.notifications (
        id, user_id, type, title, body, is_read, created_at
      )
      SELECT
        gen_random_uuid(),
        CASE WHEN s <= 500 THEN '${citizenId}'::uuid ELSE '${officerId}'::uuid END,
        'general'::notification_type,
        'Notification #' || s,
        '[${benchmarkTag}] Update regarding environmental dispatch event #' || s,
        CASE WHEN s <= 100 THEN false ELSE true END,
        now() - ((s % 30) || ' days')::interval - ((s % 3600) || ' seconds')::interval
      FROM generate_series(1, 5000) s;
    `);

    // 6. Update database statistics
    console.log('   -> Updating PostgreSQL planner statistics (ANALYZE)...');
    await runPsql('ANALYZE public.reports; ANALYZE public.cleanup_tasks; ANALYZE public.field_assignment_receipts; ANALYZE public.notifications;');

    // Verify row counts
    const counts = await runPsql(`
      SELECT 
        (SELECT count(*) FROM reports WHERE description LIKE '%${benchmarkTag}%') as reports,
        (SELECT count(*) FROM cleanup_tasks WHERE description LIKE '%${benchmarkTag}%') as tasks,
        (SELECT count(*) FROM notifications WHERE body LIKE '%${benchmarkTag}%') as notifications,
        (SELECT count(*) FROM field_assignment_receipts WHERE crew_id = '${crewId}') as receipts;
    `);
    console.log(`   -> Active Benchmark Counts:\n${counts.trim()}`);
    telemetry.application_flows=await benchmarkApplicationFlows({local,citizenId,officerId,crewId,citizenJwt,officerJwt,crewJwt,benchmarkTag,runPsql});

    // =========================================================================
    // P01: Owner Feed and Moderation Queue at Representative Scale
    // =========================================================================
    console.log('\n[2/7] Benchmarking P01: Owner Feed & Moderation Queue under Authenticated RLS...');
    
    // P01.1: Citizen Owner Feed (Page 1)
    const p01FeedPlan = await runPsql(`
      BEGIN;
      SET LOCAL ROLE authenticated;
      SET LOCAL "request.jwt.claims" = '{"sub": "${citizenId}", "role": "authenticated"}';
      EXPLAIN (ANALYZE, BUFFERS)
      SELECT id, title, status, severity_score, created_at
      FROM public.reports
      WHERE user_id = '${citizenId}'
      ORDER BY created_at DESC
      LIMIT 20;
      ROLLBACK;
    `);

    // P01.2: Citizen Owner Feed (Page 2 - Pagination offset)
    const p01FeedPage2Plan = await runPsql(`
      BEGIN;
      SET LOCAL ROLE authenticated;
      SET LOCAL "request.jwt.claims" = '{"sub": "${citizenId}", "role": "authenticated"}';
      EXPLAIN (ANALYZE, BUFFERS)
      SELECT id, title, status, severity_score, created_at
      FROM public.reports
      WHERE user_id = '${citizenId}'
      ORDER BY created_at DESC
      LIMIT 20 OFFSET 20;
      ROLLBACK;
    `);

    // P01.3: Officer Moderation Queue
    const p01ModPlan = await runPsql(`
      BEGIN;
      SET LOCAL ROLE authenticated;
      SET LOCAL "request.jwt.claims" = '{"sub": "${officerId}", "role": "authenticated"}';
      EXPLAIN (ANALYZE, BUFFERS)
      SELECT id, title, status, severity_score, created_at
      FROM public.reports
      WHERE status = 'unresolved' AND validation_status = 'pending'
      ORDER BY created_at ASC
      LIMIT 20;
      ROLLBACK;
    `);

    telemetry.benchmarks.P01_owner_feed_and_moderation = {
      description: 'Owner feed and moderation queue under authenticated RLS across 10,000 reports',
      page_1_plan: p01FeedPlan.trim(),
      page_2_plan: p01FeedPage2Plan.trim(),
      moderation_queue_plan: p01ModPlan.trim()
    };

    // =========================================================================
    // P02: Dispatch Queue at Representative Scale
    // =========================================================================
    console.log('\n[3/7] Benchmarking P02: Dispatch Queue Query across 1,000 tasks...');
    const p02Plan = await runPsql(`
      BEGIN;
      SET LOCAL ROLE authenticated;
      SET LOCAL "request.jwt.claims" = '{"sub": "${officerId}", "role": "authenticated"}';
      EXPLAIN (ANALYZE, BUFFERS)
      SELECT id, title, status, route_status, priority, created_at
      FROM public.cleanup_tasks
      WHERE status IN ('created', 'pending') AND route_status = 'ready'
      ORDER BY created_at ASC
      LIMIT 50;
      ROLLBACK;
    `);

    telemetry.benchmarks.P02_dispatch_queue = {
      description: 'Ready task dispatch queue across 1,000 tasks with route_status and status predicates',
      plan: p02Plan.trim()
    };

    // =========================================================================
    // P03: Task-Receipts Join at Representative Scale (service_role)
    // =========================================================================
    console.log('\n[4/7] Benchmarking P03: Task-Receipts Join Execution Plan (service_role)...');
    const p03Plan = await runPsql(`
      BEGIN;
      SET LOCAL ROLE service_role;
      EXPLAIN (ANALYZE, BUFFERS)
      SELECT t.id, t.title, t.route_status, r.id AS receipt_id, r.assignment_generation, r.issued_at
      FROM public.cleanup_tasks t
      JOIN public.field_assignment_receipts r ON r.task_id = t.id
      WHERE t.route_status = 'ready'
      LIMIT 50;
      ROLLBACK;
    `);

    telemetry.benchmarks.P03_task_receipts_join = {
      description: 'Join execution plan between cleanup_tasks and field_assignment_receipts across 1,000 tasks and 1,000 receipts under service_role',
      plan: p03Plan.trim()
    };

    // =========================================================================
    // P04: Unread Notifications Query
    // =========================================================================
    console.log('\n[5/7] Benchmarking P04: Unread Notifications Query across 5,000 notifications...');
    const p04Plan = await runPsql(`
      BEGIN;
      SET LOCAL ROLE authenticated;
      SET LOCAL "request.jwt.claims" = '{"sub": "${citizenId}", "role": "authenticated"}';
      EXPLAIN (ANALYZE, BUFFERS)
      SELECT id, title, body, is_read, created_at
      FROM public.notifications
      WHERE user_id = '${citizenId}' AND is_read = false
      ORDER BY created_at DESC
      LIMIT 20;
      ROLLBACK;
    `);

    telemetry.benchmarks.P04_unread_notifications = {
      description: 'Unread notification inbox query under authenticated RLS across 5,000 notifications',
      plan: p04Plan.trim()
    };

    // =========================================================================
    // G02: Spatial Proximity & GiST Spatial Index Scan
    // =========================================================================
    console.log('\n[6/7] Benchmarking G02: Spatial Proximity Search over 10,000 PostGIS points...');
    const g02Plan = await runPsql(`
      EXPLAIN (ANALYZE, BUFFERS)
      SELECT id, title, ST_Distance(location, ST_SetSRID(ST_MakePoint(120.9842, 14.5995), 4326)::geography) AS dist_meters
      FROM public.reports
      WHERE ST_DWithin(location, ST_SetSRID(ST_MakePoint(120.9842, 14.5995), 4326)::geography, 5000)
      ORDER BY location <-> ST_SetSRID(ST_MakePoint(120.9842, 14.5995), 4326)::geography
      LIMIT 50;
    `);

    telemetry.benchmarks.G02_spatial_proximity = {
      description: 'GiST spatial index proximity query with ST_DWithin and k-NN (<->) distance ordering across 10,000 points',
      plan: g02Plan.trim()
    };

    // =========================================================================
    // P05: Parent-Delete and Cascading Cost (WAL & Execution Timing)
    // =========================================================================
    console.log('\n[7/7] Benchmarking P05: Parent-Delete Cascading Cost and WAL Telemetry...');
    
    const parentSql = await fs.readFile(new URL('../tests/sql/parent-lifecycle-wal-regression.sql', import.meta.url), 'utf8');
    const parentOutput = await runPsql(parentSql);
    const parentJson = parentOutput.split(/\r?\n/).find(line => line.startsWith('{') && line.includes('restrictive_parent_delete'));
    if (!parentJson) throw new Error('Native parent/WAL benchmark emitted no evidence');
    telemetry.benchmarks.P05_parent_delete_cascading = JSON.parse(parentJson);
    console.log('   -> Real parent cascades, restrictive FKs and transactional lifecycle index comparison verified.');
    // =========================================================================
    // API Latency vs SQL Execution (Separating API Percentiles)
    // =========================================================================
    console.log('\nMeasuring HTTP API Latency vs SQL Execution over PostgREST/Kong (100 requests)...');

    const latencies = [];
    for (let i = 0; i < 100; i++) {
      const t0 = performance.now();
      const res = await fetch(`${apiUrl}/rest/v1/reports?user_id=eq.${citizenId}&order=created_at.desc&limit=20`, {
        headers: {
          'apikey': local.ANON_KEY,
          'Authorization': `Bearer ${citizenJwt}`
        }
      });
      const t1 = performance.now();
      if (!res.ok) {
        throw new Error(`API fetch failed with ${res.status}: ${await res.text()}`);
      }
      latencies.push(t1 - t0);
    }

    latencies.sort((a, b) => a - b);
    const p50 = latencies[Math.floor(latencies.length * 0.50)];
    const p95 = latencies[Math.floor(latencies.length * 0.95)];
    const p99 = latencies[Math.floor(latencies.length * 0.99)];
    const mean = latencies.reduce((sum, v) => sum + v, 0) / latencies.length;

    console.log(`   -> API Latency Percentiles (100 authenticated requests):`);
    console.log(`      p50:  ${p50.toFixed(2)} ms`);
    console.log(`      p95:  ${p95.toFixed(2)} ms`);
    console.log(`      p99:  ${p99.toFixed(2)} ms`);
    console.log(`      mean: ${mean.toFixed(2)} ms`);

    telemetry.benchmarks.api_latency_vs_sql = {
      endpoint: '/rest/v1/reports?user_id=eq.:id&order=created_at.desc&limit=20',
      authenticated_role: 'citizen',
      sample_size: 100,
      p50_ms: parseFloat(p50.toFixed(2)),
      p95_ms: parseFloat(p95.toFixed(2)),
      p99_ms: parseFloat(p99.toFixed(2)),
      mean_ms: parseFloat(mean.toFixed(2)),
      analysis: 'These are separate local HTTP end-to-end samples, not 100 concurrent clients. Application-flow concurrency is recorded separately. Transport, serialization and Auth costs are not individually attributed by this measurement.'
    };

    // =========================================================================
    // Clean Teardown
    // =========================================================================
    console.log('\nCleaning up benchmark dataset and restoring original database state...');
    await runPsql(`
      BEGIN;
      DELETE FROM public.field_assignment_receipts WHERE crew_id = '${crewId}';
      DELETE FROM public.sweeper_audit_log WHERE entity_id IN (SELECT id::text FROM public.reports WHERE description LIKE '%${benchmarkTag}%' UNION ALL SELECT id::text FROM public.cleanup_tasks WHERE description LIKE '%${benchmarkTag}%');
      DELETE FROM public.notifications WHERE body LIKE '%${benchmarkTag}%';
      DELETE FROM public.reports WHERE description LIKE '%${benchmarkTag}%';
      DELETE FROM public.cleanup_tasks WHERE description LIKE '%${benchmarkTag}%';
      DELETE FROM public.profiles WHERE id IN ('${citizenId}', '${officerId}', '${crewId}');
      DELETE FROM auth.users WHERE id IN ('${citizenId}', '${officerId}', '${crewId}');
      COMMIT;
      ANALYZE public.reports;
      ANALYZE public.cleanup_tasks;
      ANALYZE public.field_assignment_receipts;
      ANALYZE public.notifications;
    `);
    console.log('   -> Database cleaned and re-analyzed successfully.');

  } catch (err) {
    console.error('Benchmark error:', err);
    try {
      await runPsql(`
        DELETE FROM public.field_assignment_receipts WHERE crew_id = '${crewId}';
        DELETE FROM public.sweeper_audit_log WHERE entity_id IN (SELECT id::text FROM public.reports WHERE description LIKE '%${benchmarkTag}%' UNION ALL SELECT id::text FROM public.cleanup_tasks WHERE description LIKE '%${benchmarkTag}%');
        DELETE FROM public.notifications WHERE body LIKE '%${benchmarkTag}%';
        DELETE FROM public.reports WHERE description LIKE '%${benchmarkTag}%';
        DELETE FROM public.cleanup_tasks WHERE description LIKE '%${benchmarkTag}%';
        DELETE FROM public.profiles WHERE id IN ('${citizenId}', '${officerId}', '${crewId}');
        DELETE FROM auth.users WHERE id IN ('${citizenId}', '${officerId}', '${crewId}');
      `);
    } catch {}
    throw err;
  }

  // Save Telemetry Artifact
  const outputPath = `${ROOT_PATH}/REPRESENTATIVE_SCALE_PERFORMANCE_BENCHMARK.json`;
  await fs.writeFile(outputPath, JSON.stringify(telemetry, null, 2), 'utf8');
  console.log(`\n=== Benchmark Completed Successfully ===`);
  console.log(`Telemetry saved to: ${outputPath}`);
}

main().catch(err => {
  console.error('Fatal error in benchmark:', err);
  process.exit(1);
});
