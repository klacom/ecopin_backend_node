import { createClient } from "@supabase/supabase-js";

export const createReport = async (req, res, next) => {
    const { title, description, issue_type, latitude, longitude } = req.body;
    const user_id = req.user.id;

    // Use service role key to ensure we can bypass any RLS if needed, 
    // but typically the authenticate middleware ensures we have a valid user.
    const supabase = createClient(process.env.NEXT_PUBLIC_SUPABASE_URL, process.env.NEXT_PUBLIC_SERVICE_ROLE_KEY);

    try {
        // PostGIS point format: 'POINT(longitude latitude)'
        const point = `POINT(${longitude} ${latitude})`;

        const { data, error } = await supabase
            .from('reports')
            .insert({
                user_id,
                title,
                description,
                issue_type,
                location: point,
                status: 'unresolved',
                validation_status: 'pending'
            })
            .select()
            .single();

        if (error) {
            return res.status(400).json({
                message: 'Failed to create report',
                error: error.message
            });
        }

        res.status(201).json({
            message: 'Report created successfully',
            report: data
        });
    } catch (error) {
        next(error);
    }
};

export const getMyReports = async (req, res, next) => {
    const user_id = req.user.id;
    const supabase = createClient(process.env.NEXT_PUBLIC_SUPABASE_URL, process.env.NEXT_PUBLIC_SERVICE_ROLE_KEY);

    try {
        const { data, error } = await supabase
            .from('reports_view')
            .select('*')
            .eq('user_id', user_id)
            .order('created_at', { ascending: false });

        if (error) {
            return res.status(400).json({
                message: 'Failed to fetch your reports',
                error: error.message
            });
        }

        res.status(200).json(data);
    } catch (error) {
        next(error);
    }
};

export const getPublicReports = async (req, res, next) => {
    const supabase = createClient(process.env.NEXT_PUBLIC_SUPABASE_URL, process.env.NEXT_PUBLIC_SERVICE_ROLE_KEY);

    try {
        const { data, error } = await supabase
            .from('reports_view')
            .select('*');

        if (error) {
            return res.status(400).json({
                message: 'Failed to fetch public reports from view',
                error: error.message
            });
        }

        res.status(200).json(data);
    } catch (error) {
        next(error);
    }
};

export const getReportById = async (req, res, next) => {
    const { id } = req.params;
    const supabase = createClient(process.env.NEXT_PUBLIC_SUPABASE_URL, process.env.NEXT_PUBLIC_SERVICE_ROLE_KEY);

    try {
        const { data, error } = await supabase
            .from('reports_view')
            .select('*, profiles(full_name)')
            .eq('id', id)
            .single();

        if (error) {
            return res.status(404).json({
                message: 'Report not found',
                error: error.message
            });
        }

        res.status(200).json(data);
    } catch (error) {
        next(error);
    }
};
