import { supabaseAdmin as db } from '../config/supabase.config.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function fail(res, error, next) {
  const status = { '42501': 403, '23505': 409, '22023': 400, PGRST202: 503 }[error.code];
  if (!status) return next(error);
  return res.status(status).json({ message: status === 503 ? 'Trust review is temporarily unavailable. Please try again later.' : error.message });
}

export async function getMyCitizenTrust(req, res, next) {
  try {
    const { data, error } = await db.rpc('citizen_trust_snapshot', { target: req.user.id });
    if (error) return fail(res, error, next);
    res.set('Cache-Control', 'no-store');
    return res.json(data);
  } catch (error) { return next(error); }
}

export async function getCitizenTrustReview(req, res, next) {
  if (!UUID.test(req.params.id)) return res.status(400).json({ message: 'Invalid report ID.' });
  try {
    const { data, error } = await db.rpc('read_citizen_trust_review', { actor: req.user.id, report_id: req.params.id });
    if (error) return fail(res, error, next);
    res.set('Cache-Control', 'no-store');
    return res.json(data);
  } catch (error) { return next(error); }
}

export async function recordCitizenTrustReview(req, res, next) {
  const { outcome, reason, operation_id, expected_decision_id } = req.body ?? {};
  if (!UUID.test(req.params.id) || !UUID.test(operation_id) || !['valid', 'neutral', 'false_urgency', 'withdrawn'].includes(outcome)
    || typeof reason !== 'string' || reason.trim().length < 3 || reason.length > 1000
    || (expected_decision_id != null && (!Number.isSafeInteger(expected_decision_id) || expected_decision_id < 1))) {
    return res.status(400).json({ message: 'Choose a review outcome, give a reason (3-1000 characters), and supply a valid operation ID.' });
  }
  try {
    const { data, error } = await db.rpc('record_citizen_trust_review', {
      actor: req.user.id, report_id: req.params.id, outcome, reason: reason.trim(), operation_id,
      expected_decision_id: expected_decision_id ?? null,
    });
    if (error) return fail(res, error, next);
    return res.json(data);
  } catch (error) { return next(error); }
}
