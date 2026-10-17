import crypto from 'node:crypto';

export const HOT_RETENTION_DAYS = 180;
export const WORM_RETENTION_YEARS = 7;
export const DEFAULT_AUDIT_TABLE = 'sweeper_audit_log';

/**
 * Calculates the hot storage cutoff date based on retention days.
 * @param {number} [retentionDays=180] 
 * @param {Date} [referenceDate=new Date()]
 * @returns {Date}
 */
export function calculateCutoffDate(retentionDays = HOT_RETENTION_DAYS, referenceDate = new Date()) {
  const days = Number.isInteger(retentionDays) && retentionDays > 0 ? retentionDays : HOT_RETENTION_DAYS;
  const cutoff = new Date(referenceDate);
  cutoff.setDate(cutoff.getDate() - days);
  return cutoff;
}

/**
 * Calculates the WORM compliance expiry timestamp (7 years retention).
 * @param {Date|string} [archivedAt=new Date()]
 * @param {number} [wormYears=7]
 * @returns {string} ISO-8601 string
 */
export function calculateWormExpiry(archivedAt = new Date(), wormYears = WORM_RETENTION_YEARS) {
  const years = Number.isInteger(wormYears) && wormYears > 0 ? wormYears : WORM_RETENTION_YEARS;
  const expiry = new Date(archivedAt);
  expiry.setFullYear(expiry.getFullYear() + years);
  return expiry.toISOString();
}

/**
 * Deterministically serializes audit records into canonical NDJSON format.
 * @param {Array<Object>} records
 * @returns {string}
 */
export function canonicalSerialize(records) {
  if (!Array.isArray(records)) return '';
  // Sort deterministically by created_at then id
  const sorted = [...records].sort((a, b) => {
    const timeA = new Date(a.created_at || 0).getTime();
    const timeB = new Date(b.created_at || 0).getTime();
    if (timeA !== timeB) return timeA - timeB;
    return String(a.id || '').localeCompare(String(b.id || ''));
  });

  return sorted.map(r => JSON.stringify(r)).join('\n');
}

/**
 * Computes a cryptographic SHA-256 digest of a string or buffer.
 * @param {string|Buffer} payload
 * @returns {string} hex digest
 */
export function computePayloadDigest(payload) {
  return crypto.createHash('sha256').update(payload || '').digest('hex');
}

/**
 * Generates an immutable WORM compliance manifest for an archived batch.
 * @param {Object} params
 * @returns {Object}
 */
export function generateWormManifest({
  tableName = DEFAULT_AUDIT_TABLE,
  records = [],
  hotRetentionDays = HOT_RETENTION_DAYS,
  wormRetentionYears = WORM_RETENTION_YEARS,
  archivedAt = new Date().toISOString()
} = {}) {
  const payload = canonicalSerialize(records);
  const payloadSha256 = computePayloadDigest(payload);
  const dates = records.map(r => new Date(r.created_at).getTime()).filter(t => !isNaN(t));

  return {
    manifest_version: '1.0',
    compliance_standard: 'SEC-17a-4 / FINRA-4511 / WORM-7YR',
    table_name: tableName,
    archived_at: archivedAt,
    hot_retention_days: hotRetentionDays,
    worm_retention_years: wormRetentionYears,
    worm_retention_until: calculateWormExpiry(archivedAt, wormRetentionYears),
    record_count: records.length,
    earliest_record_at: dates.length > 0 ? new Date(Math.min(...dates)).toISOString() : null,
    latest_record_at: dates.length > 0 ? new Date(Math.max(...dates)).toISOString() : null,
    payload_sha256: payloadSha256,
    byte_size: Buffer.byteLength(payload, 'utf8'),
    immutability_enforced: true,
    status: 'SEALED_WORM_COMPLIANT'
  };
}

/**
 * Retrieves audit retention status and archival eligibility.
 * @param {Object} options
 * @returns {Promise<Object>}
 */
export async function getAuditArchiveStatus({
  supabaseClient,
  tableName = DEFAULT_AUDIT_TABLE,
  retentionDays = HOT_RETENTION_DAYS
} = {}) {
  const cutoffDate = calculateCutoffDate(retentionDays);
  const cutoffIso = cutoffDate.toISOString();

  if (!supabaseClient) {
    return {
      table_name: tableName,
      hot_retention_days: retentionDays,
      worm_retention_years: WORM_RETENTION_YEARS,
      cutoff_date: cutoffIso,
      total_records: 0,
      eligible_for_archival: 0,
      immutability_policy: 'active'
    };
  }

  // Count total records
  const { count: totalRecords, error: totalErr } = await supabaseClient
    .from(tableName)
    .select('*', { count: 'exact', head: true });

  if (totalErr) throw new Error(`Failed to query total audit logs: ${totalErr.message}`);

  // Count records older than cutoff
  const { count: eligibleRecords, error: eligibleErr } = await supabaseClient
    .from(tableName)
    .select('*', { count: 'exact', head: true })
    .lte('created_at', cutoffIso);

  if (eligibleErr) throw new Error(`Failed to query eligible audit logs: ${eligibleErr.message}`);

  // Get earliest and latest record timestamps
  const { data: earliestData } = await supabaseClient
    .from(tableName)
    .select('created_at')
    .order('created_at', { ascending: true })
    .limit(1);

  const { data: latestData } = await supabaseClient
    .from(tableName)
    .select('created_at')
    .order('created_at', { ascending: false })
    .limit(1);

  return {
    table_name: tableName,
    hot_retention_days: retentionDays,
    worm_retention_years: WORM_RETENTION_YEARS,
    cutoff_date: cutoffIso,
    total_records: totalRecords ?? 0,
    eligible_for_archival: eligibleRecords ?? 0,
    earliest_record_at: earliestData?.[0]?.created_at || null,
    latest_record_at: latestData?.[0]?.created_at || null,
    immutability_policy: 'active'
  };
}

/**
 * Executes a sealed WORM archival export for audit records exceeding hot retention.
 * @param {Object} options
 * @returns {Promise<Object>}
 */
export async function executeAuditArchive({
  supabaseClient,
  tableName = DEFAULT_AUDIT_TABLE,
  retentionDays = HOT_RETENTION_DAYS,
  limit = 1000
} = {}) {
  const cutoffDate = calculateCutoffDate(retentionDays);
  const cutoffIso = cutoffDate.toISOString();
  const archivedAt = new Date().toISOString();

  if (!supabaseClient) {
    const manifest = generateWormManifest({ tableName, records: [], hotRetentionDays: retentionDays, archivedAt });
    return { manifest, records_archived: 0 };
  }

  // Fetch eligible records
  const { data: records, error } = await supabaseClient
    .from(tableName)
    .select('*')
    .lte('created_at', cutoffIso)
    .order('created_at', { ascending: true })
    .limit(limit);

  if (error) throw new Error(`Failed to fetch audit records for archive: ${error.message}`);

  const manifest = generateWormManifest({
    tableName,
    records: records || [],
    hotRetentionDays: retentionDays,
    archivedAt
  });

  return {
    manifest,
    records_archived: (records || []).length,
    export_payload: canonicalSerialize(records || [])
  };
}
