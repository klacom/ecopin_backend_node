import { createClient } from 'redis';
import { supabaseAdmin as db } from '../config/supabase.config.js';

let redisClient = null;
let isRedisReady = false;
let redisConnectPromise = null;

/**
 * Lazily initialize and return Redis client if configured.
 * Catches connection failures gracefully so missing Redis doesn't crash the server.
 */
export function getQuotaRedisClient() {
  if (redisClient) return redisClient;
  const url = process.env.REDIS_URL || 'redis://localhost:6379';
  try {
    redisClient = createClient({
      url,
      socket: {
        reconnectStrategy: (retries) => (retries > 1 ? false : 50),
      },
    });

    redisClient.on('error', () => {
      isRedisReady = false;
    });

    redisConnectPromise = redisClient
      .connect()
      .then(() => {
        isRedisReady = true;
      })
      .catch(() => {
        isRedisReady = false;
      });
  } catch {
    isRedisReady = false;
  }
  return redisClient;
}

export async function closeQuotaRedis() {
  if (redisClient) {
    try {
      if (redisConnectPromise) await redisConnectPromise.catch(() => {});
      if (redisClient.isOpen) await redisClient.quit();
    } catch {
      // Ignore disconnect errors in tests
    } finally {
      redisClient = null;
      isRedisReady = false;
      redisConnectPromise = null;
    }
  }
}

/** In-memory cache for daily report quota system setting */
let cachedQuota = null;
let cacheTimestamp = 0;
const CACHE_TTL_MS = 30000; // 30 seconds

export function invalidateQuotaSettingsCache() {
  cachedQuota = null;
  cacheTimestamp = 0;
}

/**
 * Fetch the configured daily report quota from system_settings.
 * Defaults to 10 if unconfigured or database error occurs.
 */
export async function getDailyReportQuota(client = db) {
  const now = Date.now();
  if (cachedQuota !== null && now - cacheTimestamp < CACHE_TTL_MS) {
    return cachedQuota;
  }

  try {
    const { data, error } = await client
      .from('system_settings')
      .select('daily_report_quota')
      .maybeSingle();

    if (!error && data?.daily_report_quota != null) {
      const parsed = parseInt(data.daily_report_quota, 10);
      if (!isNaN(parsed) && parsed > 0) {
        cachedQuota = parsed;
        cacheTimestamp = now;
        return cachedQuota;
      }
    }
  } catch {
    // Fall back to default
  }

  cachedQuota = 10;
  cacheTimestamp = now;
  return cachedQuota;
}

/**
 * Format remaining seconds into a user-friendly countdown string.
 * Examples: "3 hours 15 minutes", "42 minutes", "15 seconds"
 */
export function formatCountdown(seconds) {
  if (!seconds || seconds <= 0) return '0 seconds';
  const s = Math.floor(seconds);
  const hours = Math.floor(s / 3600);
  const minutes = Math.floor((s % 3600) / 60);
  const remSeconds = s % 60;

  if (hours > 0) {
    const hStr = `${hours} hour${hours === 1 ? '' : 's'}`;
    const mStr = minutes > 0 ? ` ${minutes} minute${minutes === 1 ? '' : 's'}` : '';
    return `${hStr}${mStr}`;
  }
  if (minutes > 0) {
    const mStr = `${minutes} minute${minutes === 1 ? '' : 's'}`;
    const sStr = remSeconds > 0 && minutes < 5 ? ` ${remSeconds} second${remSeconds === 1 ? '' : 's'}` : '';
    return `${mStr}${sStr}`;
  }
  return `${remSeconds} second${remSeconds === 1 ? '' : 's'}`;
}

/**
 * Check citizen report submission quota for the rolling 24-hour window.
 *
 * @param {string} userId - User UUID
 * @param {object} [options]
 * @param {object} [options.client] - Supabase client override
 * @param {object} [options.redis] - Redis client override
 * @param {number} [options.now] - Current timestamp override
 * @returns {Promise<{
 *   allowed: boolean,
 *   limit: number,
 *   used: number,
 *   remaining: number,
 *   resetAt: string,
 *   resetInSeconds: number,
 *   countdown: string,
 *   warning: string | null
 * }>}
 */
export async function checkUserReportQuota(userId, options = {}) {
  const client = options.client || db;
  const now = options.now || Date.now();
  const limit = await getDailyReportQuota(client);
  const windowDurationMs = 24 * 60 * 60 * 1000; // 24 hours rolling
  const windowStartMs = now - windowDurationMs;
  const windowStartIso = new Date(windowStartMs).toISOString();

  // Try Redis sorted set if available
  const activeRedis = options.redis !== undefined ? options.redis : (isRedisReady ? getQuotaRedisClient() : null);
  if (activeRedis && typeof activeRedis.zRemRangeByScore === 'function') {
    try {
      const key = `report_quota:${userId}`;
      await activeRedis.zRemRangeByScore(key, 0, windowStartMs);
      const used = await activeRedis.zCard(key);

      if (used >= limit) {
        // Fetch earliest submission in window for reset time
        const oldestEntries = await activeRedis.zRangeWithScores(key, 0, 0);
        const earliestMs = oldestEntries?.[0]?.score || windowStartMs;
        const resetAtMs = earliestMs + windowDurationMs;
        const resetInSeconds = Math.max(1, Math.ceil((resetAtMs - now) / 1000));
        const countdown = formatCountdown(resetInSeconds);

        return {
          allowed: false,
          limit,
          used,
          remaining: 0,
          resetAt: new Date(resetAtMs).toISOString(),
          resetInSeconds,
          countdown,
          warning: `Daily report submission limit reached (${limit} reports per day). Your quota will reset in ${countdown}.`,
        };
      }
    } catch {
      // Fall through to database check on Redis error
    }
  }

  // Database check: query reports submitted by user within rolling 24 hours
  try {
    const { data: userReports, error } = await client
      .from('reports')
      .select('id, created_at')
      .eq('user_id', userId)
      .gte('created_at', windowStartIso)
      .order('created_at', { ascending: true });

    if (error) throw error;

    const count = userReports?.length || 0;
    const allowed = count < limit;
    const remaining = Math.max(0, limit - count);

    let resetAtMs = now + windowDurationMs;
    if (userReports && userReports.length > 0) {
      // The earliest report in the window dictates when the next quota slot frees up
      const earliestCreated = new Date(userReports[0].created_at).getTime();
      resetAtMs = earliestCreated + windowDurationMs;
    }
    const resetInSeconds = Math.max(0, Math.ceil((resetAtMs - now) / 1000));
    const countdown = formatCountdown(resetInSeconds);

    let warning = null;
    if (!allowed) {
      warning = `Daily report submission limit reached (${limit} reports per day). Your quota will reset in ${countdown}.`;
    } else if (remaining <= 2 && remaining > 0) {
      warning = `You have ${remaining} report${remaining === 1 ? '' : 's'} remaining for today.`;
    }

    return {
      allowed,
      limit,
      used: count,
      remaining,
      resetAt: new Date(resetAtMs).toISOString(),
      resetInSeconds,
      countdown,
      warning,
    };
  } catch (dbErr) {
    console.error('Error querying report quota from database:', dbErr);
    // Fail open in case of unexpected DB error with default limit
    return {
      allowed: true,
      limit,
      used: 0,
      remaining: limit,
      resetAt: new Date(now + windowDurationMs).toISOString(),
      resetInSeconds: Math.floor(windowDurationMs / 1000),
      countdown: '24 hours',
      warning: null,
    };
  }
}

/**
 * Record a report submission in Redis to keep the fast-path counter warm.
 */
export async function recordReportSubmission(userId, reportId, createdAt = new Date(), options = {}) {
  const activeRedis = options.redis !== undefined ? options.redis : (isRedisReady ? getQuotaRedisClient() : null);
  if (!activeRedis || typeof activeRedis.zAdd !== 'function') return;

  try {
    const key = `report_quota:${userId}`;
    const score = new Date(createdAt).getTime();
    const value = `${reportId || score}:${score}`;
    await activeRedis.zAdd(key, [{ score, value }]);
    await activeRedis.expire(key, 86400); // 24 hours TTL
  } catch {
    // Secondary caching operation, silent fail
  }
}
