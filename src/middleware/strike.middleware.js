import { supabaseAdmin } from "../config/supabase.config.js";

// Middleware to check if user is suspended
export const checkSuspension = async (req, res, next) => {
    try {
        const userId = req.user.id;

        // Fetch user's suspension status
        const { data: profile, error } = await supabaseAdmin
            .from('profiles')
            .select('suspended_until, strike_count')
            .eq('id', userId)
            .single();

        if (error) {
            console.error('Failed to check suspension status:', error);
            // Allow request to proceed if we can't check suspension
            return next();
        }

        const suspendedUntil = profile.suspended_until ? new Date(profile.suspended_until) : null;
        const now = new Date();
        const isSuspended = suspendedUntil && suspendedUntil > now;

        if (isSuspended) {
            // Calculate remaining suspension time
            const remainingMs = suspendedUntil - now;
            const remainingHours = Math.ceil(remainingMs / (1000 * 60 * 60));
            const remainingDays = Math.ceil(remainingHours / 24);

            let timeRemaining;
            if (remainingDays > 1) {
                timeRemaining = `${remainingDays} days`;
            } else if (remainingHours > 1) {
                timeRemaining = `${remainingHours} hours`;
            } else {
                timeRemaining = 'less than an hour';
            }

            return res.status(403).json({
                error: 'Account suspended',
                message: `Your account has been suspended due to multiple strikes. Suspension ends in ${timeRemaining}.`,
                suspended_until: profile.suspended_until,
                strike_count: profile.strike_count
            });
        }

        // User is not suspended, proceed
        next();
    } catch (error) {
        console.error('Error checking suspension:', error);
        // Allow request to proceed if there's an error
        next();
    }
};

// Middleware to check if user has too many strikes (warning level)
export const checkStrikeCount = async (req, res, next) => {
    try {
        const userId = req.user.id;

        // Fetch user's strike count
        const { data: profile, error } = await supabaseAdmin
            .from('profiles')
            .select('strike_count')
            .eq('id', userId)
            .single();

        if (error) {
            console.error('Failed to check strike count:', error);
            return next();
        }

        const strikeCount = profile.strike_count || 0;

        // Add strike count to request for potential use in controllers
        req.strikeCount = strikeCount;

        // If user has 2 or more strikes, add a warning header
        if (strikeCount >= 2) {
            res.setHeader('X-Strike-Warning', `You have ${strikeCount} active strike(s). Further violations may result in suspension.`);
        }

        next();
    } catch (error) {
        console.error('Error checking strike count:', error);
        next();
    }
};

// Middleware to automatically expire old strikes
export const expireOldStrikes = async (req, res, next) => {
    try {
        const userId = req.user.id;

        // Find expired strikes
        const now = new Date().toISOString();
        const { data: expiredStrikes, error } = await supabaseAdmin
            .from('strikes')
            .select('id')
            .eq('user_id', userId)
            .eq('is_active', true)
            .lt('expires_at', now);

        if (error) {
            console.error('Failed to find expired strikes:', error);
            return next();
        }

        // If there are expired strikes, deactivate them
        if (expiredStrikes && expiredStrikes.length > 0) {
            const expiredIds = expiredStrikes.map(s => s.id);
            
            await supabaseAdmin
                .from('strikes')
                .update({ is_active: false })
                .in('id', expiredIds);

            // Recalculate strike count
            const { data: activeStrikes } = await supabaseAdmin
                .from('strikes')
                .select('id')
                .eq('user_id', userId)
                .eq('is_active', true)
                .gte('expires_at', now);

            const activeStrikeCount = activeStrikes?.length || 0;

            await supabaseAdmin
                .from('profiles')
                .update({ 
                    strike_count: activeStrikeCount,
                    updated_at: now
                })
                .eq('id', userId);

            // If strike count dropped below suspension threshold, lift suspension
            if (activeStrikeCount < 2) {
                const { data: profile } = await supabaseAdmin
                    .from('profiles')
                    .select('suspended_until')
                    .eq('id', userId)
                    .single();

                if (profile.suspended_until) {
                    await supabaseAdmin
                        .from('profiles')
                        .update({ 
                            suspended_until: null,
                            updated_at: now
                        })
                        .eq('id', userId);
                }
            }
        }

        next();
    } catch (error) {
        console.error('Error expiring old strikes:', error);
        next();
    }
};
