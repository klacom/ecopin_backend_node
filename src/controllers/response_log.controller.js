import { supabaseAdmin as supabase } from "../config/supabase.config.js";

// Get response logs for reports
export const getResponseLogs = async (req, res, next) => {
    const { page = 1, limit = 50, action_type = '', user_id = '', start_date = '', end_date = '' } = req.query;
    const offset = (page - 1) * limit;

    try {
        let query = supabase
            .from('response_log')
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
                message: 'Failed to fetch response logs',
                error: error.message
            });
        }

        // Fetch related data for each log
        const logs = await Promise.all(data.map(async (log) => {
            // Fetch user profile with data_consent field
            let displayProfile = {
                full_name: 'Unknown',
                email: 'N/A',
                data_consent: true
            };

            try {
                const { data: profile } = await supabase
                    .from('profiles')
                    .select('full_name, data_consent')
                    .eq('id', log.user_id)
                    .single();

                if (profile) {
                    // Hide full name if data_consent is false
                    displayProfile = {
                        ...profile,
                        full_name: profile.data_consent !== false ? profile.full_name : 'Anonymous'
                    };
                }
            } catch (profileError) {
                console.error('Failed to fetch profile for user:', log.user_id, profileError);
            }

            // Fetch email from auth.users
            try {
                const { data: authUser } = await supabase.auth.admin.getUserById(log.user_id);
                if (authUser?.user?.email) {
                    // Only show email if data_consent is true
                    displayProfile.email = displayProfile.data_consent !== false ? authUser.user.email : 'Hidden';
                }
            } catch (authError) {
                console.error('Failed to fetch auth user for:', log.user_id, authError);
            }

            // Fetch report title
            let report = null;
            try {
                const { data: reportData } = await supabase
                    .from('reports')
                    .select('title')
                    .eq('id', log.report_id)
                    .single();
                report = reportData;
            } catch (reportError) {
                console.error('Failed to fetch report for log:', log.report_id, reportError);
            }

            return {
                ...log,
                profiles: displayProfile,
                reports: report
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
