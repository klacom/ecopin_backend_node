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
      const { data, error } = await db.rpc('apply_fc_operation', {
        actor: req.user.id, operation_id: op.operation_id, operation_type: op.operation_type,
        entity_id: op.entity_id, entity_type: op.entity_type, payload: op.payload, base_version: op.base_version ?? 0
      });
      results.push(error ? { operation_id: op.operation_id, status: 'failed', error_message: error.message, server_record: null } : data);
    }
    return res.json({ results });
  } catch (error) { next(error); }
};
