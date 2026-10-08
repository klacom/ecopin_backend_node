import { supabaseAdmin as db } from '../config/supabase.config.js';

// Assignment authority, version comparison, write, audit and replay cache share one transaction.
export const batchFcSync = async (req, res, next) => {
  try {
    const operations = req.body?.operations;
    if (!Array.isArray(operations) || operations.length>50) return res.status(400).json({ message: 'operations must be an array of at most 50 entries' });
    const results = [];
    for (const op of operations) {
      if (!op || typeof op.operation_id!=='string' || !op.operation_id || !Number.isSafeInteger(op.base_version ?? 0) || (op.base_version ?? 0)<0) {
        results.push({ operation_id: op?.operation_id ?? null, status: 'failed', error_message: 'Invalid operation or base_version' });
        continue;
      }
      const isReconciliation = op.operation_type === 'fc.report.reconcile';
      const isFieldLoad = op.operation_type === 'fc.load.record';
      const isFieldFailure = op.operation_type === 'fc.task.failure';
      if (isReconciliation && (op.entity_type !== 'report' || op.entity_id !== op.payload?.report_id)) {
        results.push({ operation_id: op.operation_id, status: 'rejected', error_message: 'Report receipt target mismatch' });
        continue;
      }
      if ((isFieldLoad || isFieldFailure) && (op.entity_type !== 'task' || op.entity_id !== op.payload?.task_id)) {
        results.push({ operation_id: op.operation_id, status: 'rejected', error_message: 'Task feedback target mismatch' });
        continue;
      }
      const feedbackRpc = isReconciliation ? 'reconcile_report_outcome'
        : isFieldLoad ? 'record_field_load' : isFieldFailure ? 'submit_field_failure' : null;
      const { data, error } = await db.rpc(feedbackRpc ?? 'apply_fc_operation',
        feedbackRpc ? {
          actor: req.user.id, operation_id: op.operation_id, payload: op.payload
        } : {
          actor: req.user.id, operation_id: op.operation_id, operation_type: op.operation_type,
          entity_id: op.entity_id, entity_type: op.entity_type, payload: op.payload, base_version: op.base_version ?? 0
        });
      results.push(error ? { operation_id: op.operation_id, status: 'failed', error_message: error.message, server_record: null } : data);
    }
    return res.json({ results });
  } catch (error) { next(error); }
};
