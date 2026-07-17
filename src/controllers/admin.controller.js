import { supabaseAdmin as supabase } from "../config/supabase.config.js";
import { logAuditAction } from "../controllers/auth.controller.js";

// Create user
export const createUser = async (req, res, next) => {
    const { email, password, full_name, role } = req.body;
    const ipAddress = req.ip || req.connection.remoteAddress;
    const userAgent = req.get('user-agent');

    // Validate role
    const validRoles = ['citizen', 'lgu', 'admin'];
    if (!validRoles.includes(role)) {
        return res.status(400).json({
            message: 'Invalid role',
            error: 'Role must be one of: citizen, lgu, admin'
        });
    }

    try {
        // Create user in Supabase Auth
        const { data: authData, error: authError } = await supabase.auth.admin.createUser({
            email,
            password,
            email_confirm: true
        });

        if (authError) {
            return res.status(400).json({
                message: 'Failed to create user',
                error: authError.message
            });
        }

        // Create profile with role (no email column)
        const { data: profileData, error: profileError } = await supabase
            .from('profiles')
            .upsert({
                id: authData.user.id,
                full_name: full_name || email.split('@')[0],
                role: role
            })
            .select()
            .single();

        if (profileError) {
            return res.status(400).json({
                message: 'Failed to create user profile',
                error: profileError.message
            });
        }

        // Log user creation event
        await logAuditAction(req.user.id, 'user_created', `Created user account for ${email}`, ipAddress, userAgent);

        res.status(201).json({
            message: 'User created successfully',
            user: profileData
        });
    } catch (error) {
        next(error);
    }
};

 // Get all users with pagination and filtering
export const getAllUsers = async (req, res, next) => {
    const { page = 1, limit = 20, search = '', role = '' } = req.query;
    const offset = (page - 1) * limit;

    console.log('getAllUsers called with:', { page, limit, search, role });

    try {
        // First, fetch all profiles (without search/email filter first)
        let query = supabase
            .from('profiles')
            .select('*', { count: 'exact' })
            .order('created_at', { ascending: false });

        // Apply role filter (this can be done in Supabase)
        if (role) {
            console.log('Applying role filter:', role);
            query = query.eq('role', role);
        }

        // First get all matching profiles (without search)
        const { data: allProfiles, error: profilesError } = await query;
        
        if (profilesError) {
            return res.status(400).json({
                message: 'Failed to fetch users',
                error: profilesError.message
            });
        }

        // Now fetch all emails from auth.users for these profiles
        const usersWithEmails = await Promise.all(allProfiles.map(async (user) => {
            try {
                const { data: authUser } = await supabase.auth.admin.getUserById(user.id);
                if (authUser?.user?.email) {
                    return { ...user, email: authUser.user.email };
                }
                return { ...user, email: 'N/A' };
            } catch (authError) {
                console.error('Failed to fetch email for user:', user.id, authError);
                return { ...user, email: 'N/A' };
            }
        }));

        // Now apply search filter in JavaScript
        let filteredUsers = usersWithEmails;
        if (search) {
            const searchLower = search.toLowerCase();
            filteredUsers = usersWithEmails.filter(user => 
                (user.full_name && user.full_name.toLowerCase().includes(searchLower)) || 
                (user.email && user.email.toLowerCase().includes(searchLower))
            );
        }

        // Apply pagination
        const total = filteredUsers.length;
        const paginatedUsers = filteredUsers.slice(offset, offset + parseInt(limit));

        res.status(200).json({
            users: paginatedUsers,
            pagination: {
                page: parseInt(page),
                limit: parseInt(limit),
                total: total,
                totalPages: Math.ceil(total / parseInt(limit))
            }
        });
    } catch (error) {
        next(error);
    }
};

// Get user by ID
export const getUserById = async (req, res, next) => {
    const { id } = req.params;

    try {
        const { data: profile, error: profileError } = await supabase
            .from('profiles')
            .select('*')
            .eq('id', id)
            .single();

        if (profileError) {
            return res.status(404).json({
                message: 'User not found',
                error: profileError.message
            });
        }

        // Fetch auth user data separately
        let authUserData = {};
        try {
            const { data: authUser } = await supabase.auth.admin.getUserById(id);
            if (authUser?.user) {
                authUserData = {
                    email: authUser.user.email,
                    created_at: authUser.user.created_at,
                    last_sign_in_at: authUser.user.last_sign_in_at
                };
            }
        } catch (authError) {
            console.error('Failed to fetch auth user data for:', id, authError);
        }

        res.status(200).json({ ...profile, auth: authUserData });
    } catch (error) {
        next(error);
    }
};

// Update user role
export const updateUserRole = async (req, res, next) => {
    const { id } = req.params;
    const { role } = req.body;

    // Validate role
    const validRoles = ['citizen', 'lgu', 'admin'];
    if (!validRoles.includes(role)) {
        return res.status(400).json({
            message: 'Invalid role',
            error: 'Role must be one of: citizen, lgu, admin'
        });
    }

    // Prevent admin from changing their own role
    if (id === req.user.id) {
        return res.status(400).json({
            message: 'Cannot change your own role',
            error: 'You cannot change your own role'
        });
    }

    try {
        const { data, error } = await supabase
            .from('profiles')
            .update({ role })
            .eq('id', id)
            .select()
            .single();

        if (error) {
            return res.status(400).json({
                message: 'Failed to update user role',
                error: error.message
            });
        }

        res.status(200).json({
            message: 'User role updated successfully',
            user: data
        });
    } catch (error) {
        next(error);
    }
};

// Delete user
export const deleteUser = async (req, res, next) => {
    const { id } = req.params;

    // Prevent admin from deleting themselves
    if (id === req.user.id) {
        return res.status(400).json({
            message: 'Cannot delete your own account',
            error: 'You cannot delete your own account'
        });
    }

    try {
        // Delete from auth.users (this will cascade to profiles)
        const { error: authError } = await supabase.auth.admin.deleteUser(id);

        if (authError) {
            return res.status(400).json({
                message: 'Failed to delete user',
                error: authError.message
            });
        }

        res.status(200).json({
            message: 'User deleted successfully'
        });
    } catch (error) {
        next(error);
    }
};

// Get system settings
export const getSystemSettings = async (req, res, next) => {
    try {
        const { data, error } = await supabase
            .from('system_settings')
            .select('*')
            .single();

        if (error) {
            // If settings don't exist, return defaults
            if (error.code === 'PGRST116') {
                return res.status(200).json({
                    password_min_length: 8,
                    password_require_uppercase: true,
                    password_require_lowercase: true,
                    password_require_numbers: true,
                    password_require_special_chars: true,
                    session_timeout_minutes: 60
                });
            }
            return res.status(400).json({
                message: 'Failed to fetch system settings',
                error: error.message
            });
        }

        res.status(200).json(data);
    } catch (error) {
        next(error);
    }
};

// Update system settings
export const updateSystemSettings = async (req, res, next) => {
    const settings = req.body;

    try {
        const { data, error } = await supabase
            .from('system_settings')
            .upsert(settings)
            .select()
            .single();

        if (error) {
            return res.status(400).json({
                message: 'Failed to update system settings',
                error: error.message
            });
        }

        res.status(200).json({
            message: 'System settings updated successfully',
            settings: data
        });
    } catch (error) {
        next(error);
    }
};

// Get audit logs
export const getAuditLogs = async (req, res, next) => {
    const { page = 1, limit = 50, action_type = '', user_id = '', start_date = '', end_date = '' } = req.query;
    const offset = (page - 1) * limit;

    try {
        let query = supabase
            .from('audit_logs')
            .select('*', { count: 'exact' })
            .range(offset, offset + limit - 1)
            .order('created_at', { ascending: false });

        // Apply action type filter
        if (action_type) {
            query = query.eq('action_type', action_type);
        }

        // Apply user filter
        if (user_id) {
            query = query.eq('user_id', user_id);
        }

        // Apply date range filter
        if (start_date) {
            query = query.gte('created_at', start_date);
        }
        if (end_date) {
            query = query.lte('created_at', end_date);
        }

        const { data, error, count } = await query;

        if (error) {
            return res.status(400).json({
                message: 'Failed to fetch audit logs',
                error: error.message
            });
        }

        // Fetch related user profile data for each log
        const logs = await Promise.all(data.map(async (log) => {
            // Fetch user profile
            let displayProfile = {
                full_name: 'Unknown',
                email: 'N/A'
            };

            try {
                const { data: profile } = await supabase
                    .from('profiles')
                    .select('full_name')
                    .eq('id', log.user_id)
                    .single();

                if (profile) {
                    displayProfile.full_name = profile.full_name;
                }
            } catch (profileError) {
                console.error('Failed to fetch profile for user:', log.user_id, profileError);
            }

            // Fetch email from auth.users
            try {
                const { data: authUser } = await supabase.auth.admin.getUserById(log.user_id);
                if (authUser?.user?.email) {
                    displayProfile.email = authUser.user.email;
                }
            } catch (authError) {
                console.error('Failed to fetch auth user for:', log.user_id, authError);
            }

            return {
                ...log,
                profiles: displayProfile
            };
        }));

        res.status(200).json({
            logs,
            pagination: {
                page: parseInt(page),
                limit: parseInt(limit),
                total: count || 0,
                totalPages: Math.ceil((count || 0) / limit)
            }
        });
    } catch (error) {
        next(error);
    }
};

// Get system statistics
export const getSystemStats = async (req, res, next) => {
    try {
        // Get user counts by role
        const { data: usersByRole, error: usersError } = await supabase
            .from('profiles')
            .select('role');

        const roleCounts = usersByRole?.reduce((acc, user) => {
            acc[user.role] = (acc[user.role] || 0) + 1;
            return acc;
        }, {}) || {};

        // Get report counts
        const { count: totalReports, error: reportsError } = await supabase
            .from('reports')
            .select('*', { count: 'exact', head: true });

        // Get report counts by status
        const { data: reportsByStatus } = await supabase
            .from('reports')
            .select('status');

        const statusCounts = reportsByStatus?.reduce((acc, report) => {
            acc[report.status] = (acc[report.status] || 0) + 1;
            return acc;
        }, {}) || {};

        // Get total audit logs count
        const { count: totalAuditLogs } = await supabase
            .from('response_log')
            .select('*', { count: 'exact', head: true });

        res.status(200).json({
            users: {
                total: usersByRole?.length || 0,
                byRole: roleCounts
            },
            reports: {
                total: totalReports || 0,
                byStatus: statusCounts
            },
            auditLogs: {
                total: totalAuditLogs || 0
            }
        });
    } catch (error) {
        next(error);
    }
};
