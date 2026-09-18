import { createClient } from '@supabase/supabase-js';
import WebSocket from 'ws';
import { NEXT_PUBLIC_SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_ANON_KEY } from './index.js';

if (!NEXT_PUBLIC_SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
    console.error('Missing Supabase configuration environment variables.');
}

// Client for standard user operations (Anon Key)
export const supabase = createClient(
    NEXT_PUBLIC_SUPABASE_URL,
    SUPABASE_ANON_KEY,
    {
        auth: {
            persistSession: false,
        },
        global: {
            WebSocket: WebSocket
        }
    }
);

// Admin client for restricted operations (Service Role Key)
export const supabaseAdmin = createClient(
    NEXT_PUBLIC_SUPABASE_URL,
    SUPABASE_SERVICE_ROLE_KEY,
    {
        auth: {
            persistSession: false,
        },
        global: {
            WebSocket: WebSocket
        }
    }
);
