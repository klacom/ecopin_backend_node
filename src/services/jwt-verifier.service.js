import jwt from 'jsonwebtoken';
import * as config from '../config/index.js';

const getJwtSecret = () => config.JWT_SECRET || process.env.JWT_SECRET;
const getSupabaseUrl = () => config.NEXT_PUBLIC_SUPABASE_URL || process.env.NEXT_PUBLIC_SUPABASE_URL;

const KNOWN_WEAK_SECRETS = new Set([
    'secret',
    'your_jwt_secret',
    'your-jwt-secret',
    'change_this',
    'changeme',
    'supersecret',
    'password',
    'development_secret',
    'default_secret',
    '12345678',
    '1234567890',
    '12345678901234567890123456789012'
]);

/**
 * Calculates Shannon entropy and character distribution metrics for a given secret.
 */
export const calculateEntropy = (str) => {
    if (!str || typeof str !== 'string') {
        return { entropyPerChar: 0, totalEntropy: 0, uniqueChars: 0 };
    }
    const len = str.length;
    const freqs = {};
    for (let i = 0; i < len; i++) {
        const c = str[i];
        freqs[c] = (freqs[c] || 0) + 1;
    }
    let entropy = 0;
    for (const c in freqs) {
        const p = freqs[c] / len;
        entropy -= p * Math.log2(p);
    }
    return {
        entropyPerChar: entropy,
        totalEntropy: entropy * len,
        uniqueChars: Object.keys(freqs).length
    };
};

/**
 * Validates that a JWT_SECRET meets strict cryptographic entropy standards (>= 256 bits).
 * Supports hex strings (>= 64 chars), base64/raw strings (>= 32 bytes),
 * and verifies high Shannon entropy without weak placeholders.
 */
export const validateJwtSecretEntropy = (...args) => {
    const secret = args.length > 0 ? args[0] : getJwtSecret();
    if (!secret || typeof secret !== 'string') {
        return { valid: false, reason: 'JWT_SECRET is missing or not a string', bitLength: 0 };
    }

    const trimmed = secret.trim();
    if (KNOWN_WEAK_SECRETS.has(trimmed.toLowerCase())) {
        return { valid: false, reason: 'JWT_SECRET is a known weak or placeholder secret', bitLength: 0 };
    }

    const isHex = /^[0-9a-fA-F]+$/.test(trimmed);
    let byteLength = 0;

    if (isHex) {
        // Each 2 hex characters represent 1 byte (8 bits)
        byteLength = Math.floor(trimmed.length / 2);
    } else {
        // Fallback to buffer byte length
        byteLength = Buffer.byteLength(trimmed, 'utf8');
    }

    const bitLength = byteLength * 8;
    if (bitLength < 256) {
        return {
            valid: false,
            reason: `JWT_SECRET entropy is insufficient (${bitLength} bits < 256 bits required)`,
            bitLength
        };
    }

    const metrics = calculateEntropy(trimmed);
    const minEntropyPerChar = isHex ? 3.0 : 3.5;
    const minUniqueChars = isHex ? 10 : 16;

    if (metrics.entropyPerChar < minEntropyPerChar || metrics.uniqueChars < minUniqueChars) {
        return {
            valid: false,
            reason: `JWT_SECRET has low Shannon entropy (${metrics.entropyPerChar.toFixed(2)} bits/char, ${metrics.uniqueChars} unique symbols)`,
            bitLength,
            metrics
        };
    }

    return {
        valid: true,
        bitLength,
        metrics
    };
};

/**
 * Asserts that the secret meets entropy requirements or throws an error.
 */
export const assertStrongJwtSecret = (...args) => {
    const secret = args.length > 0 ? args[0] : getJwtSecret();
    const result = validateJwtSecretEntropy(secret);
    if (!result.valid) {
        throw new Error(`Insecure JWT_SECRET: ${result.reason}`);
    }
    return true;
};

/**
 * Verifies that two environment secrets are not reused across environments.
 */
export const verifyEnvironmentSecretSeparation = (backendSecret, webSecret) => {
    if (!backendSecret || !webSecret) return false;
    return backendSecret.trim() !== webSecret.trim();
};

/**
 * Resolves standard allowed issuers for Supabase Auth / EcoPin authority.
 */
export const getDefaultAllowedIssuers = () => {
    const issuers = ['supabase'];
    const supabaseUrl = getSupabaseUrl();
    if (supabaseUrl) {
        issuers.push(`${supabaseUrl.replace(/\/+$/, '')}/auth/v1`);
    }
    if (process.env.JWT_ISSUER) {
        issuers.push(process.env.JWT_ISSUER);
    }
    return Array.from(new Set(issuers));
};

/**
 * Cryptographically verifies a JWT with strict algorithm allowlist ('HS256'),
 * valid issuer check, and expiration check.
 */
export const verifyJwtToken = (token, options = {}) => {
    const secret = options.secret || getJwtSecret();
    const allowedAlgorithms = options.algorithms || ['HS256'];
    const allowedIssuers = options.issuer || getDefaultAllowedIssuers();
    const clockTolerance = options.clockTolerance || 0;

    // Check secret strength first
    const secretCheck = validateJwtSecretEntropy(secret);
    if (!secretCheck.valid) {
        return {
            valid: false,
            expired: false,
            message: `Cryptographic authority configuration error: ${secretCheck.reason}`
        };
    }

    if (!token || typeof token !== 'string') {
        return { valid: false, expired: false, message: 'Token is missing or not a string' };
    }

    // Pre-flight header inspection to prevent algorithm substitution
    let decoded;
    try {
        decoded = jwt.decode(token, { complete: true });
    } catch {
        return { valid: false, expired: false, message: 'Invalid token format' };
    }

    if (!decoded || !decoded.header || !decoded.payload) {
        return { valid: false, expired: false, message: 'Invalid token format' };
    }

    // Explicitly check algorithm allowlist before verification
    if (!allowedAlgorithms.includes(decoded.header.alg)) {
        return {
            valid: false,
            expired: false,
            message: `Disallowed JWT algorithm: ${decoded.header.alg}. Allowed: ${allowedAlgorithms.join(', ')}`
        };
    }

    try {
        const payload = jwt.verify(token, secret, {
            algorithms: allowedAlgorithms,
            issuer: allowedIssuers,
            clockTolerance
        });

        return {
            valid: true,
            expired: false,
            payload,
            header: decoded.header
        };
    } catch (err) {
        if (err.name === 'TokenExpiredError') {
            return {
                valid: false,
                expired: true,
                message: 'Token expired',
                expiredAt: err.expiredAt
            };
        }
        if (err.name === 'JsonWebTokenError') {
            return {
                valid: false,
                expired: false,
                message: `Invalid token: ${err.message}`
            };
        }
        return {
            valid: false,
            expired: false,
            message: 'Session validation failed'
        };
    }
};

/**
 * Helper to sign a JWT token strictly using HS256 and enforcing standard claims.
 */
export const signJwtToken = (payload, options = {}) => {
    const secret = options.secret || getJwtSecret();
    assertStrongJwtSecret(secret);

    const expiresIn = options.expiresIn || '1h';
    const issuer = options.issuer || 'supabase';

    return jwt.sign(payload, secret, {
        algorithm: 'HS256',
        expiresIn,
        issuer,
        ...options.jwtOptions
    });
};
