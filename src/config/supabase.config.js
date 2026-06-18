import { createClient } from '@supabase/supabase-js';
import { NEXT_PUBLIC_SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_ANON_KEY } from '../config/index.js';

if (!NEXT_PUBLIC_SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
    console.error('Missing Supabase configuration environment variables.');
}

// Client for standard user operations (Anon Key)
export const supabase = createClient(
    NEXT_PUBLIC_SUPABASE_URL,
    SUPABASE_ANON_KEY,
);

// Admin client for restricted operations (Service Role Key)
export const supabaseAdmin = createClient(
    NEXT_PUBLIC_SUPABASE_URL,
    SUPABASE_SERVICE_ROLE_KEY,
);
