import { supabaseAdmin } from '../config/supabase.config.js';

const CMS_BUCKET = 'cms-media';
const CMS_FILE = 'settings.json';

export const DEFAULT_CMS_SETTINGS = {
    // Contact & Office Information
    contact_support_email: 'ecopinmail@gmail.com',
    contact_office_email: 'swmo@pasigcity.gov.ph',
    contact_phone: '09173726888',
    contact_office_name: 'Pasig Solid Waste Management Office (SWMO)',
    contact_office_address: 'Pasig City Hall Complex, Caruncho Ave, Pasig, Metro Manila',
    contact_operating_hours: 'Monday – Friday: 8:00 AM – 5:00 PM',
    contact_facebook_url: 'https://www.facebook.com/PasigPIO',
    contact_facebook_label: 'Pasig City Public Information Office',

    // Media & Community Showcase
    lead_story_title: 'From reports to response.',
    lead_story_subtitle: 'Meet the field crews of Pasig’s Solid Waste Management Office (SWMO), working on the ground to collect waste and clear neighborhood streets.',
    lead_photo_url: '/images/community/street-cleanup.jpg',
    lead_photo_caption: 'Pasig Solid Waste Management Office',
    lead_photo_tagline: 'On the ground. Getting it done.',
    lead_photo_credit_name: 'Pasig Tayo (Jonah Talagtag)',
    lead_photo_credit_url: 'https://www.facebook.com/share/p/19hk6BA5W8/',

    gallery_photo_1_url: '/images/community/neighborhood-team.jpg',
    gallery_photo_1_caption: 'SWMO crews collecting waste.',

    gallery_photo_2_url: '/images/community/working-together.jpg',
    gallery_photo_2_caption: 'Working together to clear bulky debris.',

    // Public Announcement / Advisory Banner
    announcement_enabled: false,
    announcement_title: 'Notice to Residents',
    announcement_message: 'Regular waste collection schedules may be adjusted during inclement weather. Check your barangay advisories for real-time updates.',
    announcement_severity: 'info', // 'info' | 'warning' | 'urgent'
    announcement_link_url: '',
    announcement_link_text: 'Read advisory',

    // App Distribution & Downloads
    app_download_url: '/ecopin-app-release.apk',
    app_version_name: 'v1.0.0',
    app_release_notes: 'EcoPin official Android release for verified Pasig residents.',
    app_playstore_url: '',

    // Public System Notice
    maintenance_mode: false,
    maintenance_notice: 'The reporting service is currently undergoing scheduled maintenance. Please check back shortly.'
};

let cachedCmsSettings = null;
let cacheTimestamp = 0;
const CACHE_TTL_MS = 60 * 1000; // 1 minute in-memory cache

/**
 * Get CMS settings (with fallback to default if not yet created in storage)
 */
export async function getCmsSettingsService() {
    const now = Date.now();
    if (cachedCmsSettings && (now - cacheTimestamp < CACHE_TTL_MS)) {
        return cachedCmsSettings;
    }

    try {
        const { data, error } = await supabaseAdmin.storage
            .from(CMS_BUCKET)
            .download(CMS_FILE);

        if (error || !data) {
            // If file doesn't exist, return defaults and initialize asynchronously
            cachedCmsSettings = { ...DEFAULT_CMS_SETTINGS };
            cacheTimestamp = now;
            await saveCmsSettingsService(DEFAULT_CMS_SETTINGS).catch(err => {
                console.warn('[CMS Service] Initial settings seeding notice:', err.message);
            });
            return cachedCmsSettings;
        }

        const text = await data.text();
        const parsed = JSON.parse(text);
        cachedCmsSettings = { ...DEFAULT_CMS_SETTINGS, ...parsed };
        cacheTimestamp = now;
        return cachedCmsSettings;
    } catch (err) {
        console.error('[CMS Service] Failed to read cms settings:', err);
        return { ...DEFAULT_CMS_SETTINGS };
    }
}

/**
 * Save / Update CMS settings
 */
export async function saveCmsSettingsService(updatedSettings) {
    const merged = {
        ...DEFAULT_CMS_SETTINGS,
        ...(cachedCmsSettings || {}),
        ...updatedSettings,
        updated_at: new Date().toISOString()
    };

    const payload = Buffer.from(JSON.stringify(merged, null, 2), 'utf-8');

    const { error } = await supabaseAdmin.storage
        .from(CMS_BUCKET)
        .upload(CMS_FILE, payload, {
            contentType: 'application/json',
            upsert: true
        });

    if (error) {
        throw new Error(`Failed to upload cms settings: ${error.message}`);
    }

    cachedCmsSettings = merged;
    cacheTimestamp = Date.now();
    return merged;
}

/**
 * Invalidate cache
 */
export function invalidateCmsCache() {
    cachedCmsSettings = null;
    cacheTimestamp = 0;
}
