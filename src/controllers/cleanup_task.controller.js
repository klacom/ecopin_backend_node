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
    const { cluster_id, title, description } = req.body;
    const user_id = req.user.id;

    try {
        const { data, error } = await supabase
            .from('cleanup_tasks')
            .insert({
                cluster_id,
                title,
                description,
                status: 'pending',
                created_by: user_id
            })
            .select()
            .single();

        if (error) {
            return res.status(400).json({
                message: 'Failed to create cleanup task',
                error: error.message
            });
        }

        // Update all reports in the cluster to 'in_progress'
        const { error: reportsError } = await supabase
            .from('reports')
            .update({
                status: 'in_progress',
                updated_at: new Date().toISOString()
            })
            .eq('cluster_id', cluster_id);

        if (reportsError) {
            console.error('Failed to update reports to in_progress:', reportsError);
            // Don't fail the request, just log the error
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
    const { report_ids, title, description } = req.body;
    const user_id = req.user.id;

    if (!report_ids || !Array.isArray(report_ids) || report_ids.length === 0) {
        return res.status(400).json({
            message: 'Report IDs are required',
            error: 'Please provide at least one report ID'
        });
    }

    try {
        // Create cleanup task with report_ids array (custom task)
        const { data, error } = await supabase
            .from('cleanup_tasks')
            .insert({
                title,
                description,
                status: 'pending',
                created_by: user_id,
                is_custom: true,
                report_ids: report_ids
            })
            .select()
            .single();

        if (error) {
            return res.status(400).json({
                message: 'Failed to create cleanup task',
                error: error.message
            });
        }

        // Update selected reports to 'in_progress'
        const { error: reportsError } = await supabase
            .from('reports')
            .update({
                status: 'in_progress',
                updated_at: new Date().toISOString()
            })
            .in('id', report_ids);

        if (reportsError) {
            console.error('Failed to update reports to in_progress:', reportsError);
            // Don't fail the request, just log the error
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
        const { data, error } = await supabase
            .from('cleanup_tasks')
            .select('*, clusters(*)')
            .order('created_at', { ascending: false });

        if (error) {
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

export const getCleanupTaskById = async (req, res, next) => {
    const { id } = req.params;

    try {
        const { data, error } = await supabase
            .from('cleanup_tasks')
            .select('*, clusters(*), profiles(full_name)')
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

    try {
        // 1. Mark the task as complete
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

        // 2. Handle different task types
        if (taskData.is_custom && taskData.report_ids) {
            // Custom task: Update reports from report_ids array
            const reportIds = taskData.report_ids;

            if (reportIds.length > 0) {
                const { error: reportsError } = await supabase
                    .from('reports')
                    .update({
                        status: 'resolved',
                        updated_at: new Date().toISOString()
                    })
                    .in('id', reportIds);

                if (reportsError) {
                    console.error('Failed to update reports:', reportsError);
                    return res.status(400).json({
                        message: 'Task marked complete, but failed to update reports',
                        error: reportsError.message
                    });
                }
            }
        } else {
            // Cluster-based task: Update all reports in the cluster
            const clusterId = taskData.cluster_id;

            if (clusterId) {
                const { error: reportsError } = await supabase
                    .from('reports')
                    .update({
                        status: 'resolved',
                        updated_at: new Date().toISOString()
                    })
                    .eq('cluster_id', clusterId);

                if (reportsError) {
                    return res.status(400).json({
                        message: 'Task marked complete, but failed to update reports',
                        error: reportsError.message
                    });
                }
            }
        }

        res.status(200).json({
            message: 'Cleanup task completed successfully, all linked reports marked as resolved',
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
