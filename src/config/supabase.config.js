import { createClient } from '@supabase/supabase-js';
import WebSocket from 'ws';
import { NEXT_PUBLIC_SUPABASE_URL, SUPABASE_SECRET_KEY, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_PUBLISHABLE_KEY, SUPABASE_ANON_KEY } from './index.js';

const secretKey = SUPABASE_SECRET_KEY || SUPABASE_SERVICE_ROLE_KEY;
const publishableKey = SUPABASE_PUBLISHABLE_KEY || SUPABASE_ANON_KEY;

if (!NEXT_PUBLIC_SUPABASE_URL || !publishableKey || !secretKey) {
    console.error('Missing Supabase configuration environment variables (SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, or SUPABASE_SECRET_KEY).');
}

// Client for standard user operations (Publishable / Anon Key)
export const supabase = createClient(
    NEXT_PUBLIC_SUPABASE_URL,
    publishableKey,
    {
        auth: {
            persistSession: false,
        },
        global: {
            WebSocket: WebSocket
        }
    }
);

// Admin client for restricted operations (Secret Key / Service Role Key)
export const supabaseAdmin = createClient(
    NEXT_PUBLIC_SUPABASE_URL,
    secretKey,
    {
        auth: {
            persistSession: false,
        },
        global: {
            WebSocket: WebSocket
        }
    }
);
