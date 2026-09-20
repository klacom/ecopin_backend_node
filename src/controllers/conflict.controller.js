import { supabaseAdmin as supabase } from '../config/supabase.config.js';

export const getUnresolvedConflicts = async (req, res, next) => {
    try {
        const { page = 1, limit = 10 } = req.query;
        const offset = (page - 1) * limit;

        const { data, error, count } = await supabase
            .from('sync_conflicts')
            .select(`
                *,
                user:user_id(id, email, full_name)
            `, { count: 'exact' })
            .is('resolved_at', null)
            .order('created_at', { ascending: false })
            .range(offset, offset + limit - 1);

        if (error) {
            return res.status(400).json({
                message: 'Failed to fetch conflicts',
                error: error.message
            });
        }

        res.status(200).json({
            conflicts: data,
            pagination: {
                total: count,
                page: parseInt(page),
                limit: parseInt(limit),
                totalPages: Math.ceil(count / limit)
            }
        });
    } catch (error) {
        console.error('Error in getUnresolvedConflicts:', error);
        next(error);
    }
};

export const resolveConflict = async (req, res, next) => {
    try {
        const { id } = req.params;
        const { resolution_notes, resolution_action, payload } = req.body;
        const resolved_by = req.user.id;

        // resolution_action could be 'apply_client', 'keep_server', 'merge'
        // If 'apply_client' or 'merge', the client needs to pass the final payload to apply

        const { data: conflict, error: fetchError } = await supabase
            .from('sync_conflicts')
            .select('*')
            .eq('id', id)
            .single();

        if (fetchError || !conflict) {
            return res.status(404).json({ message: 'Conflict not found' });
        }

        if (conflict.resolved_at) {
            return res.status(400).json({ message: 'Conflict already resolved' });
        }

        if (resolution_action === 'apply_client' || resolution_action === 'merge') {
            if (!payload) {
                return res.status(400).json({ message: 'Payload is required for this resolution action' });
            }

            if (conflict.operation_type === 'task_update') {
                const task_id = conflict.operation_payload.task_id || conflict.server_state.id;
                const { error: updateError } = await supabase
                    .from('cleanup_tasks')
                    .update({ ...payload, updated_at: new Date().toISOString() })
                    .eq('id', task_id);

                if (updateError) {
                    return res.status(400).json({ message: 'Failed to apply resolution', error: updateError.message });
                }
            } else if (conflict.operation_type === 'report_create') {
                 // Future expansion for report create conflicts if needed
            }
        }

        // Mark as resolved
        const { data: resolvedConflict, error: resolveError } = await supabase
            .from('sync_conflicts')
            .update({
                resolved_at: new Date().toISOString(),
                resolved_by,
                resolution_notes
            })
            .eq('id', id)
            .select()
            .single();

        if (resolveError) {
            return res.status(400).json({
                message: 'Failed to mark conflict as resolved',
                error: resolveError.message
            });
        }

        res.status(200).json({
            message: 'Conflict resolved successfully',
            conflict: resolvedConflict
        });

    } catch (error) {
        console.error('Error in resolveConflict:', error);
        next(error);
    }
};
