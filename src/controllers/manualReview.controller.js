import { supabaseAdmin } from "../config/supabase.config.js";

// Get all items in manual review queue
export const getManualReviewQueue = async (req, res, next) => {
    try {
        const { page = 1, limit = 50, status, priority, review_type } = req.query;
        const offset = (page - 1) * limit;

        let query = supabaseAdmin
            .from('manual_review_queue')
            .select(`
                *,
                reports!manual_review_queue_report_id_fkey (id, title, user_id, validation_status, created_at),
                strikes!manual_review_queue_strike_id_fkey (id, reason, severity, severe_category, issued_at),
                profiles!manual_review_queue_assigned_to_fkey (full_name, email)
            `, { count: 'exact' })
            .order('created_at', { ascending: false })
            .range(offset, offset + limit - 1);

        if (status) {
            query = query.eq('status', status);
        }

        if (priority) {
            query = query.eq('priority', priority);
        }

        if (review_type) {
            query = query.eq('review_type', review_type);
        }

        const { data: items, error, count } = await query;

        if (error) {
            return res.status(400).json({
                message: 'Failed to fetch manual review queue',
                error: error.message
            });
        }

        res.status(200).json({
            items,
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

// Get a single manual review item
export const getManualReviewItem = async (req, res, next) => {
    const { id } = req.params;

    try {
        const { data: item, error } = await supabaseAdmin
            .from('manual_review_queue')
            .select(`
                *,
                reports!manual_review_queue_report_id_fkey (*),
                strikes!manual_review_queue_strike_id_fkey (*),
                profiles!manual_review_queue_assigned_to_fkey (full_name, email)
            `)
            .eq('id', id)
            .single();

        if (error) {
            return res.status(404).json({
                message: 'Review item not found',
                error: error.message
            });
        }

        res.status(200).json({
            item
        });
    } catch (error) {
        next(error);
    }
};

// Assign a review item to an admin
export const assignReviewItem = async (req, res, next) => {
    const { id } = req.params;
    const { assigned_to } = req.body;
    const adminId = req.user.id;

    try {
        const { data: item, error } = await supabaseAdmin
            .from('manual_review_queue')
            .update({
                assigned_to: assigned_to || adminId,
                assigned_at: new Date().toISOString(),
                status: 'in_review',
                updated_at: new Date().toISOString()
            })
            .eq('id', id)
            .select()
            .single();

        if (error) {
            return res.status(400).json({
                message: 'Failed to assign review item',
                error: error.message
            });
        }

        res.status(200).json({
            message: 'Review item assigned successfully',
            item
        });
    } catch (error) {
        next(error);
    }
};

// Complete a review item
export const completeReviewItem = async (req, res, next) => {
    const { id } = req.params;
    const { status, review_notes, action } = req.body; // action: 'approve', 'reject', 'dismiss'

    try {
        const updateData = {
            status: status || 'reviewed',
            review_notes,
            reviewed_at: new Date().toISOString(),
            updated_at: new Date().toISOString()
        };

        const { data: item, error: updateError } = await supabaseAdmin
            .from('manual_review_queue')
            .update(updateData)
            .eq('id', id)
            .select()
            .single();

        if (updateError) {
            return res.status(400).json({
                message: 'Failed to complete review',
                error: updateError.message
            });
        }

        // Handle actions based on review type
        if (item.review_type === 'severe_violation') {
            // Update associated strike if exists
            if (item.strike_id && action) {
                const strikeUpdate = {};
                if (action === 'dismiss') {
                    strikeUpdate.is_active = false;
                    strikeUpdate.manual_review_status = 'dismissed';
                } else if (action === 'approve') {
                    strikeUpdate.manual_review_status = 'reviewed';
                }

                if (Object.keys(strikeUpdate).length > 0) {
                    await supabaseAdmin
                        .from('strikes')
                        .update(strikeUpdate)
                        .eq('id', item.strike_id);
                }
            }

            // Update associated report if exists
            if (item.report_id && action) {
                const reportUpdate = {};
                if (action === 'dismiss') {
                    reportUpdate.validation_status = 'pending_ai_validation';
                    reportUpdate.flagged_severe = false;
                    reportUpdate.severe_violation_category = null;
                    reportUpdate.rejection_reason = null;
                } else if (action === 'approve') {
                    // Keep the rejection status
                    reportUpdate.validation_status = 'rejected';
                }

                if (Object.keys(reportUpdate).length > 0) {
                    await supabaseAdmin
                        .from('reports')
                        .update(reportUpdate)
                        .eq('id', item.report_id);
                }
            }
        }

        res.status(200).json({
            message: 'Review completed successfully',
            item
        });
    } catch (error) {
        next(error);
    }
};

// Delete a review item
export const deleteReviewItem = async (req, res, next) => {
    const { id } = req.params;

    try {
        const { error } = await supabaseAdmin
            .from('manual_review_queue')
            .delete()
            .eq('id', id);

        if (error) {
            return res.status(400).json({
                message: 'Failed to delete review item',
                error: error.message
            });
        }

        res.status(200).json({
            message: 'Review item deleted successfully'
        });
    } catch (error) {
        next(error);
    }
};

// Get review statistics
export const getReviewStats = async (req, res, next) => {
    try {
        const { data: pending } = await supabaseAdmin
            .from('manual_review_queue')
            .select('id', { count: 'exact', head: true })
            .eq('status', 'pending');

        const { data: inReview } = await supabaseAdmin
            .from('manual_review_queue')
            .select('id', { count: 'exact', head: true })
            .eq('status', 'in_review');

        const { data: reviewed } = await supabaseAdmin
            .from('manual_review_queue')
            .select('id', { count: 'exact', head: true })
            .eq('status', 'reviewed');

        const { data: urgent } = await supabaseAdmin
            .from('manual_review_queue')
            .select('id', { count: 'exact', head: true })
            .eq('priority', 'urgent')
            .eq('status', 'pending');

        res.status(200).json({
            stats: {
                pending: pending || 0,
                in_review: inReview || 0,
                reviewed: reviewed || 0,
                urgent: urgent || 0
            }
        });
    } catch (error) {
        next(error);
    }
};
