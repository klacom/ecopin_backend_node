// Configuration file for the EcoPin backend API server. Loads environment variables from a .env file using dotenv and exports configuration values for use throughout the application. Includes settings for the server environment, port, frontend URL, Supabase credentials, JWT settings, and rate limiting parameters.

import dotenv from 'dotenv';

dotenv.config();

export const NODE_ENV = process.env.NODE_ENV || 'development';
export const PORT = process.env.PORT || 3000;
export const FRONTEND_URL = process.env.FRONTEND_URL || 'http://localhost:3001';
export const NEXT_PUBLIC_SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL;
export const SUPABASE_SERVICE_ROLE_KEY = process.env.NEXT_PUBLIC_SERVICE_ROLE_KEY;
export const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
export const JWT_SECRET = process.env.JWT_SECRET;
export const JWT_EXPIRES_IN = process.env.JWT_EXPIRES_IN || '7d';
export const RATE_LIMIT_WINDOW_MS = process.env.RATE_LIMIT_WINDOW_MS || 15 * 60 * 1000;
export const RATE_LIMIT_MAX_REQUESTS = process.env.RATE_LIMIT_MAX_REQUESTS || 100;
export const MIN_PASSWORD_LENGTH = 8;

export const VALIDATION_STATUS = {
    AUTOMATICALLY_VALID: 'automatically_valid',
    MANUAL_REVIEW: 'manual_review',
    REJECTED: 'rejected',
    PENDING: 'pending'
};

export const IMAGE_VALIDATION_WEIGHTS = {
    ISSUE_RELEVANCE: 0.4,
    OBJECT_EVIDENCE: 0.3,
    SCENE_CONTEXT: 0.2,
    IMAGE_QUALITY: 0.1
};

export const IMAGE_VALIDATION_THRESHOLDS = {
    VALID: 80,
    REVIEW: 60
};
