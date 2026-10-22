import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const sqlFile = path.resolve(__dirname, '../.private/demo-history.sql');
const tokenFile = 'C:/Users/murasakino/.gemini/antigravity-ide/mcp_oauth_tokens.json';

const tokenData = JSON.parse(await readFile(tokenFile, 'utf8'));
const token = tokenData['https://mcp.supabase.com/mcp']?.token?.access_token;
if (!token) throw new Error('Supabase MCP OAuth token not found.');

const projectId = 'wcruoyygungqxazdwhtv';
const apiUrl = `https://api.supabase.com/v1/projects/${projectId}/database/query`;

async function executeSql(query, desc = '') {
  const maxRetries = 2;
  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      const res = await fetch(apiUrl, {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${token}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ query }),
        signal: AbortSignal.timeout(60000)
      });

      if (!res.ok) {
        const text = await res.text();
        throw new Error(`HTTP ${res.status} ${res.statusText}: ${text}`);
      }

      return await res.json();
    } catch (err) {
      if (attempt < maxRetries) {
        console.warn(`[Retry ${attempt}] Error on "${desc}": ${err.message}. Retrying in 2s...`);
        await new Promise(r => setTimeout(r, 2000));
      } else {
        throw new Error(`Failed "${desc}": ${err.message}`);
      }
    }
  }
}

function chunkArray(arr, size) {
  const chunks = [];
  for (let i = 0; i < arr.length; i += size) {
    chunks.push(arr.slice(i, i + size));
  }
  return chunks;
}

const quote = value => `'${value.replaceAll("'", "''")}'`;

async function main() {
  console.log('======================================================');
  console.log(' SUPABASE DEMO HISTORY IMPORTER (CHUNKED VIA API)');
  console.log('======================================================');
  console.log(`Target: Project ${projectId}`);

  // Step 0: Check existing demo records
  const existingCheck = await executeSql(
    "SELECT count(*) as count FROM public.reports WHERE idempotency_key LIKE 'ecopin-demo-history-v1:%';",
    "Check existing demo reports"
  );
  const existingCount = Number(existingCheck[0]?.count || 0);
  if (existingCount > 0) {
    throw new Error(`Demo history already exists (${existingCount} reports found). Run operational cleanup first before reseeding.`);
  }

  const content = await readFile(sqlFile, 'utf8');
  const lines = content.split('\n');
  const stmts = [];
  let cur = '';
  for (const line of lines) {
    if (line.startsWith('--') || !line.trim()) continue;
    cur += (cur ? '\n' : '') + line;
    if (line.trim().endsWith(';')) {
      stmts.push(cur);
      cur = '';
    }
  }

  console.log(`Parsed ${stmts.length} raw SQL statements from demo-history.sql.`);

  try {
    // 1. Pause clock-derived triggers
    console.log('\n[1/7] Pausing clock-derived triggers on reports & clusters...');
    await executeSql(`
      ALTER TABLE public.reports DISABLE TRIGGER set_report_deadline;
      ALTER TABLE public.reports DISABLE TRIGGER zz_apply_report_lifecycle;
      ALTER TABLE public.clusters DISABLE TRIGGER update_clusters_updated_at;
    `, 'Disable triggers');
    console.log('✓ Triggers set_report_deadline, zz_apply_report_lifecycle, update_clusters_updated_at paused.');

    // 2. Insert clusters
    console.log('\n[2/7] Inserting clusters...');
    const clusterStmt = stmts.find(s => s.startsWith('INSERT INTO public.clusters'));
    if (!clusterStmt) throw new Error('Missing clusters insert statement.');
    await executeSql(clusterStmt, 'Insert clusters');
    console.log('✓ Clusters inserted.');

    // 3. Insert reports (chunked)
    console.log('\n[3/7] Inserting reports (chunked in batches of 100)...');
    const reportsInserts = stmts.filter(s => s.startsWith('INSERT INTO public.reports'));
    for (const rStmt of reportsInserts) {
      const match = rStmt.match(/from\s+jsonb_populate_recordset\(([^,]+),\s*'((?:[^']|'')*)'::jsonb\)/i);
      if (!match) {
        await executeSql(rStmt, 'Insert reports');
        continue;
      }
      const recordType = match[1];
      const items = JSON.parse(match[2].replaceAll("''", "'"));
      const prefix = rStmt.slice(0, match.index);
      const suffix = rStmt.slice(match.index + match[0].length);

      const chunks = chunkArray(items, 100);
      for (let i = 0; i < chunks.length; i++) {
        const chunkSql = `${prefix}FROM jsonb_populate_recordset(${recordType}, ${quote(JSON.stringify(chunks[i]))}::jsonb)${suffix}`;
        await executeSql(chunkSql, `Insert reports chunk ${i + 1}/${chunks.length}`);
        process.stdout.write(`  Inserted reports batch ${i + 1}/${chunks.length} (${chunks[i].length} records)\r`);
      }
      console.log(`\n✓ Inserted ${items.length} reports.`);
    }

    // 4. Insert auxiliary operational tables
    console.log('\n[4/7] Inserting operations, dispatches, tasks, logs & routes...');
    const auxTables = [
      'optimization_runs',
      'dispatch_plans',
      'plan_generation_jobs',
      'crew_routes',
      'cleanup_tasks',
      'dispatch_plan_items',
      'dispatch_group_commits',
      'route_waypoints',
      'manual_review_queue',
      'notifications',
      'audit_logs',
      'field_load_events',
      'field_task_failure_events',
      'dispatch_access_blocks',
      'report_resolution_events',
      'fc_operation_log',
      'sweeper_audit_log',
      'hotspot_predictions',
      'hotspot_accuracy'
    ];

    for (const table of auxTables) {
      const stmt = stmts.find(s => s.startsWith(`INSERT INTO public.${table}`));
      if (stmt) {
        // If cleanup_tasks or notifications or audit_logs, chunk if large
        const match = stmt.match(/from\s+jsonb_populate_recordset\(([^,]+),\s*'((?:[^']|'')*)'::jsonb\)/i);
        if (match && stmt.length > 200000) {
          const recordType = match[1];
          const items = JSON.parse(match[2].replaceAll("''", "'"));
          const prefix = stmt.slice(0, match.index);
          const suffix = stmt.slice(match.index + match[0].length);
          const chunks = chunkArray(items, 60);
          for (let i = 0; i < chunks.length; i++) {
            const chunkSql = `${prefix}FROM jsonb_populate_recordset(${recordType}, ${quote(JSON.stringify(chunks[i]))}::jsonb)${suffix}`;
            await executeSql(chunkSql, `Insert ${table} batch ${i + 1}/${chunks.length}`);
          }
          console.log(`  ✓ Inserted ${table} (${items.length} rows in ${chunks.length} batches)`);
        } else {
          await executeSql(stmt, `Insert ${table}`);
          console.log(`  ✓ Inserted ${table}`);
        }
      }

      if (table === 'plan_generation_jobs') {
        const updatePlanStmt = stmts.find(s => s.startsWith('UPDATE public.dispatch_plans p SET generation_job_id'));
        if (updatePlanStmt) {
          await executeSql(updatePlanStmt, 'Link dispatch plans to generation jobs');
          console.log('  ✓ Linked dispatch plans to generation jobs');
        }
      }
    }

    // 5. Update reports & clusters
    console.log('\n[5/7] Updating reports & clusters lifecycle/task linkages...');
    const reportUpdateStmt = stmts.find(s => s.startsWith('UPDATE public.reports r SET cleanup_task_id'));
    if (reportUpdateStmt) {
      const match = reportUpdateStmt.match(/from\s+jsonb_populate_recordset\(([^,]+),\s*'((?:[^']|'')*)'::jsonb\)\s*s\s*where\s*r\.id\s*=\s*s\.id/i);
      if (match) {
        const items = JSON.parse(match[2].replaceAll("''", "'"));
        const chunks = chunkArray(items, 100);
        for (let i = 0; i < chunks.length; i++) {
          const updateSql = `UPDATE public.reports r SET cleanup_task_id = s.cleanup_task_id, manual_review_id = s.manual_review_id,
            lifecycle_state = s.lifecycle_state, updated_at = s.updated_at
            FROM jsonb_populate_recordset(NULL::public.reports, ${quote(JSON.stringify(chunks[i]))}::jsonb) s WHERE r.id = s.id;`;
          await executeSql(updateSql, `Update reports chunk ${i + 1}/${chunks.length}`);
          process.stdout.write(`  Updated reports batch ${i + 1}/${chunks.length} (${chunks[i].length} records)\r`);
        }
        console.log(`\n  ✓ Updated all ${items.length} reports with tasks and lifecycle states.`);
      }
    }

    const clusterUpdateStmt = stmts.find(s => s.startsWith('UPDATE public.clusters c SET status'));
    if (clusterUpdateStmt) {
      await executeSql(clusterUpdateStmt, 'Update clusters');
      console.log('  ✓ Updated clusters with final statuses.');
    }

    const receiptsUpdateStmt = stmts.find(s => s.startsWith('UPDATE public.field_assignment_receipts'));
    if (receiptsUpdateStmt) {
      await executeSql(receiptsUpdateStmt, 'Update field assignment receipts');
      console.log('  ✓ Updated field assignment receipts.');
    }

    // 6. Insert task_report_outcomes (chunked)
    console.log('\n[6/7] Inserting task report outcomes...');
    await executeSql(`
      INSERT INTO public.field_assignment_receipts (task_id, report_id, crew_id, assignment_generation, report_claim_generation, issued_at)
      SELECT e.task_id, e.report_id, e.crew_id, 1, 1, coalesce(t.assigned_at, t.created_at)
      FROM public.report_resolution_events e
      JOIN public.cleanup_tasks t ON t.id = e.task_id
      WHERE e.operation_id LIKE 'ecopin-demo-history-v1:%'
      ON CONFLICT (task_id, report_id, crew_id, assignment_generation, report_claim_generation) 
      DO UPDATE SET issued_at = EXCLUDED.issued_at;
    `, 'Ensure receipts');

    const outcomesStmt = stmts.find(s => s.startsWith('INSERT INTO public.task_report_outcomes'));
    if (outcomesStmt) {
      const match = outcomesStmt.match(/from\s+jsonb_populate_recordset\(([^,]+),\s*'((?:[^']|'')*)'::jsonb\)/i);
      if (match) {
        const items = JSON.parse(match[2].replaceAll("''", "'"));
        const prefix = outcomesStmt.slice(0, match.index);
        const suffix = outcomesStmt.slice(match.index + match[0].length);
        const chunks = chunkArray(items, 100);
        for (let i = 0; i < chunks.length; i++) {
          const chunkSql = `${prefix}FROM jsonb_populate_recordset(NULL::public.task_report_outcomes, ${quote(JSON.stringify(chunks[i]))}::jsonb)${suffix}`;
          await executeSql(chunkSql, `Insert outcomes batch ${i + 1}/${chunks.length}`);
          process.stdout.write(`  Inserted outcomes batch ${i + 1}/${chunks.length} (${chunks[i].length} records)\r`);
        }
        console.log(`\n  ✓ Inserted ${items.length} task report outcomes.`);
      } else {
        await executeSql(outcomesStmt, 'Insert task_report_outcomes');
      }
    }

  } finally {
    // 7. ALWAYS restore triggers
    console.log('\n[7/7] Re-enabling triggers on reports & clusters...');
    await executeSql(`
      ALTER TABLE public.reports ENABLE TRIGGER set_report_deadline;
      ALTER TABLE public.reports ENABLE TRIGGER zz_apply_report_lifecycle;
      ALTER TABLE public.clusters ENABLE TRIGGER update_clusters_updated_at;
    `, 'Re-enable triggers');
    console.log('✓ Triggers restored to active state.');
  }

  // Verification
  console.log('\n======================================================');
  console.log(' VERIFICATION AUDIT');
  console.log('======================================================');
  const [repCount, outcomesCount, statusBreakdown, clusterCount] = await Promise.all([
    executeSql("SELECT count(*) as count FROM public.reports WHERE idempotency_key LIKE 'ecopin-demo-history-v1:%';", 'Count demo reports'),
    executeSql("SELECT count(*) as count FROM public.task_report_outcomes WHERE operation_id LIKE 'ecopin-demo-history-v1:%';", 'Count outcomes'),
    executeSql("SELECT status, count(*) as count FROM public.reports WHERE idempotency_key LIKE 'ecopin-demo-history-v1:%' GROUP BY status ORDER BY count DESC;", 'Report status breakdown'),
    executeSql("SELECT status, count(*) as count FROM public.clusters WHERE label LIKE '[DEMO]%' GROUP BY status ORDER BY count DESC;", 'Cluster status breakdown')
  ]);

  console.log(`Total Demo Reports Seeded : ${repCount[0]?.count}`);
  console.log(`Total Outcomes Recorded   : ${outcomesCount[0]?.count}`);
  console.log('\nReport Status Breakdown:');
  console.table(statusBreakdown);
  console.log('Cluster Status Breakdown:');
  console.table(clusterCount);
  console.log('\n✓ DEMO HISTORY SEED COMPLETED SUCCESSFULLY!');
}

main().catch(err => {
  console.error('\n❌ IMPORT FAILED:', err.message);
  process.exit(1);
});
