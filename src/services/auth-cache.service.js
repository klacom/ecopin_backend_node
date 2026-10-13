import { createHash } from 'node:crypto';

// In-memory cache for validated Supabase tokens and user profile roles.
// Prevents burst API requests from repeatedly hitting Supabase Auth / profiles endpoints.

const cache = new Map();
const DEFAULT_TTL_MS = 60 * 1000; // 60 seconds TTL
const MAX_CACHE_SIZE = 2000;

function hashToken(token) {
  if (!token || typeof token !== 'string') return '';
  return createHash('sha256').update(token).digest('hex');
}

/**
 * Retrieves a cached user if present and not expired.
 * Returns a shallow copy to prevent cross-request reference mutations.
 */
export function getCachedUser(token) {
  if (!token) return null;
  const key = hashToken(token);
  const entry = cache.get(key);
  if (!entry) return null;

  if (Date.now() > entry.expiresAt) {
    cache.delete(key);
    return null;
  }

  return { ...entry.user };
}

/**
 * Stores a user in the cache with the configured TTL.
 */
export function setCachedUser(token, user, ttlMs = DEFAULT_TTL_MS) {
  if (!token || !user) return;
  const key = hashToken(token);

  if (cache.size >= MAX_CACHE_SIZE) {
    const oldestKey = cache.keys().next().value;
    if (oldestKey) cache.delete(oldestKey);
  }

  cache.set(key, {
    user: { ...user },
    expiresAt: Date.now() + ttlMs
  });
}

/**
 * Removes a token from the cache (e.g. upon logout or password change).
 */
export function invalidateToken(token) {
  if (!token) return;
  const key = hashToken(token);
  cache.delete(key);
}

/**
 * Clears the entire auth cache (useful for testing and teardowns).
 */
export function clearAuthCache() {
  cache.clear();
}

/**
 * Returns current cache size for diagnostics.
 */
export function getAuthCacheSize() {
  return cache.size;
}
