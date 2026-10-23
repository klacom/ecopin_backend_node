// Uses express-rate-limit to define rate limiting rules for incoming requests to prevent abuse and protect against brute-force attacks.
// Provides a general rate limiter for all API routes and a stricter limiter specifically for authentication-related endpoints.

import { createHash } from 'node:crypto';
import rateLimit, { ipKeyGenerator } from 'express-rate-limit';
import { RATE_LIMIT_WINDOW_MS, RATE_LIMIT_MAX_REQUESTS, OPS_RATE_LIMIT_MAX_REQUESTS } from '../config/index.js';

function normalizedClientIpKey(req) {
    return ipKeyGenerator(req.ip || req.socket?.remoteAddress || '127.0.0.1');
}

export function resolveGeneralRateLimitKey(req) {
    const authHeader = req.headers?.authorization;
    if (typeof authHeader === 'string' && authHeader.startsWith('Bearer ')) {
        const token = authHeader.slice(7).trim();
        if (token.length > 0 && token.length <= 8192) {
            const digest = createHash('sha256').update(token).digest('hex').slice(0, 32);
            return `bearer:${digest}`;
        }
    }
    return `ip:${normalizedClientIpKey(req)}`;
}

export function resolveAuthRateLimitKey(req) {
    const ipKey = normalizedClientIpKey(req);
    const rawEmail = typeof req.body?.email === 'string' ? req.body.email.trim().toLowerCase() : '';
    if (rawEmail.length > 0 && rawEmail.length <= 320) {
        const emailDigest = createHash('sha256').update(rawEmail).digest('hex').slice(0, 32);
        return `auth:${ipKey}:${emailDigest}`;
    }
    return `auth:${ipKey}`;
}

const AUTH_DEDICATED_PATHS = new Set([
    '/api/auth/login',
    '/api/auth/register',
    '/api/auth/forgot-password',
    '/api/auth/reset-password',
    '/api/auth/resend-verification',
]);

// General rate limiter for API routes
export const rateLimiter = rateLimit({
    windowMs: parseInt(RATE_LIMIT_WINDOW_MS, 10),
    max: parseInt(RATE_LIMIT_MAX_REQUESTS, 10),
    keyGenerator: resolveGeneralRateLimitKey,
    message: {
        error: 'Too many requests, please try again later.',
        message: 'Too many requests, please try again later.',
        retryAfter: Math.ceil(RATE_LIMIT_WINDOW_MS / 1000 / 60) + ' minutes'
    },
    standardHeaders: true, // Return rate limit info in the `RateLimit-*` headers
    legacyHeaders: false,
    // Optimization and auth endpoints have their own dedicated limiters
    skip: (req) => {
        const rawPath = (req.originalUrl || req.baseUrl + (req.path || '') || req.url || '').split('?')[0];
        return rawPath.startsWith('/api/optimization') || AUTH_DEDICATED_PATHS.has(rawPath);
    }
});

// Dedicated higher-capacity limiter for operational desk/officer optimization workflows
export const operationalRateLimiter = rateLimit({
    windowMs: parseInt(RATE_LIMIT_WINDOW_MS, 10),
    max: parseInt(OPS_RATE_LIMIT_MAX_REQUESTS, 10),
    keyGenerator: resolveGeneralRateLimitKey,
    message: {
        error: 'Too many requests, please try again later.',
        message: 'Operational request threshold exceeded. Please retry in a few moments.',
        retryAfter: '1 minute'
    },
    standardHeaders: true,
    legacyHeaders: false,
});

// Stricter limiter for auth endpoints, scoped per (client IP, email) so one user or BFF proxy does not lock out others
export const authRateLimiter = rateLimit({
    windowMs: 15 * 60 * 1000, // 15 minutes
    max: 10, // 10 failed attempts per 15 minutes per (IP, email)
    keyGenerator: resolveAuthRateLimitKey,
    message: { error: 'Too many authentication attempts, please try again later.' },
    standardHeaders: true,
    legacyHeaders: false,
    skipSuccessfulRequests: true, // Don't count successful logins
});

// A separate instance avoids counting contact requests twice in the global store.
export const contactRateLimiter = rateLimit({
    windowMs: 15 * 60 * 1000,
    max: 3,
    keyGenerator: (req) => `contact:${normalizedClientIpKey(req)}`,
    message: 'Too many contact form submissions, please try again later.',
    standardHeaders: true,
    legacyHeaders: false,
});
