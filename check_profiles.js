import { supabaseAdmin } from './src/config/supabase.config.js';

async function checkProfiles() {
    const { data, error } = await supabaseAdmin.from('profiles').select('id, full_name, is_email_verified').order('created_at', { ascending: false }).limit(5);
    console.log(data, error);
}

checkProfiles();
