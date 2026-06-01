// Rate limiting middleware for the EcoPin backend API server. Uses express-rate-limit to define rate limiting rules for incoming requests to prevent abuse and protect against brute-force attacks. Provides a general rate limiter for all routes and a stricter limiter specifically for authentication-related endpoints.

import rateLimit from 'express-rate-limit';
import { RATE_LIMIT_WINDOW_MS, RATE_LIMIT_MAX_REQUESTS } from '../config/index.js';

// General rate limiter for all routes
export const rateLimiter = rateLimit({
    windowMs: parseInt(RATE_LIMIT_WINDOW_MS),
    max: parseInt(RATE_LIMIT_MAX_REQUESTS),
    message: {
        error: 'Too many requests, please try again later.',
        retryAfter: Math.ceil(RATE_LIMIT_WINDOW_MS / 1000 / 60) + ' minutes'
    },
    standardHeaders: true, // Return rate limit info in the `RateLimit-*` headers
    legacyHeaders: false,
});

// Stricter limiter for auth endpoints
export const authRateLimiter = rateLimit({
    windowMs: 15 * 60 * 1000, // 15 minutes
    max: 5, // 5 attempts per 15 minutes
    message: { error: 'Too many authentication attempts, please try again later.' },
    skipSuccessfulRequests: true, // Don't count successful logins
});