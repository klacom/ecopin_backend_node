import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { parseArgs } from 'node:util';

const ROOT = fileURLToPath(new URL('../', import.meta.url));
const SQL = path.join(ROOT, 'scripts/clear-reports-and-clusters.sql');
const TABLES = [
  'field_load_events', 'field_task_failure_events', 'task_report_outcomes',
  'report_resolution_events', 'field_assignment_receipts', 'route_waypoints',
  'dispatch_access_blocks', 'dispatch_plan_items', 'dispatch_group_commits',
  'plan_generation_jobs', 'cleanup_tasks', 'crew_routes', 'dispatch_plans',
  'optimization_runs', 'manual_review_queue', 'notifications', 'audit_logs',
  'reports', 'clusters', 'hotspot_accuracy', 'hotspot_predictions',
  'sweeper_audit_log', 'fc_operation_log', 'fc_conflict_audit', 'sync_conflicts',
];
const PROTECTED = ['profiles', 'field_crews', 'system_settings', 'system_logs', 'strikes',
  'optimization_settings', 'optimization_templates', 'sweeper_configuration',
  'work_time_configuration', 'email_verifications'];
export { TABLES as PURGE_TABLES, PROTECTED as PROTECTED_TABLES };
const BUCKETS = ['Report Evidence', 'Cleanup Task Photos', 'Report Cleanup'];
const key = table => ({dispatch_group_commits:'dispatch_plan_id', fc_operation_log:'operation_id'})[table] || 'id';

// Account-only audits/notifications and strike reviews are outside the demo reset.
function scope(query, table) {
  if (['notifications', 'audit_logs'].includes(table)) return query.not('report_id', 'is', null);
  if (table === 'manual_review_queue') return query.is('strike_id', null);
  return query;
}
export async function assertEmpty(countRows, tables = TABLES) {
  const failures = [];
  for (const table of tables) {
    const {count, error} = await countRows(table);
    if (error || !Number.isInteger(count) || count !== 0) failures.push(`${table}: ${error || (count == null ? 'count unavailable' : `${count} rows remain`)}`);
  }
  if (failures.length) throw new Error(`Purge is incomplete:\n${failures.join('\n')}`);
}
export async function assertRestPurgeAllowed(countRows) {
  const {count,error} = await countRows('audit_logs');
  if (error || !Number.isInteger(count)) throw new Error(`Cannot check audit rows: ${error || 'count unavailable'}. Nothing was modified.`);
  if (count) throw new Error(`Report-linked audit history requires the SQL demo reset to pause its immutability trigger. Nothing was modified. Run the WHOLE file as postgres:\n${SQL}`);
}

export async function listStoragePaths(bucket, prefix = '') {
  const paths = [];
  for (let offset = 0; ; offset += 1000) {
    const {data, error} = await bucket.list(prefix, {limit:1000, offset, sortBy:{column:'name', order:'asc'}});
    if (error) throw new Error(`List ${prefix || '/'}: ${error.message}`);
    if (!Array.isArray(data)) throw new Error('Storage listing returned no result');
    for (const item of data) {
      const objectPath = prefix ? `${prefix}/${item.name}` : item.name;
      if (item.id == null) paths.push(...await listStoragePaths(bucket, objectPath));
      else paths.push(objectPath);
    }
    if (data.length < 1000) break;
  }
  return paths;
}
export async function emptyStorageBuckets(db, names = BUCKETS) {
  for (const name of names) {
    const bucket = db.storage.from(name);
    // Finish listing before deleting: offsets otherwise skip objects as pages shrink.
    const paths = await listStoragePaths(bucket);
    for (let i = 0; i < paths.length; i += 1000) {
      const {error} = await bucket.remove(paths.slice(i, i + 1000));
      if (error) throw new Error(`Remove ${name}: ${error.message}`);
    }
    const remaining = await listStoragePaths(bucket);
    if (remaining.length) throw new Error(`${name}: ${remaining.length} storage objects remain`);
    console.log(`${name}: verified empty (${paths.length} objects removed)`);
  }
}
async function main() {
  const {values} = parseArgs({options:{
    'dry-run':{type:'boolean'}, confirm:{type:'boolean',short:'y'},
    'include-storage':{type:'boolean'}, 'storage-only':{type:'boolean'},
    verify:{type:'boolean'}, help:{type:'boolean'},
  }});
  if (values.help) {
    console.log('node scripts/clear-reports-and-clusters.mjs [--dry-run | --verify | --confirm] [--include-storage]\n'
      + 'Use scripts/clear-reports-and-clusters.sql in Supabase SQL Editor for an atomic full purge.\n'
      + '--storage-only --confirm deletes report bucket contents only after database emptiness is verified.');
    return;
  }
  if (values['dry-run'] && (values.confirm || values.verify || values['storage-only'])) throw new Error('Choose --dry-run, --verify or --confirm');
  if (values.verify && (values.confirm || values['storage-only'])) throw new Error('--verify is read-only; use it separately');
  if (values['storage-only'] && !values.confirm) throw new Error('--storage-only requires --confirm');
  const {config} = await import('dotenv');
  config({path:path.join(ROOT,'.env'), quiet:true});
  const {supabaseAdmin:db} = await import('../src/config/supabase.config.js');
  const countRows = async table => {
    const {count,error} = await scope(db.from(table).select('*',{count:'exact',head:true}),table);
    return {count,error:error?.message};
  };
  const protectedCounts = new Map();
  console.log(`Target: ${new URL(process.env.SUPABASE_URL || process.env.NEXT_PUBLIC_SUPABASE_URL).host}`);
  for (const table of TABLES) {
    const {count,error} = await countRows(table);
    if (error || !Number.isInteger(count)) throw new Error(`Cannot audit ${table}: ${error || 'count unavailable'}`);
    console.log(`${table}: ${count} operational rows`);
  }
  for (const table of PROTECTED) {
    const {count,error} = await db.from(table).select('*',{count:'exact',head:true});
    if (error || !Number.isInteger(count)) throw new Error(`Cannot audit protected table ${table}: ${error?.message || 'count unavailable'}`);
    protectedCounts.set(table,count);
  }
  if (values.verify) {
    await assertEmpty(countRows);
    console.log('Verified: all targeted operational rows, including report-linked audit history, are gone. Account-only audits/notifications and strike reviews are retained.');
    return;
  }
  if (!values.confirm) {
    console.log(`Read-only audit complete. The NON-PRODUCTION SQL reset deletes reports and their audit history:\n${SQL}`);
    return;
  }
  await assertRestPurgeAllowed(countRows);
  if (!values['storage-only']) {
    const {count,error} = await countRows('dispatch_group_commits');
    if (error || !Number.isInteger(count)) throw new Error(`Cannot check immutable commits: ${error || 'count unavailable'}. Nothing was modified.`);
    if (count) throw new Error(`Immutable dispatch commits prevent a complete REST purge. Nothing was modified. Run the WHOLE file in Supabase SQL Editor as postgres:\n${SQL}\nThen run this utility with --verify, or --storage-only --confirm to also remove Supabase report images.`);
    const mutate = async (label, query) => {
      const {error} = await query;
      if (error) throw new Error(`${label}: ${error.message}. REST cleanup stopped; previous requests may have committed. Use the transactional SQL purge: ${SQL}`);
    };
    await mutate('Cancel tasks', db.from('cleanup_tasks').update({status:'cancelled'}).not('status','in','(completed,cancelled)'));
    const unlinks = [
      ['reports',{cleanup_task_id:null,cluster_id:null,manual_review_id:null}],
      ['cleanup_tasks',{crew_route_id:null,source_plan_id:null,cluster_id:null}],
      ['dispatch_plans',{generation_job_id:null,optimization_run_id:null}],
      ['plan_generation_jobs',{plan_id:null}], ['manual_review_queue',{report_id:null}],
    ];
    for (const [table,fields] of unlinks) await mutate(`Unlink ${table}`,db.from(table).update(fields).not(key(table),'is',null));
    for (const table of TABLES) await mutate(`Delete ${table}`,scope(db.from(table).delete().not(key(table),'is',null),table));
  }
  await assertEmpty(countRows);
  for (const [table,before] of protectedCounts) {
    const {count,error} = await db.from(table).select('*',{count:'exact',head:true});
    if (error || count !== before) throw new Error(`Protected table ${table} changed or could not be verified; no success claimed`);
  }
  if (values['include-storage'] || values['storage-only']) {
    // Missing legacy buckets are optional; listing failures for existing buckets are fatal.
    const {data:buckets,error} = await db.storage.listBuckets();
    if (error) throw new Error(`Cannot audit storage buckets: ${error.message}`);
    await emptyStorageBuckets(db, BUCKETS.filter(name=>buckets.some(b=>b.name===name)));
    const {readFile,writeFile} = await import('node:fs/promises');
    const manifestPath=path.join(ROOT,'.private/citizen-demo-media.json');
    try {
      const manifest=JSON.parse(await readFile(manifestPath,'utf8'));
      for (const entry of Object.values(manifest)) delete entry.after;
      await writeFile(manifestPath,JSON.stringify(manifest,null,2));
    } catch(error) { if(error.code!=='ENOENT') throw error; }
  }
  console.log('Verified: operational database rows are empty and protected table counts are unchanged.');
  if (!values['include-storage'] && !values['storage-only']) console.log('Supabase Storage images were retained. Use --storage-only --confirm to remove them.');
  console.log('Cloudinary assets are separate and are not deleted by this Supabase utility.');
}
if (process.argv[1] && path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  main().catch(error=>{console.error(`Purge failed: ${error.message}`);process.exitCode=1;});
}
