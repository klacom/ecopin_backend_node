// Authentication controller for the EcoPin backend API server. 
// Handles user registration, login, logout, token refresh, and password reset.

import { supabase, supabaseAdmin } from "../config/supabase.config.js";
import { MOBILE_REDIRECT_URL } from "../config/index.js";

// Helper function to log audit action
const logAuditAction = async (userId, actionType, actionDetails, ipAddress = null, userAgent = null) => {
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
        const { data, error } = await supabaseAdmin.auth.signUp({
            email,
            password
        });

        if (error) {
            return res.status(400).json({
                message: 'Registration failed',
                error: error.message
            });
        }

        // Ensure profile is created in 'profiles' table with default role
        const { error: profileError } = await supabaseAdmin
            .from('profiles')
            .upsert({
                id: data.user.id,
                email: data.user.email,
                full_name: data.user.email.split('@')[0], // Use email username as default full_name
                role: 'citizen'
            });

        res.status(201).json({
            message: 'Register Successful',
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

        // Fetch role from profiles table
        const { data: profile } = await supabaseAdmin
            .from('profiles')
            .select('role')
            .eq('id', data.user.id)
            .single();

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
