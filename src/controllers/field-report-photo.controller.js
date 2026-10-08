import { randomUUID } from 'node:crypto';
import { supabaseAdmin as db } from '../config/supabase.config.js';
import { uploadFromBuffer, deleteFromCloudinary } from '../services/cloudinary.service.js';
import { hashBuffer } from '../services/photo_dedup.service.js';

async function assignedReport(id, actor, expectedVersion) {
  if (!Number.isSafeInteger(expectedVersion) || expectedVersion < 0) {
    const error = new Error('base_version is required'); error.statusCode = 409; throw error;
  }
  const { data: report, error } = await db.from('reports').select('id,cleanup_task_id,fc_version,before_photo_url,after_photo_url,before_photo_hash,after_photo_hash,status').eq('id', id).maybeSingle();
  if (error) throw error;
  if (!report?.cleanup_task_id) { const denied = new Error('Report is not assigned'); denied.statusCode = 403; throw denied; }
  const { data: task, error: taskError } = await db.from('cleanup_tasks').select('status,route_status,assigned_crew_ids').eq('id', report.cleanup_task_id).maybeSingle();
  if (taskError) throw taskError;
  if (!task || !['created','pending','in_progress','partially_completed'].includes(task.status) || task.route_status !== 'ready' || !task.assigned_crew_ids?.includes(actor)) {
    const denied = new Error('Report is not assigned to this crew'); denied.statusCode = 403; throw denied;
  }
  if (report.fc_version !== expectedVersion) { const stale = new Error('Report changed; refresh before uploading'); stale.statusCode = 409; throw stale; }
  return report;
}

async function writePhoto(id, actor, slot, url, hash, version) {
  const { data, error } = await db.rpc('set_report_photo', {
    report_id: id, actor, slot, url, photo_hash: hash, expected_version: version
  });
  if (error) { error.statusCode = error.code === '42501' ? 403 : 400; throw error; }
  if (data.status === 'conflict') { const conflict = new Error(data.error_message); conflict.statusCode = 409; throw conflict; }
  return data;
}

export async function uploadFieldReportPhoto(req, res, next) {
  const { id } = req.params;
  const slot = req.body.photo_type;
  const version = Number(req.body.base_version);
  if (!['before','after'].includes(slot) || !req.file || req.body.base_version === undefined || !Number.isSafeInteger(version)) return res.status(400).json({ message: 'Image, photo_type and base_version are required' });
  try {
    const report = await assignedReport(id, req.user.id, version);
    const hash = hashBuffer(req.file.buffer);
    if (report[`${slot}_photo_hash`] === hash && report[`${slot}_photo_url`]) return res.json({ duplicate: true, report });
    const uploaded = await uploadFromBuffer(req.file.buffer, `report_photos/${id}/${slot}`, randomUUID());
    try {
      const updated = await writePhoto(id, req.user.id, slot, uploaded.secure_url, hash, version);
      res.json({ report: updated.server_record });
    } catch (error) {
      try { await deleteFromCloudinary(uploaded.secure_url); } catch (cleanupError) { console.error('Failed to remove rejected report photo', cleanupError); }
      throw error;
    }
  } catch (error) { next(error); }
}

export async function deleteFieldReportPhoto(req, res, next) {
  const { id } = req.params;
  const slot = req.body.photo_type;
  const version = req.body.base_version;
  if (!['before','after'].includes(slot) || !Number.isSafeInteger(version)) return res.status(400).json({ message: 'photo_type and base_version are required' });
  try {
    await assignedReport(id, req.user.id, version);
    const result = await writePhoto(id, req.user.id, slot, null, null, version);
    if (result.previous_url) {
      try { await deleteFromCloudinary(result.previous_url); } catch (error) { console.error('Report photo storage cleanup failed', error); }
    }
    res.json({ report: result.server_record });
  } catch (error) { next(error); }
}
