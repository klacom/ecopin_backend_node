/**
 * photo_dedup.service.js  —  Phase 5 server-side photo deduplication
 *
 * Computes the SHA-256 hash of an uploaded file buffer and checks whether
 * the same hash is already stored for the target entity/slot.
 *
 * If an identical hash is found the upload is short-circuited:
 *   • The existing CDN URL is returned as-is.
 *   • No storage write is performed.
 *   • The response status is 'duplicate' so the client can update its local
 *     FcLocalPhotos row with the definitive remote URL without re-uploading.
 *
 * If the hash differs from what is stored, the caller proceeds with the
 * normal upload and then calls storePhotoHash() to persist the new hash.
 *
 * This covers the "two users add the same photo" scenario from the Phase 5
 * spec: identical binary content → same hash → no duplicate CDN asset.
 * Different photos have different hashes and are both accepted normally.
 */

import { createHash } from 'node:crypto';
import { supabaseAdmin as supabase } from '../config/supabase.config.js';

/**
 * Computes the SHA-256 hex digest of a Buffer or Uint8Array.
 *
 * @param {Buffer} buffer
 * @returns {string}  40-char lowercase hex string
 */
export function hashBuffer(buffer) {
  return createHash('sha256').update(buffer).digest('hex');
}

/**
 * Checks whether the given hash is already stored for this entity/slot.
 *
 * @param {'reports'|'cleanup_tasks'} table
 * @param {string} entityId
 * @param {'before'|'after'} photoType
 * @param {string} incomingHash  SHA-256 hex of the incoming upload buffer
 * @returns {Promise<{isDuplicate: boolean, existingUrl: string|null}>}
 */
export async function checkPhotoDuplicate(table, entityId, photoType, incomingHash) {
  const hashCol = `${photoType}_photo_hash`;
  const urlCol  = `${photoType}_photo_url`;

  const { data, error } = await supabase
    .from(table)
    .select(`${hashCol}, ${urlCol}`)
    .eq('id', entityId)
    .maybeSingle();

  if (error || !data) {
    // If we can't read the entity, let the upload proceed (fail-open).
    return { isDuplicate: false, existingUrl: null };
  }

  const storedHash = data[hashCol];
  const existingUrl = data[urlCol];

  if (storedHash && storedHash === incomingHash && existingUrl) {
    return { isDuplicate: true, existingUrl };
  }

  return { isDuplicate: false, existingUrl: null };
}

/**
 * Persists the SHA-256 hash after a successful upload.
 * Non-throwing — hash storage failures must not fail the upload response.
 *
 * @param {'reports'|'cleanup_tasks'} table
 * @param {string} entityId
 * @param {'before'|'after'} photoType
 * @param {string} hash
 */
export async function storePhotoHash(table, entityId, photoType, hash) {
  const hashCol = `${photoType}_photo_hash`;
  const { error } = await supabase
    .from(table)
    .update({ [hashCol]: hash })
    .eq('id', entityId);

  if (error) {
    console.error(`[photo_dedup] storePhotoHash failed for ${entityId}:`, error.message);
  }
}
