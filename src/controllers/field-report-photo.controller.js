import { randomUUID } from 'node:crypto';
import { supabaseAdmin as db } from '../config/supabase.config.js';
import { uploadFromBuffer, deleteFromCloudinary } from '../services/cloudinary.service.js';
import { hashBuffer } from '../services/photo_dedup.service.js';
import { validateUploadedPhotoBuffer } from '../services/magic-byte.service.js';

function respondToPhotoError(error, res, next) {
  if ((error.code === '42703' && error.message?.includes('before_photos')) ||
      (error.code === 'PGRST202' && error.message?.includes('set_report_before_photo'))) {
    return res.status(503).json({
      code: 'CREW_PHOTO_SCHEMA_NOT_READY',
      message: 'Photo uploads are temporarily unavailable: the server needs the Before photo database update. Your photo remains on this device. Ask your administrator to update the server before retrying.',
    });
  }
  return next(error);
}

async function assignedReport(id, actor, expectedVersion) {
  if (!Number.isSafeInteger(expectedVersion) || expectedVersion < 0) {
    const error = new Error('base_version is required'); error.statusCode = 409; throw error;
  }
  const { data: report, error } = await db.from('reports').select('id,cleanup_task_id,fc_version,before_photo_url,after_photo_url,before_photo_hash,after_photo_hash,before_photos,status').eq('id', id).maybeSingle();
  if (error) throw error;
  if (!report?.cleanup_task_id) { const denied = new Error('Report is not assigned'); denied.statusCode = 403; throw denied; }
  const { data: task, error: taskError } = await db.from('cleanup_tasks').select('status,route_status,assigned_crew_ids,assigned_field_crew_id').eq('id', report.cleanup_task_id).maybeSingle();
  if (taskError) throw taskError;
  if (!task || !['created','pending','assigned','en_route','in_progress','partially_completed'].includes(task.status) || task.route_status !== 'ready') {
    const denied = new Error('Report is not assigned to this crew'); denied.statusCode = 403; throw denied;
  }
  let isAssigned = task.assigned_crew_ids?.includes(actor);
  if (!isAssigned && task.assigned_field_crew_id) {
    const { data: crew } = await db.from('field_crews').select('team_lead_profile_id,member_profile_ids').eq('id', task.assigned_field_crew_id).maybeSingle();
    if (crew && (crew.team_lead_profile_id === actor || crew.member_profile_ids?.includes(actor))) {
      isAssigned = true;
    }
  }
  if (!isAssigned) {
    const denied = new Error('Report is not assigned to this crew'); denied.statusCode = 403; throw denied;
  }
  if (report.fc_version !== expectedVersion) {
    const stale = new Error('Report changed; refresh before uploading');
    stale.statusCode = 409;
    stale.serverRecord = report;
    throw stale;
  }
  return report;
}

async function writePhoto(id, actor, slot, url, hash, version, photoKey) {
  const { data, error } = await db.rpc(slot === 'before' ? 'set_report_before_photo' : 'set_report_photo', {
    report_id: id, actor, ...(slot === 'before' ? {photo_key:photoKey} : {slot}), url, photo_hash: hash, expected_version: version
  });
  if (error) { error.statusCode = error.code === '42501' ? 403 : 400; throw error; }
  if (data.status === 'conflict') {
    const conflict = new Error(data.error_message || 'Report conflict');
    conflict.statusCode = 409;
    conflict.serverRecord = data.server_record;
    throw conflict;
  }
  return data;
}

export async function uploadFieldReportPhoto(req, res, next) {
  const { id } = req.params;
  const slot = req.body.photo_type;
  const version = Number(req.body.base_version);
  if (!['before','after'].includes(slot) || !req.file || req.body.base_version === undefined || !Number.isSafeInteger(version)) return res.status(400).json({ message: 'Image, photo_type and base_version are required' });
  validateUploadedPhotoBuffer(req.file.buffer, req.file.mimetype);
  try {
    const report = await assignedReport(id, req.user.id, version);
    const photoKey = req.body.photo_id || randomUUID();
    if (!/^[a-zA-Z0-9-]{1,80}$/.test(photoKey)) return res.status(400).json({message:'Invalid photo ID'});
    const hash = hashBuffer(req.file.buffer);
    if (slot === 'before') {
      const duplicate = (report.before_photos || []).find(p => p.hash === hash);
      if (duplicate) return res.json({duplicate:true, report, photo_id:duplicate.id, url:duplicate.url});
      if ((report.before_photos || []).length >= 5) return res.status(400).json({message:'Maximum 5 Before photos per report'});
    }
    if (slot !== 'before' && report[`${slot}_photo_hash`] === hash && report[`${slot}_photo_url`]) return res.json({ duplicate: true, report });
    const uploaded = await uploadFromBuffer(req.file.buffer, `report_photos/${id}/${slot}`, randomUUID());
    try {
      const updated = await writePhoto(id, req.user.id, slot, uploaded.secure_url, hash, version, photoKey);
      res.json({ report: updated.server_record, photo_id:updated.photo_id, url:updated.url ?? uploaded.secure_url });
    } catch (error) {
      try { await deleteFromCloudinary(uploaded.secure_url); } catch (cleanupError) { console.error('Failed to remove rejected report photo', cleanupError); }
      throw error;
    }
  } catch (error) { respondToPhotoError(error, res, next); }
}

export async function deleteFieldReportPhoto(req, res, next) {
  const { id } = req.params;
  const slot = req.body.photo_type;
  const version = req.body.base_version;
  if (!['before','after'].includes(slot) || !Number.isSafeInteger(version)) return res.status(400).json({ message: 'photo_type and base_version are required' });
  try {
    await assignedReport(id, req.user.id, version);
    const result = await writePhoto(id, req.user.id, slot, null, null, version, req.body.photo_id || 'legacy');
    if (result.previous_url) {
      try { await deleteFromCloudinary(result.previous_url); } catch (error) { console.error('Report photo storage cleanup failed', error); }
    }
    res.json({ report: result.server_record });
  } catch (error) { respondToPhotoError(error, res, next); }
}
