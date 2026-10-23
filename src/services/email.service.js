import { verificationEmailHtml } from './verification-template.service.js';
import { v4 as uuidv4 } from 'uuid';
import { createHash } from 'node:crypto';
import { supabaseAdmin } from '../config/supabase.config.js';
import { transporter } from '../config/email.config.js';
import { SMTP_FROM_NAME, SMTP_USER, APP_BASE_URL, EMAIL_VERIFICATION_EXPIRY_HOURS } from '../config/index.js';

/**
 * Generates a verification token; only its digest crosses the database boundary.
 * @param {string} userId - The Supabase user ID
 * @returns {Promise<string|null>} - Token, or null when issuance is deferred.
 */
export const generateVerificationToken = async (userId, email) => {
    if (typeof email !== 'string' || !email.trim()) throw new Error('Verification email binding is required');
    const token = uuidv4();
    const tokenDigest = createHash('sha256').update(token).digest('hex');
    const rpcParams = {
        p_user_id: userId,
        p_token_digest: tokenDigest,
        p_ttl_hours: EMAIL_VERIFICATION_EXPIRY_HOURS,
        p_email: email.trim().toLowerCase()
    };
    const { data, error } = await supabaseAdmin.rpc('issue_email_verification', rpcParams);

    if (error) {
        console.error('Error storing verification token', {
            code: /^[0-9A-Z]{5,12}$/.test(error?.code ?? '') ? error.code : 'UNKNOWN'
        });
        throw new Error('Failed to generate verification token');
    }

    return data ? token : null;
};

/**
 * Sends a branded verification email to the user
 * @param {string} toEmail - The recipient's email address
 * @param {string} token - The verification token
 */
export const sendVerificationEmail = async (toEmail, token) => {
    const verificationUrl = new URL('/api/auth/verify-email', APP_BASE_URL);
    if (process.env.NODE_ENV === 'production' && verificationUrl.protocol !== 'https:') {
        throw new Error('Verification emails require an HTTPS APP_BASE_URL');
    }
    verificationUrl.searchParams.set('token', token);
    await transporter.sendMail({
        from: `"${SMTP_FROM_NAME}" <${SMTP_USER}>`,
        to: toEmail,
        subject: 'Verify your EcoPin account',
        text: `Verify your email: ${verificationUrl.href}\nThis link expires in ${EMAIL_VERIFICATION_EXPIRY_HOURS} hours. Return to Ecopin and sign in after verifying.`,
        html: verificationEmailHtml(verificationUrl.href, EMAIL_VERIFICATION_EXPIRY_HOURS)
    });
};
