import nodemailer from 'nodemailer';
import { SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS } from './index.js';

console.log(`[SMTP Config] Initializing Nodemailer transporter...`);
console.log(`[SMTP Config] HOST: ${SMTP_HOST}, PORT: ${SMTP_PORT}, USER: ${SMTP_USER}`);

export const transporter = nodemailer.createTransport({
    host: SMTP_HOST,
    port: SMTP_PORT,
    secure: SMTP_PORT == 465, // true for 465, false for other ports
    auth: {
        user: SMTP_USER,
        pass: SMTP_PASS,
    },
});

// Verify connection on startup
transporter.verify((error, success) => {
    if (error) {
        console.error('[SMTP Config] ❌ Transporter connection failed on startup:', error);
    } else {
        console.log('[SMTP Config] ✅ Transporter is ready to take our messages!');
    }
});
