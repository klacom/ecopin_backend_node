// Authentication controller for the EcoPin backend API server. 
// Handles user registration, login, logout, token refresh, and password reset.

import { supabase, supabaseAdmin } from "../config/supabase.config.js";
import { MOBILE_REDIRECT_URL } from "../config/index.js";
import { generateVerificationToken, sendVerificationEmail } from "../services/email.service.js";

// Helper function to log audit action
export const logAuditAction = async (userId, actionType, actionDetails, ipAddress = null, userAgent = null) => {
    try {
        await supabaseAdmin
            .from('audit_logs')
            .insert({
                user_id: userId,
                action_type: actionType,
                action_details: actionDetails,
                ip_address: ipAddress,
                user_agent: userAgent
            });
    } catch (error) {
        console.error('Failed to log audit action:', error);
        // Don't throw error - logging is secondary to main operation
    }
};

// TODO: Add Validation here
export const register = async (req, res, next) => {
    const { email, password } = req.body;

    try {
        console.log(`Attempting to register user: ${email}`);
        const { data, error } = await supabaseAdmin.auth.signUp({
            email,
            password
        });
        
        console.log(`Supabase signUp response - data.user: ${data?.user ? 'exists' : 'null'}, error: ${error ? error.message : 'none'}`);

        if (error) {
            console.error('Supabase signUp error:', error);
            return res.status(400).json({
                message: 'Registration failed',
                error: error.message
            });
        }

        if (!data?.user) {
             console.error('Supabase signUp succeeded but data.user is null (User likely already exists)');
             return res.status(400).json({
                 message: 'Registration failed: User may already exist'
             });
        }

        // Ensure profile is created in 'profiles' table with default role and unverified email
        const { error: profileError } = await supabaseAdmin
            .from('profiles')
            .upsert({
                id: data.user.id,
                full_name: data.user.email.split('@')[0], // Use email username as default full_name
                role: 'citizen',
                is_email_verified: false
            });

        if (profileError) {
            console.error('Failed to create/update profile during registration:', profileError);
        }

        // Generate and send verification email
        try {
            const token = await generateVerificationToken(data.user.id);
            await sendVerificationEmail(email, token);
        } catch (emailError) {
            console.error('Failed to send verification email:', emailError);
            // We don't fail the registration, but they won't be able to log in. 
            // They can use resend later.
        }

        res.status(201).json({
            message: 'Registration successful. Please check your email to verify your account.',
            user: {
                ...data.user,
                role: 'citizen'
            }
        });
    } catch (error) {
        next(error);
    }
};

export const login = async (req, res, next) => {
    const { email, password } = req.body;
    const ipAddress = req.ip || req.connection.remoteAddress;
    const userAgent = req.get('user-agent');

    try {
        const { data, error } = await supabase.auth.signInWithPassword({
            email,
            password
        });

        if (error) {
            return res.status(401).json({
                message: 'Login failed',
                error: error.message
            });
        }

        // Fetch role and verification status from profiles table
        const { data: profile, error: profileError } = await supabaseAdmin
            .from('profiles')
            .select('role, is_email_verified')
            .eq('id', data.user.id)
            .single();

        // Fail-secure: if profile row is missing or fetch failed, block login.
        // This prevents users who bypassed the trigger from slipping through.
        if (profileError || !profile) {
            await supabase.auth.signOut();
            return res.status(403).json({
                message: 'Account setup incomplete. Please contact support.',
                code: 'PROFILE_NOT_FOUND'
            });
        }

        // Check if email is verified — treat false OR null as unverified
        if (profile.is_email_verified !== true) {
            // Sign the user out since they shouldn't be logged in
            await supabase.auth.signOut();
            return res.status(403).json({
                message: 'Email not verified. Please check your inbox.',
                code: 'EMAIL_NOT_VERIFIED'
            });
        }

        // Log login event
        await logAuditAction(data.user.id, 'login', `User logged in`, ipAddress, userAgent);

        res.status(200).json({
            message: 'Login Successful',
            session: data.session,
            user: {
                ...data.user,
                role: profile?.role || 'citizen'
            },
            token: data.session.access_token
        });
    } catch (error) {
        next(error);
    }
};

// req.user is already populated by the authenticate middleware
export const getMe = async (req, res, next) => {
    try {
        // Fetch full profile data including avatar_url
        const { data: profile, error: profileError } = await supabaseAdmin
            .from('profiles')
            .select('*')
            .eq('id', req.user.id)
            .single();

        if (profileError) {
            // Return basic user data if profile fetch fails
            return res.status(200).json({
                user: req.user
            });
        }

        // Merge profile data with user data
        res.status(200).json({
            user: {
                ...req.user,
                ...profile
            }
        });
    } catch (error) {
        next(error);
    }
};

// Global signout is handled by the client
// But keep these just in case
 
export const logout = async (req, res, next) => {
    try {
        res.status(200).json({ message: 'Logout Successful' });
    } catch (error) {
        next(error);
    }
};

export const refreshToken = async (req, res, next) => {
    try {
        res.status(200).json({ message: 'Refresh token endpoint' });
    } catch (error) {
        next(error);
    }
};

export const forgotPassword = async (req, res, next) => {
    try {
        res.status(200).json({ message: 'Forgot password endpoint' });
    } catch (error) {
        next(error);
    }
};

export const resetPassword = async (req, res, next) => {
    const { token, password } = req.body;
    const ipAddress = req.ip || req.connection.remoteAddress;
    const userAgent = req.get('user-agent');

    try {
        const { data, error } = await supabaseAdmin.auth.updateUser(token, {
            password
        });

        if (error) {
            return res.status(400).json({
                message: 'Password reset failed',
                error: error.message
            });
        }

        // Log password change event
        await logAuditAction(data.user.id, 'password_change', `User reset password`, ipAddress, userAgent);

        res.status(200).json({ message: 'Password reset successful' });
    } catch (error) {
        next(error);
    }
};

export const changePassword = async (req, res, next) => {
    const { current_password, new_password } = req.body;
    const ipAddress = req.ip || req.connection.remoteAddress;
    const userAgent = req.get('user-agent');

    try {
        // First verify current password by attempting to sign in
        const { data: signInData, error: signInError } = await supabase.auth.signInWithPassword({
            email: req.user.email,
            password: current_password
        });

        if (signInError) {
            return res.status(400).json({
                message: 'Current password is incorrect',
                error: 'Invalid current password'
            });
        }

        // Update password using the admin client
        const { data, error } = await supabaseAdmin.auth.admin.updateUserById(req.user.id, {
            password: new_password
        });

        if (error) {
            return res.status(400).json({
                message: 'Password change failed',
                error: error.message
            });
        }

        // Log password change event
        await logAuditAction(req.user.id, 'password_change', `User changed password`, ipAddress, userAgent);

        res.status(200).json({ message: 'Password changed successfully' });
    } catch (error) {
        next(error)
    }
};

// Lightweight session validation - JWT only, no database operations
export const validateSession = async (req, res, next) => {
    try {
        const authHeader = req.headers.authorization;
        
        if (!authHeader || !authHeader.startsWith('Bearer ')) {
            return res.status(401).json({ valid: false, message: 'No token provided' });
        }

        const token = authHeader.split(' ')[1];

        // Decode and validate JWT only (no database lookup for free tier optimization)
        try {
            const parts = token.split('.');
            if (parts.length !== 3) {
                return res.status(401).json({ valid: false, message: 'Invalid token format' });
            }

            const payload = JSON.parse(atob(parts[1]));
            const currentTime = Math.floor(Date.now() / 1000);

            if (payload.exp && payload.exp < currentTime) {
                return res.status(401).json({ valid: false, expired: true, message: 'Token expired' });
            }

            res.status(200).json({ valid: true, message: 'Session valid' });
        } catch (jwtError) {
            return res.status(401).json({ valid: false, message: 'Invalid token format' });
        }
    } catch (error) {
        res.status(401).json({ valid: false, message: 'Session validation failed' });
    }
};

export const verifyEmail = async (req, res, next) => {
    const { token } = req.query;

    if (!token) {
        return res.status(400).send('Verification token is required');
    }

    try {
        // 1. Find token
        const { data: verificationData, error: fetchError } = await supabaseAdmin
            .from('email_verifications')
            .select('*')
            .eq('token', token)
            .single();

        if (fetchError || !verificationData) {
            return res.status(400).send(renderVerificationHtml('Invalid or expired token', false));
        }

        // 2. Check if already used
        if (verificationData.used_at) {
            return res.status(400).send(renderVerificationHtml('Email already verified. You can log in.', false));
        }

        // 3. Check expiry
        if (new Date(verificationData.expires_at) < new Date()) {
            return res.status(400).send(renderVerificationHtml('Verification link has expired. Please request a new one.', false));
        }

        // 4. Update verification record
        await supabaseAdmin
            .from('email_verifications')
            .update({ used_at: new Date().toISOString() })
            .eq('id', verificationData.id);

        // 5. Update profile
        await supabaseAdmin
            .from('profiles')
            .update({ is_email_verified: true })
            .eq('id', verificationData.user_id);

        // 6. Update Supabase Auth user (optional, but good practice for sync)
        await supabaseAdmin.auth.admin.updateUserById(verificationData.user_id, { email_confirm: true });

        // 7. Return success HTML with deep link
        return res.status(200).send(renderVerificationHtml('Email verified successfully!', true));
    } catch (error) {
        console.error('Error in verifyEmail:', error);
        return res.status(500).send(renderVerificationHtml('An error occurred during verification.', false));
    }
};

export const resendVerification = async (req, res, next) => {
    const { email } = req.body;

    if (!email) {
        return res.status(400).json({ message: 'Email is required' });
    }

    try {
        // Find user by email
        const { data: { users }, error: authError } = await supabaseAdmin.auth.admin.listUsers();
        if (authError) throw authError;

        const user = users.find(u => u.email === email);
        
        if (!user) {
            // Return 200 to not leak existence of user
            return res.status(200).json({ message: 'If an account exists, a verification email has been sent.' });
        }

        // Check profile
        const { data: profile } = await supabaseAdmin
            .from('profiles')
            .select('is_email_verified')
            .eq('id', user.id)
            .single();

        if (profile && profile.is_email_verified) {
            return res.status(400).json({ message: 'Email is already verified.' });
        }

        // Generate and send new token
        const token = await generateVerificationToken(user.id);
        await sendVerificationEmail(email, token);

        return res.status(200).json({ message: 'Verification email resent successfully.' });
    } catch (error) {
        next(error);
    }
};

// Helper function to render simple HTML page for deep link redirect
const renderVerificationHtml = (message, isSuccess) => {
    const color = isSuccess ? '#85D22D' : '#D32F2F';
    const redirectUrl = `ecopin://auth/verified`;
    
    return `
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
                body {
                    background-color: #000000;
                    color: #FFFFFF;
                    font-family: -apple-system, system-ui, sans-serif;
                    display: flex;
                    flex-direction: column;
                    align-items: center;
                    justify-content: center;
                    height: 100vh;
                    margin: 0;
                    text-align: center;
                    padding: 20px;
                }
                .card {
                    background: #121212;
                    padding: 30px;
                    border-radius: 16px;
                    border: 1px solid #2C2C2C;
                    max-width: 400px;
                    width: 100%;
                }
                h2 { color: ${color}; }
                .btn {
                    display: inline-block;
                    margin-top: 20px;
                    padding: 12px 24px;
                    background-color: #85D22D;
                    color: #000000;
                    text-decoration: none;
                    border-radius: 8px;
                    font-weight: bold;
                }
            </style>
        </head>
        <body>
            <div class="card">
                <h2>${isSuccess ? 'Success' : 'Oops'}</h2>
                <p>${message}</p>
                ${isSuccess ? `<a href="${redirectUrl}" class="btn">Open App</a>` : ''}
            </div>
            ${isSuccess ? `
            <script>
                setTimeout(() => {
                    window.location.href = '${redirectUrl}';
                }, 1500);
            </script>
            ` : ''}
        </body>
        </html>
    `;
};

export const getPasswordRequirements = async (req, res, next) => {
    try {
        const { data, error } = await supabaseAdmin
            .from('system_settings')
            .select('password_min_length, password_require_uppercase, password_require_lowercase, password_require_numbers, password_require_special_chars')
            .single();

        if (error) {
            // Return defaults if not found
            return res.status(200).json({
                password_min_length: 8,
                password_require_uppercase: true,
                password_require_lowercase: true,
                password_require_numbers: true,
                password_require_special_chars: true
            });
        }

        res.status(200).json(data);
    } catch (error) {
        next(error);
    }
};
