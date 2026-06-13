import { supabaseAdmin as supabase } from "../supabase_config/supabase.config.js";
import multer from 'multer';

// Configure multer for memory storage
const storage = multer.memoryStorage();
export const upload = multer({
    storage: storage,
    limits: { fileSize: 10 * 1024 * 1024 }, // 10MB limit
    fileFilter: (req, file, cb) => {
        if (file.mimetype.startsWith('image/')) {
            cb(null, true);
        } else {
            cb(new Error('Only image files are allowed'), false);
        }
    }
});

/**
 * Create a new cleanup task
 */
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

        res.status(201).json({
            message: 'Cleanup task created successfully',
            task: data
        });
    } catch (error) {
        next(error);
    }
};

/**
 * Get all cleanup tasks
 */
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

/**
 * Get cleanup task by ID
 */
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

/**
 * Upload before/after photo for cleanup task
 */
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
            .from('Cleanup Task Photos')
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
            .from('Cleanup Task Photos')
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

/**
 * Mark cleanup task as complete
 */
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

        // 2. Get the cluster_id from the task
        const clusterId = taskData.cluster_id;

        // 3. Update all reports in this cluster to RESOLVED
        const { error: reportsError } = await supabase
            .from('reports')
            .update({ status: 'resolved' })
            .eq('cluster_id', clusterId);

        if (reportsError) {
            return res.status(400).json({
                message: 'Task marked complete, but failed to update reports',
                error: reportsError.message
            });
        }

        res.status(200).json({
            message: 'Cleanup task completed successfully, all linked reports marked as resolved',
            task: taskData
        });
    } catch (error) {
        next(error);
    }
};

/**
 * Get cleanup tasks by cluster ID
 */
export const getTasksByClusterId = async (req, res, next) => {
    const { clusterId } = req.params;

    try {
        const { data, error } = await supabase
            .from('cleanup_tasks')
            .select('*')
            .eq('cluster_id', clusterId)
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
