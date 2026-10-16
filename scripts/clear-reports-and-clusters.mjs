/**
 * clear-reports-and-clusters.mjs
 * 
 * Standalone script to cleanly and safely delete all reports, clusters,
 * cleanup tasks, dispatch plans, routes, and related operational entities
 * from the database, while strictly preserving user accounts, field crews,
 * system configurations, strikes, and system logs.
 * 
 * Usage:
 *   node scripts/clear-reports-and-clusters.mjs --dry-run
 *   node scripts/clear-reports-and-clusters.mjs --confirm
 *   node scripts/clear-reports-and-clusters.mjs --confirm --include-storage
 */

import 'dotenv/config';
import readline from 'node:readline';
import { supabaseAdmin } from '../src/config/supabase.config.js';

// Specific primary/filtering key column for tables that don't have an "id" column
const TABLE_KEY_COLUMNS = {
  dispatch_group_commits: 'dispatch_plan_id',
  fc_operation_log: 'operation_id',
};

function getKeyColumn(table) {
  return TABLE_KEY_COLUMNS[table] || 'id';
}

// Tables to be wiped (in safe child-to-parent deletion order)
const TABLES_TO_CLEAR = [
  // 1. Leaf and child event tables
  'field_load_events',
  'field_task_failure_events',
  'task_report_outcomes',
  'report_resolution_events',
  'field_assignment_receipts',
  'route_waypoints',
  'dispatch_access_blocks',
  'dispatch_plan_items',
  'dispatch_group_commits',
  
  // 2. Planning and task coordination
  'plan_generation_jobs',
  'cleanup_tasks',
  'crew_routes',
  'dispatch_plans',
  'optimization_runs',

  // 3. Report-specific queues and logs
  'manual_review_queue',
  'notifications',
  'audit_logs',

  // 4. Primary entities
  'reports',
  'clusters',

  // 5. Predictions and offline/sync telemetry
  'hotspot_accuracy',
  'hotspot_predictions',
  'sweeper_audit_log',
  'fc_operation_log',
  'fc_conflict_audit',
  'sync_conflicts',
];

// Tables that MUST NEVER be deleted
const PROTECTED_TABLES = [
  'profiles',
  'field_crews',
  'system_settings',
  'system_logs',
  'strikes',
  'optimization_settings',
  'optimization_templates',
  'sweeper_configuration',
  'work_time_configuration',
  'email_verifications',
];

// Storage buckets associated with reports/tasks (cleaned only if --include-storage is provided)
const REPORT_STORAGE_BUCKETS = [
  'Report Evidence',
  'Cleanup Task Photos',
  'Report Cleanup'
];

async function getTableRowCount(tableName) {
  const keyCol = getKeyColumn(tableName);
  try {
    const { count, error } = await supabaseAdmin
      .from(tableName)
      .select(keyCol, { count: 'exact', head: true })
      .not(keyCol, 'is', null);

    if (error) {
      // Fallback for edge-cases or schema differences
      const { count: fallbackCount, error: fallbackError } = await supabaseAdmin
        .from(tableName)
        .select('*', { count: 'exact', head: true });
      if (fallbackError) {
        return { count: null, error: fallbackError.message };
      }
      return { count: fallbackCount ?? 0, error: null };
    }
    return { count: count ?? 0, error: null };
  } catch (err) {
    return { count: null, error: err.message };
  }
}

async function printDatabaseSummary() {
  console.log('\n======================================================');
  console.log(' DATABASE PURGE AUDIT: REPORTS, CLUSTERS & RELATED');
  console.log('======================================================\n');

  console.log('--- TARGET TABLES TO PURGE ---');
  let totalRowsToPurge = 0;
  for (const table of TABLES_TO_CLEAR) {
    const { count, error } = await getTableRowCount(table);
    const countDisplay = error ? `[ERROR: ${error}]` : `${count} rows`;
    console.log(`  - ${table.padEnd(28)}: ${countDisplay}`);
    if (typeof count === 'number') {
      totalRowsToPurge += count;
    }
  }
  console.log(`\n  Total operational rows to delete: ~${totalRowsToPurge}`);

  console.log('\n--- PROTECTED TABLES (WILL NOT BE MODIFIED) ---');
  for (const table of PROTECTED_TABLES) {
    const { count, error } = await getTableRowCount(table);
    const countDisplay = error ? `[ERROR: ${error}]` : `${count} rows (PRESERVED)`;
    console.log(`  * ${table.padEnd(28)}: ${countDisplay}`);
  }
  console.log('\n======================================================\n');
}

async function breakCircularForeignKeys() {
  console.log('Step 1/3: Breaking circular and mutually-referencing foreign keys...');

  // 1. Cancel active cleanup tasks first.
  // The PostgreSQL trigger workflow_private.guard_report_claim prevents unlinking
  // reports.cleanup_task_id if the task's status is not ('completed', 'cancelled').
  const { error: errCancelTasks } = await supabaseAdmin
    .from('cleanup_tasks')
    .update({ status: 'cancelled' })
    .not('id', 'is', null);
  if (errCancelTasks && errCancelTasks.code !== 'PGRST116') {
    console.warn('  Notice (cleanup_tasks cancel guard):', errCancelTasks.message);
  }

  // 2. Nullify reports -> cleanup_tasks, clusters, manual_review_queue
  const { error: errReports } = await supabaseAdmin
    .from('reports')
    .update({ cleanup_task_id: null, cluster_id: null, manual_review_id: null })
    .not('id', 'is', null);
  if (errReports && errReports.code !== 'PGRST116') {
    console.warn('  Notice (reports unlinking):', errReports.message);
  }

  // 3. Nullify cleanup_tasks -> crew_routes, source_plan_id, cluster_id
  const { error: errTasks } = await supabaseAdmin
    .from('cleanup_tasks')
    .update({ crew_route_id: null, source_plan_id: null, cluster_id: null })
    .not('id', 'is', null);
  if (errTasks && errTasks.code !== 'PGRST116') {
    console.warn('  Notice (cleanup_tasks unlinking):', errTasks.message);
  }

  // 4. Nullify dispatch_plans -> generation_job_id, optimization_run_id
  const { error: errPlans } = await supabaseAdmin
    .from('dispatch_plans')
    .update({ generation_job_id: null, optimization_run_id: null })
    .not('id', 'is', null);
  if (errPlans && errPlans.code !== 'PGRST116') {
    console.warn('  Notice (dispatch_plans unlinking):', errPlans.message);
  }

  // 5. Nullify plan_generation_jobs -> plan_id
  const { error: errJobs } = await supabaseAdmin
    .from('plan_generation_jobs')
    .update({ plan_id: null })
    .not('id', 'is', null);
  if (errJobs && errJobs.code !== 'PGRST116') {
    console.warn('  Notice (plan_generation_jobs unlinking):', errJobs.message);
  }

  // 6. Nullify manual_review_queue -> report_id
  const { error: errReview } = await supabaseAdmin
    .from('manual_review_queue')
    .update({ report_id: null })
    .not('id', 'is', null);
  if (errReview && errReview.code !== 'PGRST116') {
    console.warn('  Notice (manual_review_queue unlinking):', errReview.message);
  }

  console.log('  Circular foreign keys successfully unlinked.');
}

async function deleteTableRows(tableName) {
  process.stdout.write(`  Deleting ${tableName.padEnd(28)}... `);
  const keyCol = getKeyColumn(tableName);

  let query = supabaseAdmin.from(tableName).delete();
  query = query.not(keyCol, 'is', null);

  const { error } = await query;
  if (error && error.code !== 'PGRST116') {
    if (tableName === 'dispatch_group_commits' && error.message.includes('immutable')) {
      console.log('[TRIGGER PROTECTED]');
      console.log('    -> PostgreSQL trigger "immutable_group_result" blocks REST deletion.');
      return false;
    }
    if (tableName === 'dispatch_plans' && error.message.includes('dispatch_group_commits')) {
      // Archive/discard the plans instead so they are inactive
      const { error: discardError } = await supabaseAdmin
        .from('dispatch_plans')
        .update({ status: 'discarded' })
        .not('id', 'is', null);
      if (!discardError) {
        console.log('[DISCARDED]');
        console.log('    -> Plans marked as "discarded" due to immutable child commits.');
        return true;
      }
    }
    console.log(`[FAILED: ${error.message}]`);
    return false;
  }
  console.log('[CLEARED]');
  return true;
}

async function emptyStorageBuckets() {
  console.log('\nCleaning up Supabase Storage buckets for reports & tasks...');
  for (const bucketName of REPORT_STORAGE_BUCKETS) {
    try {
      const { data: files, error: listError } = await supabaseAdmin.storage.from(bucketName).list('', { limit: 1000 });
      if (listError) {
        console.warn(`  Failed to list bucket "${bucketName}":`, listError.message);
        continue;
      }

      if (!files || files.length === 0) {
        console.log(`  Bucket "${bucketName}" is already empty.`);
        continue;
      }

      // Collect all file paths recursively
      const pathsToDelete = [];
      for (const item of files) {
        if (item.id === null) {
          // Folder: list contents
          const { data: subFiles } = await supabaseAdmin.storage.from(bucketName).list(item.name, { limit: 1000 });
          if (subFiles) {
            for (const sub of subFiles) {
              pathsToDelete.push(`${item.name}/${sub.name}`);
            }
          }
        } else {
          pathsToDelete.push(item.name);
        }
      }

      if (pathsToDelete.length > 0) {
        const { error: removeError } = await supabaseAdmin.storage.from(bucketName).remove(pathsToDelete);
        if (removeError) {
          console.warn(`  Error removing files from "${bucketName}":`, removeError.message);
        } else {
          console.log(`  Bucket "${bucketName}": removed ${pathsToDelete.length} files.`);
        }
      } else {
        console.log(`  Bucket "${bucketName}" has no removable objects.`);
      }
    } catch (err) {
      console.warn(`  Storage cleanup error for "${bucketName}":`, err.message);
    }
  }
}

async function promptConfirmation() {
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });

  return new Promise((resolve) => {
    rl.question(
      'Are you sure you want to permanently delete all reports, clusters, and related operational data? Type "DELETE" to confirm: ',
      (answer) => {
        rl.close();
        resolve(answer.trim() === 'DELETE');
      }
    );
  });
}

async function main() {
  const isDryRun = process.argv.includes('--dry-run');
  const isConfirmed = process.argv.includes('--confirm') || process.argv.includes('-y');
  const includeStorage = process.argv.includes('--include-storage');

  await printDatabaseSummary();

  if (isDryRun) {
    console.log('DRY RUN COMPLETE. No data was modified.');
    console.log('To execute the purge, run:');
    console.log('  node scripts/clear-reports-and-clusters.mjs --confirm\n');
    process.exit(0);
  }

  if (!isConfirmed) {
    const confirmed = await promptConfirmation();
    if (!confirmed) {
      console.log('\nOperation aborted. No changes were made.');
      process.exit(0);
    }
  }

  console.log('\nStarting database wipe...\n');

  // Step 1: Unlink
  await breakCircularForeignKeys();

  // Step 2: Delete tables in order
  console.log('\nStep 2/3: Deleting operational tables in topological order...');
  for (const table of TABLES_TO_CLEAR) {
    await deleteTableRows(table);
  }

  // Step 3: Optional storage cleanup
  if (includeStorage) {
    await emptyStorageBuckets();
  } else {
    console.log('\n(Storage buckets untouched. Pass --include-storage to delete report images from Supabase Storage.)');
  }

  // Step 4: Verification
  console.log('\nStep 3/3: Verifying database state post-purge...');
  let hasLeak = false;
  for (const table of TABLES_TO_CLEAR) {
    const { count } = await getTableRowCount(table);
    if (count > 0) {
      console.error(`  [WARNING] Table ${table} still has ${count} rows!`);
      hasLeak = true;
    }
  }

  if (!hasLeak) {
    console.log('  [PASS] All target tables are completely clean (0 rows).');
  } else {
    const { count: dgcCount } = await getTableRowCount('dispatch_group_commits');
    if (dgcCount > 0) {
      console.log('\n  ℹ️  Note: dispatch_group_commits has a PostgreSQL trigger "immutable_group_result"');
      console.log('     that blocks deletion over PostgREST. The parent dispatch_plans were marked as "discarded".');
      console.log('     To physically wipe dispatch_group_commits down to 0 rows:');
      console.log('     Run scripts/clear-reports-and-clusters.sql in the Supabase SQL Editor.');
    }
  }

  console.log('\nChecking protected tables integrity:');
  for (const table of PROTECTED_TABLES) {
    const { count } = await getTableRowCount(table);
    console.log(`  * ${table.padEnd(28)}: ${count} rows intact`);
  }

  console.log('\nDone! The database is now ready for fresh population.\n');
}

main().catch((err) => {
  console.error('\nFatal error during clear operation:', err);
  process.exit(1);
});
