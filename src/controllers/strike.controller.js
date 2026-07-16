import { supabase, supabaseAdmin } from "../config/supabase.config.js";

// Helper function to calculate suspension duration based on strike count and system settings
const calculateSuspensionDuration = async (strikeCount) => {
    try {
        const { data: settings, error } = await supabaseAdmin
            .from('system_settings')
            .select('*')
            .single();

        if (error) {
            console.error('Failed to fetch system settings:', error);
            // Return default values if settings fetch fails
            const defaultDurations = {
                1: null, // warning
                2: 24, // 24 hours
                3: 168, // 7 days
            };
            return defaultDurations[strikeCount] || null;
        }

        const actionMap = {
            1: settings.strike_1_action,
            2: settings.strike_2_action,
            3: settings.strike_3_action,
        };
        
        const durationMap = {
            2: settings.strike_2_duration_hours,
            3: settings.strike_3_duration_hours,
        };

        const action = actionMap[strikeCount] || settings.strike_4_action || 'permanent_ban';
        
        if (action === 'warning') {
            return null;
        } else if (action === 'suspend_24h') {
            return durationMap[2] || 24;
        } else if (action === 'suspend_7d') {
            return durationMap[3] || 168;
        } else if (action === 'permanent_ban') {
            return -1; // -1 indicates permanent ban
        }
        
        return null;
    } catch (error) {
        console.error('Error calculating suspension duration:', error);
        return null;
    }
};

// Helper function to update user's suspension status
const updateUserSuspension = async (userId, durationHours) => {
    try {
        let suspendedUntil = null;
        
        if (durationHours === -1) {
            // Permanent ban - set to a far future date
            suspendedUntil = new Date('2099-12-31').toISOString();
        } else if (durationHours && durationHours > 0) {
            const now = new Date();
            suspendedUntil = new Date(now.getTime() + durationHours * 60 * 60 * 1000).toISOString();
        }

        const { error } = await supabaseAdmin
            .from('profiles')
            .update({
                suspended_until: suspendedUntil,
                updated_at: new Date().toISOString()
            })
            .eq('id', userId);

        if (error) {
            console.error('Failed to update user suspension:', error);
            throw error;
        }

        return suspendedUntil;
    } catch (error) {
        console.error('Error updating user suspension:', error);
        throw error;
    }
};

// Helper function to update user's strike count
const updateUserStrikeCount = async (userId) => {
    try {
        // Count active strikes for the user
        const { data: strikes, error: strikesError } = await supabaseAdmin
            .from('strikes')
            .select('id')
            .eq('user_id', userId)
            .eq('is_active', true)
            .gte('expires_at', new Date().toISOString());

        if (strikesError) {
            console.error('Failed to count strikes:', strikesError);
            throw strikesError;
        }

        const activeStrikeCount = strikes?.length || 0;
        const now = new Date().toISOString();

        const { error } = await supabaseAdmin
            .from('profiles')
            .update({
                strike_count: activeStrikeCount,
                last_strike_at: now,
                updated_at: now
            })
            .eq('id', userId);

        if (error) {
            console.error('Failed to update strike count:', error);
            throw error;
        }

        return activeStrikeCount;
    } catch (error) {
        console.error('Error updating strike count:', error);
        throw error;
    }
};

// Issue a strike to a user
export const issueStrike = async (req, res, next) => {
    const { user_id, reason, violation_type, notes, expires_at, severity, severe_category } = req.body;
    const issuedBy = req.user.id;

    try {
        // Validate required fields
        if (!user_id || !reason || !violation_type) {
            return res.status(400).json({
                message: 'Missing required fields: user_id, reason, and violation_type are required'
            });
        }

        // Determine if this is a severe violation
        const isSevere = severity === 'severe' || (severe_category && severe_category !== null);
        
        // For severe violations, get system settings for immediate action
        let suspensionDuration = null;
        if (isSevere) {
            const { data: settings, error: settingsError } = await supabaseAdmin
                .from('system_settings')
                .select('*')
                .single();

            if (!settingsError && settings) {
                const severeAction = settings.severe_violation_action;
                if (severeAction === 'suspend_24h') {
                    suspensionDuration = settings.severe_violation_duration_hours || 24;
                } else if (severeAction === 'suspend_7d') {
                    suspensionDuration = settings.severe_violation_duration_hours || 168;
                } else if (severeAction === 'permanent_ban') {
                    suspensionDuration = -1;
                }
            }
        }

        // If not severe, calculate suspension duration based on current strike count
        if (!isSevere) {
            const { data: currentStrikes, error: countError } = await supabaseAdmin
                .from('strikes')
                .select('id')
                .eq('user_id', user_id)
                .eq('is_active', true)
                .gte('expires_at', new Date().toISOString());

            if (countError) {
                console.error('Failed to count current strikes:', countError);
            }

            const currentStrikeCount = currentStrikes?.length || 0;
            const newStrikeCount = currentStrikeCount + 1;
            suspensionDuration = await calculateSuspensionDuration(newStrikeCount);
        }

        // Create the strike
        const { data: strike, error: strikeError } = await supabaseAdmin
            .from('strikes')
            .insert({
                user_id,
                reason,
                violation_type,
                issued_by: issuedBy,
                expires_at: expires_at || null,
                is_active: true,
                notes,
                severity: isSevere ? 'severe' : 'normal',
                severe_category: severe_category || null,
                requires_manual_review: isSevere,
                manual_review_status: isSevere ? 'pending' : null
            })
            .select()
            .single();

        if (strikeError) {
            return res.status(400).json({
                message: 'Failed to issue strike',
                error: strikeError.message
            });
        }

        // If severe violation, add to manual review queue
        if (isSevere) {
            const { error: queueError } = await supabaseAdmin
                .from('manual_review_queue')
                .insert({
                    strike_id: strike.id,
                    review_type: 'severe_violation',
                    priority: 'high',
                    status: 'pending'
                });

            if (queueError) {
                console.error('Failed to add to manual review queue:', queueError);
            }
        }

        // Update user's strike count
        await updateUserStrikeCount(user_id);

        // Apply suspension if needed
        let suspendedUntil = null;
        if (suspensionDuration !== null) {
            suspendedUntil = await updateUserSuspension(user_id, suspensionDuration);

            // Send suspension notification
            const { error: notifError } = await supabaseAdmin
                .from('notifications')
                .insert({
                    user_id,
                    type: 'suspended',
                    title: 'Account Suspended',
                    body: 'Your account has been temporarily suspended from posting.',
                    is_read: false
                });

            if (notifError) {
                console.error('Failed to send suspension notification:', notifError);
            }
        }

        res.status(201).json({
            message: 'Strike issued successfully',
            strike,
            suspension: suspendedUntil ? {
                suspended_until: suspendedUntil,
                duration_hours: suspensionDuration === -1 ? 'permanent' : suspensionDuration
            } : null
        });
    } catch (error) {
        next(error);
    }
};

// Get all strikes for a user
export const getUserStrikes = async (req, res, next) => {
    const { userId } = req.params;

    try {
        // Check if the requesting user is an admin or the user themselves
        const isSelf = req.user.id === userId;
        const isAdmin = req.user.role === 'admin' || req.user.role === 'lgu';

        if (!isSelf && !isAdmin) {
            return res.status(403).json({
                message: 'You can only view your own strikes'
            });
        }

        const { data: strikes, error } = await supabaseAdmin
            .from('strikes')
            .select('*, profiles!strikes_issued_by_fkey (full_name, email)')
            .eq('user_id', userId)
            .order('issued_at', { ascending: false });

        if (error) {
            return res.status(400).json({
                message: 'Failed to fetch strikes',
                error: error.message
            });
        }

        res.status(200).json({
            strikes
        });
    } catch (error) {
        next(error);
    }
};

// Get all strikes (admin only)
export const getAllStrikes = async (req, res, next) => {
    try {
        const { page = 1, limit = 50, user_id, is_active } = req.query;
        const offset = (page - 1) * limit;

        let query = supabaseAdmin
            .from('strikes')
            .select('*, profiles!strikes_user_id_fkey (full_name, email), profiles!strikes_issued_by_fkey (full_name, email)', { count: 'exact' })
            .order('issued_at', { ascending: false })
            .range(offset, offset + limit - 1);

        if (user_id) {
            query = query.eq('user_id', user_id);
        }

        if (is_active !== undefined) {
            query = query.eq('is_active', is_active === 'true');
        }

        const { data: strikes, error, count } = await query;

        if (error) {
            return res.status(400).json({
                message: 'Failed to fetch strikes',
                error: error.message
            });
        }

        res.status(200).json({
            strikes,
            pagination: {
                page: parseInt(page),
                limit: parseInt(limit),
                total: count,
                pages: Math.ceil(count / limit)
            }
        });
    } catch (error) {
        next(error);
    }
};

// Update a strike
export const updateStrike = async (req, res, next) => {
    const { id } = req.params;
    const { reason, violation_type, notes, is_active, expires_at } = req.body;

    try {
        const updateData = {};
        if (reason !== undefined) updateData.reason = reason;
        if (violation_type !== undefined) updateData.violation_type = violation_type;
        if (notes !== undefined) updateData.notes = notes;
        if (is_active !== undefined) updateData.is_active = is_active;
        if (expires_at !== undefined) updateData.expires_at = expires_at;

        const { data: strike, error } = await supabaseAdmin
            .from('strikes')
            .update(updateData)
            .eq('id', id)
            .select()
            .single();

        if (error) {
            return res.status(400).json({
                message: 'Failed to update strike',
                error: error.message
            });
        }

        // If strike was deactivated, recalculate user's strike count
        if (is_active === false) {
            await updateUserStrikeCount(strike.user_id);
        }

        res.status(200).json({
            message: 'Strike updated successfully',
            strike
        });
    } catch (error) {
        next(error);
    }
};

// Delete a strike
export const deleteStrike = async (req, res, next) => {
    const { id } = req.params;

    try {
        // First get the strike to know which user it belongs to
        const { data: strike, error: fetchError } = await supabaseAdmin
            .from('strikes')
            .select('user_id')
            .eq('id', id)
            .single();

        if (fetchError) {
            return res.status(404).json({
                message: 'Strike not found',
                error: fetchError.message
            });
        }

        const { error } = await supabaseAdmin
            .from('strikes')
            .delete()
            .eq('id', id);

        if (error) {
            return res.status(400).json({
                message: 'Failed to delete strike',
                error: error.message
            });
        }

        // Recalculate user's strike count
        await updateUserStrikeCount(strike.user_id);

        res.status(200).json({
            message: 'Strike deleted successfully'
        });
    } catch (error) {
        next(error);
    }
};

// Get user's current suspension status
export const getUserSuspensionStatus = async (req, res, next) => {
    const { userId } = req.params;

    try {
        const { data: profile, error } = await supabaseAdmin
            .from('profiles')
            .select('suspended_until, strike_count, last_strike_at')
            .eq('id', userId)
            .single();

        if (error) {
            return res.status(404).json({
                message: 'User not found',
                error: error.message
            });
        }

        const now = new Date();
        const suspendedUntil = profile.suspended_until ? new Date(profile.suspended_until) : null;
        const isSuspended = suspendedUntil && suspendedUntil > now;

        res.status(200).json({
            is_suspended: isSuspended,
            suspended_until: profile.suspended_until,
            strike_count: profile.strike_count,
            last_strike_at: profile.last_strike_at
        });
    } catch (error) {
        next(error);
    }
};

// Lift user suspension (admin only)
export const liftSuspension = async (req, res, next) => {
    const { userId } = req.params;

    try {
        const { error } = await supabaseAdmin
            .from('profiles')
            .update({
                suspended_until: null,
                updated_at: new Date().toISOString()
            })
            .eq('id', userId);

        if (error) {
            return res.status(400).json({
                message: 'Failed to lift suspension',
                error: error.message
            });
        }

        // Send notification that suspension has been lifted
        const { error: notifError } = await supabaseAdmin
            .from('notifications')
            .insert({
                user_id: userId,
                type: 'suspension_lifted',
                title: 'Suspension Lifted',
                body: 'Your account suspension has been lifted. You can now post reports again.',
                is_read: false
            });

        if (notifError) {
            console.error('Failed to send suspension lifted notification:', notifError);
        }

        res.status(200).json({
            message: 'Suspension lifted successfully'
        });
    } catch (error) {
        next(error);
    }
};
