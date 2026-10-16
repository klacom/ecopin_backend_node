import { createHash } from 'node:crypto';
import { mkdir, readdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

const backend = fileURLToPath(new URL('../', import.meta.url));
const MARKER = 'ecopin-demo-history-v1';
const HOUR = 3600000;
const id = key => {
  const hex = createHash('sha256').update(`${MARKER}:${key}`).digest('hex').slice(0, 32);
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
};
const iso = value => new Date(value).toISOString();
const localDate = value => iso(value + 8 * HOUR).slice(0, 10);
const sites = [
  ['San Miguel', 14.5607, 121.0851], ['Kapasigan', 14.5609, 121.0762],
  ['Caniogan', 14.5757, 121.0857], ['Rosario', 14.5871, 121.0928],
  ['Maybunga', 14.5745, 121.0953], ['Pinagbuhatan', 14.5478, 121.0945],
  ['Bagong Ilog', 14.5648, 121.0665], ['Santolan', 14.6132, 121.0843],
];

export function parseOptions(args) {
  const { values } = parseArgs({ args, options: {
    confirm: { type: 'boolean', default: false }, 'dry-run': { type: 'boolean', default: false },
    days: { type: 'string', default: '60' }, help: { type: 'boolean', default: false },
  } });
  const days = Number(values.days);
  if (!Number.isInteger(days) || days < 30 || days > 60) throw new Error('--days must be an integer from 30 to 60.');
  if (values.confirm && values['dry-run']) throw new Error('Choose --confirm or --dry-run.');
  return { ...values, days };
}

export function buildHistory({ days, now, citizens, officer, crews, media, timing }) {
  if (!Number.isInteger(days) || days < 30 || days > 60) throw new Error('History must cover 30–60 days.');
  if (!citizens?.length || !officer?.id || !crews?.length || !media?.length) {
    throw new Error('Existing citizens, an officer/admin, a staffed crew, and sample photos are required.');
  }
  if (!(0 < timing?.high && timing.high < timing.normal && timing.normal < timing.sla && timing.sla <= 168)) {
    throw new Error('Require 0 < high maturation < normal maturation < SLA <= 168 hours.');
  }
  if (!Number.isFinite(+now)) throw new Error('Invalid history reference time.');
  const rows = {};
  const add = (table, row) => (rows[table] ??= []).push(row);
  for (let n = 0; n < days * 2; n++) {
    const age = Math.floor(n / 2);
    const stamp = +now - (age * 24 + (n % 2 ? 10 : 16)) * HOUR;
    const planned = stamp + 3 * HOUR;
    const finished = stamp + (n % 5 === 0 ? 60 : 7) * HOUR;
    const done = age >= 3 && n % 10 !== 0;
    const failed = age >= 3 && n % 20 === 0;
    const waiting = age >= 3 && n % 20 === 10;
    const dispatched = !waiting;
    const status = done ? 'completed' : failed ? 'cancelled' : n % 2 ? 'pending' : 'in_progress';
    const [area, lat, lng] = sites[n % sites.length];
    const point = `SRID=4326;POINT(${lng} ${lat})`;
    const crew = crews[n % crews.length];
    const members = [...new Set([crew.team_lead_profile_id, ...(crew.member_profile_ids ?? [])].filter(Boolean))];
    if (!members.length) throw new Error('A selected field crew has no members.');
    const actor = members[0];
    const clusterId = id(`cluster:${n}`), taskId = id(`task:${n}`), planId = id(`plan:${n}`);
    const runId = id(`run:${n}`), routeId = id(`route:${n}`), jobId = id(`job:${n}`);
    const reportIds = Array.from({ length: 3 + n % 4 }, (_, j) => id(`report:${n}:${j}`));
    const group = `demo-group-${n}`;
    const score = 25 + n % 70;
    const maturation = score >= 67 ? timing.high : timing.normal;
    const breach = (done ? finished : +now) >= stamp + timing.sla * HOUR;
    const mature = (done ? finished : +now) >= stamp + maturation * HOUR;
    add('clusters', { id: clusterId, center: point, report_count: reportIds.length, radius_meters: 80,
      issue_type: 'waste', severity: score >= 67 ? 'high' : score >= 34 ? 'medium' : 'low',
      status: done ? 'resolved' : failed ? 'deferred' : waiting ? 'prioritized' : status === 'pending' ? 'scheduled' : 'in_progress',
      priority: score >= 67 ? 'high' : 'medium', priority_score: score, label: `[DEMO] ${area} collection point ${n + 1}`,
      estimated_effort_minutes: 30 + reportIds.length * 5, created_at: iso(stamp), updated_at: iso(done ? finished : planned) });
    for (let j = 0; j < reportIds.length; j++) {
      const reportId = reportIds[j];
      const citizen = citizens[(n + j) % citizens.length].id;
      const reportStatus = done ? age > 7 ? 'closed' : 'resolved' : !failed && !waiting && status === 'in_progress' ? 'in_progress' : 'unresolved';
      const report = { id: reportId, user_id: citizen,
        title: `${['Uncollected household waste', 'Plastic litter near drainage', 'Roadside dumping', 'Overflowing collection point'][j % 4]} — ${area}`,
        description: `[DEMO] Simulated resident report near collection point ${n + 1}, ${area}, Pasig. Sample photo is illustrative.`,
        issue_type: 'waste', location: `SRID=4326;POINT(${lng + j * 0.0001} ${lat + j * 0.00008})`,
        validation_status: 'approved', status: reportStatus, cluster_id: clusterId,
        cleanup_task_id: dispatched && !done && !failed ? taskId : null,
        created_at: iso(stamp), updated_at: iso(done ? finished + (age > 7 ? HOUR : 0) : planned),
        before_photo_url: media[(n * 3 + j) % media.length],
        severity_score: score, severity_level: score >= 67 ? 'High' : score >= 34 ? 'Medium' : 'Low',
        urgency_score: score >= 67 ? 3 : 2, ra9003_category: 'solid', ml_predicted_class: 'trash',
        ml_confidence: 0.8 + (n % 18) / 100, hazard_class: 'standard', hazard_confidence: 0.9,
        hazard_model_version: 'demo-fixture-v1', hazard_decision_source: 'demo_seed', hazard_classified_at: iso(stamp),
        idempotency_key: `${MARKER}:${n}:${j}`, sla_started_at: iso(stamp), deadline_at: iso(stamp + timing.sla * HOUR),
        lifecycle_state: done ? 'closed' : dispatched && !failed ? 'dispatched' : 'clustered',
        matured_at: mature ? iso(stamp + maturation * HOUR) : null,
        breached_at: breach ? iso(stamp + timing.sla * HOUR) : null,
        report_claim_generation: dispatched ? 1 : 0, fc_version: done ? 3 : dispatched ? 1 : 0,
        lgu_resolved_at: done ? iso(finished) : null, citizen_closed_at: reportStatus === 'closed' ? iso(finished + HOUR) : null,
        satisfaction_rating: reportStatus === 'closed' ? 3 + n % 3 : null,
        stage: done ? reportStatus : status === 'in_progress' && !failed && !waiting ? 'in_progress' : 'submitted' };
      add('reports', report);
      add('notifications', { id: id(`notice:${n}:${j}`), user_id: citizen, report_id: reportId,
        type: done ? 'resolved' : 'approved', title: done ? 'Cleanup completed' : 'Report validated',
        body: `[DEMO] ${done ? 'The crew completed the cleanup.' : 'Your report is in the cleanup queue.'}`,
        is_read: age > 2, created_at: iso(done ? finished : stamp + HOUR) });
      add('audit_logs', { id: id(`audit:${n}:${j}`), report_id: reportId, user_id: officer.id,
        action_type: 'status_update', action_details: `[DEMO] ${done ? 'Cleanup completed; resident notified.' : failed ? 'Access restricted; officer clearance needed.' : 'Validated and prioritized.'}`,
        created_at: iso(done ? finished : planned) });
      if (done) {
        const eventId = id(`resolution:${n}:${j}`);
        add('report_resolution_events', { id: eventId, report_id: reportId, task_id: taskId, crew_id: actor,
          operation_id: `${MARKER}:resolve:${n}:${j}`, resolved_at: iso(finished), report_fc_version: report.fc_version, resolution_kind: 'cleaned' });
        add('task_report_outcomes', { id: id(`outcome:${n}:${j}`), operation_id: `${MARKER}:outcome:${n}:${j}`,
          task_id: taskId, report_id: reportId, crew_id: actor, outcome: 'cleaned', disposition: 'applied',
          observed_at: iso(finished), submitted_at: iso(finished), evidence_refs: [],
          notes: '[DEMO] Simulated cleanup; no after-photo evidence supplied.', resolution_event_id: eventId });
      }
    }
    if (!dispatched) continue;
    add('optimization_runs', { id: runId, triggered_by: officer.id, approved_by: officer.id, approved_at: iso(planned),
      status: 'approved', criteria: { demo: true }, num_tasks_optimized: 1, num_crews: 1,
      weather_condition: n % 5 ? 'normal' : 'heavy_rain', traffic_condition: n % 3 ? 'low' : 'moderate',
      total_estimated_distance_meters: 2400 + n * 10, total_estimated_duration_min: 60, created_at: iso(planned) });
    add('dispatch_plans', { id: planId, planned_date: localDate(planned), total_crews_available: 1,
      total_capacity_minutes: 480, status: 'approved', mode: 'standard', settings_snapshot: { demo: true },
      optimization_run_id: runId, created_by: officer.id, created_at: iso(planned), planning_as_of: iso(planned) });
    add('plan_generation_jobs', { id: jobId, requested_by: officer.id, mode: 'standard', status: 'completed',
      settings_snapshot: { demo: true }, plan_id: planId, requested_at: iso(planned - 60000),
      started_at: iso(planned - 30000), finished_at: iso(planned) });
    add('crew_routes', { id: routeId, optimization_run_id: runId, crew_id: crew.id,
      start_depot: crew.depot_location || point, end_depot: crew.depot_location || point,
      total_distance_meters: 2400 + n * 10, total_duration_min: 60, task_count: 1, created_at: iso(planned) });
    add('cleanup_tasks', { id: taskId, cluster_id: clusterId, cluster_ids: [clusterId],
      title: `[DEMO] ${area} waste collection ${n + 1}`, description: 'Simulated historical cleanup operation.',
      status, task_type: 'Cleanup', report_ids: reportIds, report_sequence: reportIds, assigned_field_crew_id: crew.id,
      assigned_crew_ids: members, assignment_generation: 1, created_by: officer.id, lgu_user_id: officer.id,
      assigned_by: officer.id, assigned_at: iso(planned), last_assigned_at: iso(planned), created_at: iso(planned),
      scheduled_date: localDate(planned), priority: score >= 67 ? 'high' : 'medium', priority_score: score,
      source_plan_id: planId, source_group_key: group, crew_route_id: routeId, sequence_in_route: 1,
      route_status: 'ready', dispatch_kind: 'standard', estimated_duration_min: 45, estimated_work_minutes: 45,
      location: point, street_address: `${area}, Pasig (simulated location)`,
      before_photo_url: media[n % media.length], completed_at: done || failed ? iso(done ? finished : planned + HOUR) : null,
      completed_by: done || failed ? actor : null, completion_result: done ? 'cleanup_completed' : failed ? 'unable_to_complete' : null,
      completion_notes: done ? '[DEMO] Segregated and collected waste; after photo not supplied.' : null,
      failure_class: failed ? 'site' : null, failure_reason: failed ? '[DEMO] Site access restricted.' : null });
    add('dispatch_plan_items', { id: id(`item:${n}`), dispatch_plan_id: planId, cluster_id: clusterId,
      item_type: 'cluster', report_ids: reportIds, cluster_ids: [clusterId], is_selected: true,
      group_key: group, planned_crew_id: crew.id, estimated_work_minutes: 45, estimated_duration_minutes: 45,
      priority_score: score, commit_disposition: 'included', committed_task_id: taskId, created_at: iso(planned) });
    add('dispatch_group_commits', { dispatch_plan_id: planId, group_key: group,
      result: { status: 'committed', task_ids: [taskId], demo: true }, committed_at: iso(planned) });
    for (let j = 0; j < 3; j++) add('route_waypoints', {
      id: id(`waypoint:${n}:${j}`), crew_route_id: routeId, sequence_order: j,
      latitude: lat, longitude: lng, cleanup_task_id: j === 1 ? taskId : null,
      waypoint_type: ['depot_start', 'task', 'depot_end'][j], created_at: iso(planned),
    });
    if (done) {
      add('field_load_events', { id: id(`load:${n}`), operation_id: `${MARKER}:load:${n}`,
        task_id: taskId, field_crew_id: crew.id, actor_id: actor, assignment_generation: 1,
        event_type: 'load_observation', fill_percent: 20 + n % 60, actual_volume_m3: 0.4 + n % 4 / 10,
        actual_weight_kg: 40 + n % 80, observed_at: iso(finished), submitted_at: iso(finished), notes: '[DEMO] Recorded collection load.' });
      if (age < 30) add('fc_operation_log', { operation_id: `${MARKER}:complete:${n}`, user_id: actor,
        operation_type: 'fc.task.mark_complete', entity_type: 'task', entity_id: taskId, status: 'success',
        result: { demo: true, status: 'completed' }, created_at: iso(finished), expires_at: iso(finished + 30 * 24 * HOUR) });
    }
    if (failed) {
      add('field_task_failure_events', { id: id(`failure:${n}`), operation_id: `${MARKER}:failure:${n}`,
        task_id: taskId, actor_id: actor, assignment_generation: 1, reason_code: 'site_inaccessible', failure_class: 'site',
        evidence_refs: [], notes: '[DEMO] Locked access gate; officer clearance requested.', observed_at: iso(planned + HOUR), submitted_at: iso(planned + HOUR) });
      add('dispatch_access_blocks', { id: id(`block:${n}`), cluster_id: clusterId, task_id: taskId,
        reason: '[DEMO] Site access restricted.', failure_class: 'site', blocked_by: actor, blocked_at: iso(planned + HOUR) });
    }
    add('sweeper_audit_log', { event_type: 'DEMO_HISTORY_IMPORTED', entity_type: 'TASK', entity_id: taskId,
      user_id: officer.id, event_data: { demo: true, status }, created_at: iso(done ? finished : planned) });
  }
  // Recent unclustered reports provide a realistic validation/review inbox.
  for (let n = 0; n < 12; n++) {
    const stamp = +now - (n + 1) * HOUR;
    const reportId = id(`inbox:${n}`), reviewId = id(`review:${n}`);
    const [area, lat, lng] = sites[n % sites.length];
    add('reports', { id: reportId, user_id: citizens[n % citizens.length].id,
      title: `New waste report — ${area}`, description: '[DEMO] Recent report awaiting assessment.',
      issue_type: 'waste', location: `SRID=4326;POINT(${lng} ${lat})`, status: 'unresolved',
      validation_status: n % 3 === 0 ? 'manual_review' : n % 3 === 1 ? 'pending_ai_validation' : 'approved',
      before_photo_url: media[n % media.length], created_at: iso(stamp), updated_at: iso(stamp),
      idempotency_key: `${MARKER}:inbox:${n}`, severity_score: 30, sla_started_at: iso(stamp),
      deadline_at: iso(stamp + timing.sla * HOUR),
      lifecycle_state: n + 1 >= timing.sla ? 'sla_breached' : n + 1 >= timing.normal ? 'maturing' : 'fresh',
      matured_at: n + 1 >= timing.normal ? iso(stamp + timing.normal * HOUR) : null,
      breached_at: n + 1 >= timing.sla ? iso(stamp + timing.sla * HOUR) : null,
      manual_review_id: n % 3 === 0 ? reviewId : null, cluster_id: null, cleanup_task_id: null });
    if (n % 3 === 0) add('manual_review_queue', { id: reviewId, report_id: reportId, review_type: 'other',
      priority: 'normal', status: 'pending', review_notes: '[DEMO] Low-confidence classification needs review.',
      created_at: iso(stamp), updated_at: iso(stamp) });
  }
  // Predictions are explicitly synthetic; historical evaluations use actual seeded counts.
  for (let n = 0; n < days; n++) {
    const stamp = +now - n * 24 * HOUR;
    const [area, lat, lng] = sites[n % sites.length];
    const predictionId = id(`prediction:${n}`);
    const areaClusters = new Set(rows.clusters.filter(c => c.label.includes(` ${area} collection`)).map(c => c.id));
    const actual = rows.reports.filter(r => areaClusters.has(r.cluster_id) && localDate(Date.parse(r.created_at)) === localDate(stamp)).length;
    add('hotspot_predictions', { id: predictionId, region_id: `${MARKER}:${area}`, time_horizon: 'daily',
      prediction_date: localDate(stamp), risk_score: 0.4 + n % 5 / 10, report_count: actual,
      risk_level: n % 5 >= 3 ? 'high' : 'medium', region_center_lat: lat, region_center_lng: lng,
      region_radius_meters: 200, top_issue_type: 'waste', issue_breakdown: { waste: actual },
      created_at: iso(stamp - 24 * HOUR), updated_at: iso(stamp - 24 * HOUR) });
    if (n > 0) add('hotspot_accuracy', { id: id(`accuracy:${n}`), prediction_id: predictionId,
      actual_reports: actual, predicted_reports: actual + 2, accuracy_score: actual / (actual + 2),
      time_horizon: 'daily', evaluation_date: localDate(stamp), created_at: iso(stamp) });
  }
  return rows;
}

const quote = value => `'${value.replaceAll("'", "''")}'`;
function insert(table, rows) {
  if (!rows?.length) return '';
  // Preserve database defaults for columns the fixture does not supply.
  const shapes = new Map();
  for (const row of rows) {
    const key = Object.keys(row).sort().join(',');
    if (!shapes.has(key)) shapes.set(key, []);
    shapes.get(key).push(row);
  }
  return [...shapes.values()].map(group => {
    const names = Object.keys(group[0]).map(c => `"${c}"`).join(',');
    return `INSERT INTO public.${table} (${names})\nSELECT ${names} FROM jsonb_populate_recordset(NULL::public.${table}, ${quote(JSON.stringify(group))}::jsonb);\n`;
  }).join('');
}

export function renderSql(rows) {
  const reports = rows.reports.map(({ cleanup_task_id, manual_review_id, ...row }) =>
    cleanup_task_id ? { ...row, report_claim_generation: 0 } : row);
  // Start clusters as unresolved so report-claim guards accept initial membership.
  const clusters = rows.clusters.map(row => ({ ...row, status: 'unresolved' }));
  const tableOrder = ['optimization_runs', 'dispatch_plans', 'plan_generation_jobs', 'crew_routes', 'cleanup_tasks',
    'dispatch_plan_items', 'dispatch_group_commits', 'route_waypoints', 'manual_review_queue', 'notifications',
    'audit_logs', 'field_load_events', 'field_task_failure_events', 'dispatch_access_blocks',
    'report_resolution_events', 'fc_operation_log', 'sweeper_audit_log', 'hotspot_predictions', 'hotspot_accuracy'];
  let sql = `-- EcoPin demo history. Run this WHOLE file in Supabase SQL Editor as postgres.\n-- Illustrative photos and synthetic activity. Existing operational data is preserved.\nBEGIN;\nSET LOCAL lock_timeout = '5s';\nSET LOCAL statement_timeout = '120s';\nSET LOCAL TIME ZONE 'Asia/Manila';\nSELECT pg_advisory_xact_lock(72631016);\nLOCK TABLE public.reports, public.cleanup_tasks, public.clusters IN SHARE ROW EXCLUSIVE MODE;\nDO $$ BEGIN\n  IF EXISTS (SELECT 1 FROM public.reports WHERE idempotency_key LIKE '${MARKER}:%') THEN\n    RAISE EXCEPTION 'Demo history already exists. Run the operational cleanup script before reseeding.';\n  END IF;\nEND $$;\n-- Pause ONLY clock-derived triggers; keep claims, receipts, security and FK checks active.\nCREATE TEMP TABLE demo_paused_triggers ON COMMIT DROP AS\nSELECT t.tgrelid::regclass AS target, t.tgname, t.tgenabled\nFROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid\nWHERE t.tgrelid IN ('public.reports'::regclass, 'public.clusters'::regclass)\n  AND NOT t.tgisinternal AND t.tgenabled <> 'D'\n  AND p.proname IN ('apply_report_lifecycle','calculate_report_deadline','update_updated_at_column');\nDO $$ DECLARE t record; BEGIN\n  FOR t IN SELECT * FROM demo_paused_triggers LOOP\n    EXECUTE format('ALTER TABLE %s DISABLE TRIGGER %I', t.target, t.tgname);\n  END LOOP;\nEND $$;\n`;
  sql += insert('clusters', clusters) + insert('reports', reports);
  for (const table of tableOrder) {
    sql += insert(table, rows[table]);
    if (table === 'plan_generation_jobs') sql += `UPDATE public.dispatch_plans p SET generation_job_id = j.id FROM public.plan_generation_jobs j WHERE j.plan_id = p.id AND p.id IN (${rows.dispatch_plans.map(r => quote(r.id)).join(',')});\n`;
  }
  sql += `UPDATE public.reports r SET cleanup_task_id = s.cleanup_task_id, manual_review_id = s.manual_review_id,\n  lifecycle_state = s.lifecycle_state, updated_at = s.updated_at\nFROM jsonb_populate_recordset(NULL::public.reports, ${quote(JSON.stringify(rows.reports))}::jsonb) s WHERE r.id = s.id;\n`;
  sql += `UPDATE public.clusters c SET status = s.status, updated_at = s.updated_at\nFROM jsonb_populate_recordset(NULL::public.clusters, ${quote(JSON.stringify(rows.clusters))}::jsonb) s WHERE c.id = s.id;\n`;
  sql += `UPDATE public.field_assignment_receipts r SET issued_at = t.assigned_at\nFROM public.cleanup_tasks t WHERE r.task_id = t.id AND t.id IN (${rows.cleanup_tasks.map(t => quote(t.id)).join(',')});\n`;
  const outcomes = rows.task_report_outcomes ?? [];
  if (outcomes.length) {
    const cols = Object.keys(outcomes[0]);
    sql += `INSERT INTO public.task_report_outcomes (${cols.join(',')},receipt_id)\nSELECT ${cols.map(c => `s.${c}`).join(',')},r.id\nFROM jsonb_populate_recordset(NULL::public.task_report_outcomes, ${quote(JSON.stringify(outcomes))}::jsonb) s\nJOIN public.field_assignment_receipts r ON r.task_id = s.task_id AND r.report_id = s.report_id AND r.crew_id = s.crew_id\n  AND r.assignment_generation = 1 AND r.report_claim_generation = 1;\n`;
  }
  sql += `DO $$ DECLARE t record; BEGIN\n  IF (SELECT count(*) FROM public.reports WHERE idempotency_key LIKE '${MARKER}:%') <> ${rows.reports.length} THEN\n    RAISE EXCEPTION 'Demo report count mismatch';\n  END IF;\n  IF (SELECT count(*) FROM public.task_report_outcomes WHERE operation_id LIKE '${MARKER}:%') <> ${outcomes.length} THEN\n    RAISE EXCEPTION 'Missing assignment receipts or report outcomes';\n  END IF;\n  FOR t IN SELECT * FROM demo_paused_triggers LOOP\n    CASE t.tgenabled\n      WHEN 'A' THEN EXECUTE format('ALTER TABLE %s ENABLE ALWAYS TRIGGER %I', t.target, t.tgname);\n      WHEN 'R' THEN EXECUTE format('ALTER TABLE %s ENABLE REPLICA TRIGGER %I', t.target, t.tgname);\n      ELSE EXECUTE format('ALTER TABLE %s ENABLE TRIGGER %I', t.target, t.tgname);\n    END CASE;\n  END LOOP;\nEND $$;\nCOMMIT;\nSELECT status, count(*) FROM public.reports WHERE idempotency_key LIKE '${MARKER}:%' GROUP BY status;\n`;
  return sql;
}

async function main() {
  const options = parseOptions(process.argv.slice(2));
  if (options.help) {
    console.log('node scripts/populate-demo-history.mjs [--dry-run | --confirm] [--days 30..60]\nDefault: read-only preview. --confirm uploads sample photos and writes .private/demo-history.sql.\nThen run the whole generated SQL file in Supabase SQL Editor as postgres.');
    return;
  }
  const { config } = await import('dotenv');
  config({ path: path.join(backend, '.env'), quiet: true });
  const { createClient } = await import('@supabase/supabase-js');
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL || process.env.SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SERVICE_ROLE_KEY || process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) throw new Error('Set NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SERVICE_ROLE_KEY in the backend .env.');
  const db = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
  const read = async (table, columns) => {
    const { data, error } = await db.from(table).select(columns);
    if (error) throw new Error(`${table}: ${error.message}`);
    return data;
  };
  const [profiles, teams, configuration, existing] = await Promise.all([
    read('profiles', 'id,role,suspended_until'),
    read('field_crews', 'id,team_lead_profile_id,member_profile_ids,depot_location,availability_status'),
    read('sweeper_configuration', 'parameter_name,parameter_value'),
    db.from('reports').select('id', { count: 'exact', head: true }).like('idempotency_key', `${MARKER}:%`),
  ]);
  if (existing.error) throw new Error(existing.error.message);
  if (existing.count) throw new Error('Demo history already exists. Run the operational cleanup script before reseeding.');
  const now = new Date();
  const active = profiles.filter(p => !p.suspended_until || Date.parse(p.suspended_until) <= +now);
  const citizens = active.filter(p => p.role === 'citizen');
  const officer = active.find(p => p.role === 'officer') || active.find(p => p.role === 'admin');
  const personnel = new Set(active.filter(p => p.role === 'field_crew').map(p => p.id));
  const crews = teams.filter(t => t.availability_status !== 'disabled').map(t => ({ ...t,
    team_lead_profile_id: personnel.has(t.team_lead_profile_id) ? t.team_lead_profile_id : null,
    member_profile_ids: (t.member_profile_ids ?? []).filter(p => personnel.has(p)),
  })).filter(t => t.team_lead_profile_id || t.member_profile_ids.length);
  const hours = name => Number(configuration.find(c => c.parameter_name === name)?.parameter_value?.hours);
  const timing = { normal: hours('maturation_threshold_hours'), high: hours('high_severity_maturation_hours'), sla: hours('sla_threshold') };
  const imagesDir = path.resolve(backend, '../sample_images');
  const files = (await readdir(imagesDir)).filter(f => /\.(jpg|jpeg|png)$/i.test(f)).sort((a, b) => a.localeCompare(b, 'en', { numeric: true })).slice(0, 40);
  const media = files.map((_, i) => `storage://Report%20Evidence/${MARKER}/photo-${i + 1}.jpg`);
  const rows = buildHistory({ days: options.days, now, citizens, officer, crews, media, timing });
  console.log(`Target: ${new URL(url).host}\n${options.days} days, ${files.length} illustrative waste photos, ${citizens.length} citizens, ${crews.length} staffed crews.`);
  console.table(Object.entries(rows).map(([table, data]) => ({ table, rows: data.length })));
  const sql = renderSql(rows);
  if (!options.confirm) {
    console.log('DRY RUN: no uploads, files, or database writes.\nRun again with --confirm to prepare the photos and SQL import.');
    return;
  }
  await mkdir(path.join(backend, '.private'), { recursive: true });
  for (let i = 0; i < files.length; i++) {
    const buffer = await readFile(path.join(imagesDir, files[i]));
    if (buffer.length > 10 * 1024 * 1024) throw new Error(`${files[i]} exceeds the 10 MB storage limit.`);
    const objectPath = `${MARKER}/photo-${i + 1}.jpg`;
    const { error } = await db.storage.from('Report Evidence').upload(objectPath, buffer, {
      contentType: files[i].toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg', upsert: true,
    });
    if (error) throw new Error(`Photo ${i + 1}: ${error.message}. Uploaded photos are reusable; rerun --confirm after fixing the error.`);
  }
  const output = path.join(backend, '.private/demo-history.sql');
  await writeFile(output, sql);
  console.log(`Prepared ${files.length} photos. No database rows have been inserted yet.\nRun the WHOLE file in Supabase SQL Editor as postgres:\n${output}`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { console.error(`Population preparation failed: ${error.message}`); process.exitCode = 1; });
}
