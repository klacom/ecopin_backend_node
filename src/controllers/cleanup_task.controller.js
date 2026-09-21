import { supabaseAdmin as supabase } from "../config/supabase.config.js";
import { CLEANUP_TASK_PHOTOS_STORAGE_PATH } from "../config/index.js";
import multer from 'multer';
import { BEFORE_AFTER_PHOTO_FILE_SIZE } from "../config/index.js";

// Configure multer for memory storage
const storage = multer.memoryStorage();
export const upload = multer({
    storage: storage,
    limits: { fileSize: BEFORE_AFTER_PHOTO_FILE_SIZE }, // 10MB limit
    fileFilter: (req, file, cb) => {
        if (file.mimetype.startsWith('image/')) {
            cb(null, true);
        } else {
            cb(new Error('Only image files are allowed'), false);
        }
    }
});

export const createCleanupTask = async (req, res, next) => {
    const { cluster_id, title, description, assigned_crew_ids } = req.body;
    const user_id = req.user.id;

    // Allow tasks without crew assignment (they remain 'pending' for later optimization)
    const hasCrewAssignment = assigned_crew_ids && Array.isArray(assigned_crew_ids) && assigned_crew_ids.length > 0;

    try {
        // Check if reports in this cluster have manual review status
        const { data: manualReviewReports, error: manualReviewError } = await supabase
            .from('reports')
            .select('id, validation_status')
            .eq('cluster_id', cluster_id)
            .eq('validation_status', 'manual_review');

        if (manualReviewError) {
            return res.status(400).json({
                message: 'Failed to check report validation status',
                error: manualReviewError.message
            });
        }

        if (manualReviewReports && manualReviewReports.length > 0) {
            return res.status(400).json({
                message: 'Reports with manual review status must be approved before being added to a cleanup task',
                manual_review_reports: manualReviewReports.map(r => r.id)
            });
        }

        // Check if reports in this cluster already belong to another cleanup task
        const { data: existingReports, error: checkError } = await supabase
            .from('reports')
            .select('id, cleanup_task_id')
            .eq('cluster_id', cluster_id)
            .not('cleanup_task_id', 'is', null);

        if (checkError) {
            return res.status(400).json({
                message: 'Failed to check report status',
                error: checkError.message
            });
        }

        if (existingReports && existingReports.length > 0) {
            return res.status(400).json({
                message: 'Some reports in this cluster already belong to another cleanup task',
                conflicting_reports: existingReports.map(r => r.id)
            });
        }

        // Create cleanup task with assignment info
        const taskData = {
            cluster_id,
            title,
            description,
            status: 'pending',
            created_by: user_id
        };

        // Inherit cluster priority if available
        if (cluster_id) {
            const { data: cluster } = await supabase
                .from('clusters')
                .select('priority, priority_score')
                .eq('id', cluster_id)
                .single();
            if (cluster) {
                taskData.priority = cluster.priority;
                taskData.priority_score = cluster.priority_score;
            }
        }

        if (hasCrewAssignment) {
            taskData.assigned_crew_ids = assigned_crew_ids;
            taskData.assigned_at = new Date().toISOString();
            taskData.assigned_by = user_id;
            taskData.last_assigned_at = new Date().toISOString();
        }

        const { data, error } = await supabase
            .from('cleanup_tasks')
            .insert(taskData)
            .select()
            .single();

        if (error) {
            return res.status(400).json({
                message: 'Failed to create cleanup task',
                error: error.message
            });
        }

        // Update all reports in the cluster to link to this cleanup task and set lifecycle
        const { error: reportsError } = await supabase
            .from('reports')
            .update({
                cleanup_task_id: data.id,
                status: 'in_progress',
                lifecycle_stage: 'assigned',
                updated_at: new Date().toISOString()
            })
            .eq('cluster_id', cluster_id);

        if (reportsError) {
            console.error('Failed to update reports with cleanup task linkage:', reportsError);
            // Don't fail the request, just log the error
        }

        // Send notifications to assigned crew members
        if (assigned_crew_ids && assigned_crew_ids.length > 0) {
            for (const crewId of assigned_crew_ids) {
                try {
                    await supabase
                        .from('notifications')
                        .insert({
                            user_id: crewId,
                            report_id: null,
                            cleanup_task_id: data.id,
                            type: 'task_assigned',
                            title: 'New Task Assigned',
                            body: `You have been assigned to cleanup task: ${title}`
                        });
                } catch (notifError) {
                    console.error('Failed to send notification to crew:', crewId, notifError);
                }
            }
        }

        res.status(201).json({
            message: 'Cleanup task created successfully',
            task: data
        });
    } catch (error) {
        next(error);
    }
};

// Create custom cleanup task with selected report IDs
export const createCustomCleanupTask = async (req, res, next) => {
    const { report_ids, title, description, assigned_crew_ids } = req.body;
    const user_id = req.user.id;

    if (!report_ids || !Array.isArray(report_ids) || report_ids.length === 0) {
        return res.status(400).json({
            message: 'Report IDs are required',
            error: 'Please provide at least one report ID'
        });
    }

    // Allow tasks without crew assignment (they remain 'pending' for later optimization)
    const hasCrewAssignment = assigned_crew_ids && Array.isArray(assigned_crew_ids) && assigned_crew_ids.length > 0;

    try {
        // Check if any of the selected reports have manual review status
        const { data: manualReviewReports, error: manualReviewError } = await supabase
            .from('reports')
            .select('id, validation_status')
            .in('id', report_ids)
            .eq('validation_status', 'manual_review');

        if (manualReviewError) {
            return res.status(400).json({
                message: 'Failed to check report validation status',
                error: manualReviewError.message
            });
        }

        if (manualReviewReports && manualReviewReports.length > 0) {
            return res.status(400).json({
                message: 'Reports with manual review status must be approved before being added to a cleanup task',
                manual_review_reports: manualReviewReports.map(r => r.id)
            });
        }

        // Check if any of the selected reports already belong to another cleanup task
        const { data: existingReports, error: checkError } = await supabase
            .from('reports')
            .select('id, cleanup_task_id')
            .in('id', report_ids)
            .not('cleanup_task_id', 'is', null);

        if (checkError) {
            return res.status(400).json({
                message: 'Failed to check report status',
                error: checkError.message
            });
        }

        if (existingReports && existingReports.length > 0) {
            return res.status(400).json({
                message: 'Some selected reports already belong to another cleanup task',
                conflicting_reports: existingReports.map(r => r.id)
            });
        }

        // Create cleanup task with assignment info
        const taskData = {
            title,
            description,
            status: 'pending',
            created_by: user_id,
            is_custom: true,
            report_ids: report_ids
        };

        if (hasCrewAssignment) {
            taskData.assigned_crew_ids = assigned_crew_ids;
            taskData.assigned_at = new Date().toISOString();
            taskData.assigned_by = user_id;
            taskData.last_assigned_at = new Date().toISOString();
        }

        const { data, error } = await supabase
            .from('cleanup_tasks')
            .insert(taskData)
            .select()
            .single();

        if (error) {
            return res.status(400).json({
                message: 'Failed to create cleanup task',
                error: error.message
            });
        }

        // Update selected reports to link to this cleanup task and set lifecycle
        const { error: reportsError } = await supabase
            .from('reports')
            .update({
                cleanup_task_id: data.id,
                status: 'in_progress',
                lifecycle_stage: 'assigned',
                updated_at: new Date().toISOString()
            })
            .in('id', report_ids);

        if (reportsError) {
            console.error('Failed to update reports with cleanup task linkage:', reportsError);
            // Don't fail the request, just log the error
        }

        // Send notifications to assigned crew members
        if (assigned_crew_ids && assigned_crew_ids.length > 0) {
            for (const crewId of assigned_crew_ids) {
                try {
                    await supabase
                        .from('notifications')
                        .insert({
                            user_id: crewId,
                            report_id: null,
                            cleanup_task_id: data.id,
                            type: 'task_assigned',
                            title: 'New Task Assigned',
                            body: `You have been assigned to cleanup task: ${title}`
                        });
                } catch (notifError) {
                    console.error('Failed to send notification to crew:', crewId, notifError);
                }
            }
        }

        res.status(201).json({
            message: 'Custom cleanup task created successfully',
            task: data
        });
    } catch (error) {
        next(error);
    }
};

export const getAllCleanupTasks = async (req, res, next) => {
    try {
        const { assigned_to_me } = req.query;
        const userId = req.user.id;

        let query = supabase
            .from('cleanup_tasks')
            .select('*, clusters(*)')
            .order('created_at', { ascending: false });

        // Filter for tasks assigned to current user if requested
        if (assigned_to_me === 'true') {
            query = query.contains('assigned_crew_ids', [userId]);
        }

        const { data, error } = await query;

        if (error) {
            console.error('Error fetching cleanup tasks:', error);
            return res.status(400).json({
                message: 'Failed to fetch cleanup tasks',
                error: error.message
            });
        }

        console.log('Fetched cleanup tasks:', data.length, 'tasks');
        if (assigned_to_me === 'true') {
            console.log('User ID:', userId);
            console.log('Tasks with assigned_crew_ids:', data.map(t => ({ id: t.id, assigned_crew_ids: t.assigned_crew_ids })));
        }

        res.status(200).json(data);
    } catch (error) {
        next(error);
    }
};

export const getCleanupTaskById = async (req, res, next) => {
    const { id } = req.params;

    try {
        const { data, error } = await supabase
            .from('cleanup_tasks')
            .select('*, clusters(*)')
            .eq('id', id)
            .single();

        if (error) {
            return res.status(404).json({
                message: 'Cleanup task not found',
                error: error.message
            });
        }

        res.status(200).json(data);
    } catch (error) {
        next(error);
    }
};

// Upload before/after photo for cleanup task
export const uploadCleanupPhoto = async (req, res, next) => {
    const { taskId } = req.params;
    const { photo_type } = req.body; // 'before' or 'after'

    if (!req.file) {
        return res.status(400).json({ message: 'No file uploaded' });
    }

    try {
        const timestamp = Date.now();
        const filename = `${timestamp}_${req.file.originalname}`;
        const filePath = `${taskId}/${photo_type}/${filename}`;

        // Upload to Supabase storage
        const { data: uploadData, error: uploadError } = await supabase
            .storage
            .from(CLEANUP_TASK_PHOTOS_STORAGE_PATH)
            .upload(filePath, req.file.buffer, {
                contentType: req.file.mimetype,
                upsert: false
            });

        if (uploadError) {
            return res.status(400).json({
                message: 'Failed to upload photo',
                error: uploadError.message
            });
        }

        // Get public URL
        const { data: urlData } = supabase
            .storage
            .from(CLEANUP_TASK_PHOTOS_STORAGE_PATH)
            .getPublicUrl(filePath);

        // Update the task with the photo URL
        const updateData = photo_type === 'before'
            ? { before_photo_url: urlData.publicUrl }
            : { after_photo_url: urlData.publicUrl };

        const { data: taskData, error: taskError } = await supabase
            .from('cleanup_tasks')
            .update(updateData)
            .eq('id', taskId)
            .select()
            .single();

        if (taskError) {
            return res.status(400).json({
                message: 'Failed to update task with photo',
                error: taskError.message
            });
        }

        res.status(200).json({
            message: 'Photo uploaded successfully',
            task: taskData
        });
    } catch (error) {
        next(error);
    }
};

// Delete before/after photo for cleanup task
export const deleteCleanupPhoto = async (req, res, next) => {
    const { taskId } = req.params;
    const { photo_type } = req.body; // 'before' or 'after'

    console.log('Deleting cleanup task photo:', { taskId, photo_type });

    try {
        // Get the current task to find the photo URL
        const { data: task, error: fetchError } = await supabase
            .from('cleanup_tasks')
            .select('*')
            .eq('id', taskId)
            .single();

        if (fetchError) {
            console.error('Failed to fetch task:', fetchError);
            return res.status(404).json({
                message: 'Cleanup task not found',
                error: fetchError.message
            });
        }

        const photoUrl = photo_type === 'before' ? task.before_photo_url : task.after_photo_url;

        if (!photoUrl) {
            return res.status(400).json({
                message: 'No photo to delete'
            });
        }

        // Extract the file path from the URL
        const urlParts = photoUrl.split('/');
        const fileName = urlParts[urlParts.length - 1];
        const filePath = `${taskId}/${photo_type}/${fileName}`;

        console.log('Deleting file path:', filePath);

        // Delete from Supabase storage
        const { error: deleteError } = await supabase
            .storage
            .from(CLEANUP_TASK_PHOTOS_STORAGE_PATH)
            .remove([filePath]);

        if (deleteError) {
            console.error('Failed to delete photo from storage:', deleteError);
            return res.status(400).json({
                message: 'Failed to delete photo from storage',
                error: deleteError.message
            });
        }

        console.log('Photo deleted from storage successfully');

        // Update the task to remove the photo URL
        const updateData = photo_type === 'before'
            ? { before_photo_url: null }
            : { after_photo_url: null };

        const { data: taskData, error: taskError } = await supabase
            .from('cleanup_tasks')
            .update(updateData)
            .eq('id', taskId)
            .select()
            .single();

        if (taskError) {
            console.error('Failed to update task:', taskError);
            return res.status(400).json({
                message: 'Failed to update task',
                error: taskError.message
            });
        }

        console.log('Task updated successfully:', taskData);

        res.status(200).json({
            message: 'Photo deleted successfully',
            task: taskData
        });
    } catch (error) {
        console.error('Delete photo error:', error);
        next(error);
    }
};

export const markTaskComplete = async (req, res, next) => {
    const { id } = req.params;
    const userId = req.user.id;

    try {
        // 1. Get the task to verify assignment
        const { data: task, error: fetchError } = await supabase
            .from('cleanup_tasks')
            .select('*')
            .eq('id', id)
            .single();

        if (fetchError) {
            return res.status(404).json({
                message: 'Cleanup task not found',
                error: fetchError.message
            });
        }

        // 2. Verify current user is assigned to this task
        if (task.assigned_crew_ids && task.assigned_crew_ids.length > 0) {
            if (!task.assigned_crew_ids.includes(userId)) {
                return res.status(403).json({
                    message: 'You are not assigned to this task',
                    error: 'Only assigned crew members can complete this task'
                });
            }
        }

        // 3. Mark the task as complete
        const { data: taskData, error: taskError } = await supabase
            .from('cleanup_tasks')
            .update({
                status: 'completed',
                completed_at: new Date().toISOString()
            })
            .eq('id', id)
            .select()
            .single();

        if (taskError) {
            return res.status(400).json({
                message: 'Failed to mark task complete',
                error: taskError.message
            });
        }

        // 4. Update linked reports' lifecycle and status
        if (taskData.is_custom && taskData.report_ids) {
            // Custom task: update selected reports
            await supabase
                .from('reports')
                .update({
                    status: 'resolved',
                    lifecycle_stage: 'resolved',
                    updated_at: new Date().toISOString()
                })
                .in('id', taskData.report_ids);
        } else if (taskData.cluster_id) {
            // Cluster-based task: update all reports in cluster
            await supabase
                .from('reports')
                .update({
                    status: 'resolved',
                    lifecycle_stage: 'resolved',
                    updated_at: new Date().toISOString()
                })
                .eq('cluster_id', taskData.cluster_id);
        }

        res.status(200).json({
            message: 'Cleanup task completed successfully',
            task: taskData
        });
    } catch (error) {
        next(error);
    }
};

export const getTasksByClusterId = async (req, res, next) => {
    const { clusterId } = req.params;

    try {
        const { data, error } = await supabase
            .from('cleanup_tasks')
            .select('*')
            .eq('cluster_id', clusterId)
            .order('created_at', { ascending: false });

        if (error) {
            console.log("Fail to fetch cleanup tasks: ", error);
            return res.status(400).json({
                message: 'Failed to fetch cleanup tasks',
                error: error.message
            });
        }

        res.status(200).json(data);
    } catch (error) {
        next(error);
    }
};

// Assign cleanup task to field crew members
export const assignCleanupTask = async (req, res, next) => {
    const { id } = req.params;
    const { assigned_crew_ids } = req.body;
    const userId = req.user.id;

    try {
        // Get current task to compare assignments
        const { data: currentTask, error: fetchError } = await supabase
            .from('cleanup_tasks')
            .select('*')
            .eq('id', id)
            .single();

        if (fetchError) {
            return res.status(404).json({
                message: 'Cleanup task not found',
                error: fetchError.message
            });
        }

        const previousAssignees = currentTask.assigned_crew_ids || [];
        const newAssignees = assigned_crew_ids || [];

        // Determine newly assigned and removed crew members
        const newlyAssigned = newAssignees.filter(id => !previousAssignees.includes(id));
        const removedAssignees = previousAssignees.filter(id => !newAssignees.includes(id));

        // Update task with new assignments
        const updateData = {
            last_assigned_at: new Date().toISOString()
        };

        if (newAssignees.length > 0) {
            updateData.assigned_crew_ids = newAssignees;
            if (!currentTask.assigned_at) {
                updateData.assigned_at = new Date().toISOString();
            }
            updateData.assigned_by = userId;
        } else {
            updateData.assigned_crew_ids = null;
        }

        const { data: taskData, error: updateError } = await supabase
            .from('cleanup_tasks')
            .update(updateData)
            .eq('id', id)
            .select()
            .single();

        if (updateError) {
            return res.status(400).json({
                message: 'Failed to assign cleanup task',
                error: updateError.message
            });
        }

        // Send notifications to newly assigned crew
        for (const crewId of newlyAssigned) {
            try {
                await supabase
                    .from('notifications')
                    .insert({
                        user_id: crewId,
                        report_id: null,
                        cleanup_task_id: id,
                        type: 'task_assigned',
                        title: 'Task Assigned',
                        body: `You have been assigned to cleanup task: ${taskData.title}`
                    });
            } catch (notifError) {
                console.error('Failed to send notification to crew:', crewId, notifError);
            }
        }

        // Send notifications to removed crew
        for (const crewId of removedAssignees) {
            try {
                await supabase
                    .from('notifications')
                    .insert({
                        user_id: crewId,
                        report_id: null,
                        cleanup_task_id: id,
                        type: 'task_reassigned',
                        title: 'Task Reassigned',
                        body: `You have been removed from cleanup task: ${taskData.title}`
                    });
            } catch (notifError) {
                console.error('Failed to send notification to crew:', crewId, notifError);
            }
        }

        res.status(200).json({
            message: 'Cleanup task assigned successfully',
            task: taskData
        });
    } catch (error) {
        next(error);
    }
};

// Get available field crew members for assignment
export const getAvailableCrew = async (req, res, next) => {
    try {
        const { data, error } = await supabase
            .from('profiles')
            .select('id, full_name, avatar_url')
            .eq('role', 'field_crew')
            .order('full_name', { ascending: true });

        if (error) {
            return res.status(400).json({
                message: 'Failed to fetch available crew',
                error: error.message
            });
        }

        res.status(200).json(data);
    } catch (error) {
        next(error);
    }
};
