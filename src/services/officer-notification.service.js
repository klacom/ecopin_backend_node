import { supabaseAdmin as db } from '../config/supabase.config.js';

/**
 * Sends a notification to all active desk officers and admins.
 * 
 * @param {Object} options
 * @param {string|null} [options.reportId] - Related report ID, if applicable
 * @param {string} [options.type='general'] - notification_type enum value
 * @param {string} options.title - Notification title
 * @param {string} options.body - Notification message body
 */
export async function notifyOfficers({ reportId = null, type = 'general', title, body }) {
  try {
    // Fetch all profiles with role 'officer' or 'admin'
    const { data: officers, error: fetchError } = await db
      .from('profiles')
      .select('id')
      .in('role', ['officer', 'admin']);

    if (fetchError) {
      console.error('[notifyOfficers] Failed to fetch officers:', fetchError.message);
      return [];
    }

    if (!officers || officers.length === 0) {
      return [];
    }

    const notifications = officers.map(officer => ({
      user_id: officer.id,
      report_id: reportId,
      type,
      title,
      body,
      is_read: false,
    }));

    const { data, error: insertError } = await db
      .from('notifications')
      .insert(notifications)
      .select('id');

    if (insertError) {
      console.error('[notifyOfficers] Failed to insert notifications:', insertError.message);
      return [];
    }

    return data || [];
  } catch (error) {
    console.error('[notifyOfficers] Unexpected error:', error);
    return [];
  }
}
