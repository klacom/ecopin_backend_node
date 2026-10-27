import { randomUUID } from 'node:crypto';
import { supabaseAdmin } from '../config/supabase.config.js';

const fields = new Set(['lead_photo_url', 'gallery_photo_1_url', 'gallery_photo_2_url', 'app_download_url']);
const types = { apk: 'application/vnd.android.package-archive', jpg: 'image/jpeg', jpeg: 'image/jpeg', png: 'image/png', webp: 'image/webp', svg: 'image/svg+xml' };
const invalid = message => Object.assign(new Error(message), { statusCode: 400 });

function description(body) {
    const { fieldKey, fileName, size } = body;
    const extension = typeof fileName === 'string' ? fileName.split('.').pop().toLowerCase() : '';
    const apk = fieldKey === 'app_download_url';
    if (!fields.has(fieldKey) || !types[extension] || apk !== (extension === 'apk')) throw invalid('Choose an APK for app downloads or a JPG, PNG, WebP, or SVG for a photo field.');
    const maximum = (apk ? 100 : 10) * 1024 * 1024;
    if (!Number.isSafeInteger(size) || size <= 0 || size > maximum) throw invalid(`File must be smaller than ${apk ? 100 : 10} MB.`);
    return { fieldKey, extension, size, contentType: types[extension] };
}

export async function prepareCmsUpload(actor, body, client = supabaseAdmin) {
    const file = description(body);
    const { data: bucket, error: bucketError } = await client.storage.getBucket('cms-media');
    if (bucketError) throw bucketError;
    if (!bucket?.public) throw invalid('CMS media must use the configured public storage bucket.');
    if (bucket.file_size_limit && file.size > bucket.file_size_limit) throw invalid('This file exceeds the configured CMS storage limit.');
    const path = `cms/${file.fieldKey}/${actor}/${randomUUID()}.${file.extension}`;
    const { data, error } = await client.storage.from('cms-media').createSignedUploadUrl(path, { upsert: false });
    if (error) throw error;
    return { path, uploadToken: data.token, bucket: 'cms-media', contentType: file.contentType };
}

export async function completeCmsUpload(actor, body, client = supabaseAdmin) {
    const file = description(body);
    const prefix = `cms/${file.fieldKey}/${actor}/`;
    if (typeof body.path !== 'string' || !body.path.startsWith(prefix) || !new RegExp(`^[0-9a-f-]{36}\\.${file.extension}$`).test(body.path.slice(prefix.length))) throw invalid('Invalid CMS upload path.');
    const storage = client.storage.from('cms-media');
    const { data, error } = await storage.info(body.path);
    if (error) throw error;
    if (Number(data.size ?? data.metadata?.size) !== file.size || (data.contentType ?? data.metadata?.mimetype) !== file.contentType) throw invalid('Uploaded file does not match the selected file. Please upload it again.');
    return { url: storage.getPublicUrl(body.path).data.publicUrl, fileName: body.path.split('/').pop() };
}
