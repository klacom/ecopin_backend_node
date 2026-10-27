import { transporter } from '../config/email.config.js';
import { SMTP_FROM_NAME, SMTP_USER } from '../config/index.js';
/**
 * Send contact form email
 */
export const sendContactEmail = async (req, res) => {
    try {
        const { name, email, subject, message, recipient } = req.body;

        // Validate required fields
        if (!name || !email || !subject || !message) {
            return res.status(400).json({
                error: 'Missing required fields',
                message: 'Name, email, subject, and message are required'
            });
        }

        // Validate email format
        const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
        if (!emailRegex.test(email)) {
            return res.status(400).json({
                error: 'Invalid email',
                message: 'Please provide a valid email address'
            });
        }

        // Validate recipient dynamically against configured CMS settings
        let validRecipients = ['ecopinmail@gmail.com', 'swmo@pasigcity.gov.ph'];
        try {
            const { getCmsSettingsService } = await import('../services/cms.service.js');
            const cms = await getCmsSettingsService();
            validRecipients = [cms.contact_support_email, cms.contact_office_email].filter(value => typeof value === 'string' && value.trim());
            validRecipients = [...new Set(validRecipients.map(e => e.trim().toLowerCase()))];
        } catch (cmsErr) {
            console.warn('[Contact Controller] Could not fetch CMS recipients, using fallback:', cmsErr.message);
        }

        const toEmail = (recipient || validRecipients[0] || 'ecopinmail@gmail.com').trim().toLowerCase();
        if (!validRecipients.includes(toEmail)) {
            return res.status(400).json({
                error: 'Invalid recipient',
                message: 'Invalid recipient email address'
            });
        }

        // HTML Email Template
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
                        font-size: 24px;
                        font-weight: 600;
                        margin: 0 0 16px 0;
                        color: #111827;
                    }
                    .field {
                        margin-bottom: 20px;
                    }
                    .field-label {
                        font-size: 13px;
                        font-weight: 600;
                        color: #6B7280;
                        text-transform: uppercase;
                        letter-spacing: 0.5px;
                        margin-bottom: 4px;
                    }
                    .field-value {
                        font-size: 16px;
                        color: #1F2937;
                        padding: 12px;
                        background-color: #F9FAFB;
                        border-radius: 8px;
                        border: 1px solid #E5E7EB;
                    }
                    .message-content {
                        font-size: 16px;
                        line-height: 1.6;
                        color: #374151;
                        white-space: pre-wrap;
                        padding: 16px;
                        background-color: #F9FAFB;
                        border-radius: 8px;
                        border: 1px solid #E5E7EB;
                    }
                    .footer {
                        margin-top: 32px;
                        font-size: 14px;
                        color: #9CA3AF;
                        text-align: center;
                    }
                </style>
            </head>
            <body>
                <div class="container">
                    <div class="card">
                        <div class="logo">EcoPin</div>
                        <h1>New Contact Form Submission</h1>
                        
                        <div class="field">
                            <div class="field-label">From</div>
                            <div class="field-value">${name} (${email})</div>
                        </div>
                        
                        <div class="field">
                            <div class="field-label">Subject</div>
                            <div class="field-value">${subject}</div>
                        </div>
                        
                        <div class="field">
                            <div class="field-label">Message</div>
                            <div class="message-content">${message}</div>
                        </div>
                    </div>
                    <div class="footer">
                        <p>Sent via EcoPin Contact Form</p>
                        <p>&copy; ${new Date().getFullYear()} EcoPin. All rights reserved.</p>
                    </div>
                </div>
            </body>
            </html>
        `;

        const mailOptions = {
            from: `"${SMTP_FROM_NAME}" <${SMTP_USER}>`,
            to: toEmail,
            subject: `EcoPin Contact: ${subject}`,
            text: `From: ${name} (${email})\nSubject: ${subject}\n\n${message}`,
            html: htmlContent,
        };

        console.log(`[Contact] Sending email to ${toEmail} from ${name} (${email})`);
        const info = await transporter.sendMail(mailOptions);
        console.log(`[Contact] ✅ Email sent successfully! MessageId: ${info.messageId}`);

        res.status(200).json({
            message: 'Email sent successfully',
            recipient: toEmail
        });

    } catch (error) {
        console.error('[Contact] Error sending email:', error);
        console.error('[Contact] Error details:', {
            code: error.code,
            responseCode: error.responseCode,
            response: error.response
        });

        // Provide specific error messages based on error type
        let errorMessage = 'An error occurred while sending your message. Please try again later.';
        if (error.code === 'EAUTH') {
            errorMessage = 'Email service authentication failed. Please contact support.';
        } else if (error.code === 'ECONNECTION') {
            errorMessage = 'Could not connect to email service. Please try again later.';
        } else if (error.code === 'ETIMEDOUT') {
            errorMessage = 'Email service timed out. Please try again.';
        }

        res.status(500).json({
            error: 'Failed to send email',
            message: errorMessage
        });
    }
};
