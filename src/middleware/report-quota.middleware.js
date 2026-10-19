import { checkUserReportQuota } from '../services/reportQuota.service.js';

/**
 * Middleware that enforces daily report submission quotas for citizen accounts (WT-97).
 * Checks the quota before processing media uploads, rejecting with 429 and a user-friendly
 * countdown warning if the citizen has exhausted their daily allotment.
 */
export async function enforceReportSubmissionQuota(req, res, next) {
  // Staff roles (admin, officer, field_crew) are exempt from citizen submission limits
  if (req.user?.role && req.user.role !== 'citizen') {
    return next();
  }

  const userId = req.user?.id;
  if (!userId) {
    return next();
  }

  try {
    const quota = await checkUserReportQuota(userId);

    // Set standard rate limit headers
    res.set('X-RateLimit-Limit', String(quota.limit));
    res.set('X-RateLimit-Remaining', String(quota.remaining));
    res.set('X-RateLimit-Reset', String(Math.floor(new Date(quota.resetAt).getTime() / 1000)));

    if (!quota.allowed) {
      res.set('Retry-After', String(quota.resetInSeconds));
      return res.status(429).json({
        error: 'Daily report submission quota exceeded',
        message: quota.warning,
        quota: quota.limit,
        used: quota.used,
        remaining: 0,
        resetAt: quota.resetAt,
        retryAfterSeconds: quota.resetInSeconds,
        countdown: quota.countdown,
      });
    }

    req.reportQuota = quota;
    next();
  } catch (error) {
    console.error('Error enforcing report submission quota:', error);
    // Fail open on unexpected error so citizens can still submit critical reports
    next();
  }
}
