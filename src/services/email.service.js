import { v4 as uuidv4 } from 'uuid';
import { supabaseAdmin } from '../config/supabase.config.js';
import { transporter } from '../config/email.config.js';
import { SMTP_FROM_NAME, SMTP_USER, APP_BASE_URL, EMAIL_VERIFICATION_EXPIRY_HOURS } from '../config/index.js';

/**
 * Generates a verification token and stores it in the database
 * @param {string} userId - The Supabase user ID
 * @returns {string} - The generated verification token
 */
export const generateVerificationToken = async (userId) => {
    const token = uuidv4();
    const expiresAt = new Date();
    expiresAt.setHours(expiresAt.getHours() + EMAIL_VERIFICATION_EXPIRY_HOURS);

    const { error } = await supabaseAdmin
        .from('email_verifications')
        .insert({
            user_id: userId,
            token: token,
            expires_at: expiresAt.toISOString(),
        });

    if (error) {
        console.error('Error storing verification token:', error);
        throw new Error('Failed to generate verification token');
    }

    return token;
};

/**
 * Sends a branded verification email to the user
 * @param {string} toEmail - The recipient's email address
 * @param {string} token - The verification token
 */
export const sendVerificationEmail = async (toEmail, token) => {
    const verificationUrl = `${APP_BASE_URL}/api/auth/verify-email?token=${token}`;
    
    // EcoPin Branded HTML Email Template
    const htmlContent = `
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <link rel="preconnect" href="https://fonts.googleapis.com">
            <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
            <link href="https://fonts.googleapis.com/css2?family=Outfit:wght@400;500;600;700&display=swap" rel="stylesheet">
            <style>
                body {
                    margin: 0;
                    padding: 0;
                    background-color: #F5F7FA;
                    font-family: 'Outfit', -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
                    color: #1A1A1A;
                    -webkit-font-smoothing: antialiased;
                }
                .container {
                    max-width: 600px;
                    margin: 0 auto;
                    padding: 40px 20px;
                }
                .card {
                    background-color: #FFFFFF;
                    border-radius: 16px;
                    padding: 40px;
                    text-align: center;
                    border: 1px solid #E5E7EB;
                    box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.05), 0 2px 4px -1px rgba(0, 0, 0, 0.03);
                }
                .logo {
                    font-size: 32px;
                    font-weight: 700;
                    color: #457113;
                    margin-bottom: 24px;
                    letter-spacing: -0.5px;
                }
                h1 {
                    font-size: 28px;
                    font-weight: 600;
                    margin: 0 0 16px 0;
                    color: #111827;
                }
                p {
                    font-size: 16px;
                    line-height: 1.6;
                    color: #4B5563;
                    margin: 0 0 32px 0;
                }
                .btn {
                    display: inline-block;
                    background-color: #457113;
                    color: #FFFFFF;
                    text-decoration: none;
                    font-weight: 600;
                    font-size: 16px;
                    padding: 16px 32px;
                    border-radius: 12px;
                    transition: background-color 0.2s ease;
                }
                .btn:hover {
                    background-color: #365A0F;
                }
                .footer {
                    margin-top: 32px;
                    font-size: 14px;
                    color: #9CA3AF;
                    text-align: center;
                }
                .link {
                    color: #457113;
                    word-break: break-all;
                }
            </style>
        </head>
        <body>
            <div class="container">
                <div class="card">
                    <div class="logo">EcoPin</div>
                    <h1>Verify your email</h1>
                    <p>Welcome to EcoPin! To finish setting up your account, please confirm your email address by clicking the button below.</p>
                    <a href="${verificationUrl}" class="btn">Verify Email Address</a>
                    <p style="margin-top: 32px; font-size: 14px; color: #888888;">
                        Or copy and paste this link into your browser:<br>
                        <a href="${verificationUrl}" class="link">${verificationUrl}</a>
                    </p>
                </div>
                <div class="footer">
                    <p>If you didn't request this email, you can safely ignore it.</p>
                    <p>&copy; ${new Date().getFullYear()} EcoPin. All rights reserved.</p>
                </div>
            </div>
        </body>
        </html>
    `;

    const mailOptions = {
        from: `"${SMTP_FROM_NAME}" <${SMTP_USER}>`,
        to: toEmail,
        subject: 'Verify your EcoPin account',
        text: `Welcome to EcoPin! Verify your email address by clicking this link: ${verificationUrl}`,
        html: htmlContent,
    };

    try {
        const info = await transporter.sendMail(mailOptions);
        console.log('Verification email sent: %s', info.messageId);
    } catch (error) {
        console.error('Error sending verification email:', error);
        throw new Error('Failed to send verification email');
    }
};
