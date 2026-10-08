import { supabaseAdmin as db } from '../../../config/supabase.config.js';
export async function processTaskFeedback(taskId, outcome, notes, userId, { failure_class = null, base_version = null, operation_id = null } = {}) {
  const { data, error } = await db.rpc('submit_task_outcome', { task_id: taskId, actor: userId, outcome, notes: notes ?? '',
    classification: failure_class, expected_version: base_version, operation_id });
  if (error) { error.statusCode = error.code === '42501' ? 403 : 400; throw error; }
  if (data.status === 'conflict') { const conflict = new Error(data.error_message ?? 'Task changed; refresh before submitting'); conflict.statusCode = 409; throw conflict; }
  return data.server_record ?? data;
}
