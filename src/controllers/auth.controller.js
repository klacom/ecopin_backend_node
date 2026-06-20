// Authentication controller for the EcoPin backend API server. 
// Handles user registration, login, logout, token refresh, and password reset.

import { supabase, supabaseAdmin } from "../config/supabase.config.js";
import { MOBILE_REDIRECT_URL } from "../config/index.js";

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
        res.status(200).json({
            user: req.user
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
    try {
        res.status(200).json({ message: 'Reset password endpoint' });
    } catch (error) {
        next(error);
    }
};
