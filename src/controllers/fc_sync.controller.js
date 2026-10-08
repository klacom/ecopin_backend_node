/**
 * fc_sync.controller.js  —  Phase 5 rewrite
 *
 * POST /api/fc/sync/batch
 *
 * ═══════════════════════════════════════════════════════════════
 * VERSIONING APPROACH
 * ═══════════════════════════════════════════════════════════════
 * Every accepted write bumps the entity's `fc_version` using a Postgres
 * sequence (fc_version_seq).  The sequence is strictly monotonic and
 * independent of device clocks.
 *
 * The client sends `base_version` (the fc_version it last read) with every
 * mutation.  On arrival:
 *
 *   base_version == server fc_version  →  clean write (no concurrent change)
 *   base_version  < server fc_version  →  concurrent write detected
 *   base_version missing / null        →  treated as 0 (initial sync compat)
 *
 * ═══════════════════════════════════════════════════════════════
 * MERGE RULES  (applied when base_version < server fc_version)
 * ═══════════════════════════════════════════════════════════════
 *
 *  Operation type          Rule
 *  ──────────────────────  ──────────────────────────────────────────────────
 *  update_status           FIRST-ACCEPTED-WINS.  The op that arrives first
 *                          bumps fc_version and wins.  Later ops with a stale
 *                          base_version are REJECTED and recorded in
 *                          fc_conflict_audit with outcome='rejected'.
 *
 *  update_lifecycle_stage  Same as update_status — first-accepted-wins.
 *
 *  update_validation       Same.
 *
 *  update_details          FIELD-AUTHORITY MERGE.  Field crew always wins on
 *                          EXECUTION_FIELDS; officers always win on
 *                          ADMIN_FIELDS.  If the payload only touches fields
 *                          owned by the submitter's role, it is applied even
 *                          over a stale base_version (outcome='merged').
 *                          If it touches fields owned by another role and
 *                          those fields changed since base_version, REJECTED.
 *
 *  add_note                ALWAYS ADDITIVE.  Notes never conflict.  Each note
 *                          is a new row in response_log.  Idempotency is
 *                          guaranteed by operation_id in fc_operation_log.
 *                          outcome='merged' is NOT recorded; notes are never
 *                          in conflict.
 *
 *  mark_task_complete      IDEMPOTENT.  If the task is already 'completed',
 *                          return 'duplicate' (success).  Otherwise apply.
 *                          First-accepted-wins for competing completions.
 *
 *  SAME STATUS / SAME FIELD VALUE
 *  If the incoming value is identical to the current server value the
 *  operation is recorded as outcome='idempotent' and returned as 'success'
 *  (no write needed, no conflict).
 *
 * ═══════════════════════════════════════════════════════════════
 * AUDIT TRAIL
 * ═══════════════════════════════════════════════════════════════
 * Every non-clean outcome (merged / rejected / idempotent) is written to
 * fc_conflict_audit.  Failed and duplicate operations are NOT written there
 * (they are in fc_operation_log instead).
 *
 * ═══════════════════════════════════════════════════════════════
 * IDEMPOTENCY
 * ═══════════════════════════════════════════════════════════════
 * Before any processing, fc_operation_log is checked.  A non-expired row
 * for the same operation_id + user_id returns the cached result immediately.
 */

import { supabaseAdmin as supabase } from '../config/supabase.config.js';

// ── Constants ────────────────────────────────────────────────────────────────

const MAX_BATCH_SIZE = 50;

// Status transitions that use first-accepted-wins.
const FIRST_ACCEPTED_WINS_OPS = new Set([
  'fc.report.update_status',
  'fc.report.update_lifecycle_stage',
  'fc.report.update_validation',
]);

// Fields owned by field crew — they win over conflicting officer writes.
const EXECUTION_FIELDS = new Set([
  'status', 'lifecycle_stage', 'stage',
  'evidence_photos', 'completed_at',
]);

// Fields owned by officers — they win over conflicting field-crew writes.
const ADMIN_FIELDS = new Set([
  'priority_level', 'assigned_team', 'issue_category',
  'cluster_id', 'priority', 'assigned_crew_ids',
]);

// ── Main handler ─────────────────────────────────────────────────────────────

export const batchFcSync = async (req, res, next) => {
  try {
    const { operations } = req.body;
    const user = req.user;

    if (!Array.isArray(operations)) {
      return res.status(400).json({ message: 'Invalid payload: operations must be an array' });
    }
    if (operations.length === 0) {
      return res.status(200).json({ results: [] });
    }
    if (operations.length > MAX_BATCH_SIZE) {
      return res.status(400).json({
        message: `Batch too large: maximum ${MAX_BATCH_SIZE} operations per request`,
      });
    }

    const results = [];
    for (const op of operations) {
      results.push(await _processOperation(op, user));
    }

    return res.status(200).json({ results });
  } catch (err) {
    console.error('[fc_sync] unhandled error:', err);
    next(err);
  }
};

// ── Per-operation processor ──────────────────────────────────────────────────

async function _processOperation(op, user) {
  const { operation_id, operation_type, entity_id, entity_type, payload, base_version } = op;

  if (!operation_id || typeof operation_id !== 'string') {
    return _invalid(null, 'Missing or invalid operation_id');
  }
  if (!operation_type || !entity_id || !entity_type || !payload) {
    return _invalid(operation_id, 'Missing required fields');
  }
  if (entity_type !== 'report' && entity_type !== 'task') {
    return _invalid(operation_id, `Unknown entity_type: ${entity_type}`);
  }

  // ── Idempotency replay ────────────────────────────────────────────────────
  const { data: existingLog } = await supabase
    .from('fc_operation_log')
    .select('status, result, expires_at')
    .eq('operation_id', operation_id)
    .eq('user_id', user.id)
    .maybeSingle();

  if (existingLog && new Date(existingLog.expires_at) > new Date()) {
    return {
      operation_id,
      status: 'duplicate',
      server_record: existingLog.result?.server_record ?? null,
      error_message: null,
      conflict_detail: null,
    };
  }

  // ── Dispatch ──────────────────────────────────────────────────────────────
  let result;
  try {
    switch (operation_type) {
      case 'fc.report.update_status':
      case 'fc.report.update_lifecycle_stage':
      case 'fc.report.update_validation':
        result = await _handleFirstAcceptedWins(
          operation_id, entity_id, payload, base_version, user, operation_type
        );
        break;

      case 'fc.report.update_details':
        result = await _handleFieldAuthorityMerge(
          operation_id, entity_id, payload, base_version, user, operation_type
        );
        break;

      case 'fc.note.add':
        result = await _handleAddNote(operation_id, entity_id, payload, user);
        break;

      case 'fc.task.mark_complete':
        result = await _handleTaskMarkComplete(
          operation_id, entity_id, payload, base_version, user
        );
        break;

      case 'fc.photo.upload_before':
      case 'fc.photo.upload_after':
      case 'fc.photo.delete':
        return _invalid(
          operation_id,
          `Photo operations must use the dedicated photo endpoint. operation_type=${operation_type}`
        );

      default:
        return _invalid(operation_id, `Unknown operation_type: ${operation_type}`);
    }
  } catch (err) {
    console.error(`[fc_sync] error processing ${operation_type} for ${entity_id}:`, err);
    result = _failed(operation_id, `Server error: ${err.message}`);
  }

  // ── Write operation log (terminal states only) ────────────────────────────
  if (result.status !== 'failed') {
    await supabase.from('fc_operation_log').upsert(
      {
        operation_id,
        user_id: user.id,
        operation_type,
        entity_id,
        entity_type,
        status: result.status,
        result: { server_record: result.server_record },
      },
      { onConflict: 'operation_id' }
    ).catch(e => console.error('[fc_sync] operation log write failed:', e.message));
  }

  return result;
}

// ── FIRST-ACCEPTED-WINS handler ───────────────────────────────────────────────
//
// For status/lifecycle/validation changes.
// The first operation to bump the server's fc_version wins.
// Any later operation with a stale base_version is REJECTED.
// Exception: if the incoming value is identical to the current value,
// the operation is treated as idempotent (no write, success returned).

async function _handleFirstAcceptedWins(
  operationId, reportId, payload, baseVersion, user, opType
) {
  const { data: report, error: fetchErr } = await supabase
    .from('reports')
    .select('*')
    .eq('id', reportId)
    .maybeSingle();

  if (fetchErr || !report) {
    return _failed(operationId, `Report ${reportId} not found`);
  }

  const serverVersion = report.fc_version ?? 0;
  const clientVersion = _parseVersion(baseVersion);

  // ── Idempotent check: incoming value matches current value ─────────────────
  const payloadKeys = Object.keys(payload);
  const allIdentical = payloadKeys.every(k => report[k] === payload[k]);
  if (allIdentical) {
    await _writeAudit({
      operationId, userId: user.id, opType,
      entityId: reportId, entityType: 'report',
      outcome: 'idempotent',
      clientBaseVersion: clientVersion,
      serverVersion,
      payload,
      serverState: report,
      reason: 'All incoming values already match server state',
    });
    return _success(operationId, report);
  }

  // ── Stale base_version → REJECT (unless is_outlier) ────────────────────────────────────────────
  if (clientVersion < serverVersion) {
    if (report.is_outlier) {
      // For sweeper tasks (is_outlier), we use field crew authority (last-write-wins with field priority)
      // Delegating this to handleFieldAuthorityMerge logic equivalent
      await _writeAudit({
        operationId, userId: user.id, opType,
        entityId: reportId, entityType: 'report',
        outcome: 'merged',
        clientBaseVersion: clientVersion,
        serverVersion,
        payload,
        serverState: report,
        reason: `Sweeper task (outlier): overriding stale base_version using field crew authority`,
      });
      const newVersion = await _nextVersion();
      const { data: updated, error: updateErr } = await supabase
        .from('reports')
        .update({ ...payload, fc_version: newVersion, updated_at: new Date().toISOString() })
        .eq('id', reportId)
        .select()
        .single();
      if (updateErr) return _failed(operationId, updateErr.message);
      return {
        operation_id: operationId,
        status: 'merged',
        server_record: updated,
        error_message: null,
        conflict_detail: {
          rule: 'field_authority',
          applied_fields: Object.keys(payload),
          rejected_fields: [],
          server_version: serverVersion,
          client_base_version: clientVersion,
        },
      };
    }
    
    await _writeAudit({
      operationId, userId: user.id, opType,
      entityId: reportId, entityType: 'report',
      outcome: 'rejected',
      clientBaseVersion: clientVersion,
      serverVersion,
      payload,
      serverState: report,
      reason: `First-accepted-wins: server already at v${serverVersion}, client had v${clientVersion}`,
    });
    return {
      operation_id: operationId,
      status: 'conflict',
      server_record: report,
      error_message: 'A newer change from another crew member was applied first',
      conflict_detail: {
        rule: 'first_accepted_wins',
        server_version: serverVersion,
        client_base_version: clientVersion,
      },
    };
  }

  // ── Apply mutation and bump fc_version ────────────────────────────────────
  const newVersion = await _nextVersion();
  const { data: updated, error: updateErr } = await supabase
    .from('reports')
    .update({ ...payload, fc_version: newVersion, updated_at: new Date().toISOString() })
    .eq('id', reportId)
    .select()
    .single();

  if (updateErr) return _failed(operationId, updateErr.message);

  return _success(operationId, updated);
}

// ── FIELD-AUTHORITY MERGE handler ─────────────────────────────────────────────
//
// For update_details operations.
// If the base_version is current → clean write.
// If stale:
//   • Only touches fields owned by the submitter's role → apply (merged).
//   • Touches fields owned by another role that changed → reject those fields,
//     apply the permitted ones if any, record in fc_conflict_audit.

async function _handleFieldAuthorityMerge(
  operationId, reportId, payload, baseVersion, user, opType
) {
  const { data: report, error: fetchErr } = await supabase
    .from('reports')
    .select('*')
    .eq('id', reportId)
    .maybeSingle();

  if (fetchErr || !report) {
    return _failed(operationId, `Report ${reportId} not found`);
  }

  const serverVersion = report.fc_version ?? 0;
  const clientVersion = _parseVersion(baseVersion);
  const payloadKeys = Object.keys(payload);

  // ── Idempotent check ──────────────────────────────────────────────────────
  const allIdentical = payloadKeys.every(k => report[k] === payload[k]);
  if (allIdentical) {
    await _writeAudit({
      operationId, userId: user.id, opType,
      entityId: reportId, entityType: 'report',
      outcome: 'idempotent',
      clientBaseVersion: clientVersion, serverVersion, payload,
      serverState: report,
      reason: 'All incoming values already match server state',
    });
    return _success(operationId, report);
  }

  // ── Clean write (no concurrent change) ────────────────────────────────────
  if (clientVersion >= serverVersion) {
    const newVersion = await _nextVersion();
    const { data: updated, error } = await supabase
      .from('reports')
      .update({ ...payload, fc_version: newVersion, updated_at: new Date().toISOString() })
      .eq('id', reportId)
      .select().single();
    if (error) return _failed(operationId, error.message);
    return _success(operationId, updated);
  }

  // ── Stale base_version: split payload by field authority ──────────────────
  const isFieldCrew = user.role === 'field_crew';
  const isOfficer   = user.role === 'officer' || user.role === 'admin';

  const permitted   = {};  // fields the submitter owns → apply
  const forbidden   = {};  // fields owned by another role that changed on server

  for (const key of payloadKeys) {
    const ownedByExecution = EXECUTION_FIELDS.has(key);
    const ownedByAdmin     = ADMIN_FIELDS.has(key);

    if (ownedByExecution && isFieldCrew) {
      permitted[key] = payload[key];
    } else if (ownedByAdmin && isOfficer) {
      permitted[key] = payload[key];
    } else if (ownedByExecution || ownedByAdmin) {
      // Owned by the opposite role — only reject if the server value changed.
      if (report[key] !== payload[key]) {
        forbidden[key] = { attempted: payload[key], current: report[key] };
      } else {
        permitted[key] = payload[key]; // same value → safe to re-apply
      }
    } else {
      // Neither execution nor admin field (e.g. 'notes' text field) — always permit.
      permitted[key] = payload[key];
    }
  }

  const hasForbidden = Object.keys(forbidden).length > 0;
  const hasPermitted = Object.keys(permitted).length > 0;

  // Write forbidden fields to the audit log.
  if (hasForbidden) {
    await _writeAudit({
      operationId, userId: user.id, opType,
      entityId: reportId, entityType: 'report',
      outcome: 'rejected',
      clientBaseVersion: clientVersion, serverVersion, payload,
      serverState: report,
      reason: `Field-authority conflict on: ${Object.keys(forbidden).join(', ')}. Server changed these fields after client's base_version.`,
    });
  }

  // Apply permitted fields if any.
  if (hasPermitted) {
    const newVersion = await _nextVersion();
    const { data: updated, error } = await supabase
      .from('reports')
      .update({ ...permitted, fc_version: newVersion, updated_at: new Date().toISOString() })
      .eq('id', reportId)
      .select().single();
    if (error) return _failed(operationId, error.message);

    if (hasForbidden) {
      await _writeAudit({
        operationId: `${operationId}_permitted`, userId: user.id, opType,
        entityId: reportId, entityType: 'report',
        outcome: 'merged',
        clientBaseVersion: clientVersion, serverVersion,
        payload: permitted, serverState: updated,
        reason: `Partial merge: permitted fields applied, forbidden fields skipped`,
      });
      return {
        operation_id: operationId,
        status: 'merged',
        server_record: updated,
        error_message: null,
        conflict_detail: {
          rule: 'field_authority',
          applied_fields: Object.keys(permitted),
          rejected_fields: Object.keys(forbidden),
          server_version: serverVersion,
          client_base_version: clientVersion,
        },
      };
    }

    await _writeAudit({
      operationId, userId: user.id, opType,
      entityId: reportId, entityType: 'report',
      outcome: 'merged',
      clientBaseVersion: clientVersion, serverVersion,
      payload: permitted, serverState: updated,
      reason: 'All payload fields permitted; applied over stale base_version',
    });
    return {
      operation_id: operationId,
      status: 'merged',
      server_record: updated,
      error_message: null,
      conflict_detail: {
        rule: 'field_authority',
        applied_fields: Object.keys(permitted),
        rejected_fields: [],
        server_version: serverVersion,
        client_base_version: clientVersion,
      },
    };
  }

  // Nothing permitted — full reject.
  return {
    operation_id: operationId,
    status: 'conflict',
    server_record: report,
    error_message: 'All fields in this update are owned by another role',
    conflict_detail: {
      rule: 'field_authority',
      applied_fields: [],
      rejected_fields: Object.keys(forbidden),
      server_version: serverVersion,
      client_base_version: clientVersion,
    },
  };
}

// ── NOTE handler ──────────────────────────────────────────────────────────────
// Notes are always additive — no conflict possible.  Idempotency via
// fc_operation_log (outer check already handled before reaching here).

async function _handleAddNote(operationId, reportId, payload, user) {
  const action = payload.action ?? payload.action_details ?? '';

  const { data: note, error } = await supabase
    .from('audit_logs')
    .insert({
      report_id: reportId,
      user_id: user.id,
      action_type: payload.action_type ?? 'manual_note',
      action_details: action,
    })
    .select()
    .single();

  if (error) return _failed(operationId, error.message);

  return { operation_id: operationId, status: 'success', server_record: note,
           error_message: null, conflict_detail: null };
}

// ── TASK MARK-COMPLETE handler ────────────────────────────────────────────────

async function _handleTaskMarkComplete(
  operationId, taskId, payload, baseVersion, user
) {
  const { data: task, error: fetchErr } = await supabase
    .from('cleanup_tasks')
    .select('*')
    .eq('id', taskId)
    .maybeSingle();

  if (fetchErr || !task) {
    return _failed(operationId, `Task ${taskId} not found`);
  }

  // Already complete — idempotent success regardless of base_version.
  if (task.status === 'completed') {
    return {
      operation_id: operationId,
      status: 'duplicate',
      server_record: task,
      error_message: null,
      conflict_detail: null,
    };
  }

  const serverVersion = task.fc_version ?? 0;
  const clientVersion = _parseVersion(baseVersion);

  // First-accepted-wins: if someone else already changed the task after the
  // client's snapshot, reject.
  if (clientVersion < serverVersion) {
    await _writeAudit({
      operationId, userId: user.id, opType: 'fc.task.mark_complete',
      entityId: taskId, entityType: 'task',
      outcome: 'rejected',
      clientBaseVersion: clientVersion, serverVersion, payload,
      serverState: task,
      reason: `Task version already advanced (v${serverVersion}) since client snapshot (v${clientVersion})`,
    });
    return {
      operation_id: operationId,
      status: 'conflict',
      server_record: task,
      error_message: 'Task was updated by another crew member since your last sync',
      conflict_detail: { rule: 'first_accepted_wins', server_version: serverVersion,
                         client_base_version: clientVersion },
    };
  }

  const newVersion = await _nextVersion();
  const { data: updated, error: updateErr } = await supabase
    .from('cleanup_tasks')
    .update({
      status: 'completed',
      completed_at: new Date().toISOString(),
      fc_version: newVersion,
      updated_at: new Date().toISOString(),
    })
    .eq('id', taskId)
    .select()
    .single();

  if (updateErr) return _failed(operationId, updateErr.message);

  return { operation_id: operationId, status: 'success', server_record: updated,
           error_message: null, conflict_detail: null };
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/** Advances the shared fc_version sequence and returns the new value. */
async function _nextVersion() {
  const { data, error } = await supabase.rpc('nextval', { seq_name: 'fc_version_seq' });
  if (error || data == null) {
    // Fallback: use epoch milliseconds (still monotonic within a process but
    // not globally ordered across replicas — acceptable degraded mode).
    console.error('[fc_sync] fc_version_seq failed, using timestamp fallback:', error?.message);
    return Date.now();
  }
  return Number(data);
}

/**
 * Writes a row to fc_conflict_audit.
 * Non-throwing — audit failures must never block the main sync response.
 */
async function _writeAudit({
  operationId, userId, opType, entityId, entityType,
  outcome, clientBaseVersion, serverVersion,
  payload, serverState, reason,
}) {
  await supabase.from('fc_conflict_audit').insert({
    operation_id:        operationId,
    user_id:             userId,
    operation_type:      opType,
    entity_id:           entityId,
    entity_type:         entityType,
    outcome,
    client_base_version: clientBaseVersion ?? null,
    server_version:      serverVersion,
    payload,
    server_state_snapshot: serverState ?? null,
    reason,
  }).catch(e => console.error('[fc_sync] audit write failed:', e.message));
}

function _parseVersion(v) {
  if (v == null || v === '') return 0;
  const n = Number(v);
  return isNaN(n) ? 0 : n;
}

function _success(operationId, record) {
  return { operation_id: operationId, status: 'success', server_record: record,
           error_message: null, conflict_detail: null };
}

function _failed(operationId, message) {
  return { operation_id: operationId, status: 'failed', server_record: null,
           error_message: message, conflict_detail: null };
}

function _invalid(operationId, message) {
  return { operation_id: operationId, status: 'invalid', server_record: null,
           error_message: message, conflict_detail: null };
}
