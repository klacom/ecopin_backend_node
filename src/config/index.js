// Config

import dotenv from 'dotenv';

dotenv.config();

export const NODE_ENV = process.env.NODE_ENV || 'development';
export const PORT = process.env.PORT || 3000;
export const FRONTEND_URL = process.env.FRONTEND_URL || 'http://localhost:3001';
export const MOBILE_REDIRECT_URL = process.env.MOBILE_REDIRECT_URL || 'ecopin://auth/callback';
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

export const CLEANUP_TASK_PHOTOS_STORAGE_PATH = 'Cleanup Task Photos';
export const VALID_STATUSES = ['unresolved', 'in_progress', 'resolved'];


// Environmental Issue Categories and related keywords for MobileNet
export const ISSUE_CATEGORIES = {
    waste: ['garbage', 'trash', 'litter', 'plastic', 'debris', 'dump', 'waste', 'bottle', 'can'],
    flooding: ['flood', 'water', 'submerged', 'river', 'inundation', 'lake'],
    pollution: ['smoke', 'smog', 'oil', 'slick', 'dirty', 'pollution', 'factory', 'industrial'],
};

// Valid Scene Keywords for MobileNet
export const VALID_SCENES = ['street', 'road', 'river', 'park', 'beach', 'canal', 'residential', 'outdoor', 'ground', 'pavement'];

// Invalid Scene Keywords for MobileNet
export const INVALID_SCENES = ['bedroom', 'living room', 'kitchen', 'office', 'screenshot', 'document', 'meme', 'drawing', 'cartoon'];

// Object Detection Keywords for COCO-SSD
export const OBJECT_KEYWORDS = {
    waste: ['bottle', 'cup', 'handbag', 'suitcase', 'backpack'], // COCO-SSD limited set, mapping trash-like items
    flooding: ['boat', 'car', 'truck', 'bus'], // Items often submerged or in water
    pollution: ['train', 'truck', 'car'] // Associated with emissions/oil
};

// File size limits for different uploads
export const BEFORE_AFTER_PHOTO_FILE_SIZE = 10 * 1024 * 1024; // 10MB
export const EVIDENCE_PHOTO_FILE_SIZE = 10 * 1024 * 1024; // 10MB
export const PROFILE_FILE_SIZE = 3 * 1024 * 1024; // 3MB
export const VALID_IMAGE_MIME_TYPES = ['image/jpeg', 'image/jpg', 'image/png', 'image/webp'];
export const VALID_IMAGE_EXTENSIONS = ['jpeg', 'jpg', 'png', 'webp'];
export const REPORT_MIN_PHOTOS = 1;
export const REPORT_MAX_PHOTOS = 5;
export const REPORT_TOTAL_PHOTOS_SIZE = 10 * 1024 * 1024; // 10MB total

