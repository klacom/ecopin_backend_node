// Project identity is public; never include database keys in guard diagnostics.
const productionOrigin = 'https://wcruoyygungqxazdwhtv.supabase.co';
const loopback = new Set(['localhost', '127.0.0.1', '[::1]']);

function origin(value) {
  let url;
  try { url = new URL(value); }
  catch { throw new Error('Configure a valid Supabase origin before starting the backend.'); }
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password ||
      url.pathname !== '/' || url.search || url.hash) {
    throw new Error('Supabase configuration must be an HTTP(S) origin without credentials, paths or query parameters.');
  }
  return url;
}

export function assertSupabaseIsolation(value, env = process.env) {
  const url = origin(value);
  if (env.NODE_ENV === 'production' && env.DEPLOYMENT_ENV === 'production' && url.protocol === 'https:') return;
  if (url.origin === productionOrigin) {
    throw new Error('Refusing production Supabase access outside an explicit production deployment. Use isolated development data.');
  }
  if (loopback.has(url.hostname)) return;
  if (url.protocol === 'https:' && env.DEVELOPMENT_SUPABASE_URL &&
      origin(env.DEVELOPMENT_SUPABASE_URL).origin === url.origin) return;
  throw new Error('Hosted development requires a separately designated DEVELOPMENT_SUPABASE_URL. Production is forbidden.');
}
