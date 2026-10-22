import { supabaseAdmin } from '../config/supabase.config.js';

// Historical saves created multiple rows. Read the most recently saved row
// consistently without deleting earlier settings or inventing new defaults.
export function getCurrentSystemSettings(client = supabaseAdmin, fields = '*') {
  return client.from('system_settings').select(fields)
    .order('updated_at', { ascending: false, nullsFirst: false })
    .order('created_at', { ascending: false, nullsFirst: false })
    .order('id', { ascending: false })
    .limit(1).maybeSingle();
}
