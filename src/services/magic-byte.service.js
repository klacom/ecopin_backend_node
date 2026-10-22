/**
 * Magic byte detection and file validation service.
 * Inspects binary buffers to determine true file type and verify consistency with declared MIME types.
 */

export const ALLOWED_IMAGE_TYPES = {
  'image/jpeg': {
    extensions: ['jpg', 'jpeg'],
    match: buffer => buffer.length >= 3 && buffer[0] === 0xff && buffer[1] === 0xd8 && buffer[2] === 0xff,
  },
  'image/png': {
    extensions: ['png'],
    match: buffer => buffer.length >= 8 &&
      buffer[0] === 0x89 && buffer[1] === 0x50 && buffer[2] === 0x4e && buffer[3] === 0x47 &&
      buffer[4] === 0x0d && buffer[5] === 0x0a && buffer[10] === 0x1a && buffer[11] === 0x0a,
  },
  'image/webp': {
    extensions: ['webp'],
    match: buffer => buffer.length >= 12 &&
      buffer.toString('ascii', 0, 4) === 'RIFF' &&
      buffer.toString('ascii', 8, 12) === 'WEBP',
  },
};

/**
 * Validates PNG magic bytes specifically (correct indices 0-7: 89 50 4E 47 0D 0A 1A 0A).
 */
function isPng(buffer) {
  if (buffer.length < 8) return false;
  return buffer[0] === 0x89 &&
    buffer[1] === 0x50 &&
    buffer[2] === 0x4e &&
    buffer[3] === 0x47 &&
    buffer[4] === 0x0d &&
    buffer[5] === 0x0a &&
    buffer[6] === 0x1a &&
    buffer[7] === 0x0a;
}

function isJpeg(buffer) {
  if (buffer.length < 3) return false;
  return buffer[0] === 0xff && buffer[1] === 0xd8 && buffer[2] === 0xff;
}

function isWebp(buffer) {
  if (buffer.length < 12) return false;
  return buffer.toString('ascii', 0, 4) === 'RIFF' &&
    buffer.toString('ascii', 8, 12) === 'WEBP';
}

/**
 * Returns detected MIME type from binary buffer, or null if unrecognized.
 */
export function detectImageMimeType(buffer) {
  if (!Buffer.isBuffer(buffer)) return null;
  if (isJpeg(buffer)) return 'image/jpeg';
  if (isPng(buffer)) return 'image/png';
  if (isWebp(buffer)) return 'image/webp';
  return null;
}

/**
 * Scans buffer for active HTML/SVG/script injection vectors disguised as images.
 */
export function hasDisallowedPayload(buffer) {
  if (!Buffer.isBuffer(buffer)) return true;
  // Inspect first 2048 bytes as text for HTML / XML / SVG / script signatures
  const sample = buffer.subarray(0, Math.min(buffer.length, 2048)).toString('utf8').toLowerCase();
  if (sample.includes('<html') ||
      sample.includes('<xml') ||
      sample.includes('<!doctype html') ||
      sample.includes('<svg') ||
      sample.includes('<script') ||
      sample.includes('onload=') ||
      sample.includes('onerror=') ||
      sample.includes('<?php') ||
      sample.includes('eval(')) {
    return true;
  }
  return false;
}

/**
 * Validates an uploaded file's binary buffer against allowed photo criteria.
 * Throws a 400 error if MIME type, magic bytes, or content are invalid or spoofed.
 */
export function validateUploadedPhotoBuffer(buffer, declaredMimeType) {
  if (!Buffer.isBuffer(buffer) || buffer.length === 0) {
    const error = new Error('Invalid or empty file buffer');
    error.statusCode = 400;
    throw error;
  }

  // Reject active payloads immediately
  if (hasDisallowedPayload(buffer)) {
    const error = new Error('File contains disallowed script or markup content (HTML/SVG/executable)');
    error.statusCode = 400;
    throw error;
  }

  const detected = detectImageMimeType(buffer);
  if (!detected) {
    const error = new Error('Invalid image format: binary signature (magic bytes) does not match JPEG, PNG, or WEBP');
    error.statusCode = 400;
    throw error;
  }

  if (declaredMimeType) {
    const normalizedDeclared = declaredMimeType.toLowerCase().trim();
    const isDeclaredJpeg = ['image/jpeg', 'image/jpg'].includes(normalizedDeclared);
    const isDetectedJpeg = detected === 'image/jpeg';

    if (isDeclaredJpeg && !isDetectedJpeg) {
      const error = new Error(`MIME type mismatch: declared ${declaredMimeType} but magic bytes indicate ${detected}`);
      error.statusCode = 400;
      throw error;
    }
    if (!isDeclaredJpeg && normalizedDeclared !== detected) {
      const error = new Error(`MIME type mismatch: declared ${declaredMimeType} but magic bytes indicate ${detected}`);
      error.statusCode = 400;
      throw error;
    }
  }

  return detected;
}
