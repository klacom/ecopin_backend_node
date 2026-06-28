import { supabase, supabaseAdmin } from "../config/supabase.config.js";

export const authenticate = async (req, res, next) => {
    const authHeader = req.headers.authorization;

    if (!authHeader || !authHeader.startsWith('Bearer ')) {
        return res.status(401).json({ error: 'No token provided' });
    }

    const token = authHeader.split(' ')[1];

    try {
        // 1. Verify the JWT and get the user
        const { data: { user }, error: authError } = await supabase.auth.getUser(token);

        if (authError || !user) {
            return res.status(401).json({ error: 'Invalid token' });
        }

        // 2. Fetch the role from the 'profiles' table
        const { data: profile, error: profileError } = await supabaseAdmin
            .from('profiles')
            .select('role, full_name')
            .eq('id', user.id)
            .single();

        if (profileError) {
            // Fallback to 'citizen' if profile not found or error
            user.role = 'citizen';
        } else {
            user.role = profile.role;
            user.full_name = profile.full_name;
        }

        // Attach user and role to request object
        req.user = user;
        next();
    } catch (error) {
        return res.status(401).json({ error: 'Authentication failed' });
    }
};

// TODO: Implement more granular role-based access control if needed (e.g., separate middleware for each role)
export const authorize = (roles = []) => {
    return (req, res, next) => {
        if (!req.user) {
            return res.status(401).json({ error: 'Unauthorized' });
        }

        // Use the role attached during authentication
        const userRole = req.user.role || 'citizen';

        if (roles.length && !roles.includes(userRole)) {
            return res.status(403).json({ error: 'Authorized accounts only' });
        }

        next();
    };
};
