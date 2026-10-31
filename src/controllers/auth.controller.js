import { assertPasswordPolicy, getPasswordPolicy } from '../services/password-policy.service.js';
// Authentication controller for the EcoPin backend API server. 
// Handles user registration, login, logout, token refresh, and password reset.

import { supabase, supabaseAdmin } from "../config/supabase.config.js";
import { MOBILE_REDIRECT_URL, FRONTEND_URL } from "../config/index.js";
import { generateVerificationToken, sendVerificationEmail } from "../services/email.service.js";
import { renderVerificationHtml } from '../services/verification-template.service.js';
import { createHash } from 'node:crypto';
import { invalidateToken } from "../services/auth-cache.service.js";
import { verifyJwtToken } from "../services/jwt-verifier.service.js";

// Helper function to log audit action
export const logAuditAction = async (userId, actionType, actionDetails, ipAddress = null, userAgent = null) => {
    try {
        await supabaseAdmin
            .from('system_logs')
            .insert({
                user_id: userId,
                action_type: actionType,
                action_details: actionDetails,
                ip_address: ipAddress,
                user_agent: userAgent
            });
    } catch (error) {
        console.error('Failed to log system audit action:', error);
        // Don't throw error - logging is secondary to main operation
    }
};

// TODO: Add Validation here
export const register = async (req, res, next) => {
    const { email, password } = req.body;

    try {
        await assertPasswordPolicy(password, supabaseAdmin);
        console.log(`Attempting to register user: ${email}`);
        const { data, error } = await supabaseAdmin.auth.admin.createUser({
            email,
            password,
            email_confirm: false
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
            const token = await generateVerificationToken(data.user.id, email);
            if (token) await sendVerificationEmail(email, token);
        } catch {
            console.error('Registration verification email failed');
            // Registration remains recoverable through resend; never log SMTP credentials.
        }

        // Log user creation
    const ipAddress = req.ip || req.connection?.remoteAddress || null;
    const userAgent = typeof req.get === 'function' ? req.get('user-agent') : (req.headers?.['user-agent'] || null);
        await logAuditAction(data.user.id, 'user_created', 'User registered', ipAddress, userAgent);

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
    const ipAddress = req.ip || req.connection?.remoteAddress || null;
    const userAgent = typeof req.get === 'function' ? req.get('user-agent') : (req.headers?.[ 'user-agent'] || null);

    if (!email || !password) {
        return res.status(400).json({
            message: 'Email and password are required',
            error: 'Missing required credentials'
        });
    }

    try {
        const { data, error } = await supabase.auth.signInWithPassword({
            email,
            password
        });

        if (error) {
            let userFriendlyMessage = 'Invalid email or password. Please check your credentials and try again.';
            const errMsg = (error.message || '').toLowerCase();

            if (errMsg.includes('email not confirmed')) {
                userFriendlyMessage = 'Email not verified. Please check your inbox for the confirmation link.';
            } else if (errMsg.includes('too many requests') || errMsg.includes('rate limit')) {
                userFriendlyMessage = 'Too many login attempts. Please wait a few moments and try again.';
            }

            return res.status(401).json({
                message: userFriendlyMessage,
                error: error.message
            });
        }

        // Fetch role and verification status from profiles table
        const { data: profile, error: profileError } = await supabaseAdmin
            .from('profiles')
            .select('role, is_email_verified, require_password_change, suspended_until')
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

        // Check if user is suspended
        if (profile.suspended_until && new Date(profile.suspended_until) > new Date()) {
            await supabase.auth.signOut();
            return res.status(403).json({
                message: `Your account is temporarily suspended until ${new Date(profile.suspended_until).toLocaleString()}.`,
                code: 'ACCOUNT_SUSPENDED',
                suspended_until: profile.suspended_until
            });
        }

        // Check if email is verified — treat false OR null as unverified
        if (profile.is_email_verified !== true) {
            // Sign the user out since they shouldn't be logged in
            await supabase.auth.signOut();
            return res.status(403).json({
                message: 'Email not verified. Please check your inbox for the verification link.',
                code: 'EMAIL_NOT_VERIFIED'
            });
        }

        if (profile.require_password_change === true) {
            return res.status(200).json({
                message: 'Password change required',
                requirePasswordChange: true,
                session: data.session,
                user: {
                    ...data.user,
                    role: profile?.role || 'citizen'
                },
                token: data.session.access_token
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
        const authHeader = req.headers.authorization;
        if (authHeader?.startsWith('Bearer ')) {
            invalidateToken(authHeader.split(' ')[1]);
        }
    const ipAddress = req.ip || req.connection?.remoteAddress || null;
    const userAgent = typeof req.get === 'function' ? req.get('user-agent') : (req.headers?.['user-agent'] || null);
        if (req.user && req.user.id) {
            await logAuditAction(req.user.id, 'logout', 'User logged out', ipAddress, userAgent);
        }
        res.status(200).json({ message: 'Logout Successful' });
    } catch (error) {
        next(error);
    }
};

export const refreshToken = async (req, res, next) => {
    try {
        const { refresh_token } = req.body;
        if (!refresh_token) {
            return res.status(400).json({ message: 'Refresh token is required' });
        }

        const { data, error } = await supabase.auth.refreshSession({ refresh_token });

        if (error) {
            return res.status(401).json({ message: 'Failed to refresh token', error: error.message });
        }

        res.status(200).json({ 
            message: 'Token refreshed successfully',
            session: data.session,
            token: data.session.access_token
        });
    } catch (error) {
        next(error);
    }
};

export const forgotPassword = async (req, res, next) => {
    // Always answer the same way so the endpoint cannot be used to discover which emails have accounts.
    const generic = { message: 'If an account exists for that email, a password reset link has been sent.' };
    try {
        const email = typeof req.body?.email === 'string' ? req.body.email.trim().toLowerCase() : '';
        if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
            return res.status(400).json({ message: 'Enter a valid email address.' });
        }
        const { error } = await supabase.auth.resetPasswordForEmail(email, {
            redirectTo: `${FRONTEND_URL}/reset-password`
        });
        if (error) console.warn('[Auth] resetPasswordForEmail failed:', error.message);
        res.status(200).json(generic);
    } catch (error) {
        next(error);
    }
};

export const resetPassword = async (req, res, next) => {
    // `token` is the short-lived recovery access token delivered in the emailed link.
    const { token, password } = req.body || {};
    const ipAddress = req.ip || req.connection?.remoteAddress || null;
    const userAgent = typeof req.get === 'function' ? req.get('user-agent') : (req.headers?.['user-agent'] || null);

    try {
        await assertPasswordPolicy(password, supabaseAdmin);
        if (typeof token !== 'string' || !token) {
            return res.status(400).json({ message: 'This reset link is invalid or has expired. Request a new one.' });
        }
        const { data: found, error: tokenError } = await supabaseAdmin.auth.getUser(token);
        if (tokenError || !found?.user) {
            return res.status(400).json({ message: 'This reset link is invalid or has expired. Request a new one.' });
        }
        const { error } = await supabaseAdmin.auth.admin.updateUserById(found.user.id, { password });

        if (error) {
            return res.status(400).json({
                message: 'Password reset failed',
                error: error.message
            });
        }

        // Log password change event
        await logAuditAction(found.user.id, 'password_change', `User reset password`, ipAddress, userAgent);

        res.status(200).json({ message: 'Password reset successful' });
    } catch (error) {
        next(error);
    }
};

export const changePassword = async (req, res, next) => {
    const { current_password, new_password } = req.body;
    const ipAddress = req.ip || req.connection?.remoteAddress || null;
    const userAgent = typeof req.get === 'function' ? req.get('user-agent') : (req.headers?.['user-agent'] || null);

    try {
        await assertPasswordPolicy(new_password, supabaseAdmin);
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

export const forceChangePassword = async (req, res, next) => {
    const { new_password } = req.body;
    const ipAddress = req.ip || req.connection?.remoteAddress || null;
    const userAgent = typeof req.get === 'function' ? req.get('user-agent') : (req.headers?.['user-agent'] || null);

    if (!new_password) {
        return res.status(400).json({ message: 'New password is required' });
    }

    try {
        await assertPasswordPolicy(new_password, supabaseAdmin);
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

        // Clear the require_password_change flag
        await supabaseAdmin
            .from('profiles')
            .update({ require_password_change: false })
            .eq('id', req.user.id);

        // Invalidate current temporary token from fast cache upon password change
        const authHeader = req.headers.authorization;
        if (authHeader?.startsWith('Bearer ')) {
            invalidateToken(authHeader.split(' ')[1]);
        }

        // Log password change event
        await logAuditAction(req.user.id, 'password_change', `User changed password upon login`, ipAddress, userAgent);

        res.status(200).json({ message: 'Password changed successfully' });
    } catch (error) {
        next(error);
    }
};

// Lightweight session validation - cryptographically verifies JWT signature, algorithm allowlist (HS256), issuer, and expiry
export const validateSession = async (req, res, next) => {
    try {
        const authHeader = req.headers.authorization;
        
        if (!authHeader || !authHeader.startsWith('Bearer ')) {
            return res.status(401).json({ valid: false, message: 'No token provided' });
        }

        const token = authHeader.split(' ')[1];

        const verification = verifyJwtToken(token);
        if (!verification.valid) {
            return res.status(401).json({
                valid: false,
                expired: verification.expired || false,
                message: verification.message || 'Session validation failed'
            });
        }

        res.status(200).json({ valid: true, message: 'Session valid', user: verification.payload });
    } catch (error) {
        res.status(401).json({ valid: false, message: 'Session validation failed' });
    }
};

export const verifyEmail = async (req, res, next) => {
    const { token } = req.query;
    res.set('Cache-Control', 'no-store');

    if (typeof token !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(token)) {
        return res.status(400).send('Verification token is required');
    }

    try {
        // 1. Find token by digest (backward-compatible across migrated and unmigrated live schemas)
        const tokenDigest = createHash('sha256').update(token.toLowerCase()).digest('hex');
        let fetchResult = await supabaseAdmin
            .from('email_verifications')
            .select('id,user_id,issued_to_email,expires_at,used_at')
            .eq('token_digest', tokenDigest)
            .maybeSingle();

        if (fetchResult.error && (fetchResult.error.code === '42703' || fetchResult.error.message?.includes('issued_to_email'))) {
            // Graceful fallback for unmigrated live database where issued_to_email does not exist
            fetchResult = await supabaseAdmin
                .from('email_verifications')
                .select('id,user_id,expires_at,used_at')
                .eq('token_digest', tokenDigest)
                .maybeSingle();
        }

        if (fetchResult.error || !fetchResult.data) {
            return res.status(400).send(renderVerificationHtml('Invalid or expired token', false));
        }

        const verificationData = fetchResult.data;

        // 2. Check if already used
        if (verificationData.used_at) {
            return res.status(400).send(renderVerificationHtml('Email already verified or link has already been used. You can log in.', false));
        }

        // 4. Fetch authoritative Auth user state
        const { data: userData, error: userError } = await supabaseAdmin.auth.admin.getUserById(verificationData.user_id);
        if (userError || !userData?.user) {
            return res.status(503).send(renderVerificationHtml('Account not found for this verification link.', false));
        }

        if (userData.user.id !== verificationData.user_id) {
            return res.status(503).send(renderVerificationHtml('Verification is temporarily unavailable.', false));
        }
        const currentAuthEmail = userData.user.email?.toLowerCase().trim();
        if (!currentAuthEmail) {
            return res.status(400).send(renderVerificationHtml('No active email found for this account.', false));
        }

        if (!verificationData.issued_to_email) {
            return res.status(400).send(renderVerificationHtml('Please request a new verification link.', false));
        }

        // Validate bound email address if recorded on token
        if (verificationData.issued_to_email) {
            const boundEmail = verificationData.issued_to_email.toLowerCase().trim();
            if (currentAuthEmail !== boundEmail) {
                // Changed email rejects the old link
                return res.status(400).send(renderVerificationHtml('Verification link is not valid for the current account email.', false));
            }
        }

        // Final authoritative email check, Auth confirmation, profile and token writes
        // occur together. A missing migration fails closed rather than using the old race.
        const rpcResult = await supabaseAdmin.rpc('redeem_email_verification_atomic', {
            p_verification_id: verificationData.id,
            p_user_id: verificationData.user_id,
            p_expected_email: currentAuthEmail
        });
        const { data: completed, error: completionError } = rpcResult;

        if (completionError) {
            // Database transient failure: do not fake rollback with email_confirm: false.
            // Leave token unconsumed so the user can safely retry and converge.
            console.error('Database completion error during verification', {
                code: completionError.code || 'UNKNOWN'
            });
            return res.status(503).send(renderVerificationHtml('Verification is temporarily unavailable. Please try this link again.', false));
        }

        if (completed !== true) {
            // Token was already consumed, expired, or invalid.
            // Do not attempt invalid Auth unconfirmation; winner's confirmation is preserved.
            return res.status(400).send(renderVerificationHtml('Invalid, expired, already used link, or incomplete account setup.', false));
        }

        // 7. Return success HTML with deep link
        return res.status(200).send(renderVerificationHtml('Email verified successfully!', true));
    } catch (error) {
        console.error('Email verification failed');
        return res.status(500).send(renderVerificationHtml('An error occurred during verification.', false));
    }
};

export const resendVerification = async (req, res, next) => {
    const { email } = req.body ?? {};

    if (!email) {
        return res.status(400).json({ message: 'Email is required' });
    }

    if (typeof email !== 'string' || email.length > 320) {
        return res.status(400).json({ message: 'Invalid email' });
    }
    const normalizedEmail = email.trim().toLowerCase();
    if (normalizedEmail.length > 254 || !/^[^\s@]+@[^\s@]+$/.test(normalizedEmail)) {
        return res.status(400).json({ message: 'Invalid email' });
    }

    try {
        const { data: userId, error: lookupError } = await supabaseAdmin.rpc(
            'find_email_verification_user', { p_email: normalizedEmail }
        );
        if (lookupError) throw lookupError;
        if (!userId) {
            // Return 200 to not leak existence of user
            return res.status(200).json({ message: 'If an account exists, a verification email has been sent.' });
        }

        // Generate and send new token with bound email
        const token = await generateVerificationToken(userId, normalizedEmail);
        if (token) await sendVerificationEmail(normalizedEmail, token);

        return res.status(200).json({ message: 'If an account exists, a verification email has been sent.' });
    } catch (error) {
        console.error('Verification resend failed', { code: /^[A-Z0-9_]{1,24}$/.test(error?.code ?? '') ? error.code : 'UNKNOWN' });
        return res.status(200).json({ message: 'If an account exists, a verification email has been sent.' });
    }
};

export const getPasswordRequirements = async (req, res, next) => {
    try { res.status(200).json(await getPasswordPolicy(supabaseAdmin)); }
    catch (error) { next(error); }
};

export const deleteAccount = async (req, res, next) => {
    let signedOut = false;
    try {
        let userId = req.user?.id;
        let sessionToken = req.headers?.authorization?.startsWith('Bearer ')
            ? req.headers.authorization.slice(7) : null;
        const { email, password, confirmation } = req.body || {};

        // If no authenticated Bearer user, authenticate using provided credentials (e.g. from web deletion form)
        if (!userId) {
            if (!email || !password) {
                return res.status(400).json({
                    message: 'Email and password are required to verify account deletion.',
                    error: 'Missing credentials'
                });
            }

            const { data: authData, error: authError } = await supabase.auth.signInWithPassword({
                email: email.trim().toLowerCase(),
                password
            });

            if (authError || !authData?.user) {
                return res.status(401).json({
                    message: 'Invalid email or password.',
                    error: authError?.message || 'Authentication failed'
                });
            }

            userId = authData.user.id;
            sessionToken = authData.session?.access_token;
        }

        // Verify that the user has a citizen role (staff/officer accounts must be handled by administrative channels)
        const { data: profile, error: profileError } = await supabaseAdmin
            .from('profiles')
            .select('id, role')
            .eq('id', userId)
            .maybeSingle();

        if (profileError || profile?.role !== 'citizen') {
            return res.status(403).json({
                message: 'Self-service account deletion is only available for citizen accounts. Staff accounts must be managed through administrative channels.',
                error: 'Forbidden'
            });
        }

        if (confirmation !== 'I confirm') {
            return res.status(400).json({ message: 'Type "I confirm" to confirm permanent account deletion.' });
        }

        if (!sessionToken) {
            return res.status(401).json({ message: 'Sign in again before deleting your account.' });
        }

        // Revoke sessions before touching account data; stop if logout cannot be confirmed.
        const { error: signOutError } = await supabaseAdmin.auth.admin.signOut(sessionToken, 'global');
        if (signOutError) {
            return res.status(503).json({ message: 'Could not sign out your sessions. Account was not deleted. Please try again.' });
        }
        signedOut = true;
        invalidateToken(sessionToken, userId);

        const ipAddress = req.ip || req.connection?.remoteAddress || null;
        const userAgent = typeof req.get === 'function' ? req.get('user-agent') : (req.headers?.['user-agent'] || null);

        // 1. Anonymize user's waste reports to preserve municipal statistics and cleanup records
        // Setting user_id = null severs all personal identification while leaving location, waste category, resolution, etc. intact
        const { error: reportsError } = await supabaseAdmin
            .from('reports')
            .update({ user_id: null })
            .eq('user_id', userId);

        if (reportsError) {
            console.error('Failed to anonymize reports during account deletion:', reportsError);
            return res.status(500).json({
                signed_out: true,
                message: 'Failed to anonymize user reports for account deletion. Sign in again to retry.',
                error: reportsError.message
            });
        }

        // 2. Delete user profile from 'profiles' table
        const { error: profileDeleteError } = await supabaseAdmin
            .from('profiles')
            .delete()
            .eq('id', userId);

        if (profileDeleteError) {
            console.error('Failed to delete user profile during account deletion:', profileDeleteError);
            return res.status(500).json({
                signed_out: true,
                message: 'Failed to delete user profile. Sign in again to retry.',
                error: profileDeleteError.message
            });
        }

        // 3. Delete user from auth.users via Supabase Admin (removes auth credentials, cascades to notifications and email verifications)
        const { error: deleteAuthError } = await supabaseAdmin.auth.admin.deleteUser(userId);

        if (deleteAuthError) {
            console.error('Failed to delete user credentials from auth.users:', deleteAuthError);
            return res.status(500).json({
                signed_out: true,
                message: 'Failed to delete authentication credentials. Please contact support.',
                error: deleteAuthError.message
            });
        }

        // Invalidate token from cache if Bearer token was provided
        const authHeader = req.headers?.authorization;
        if (authHeader?.startsWith('Bearer ')) {
            invalidateToken(authHeader.split(' ')[1]);
        }

        // Log audit event (anonymized at system level)
        await logAuditAction(null, 'account_deletion', `Citizen account ${userId} permanently deleted and waste reports anonymized`, ipAddress, userAgent);

        return res.status(200).json({
            success: true,
            message: 'Account deleted successfully. Personal data removed and waste reports anonymized for public statistics.'
        });
    } catch (error) {
        if (signedOut) {
            return res.status(500).json({ signed_out: true, message: 'Deletion could not be completed. Please contact support.' });
        }
        next(error);
    }
};

