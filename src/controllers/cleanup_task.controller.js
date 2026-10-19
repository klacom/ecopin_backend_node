import {getStorageMedia} from './media.controller.js';
import {storageReference,parseStorageReference} from '../services/storage-reference.js';
import { removeOrQueue } from '../services/storage-cleanup.service.js';
import { generateDispatchPlan } from '../modules/optimization/services/dispatchPlanner.service.js';
import { commitAndRoutePlan } from '../modules/optimization/services/dispatchCommit.service.js';
import { processTaskFeedback } from '../modules/optimization/services/taskFeedback.service.js';
import { supabaseAdmin as supabase } from "../config/supabase.config.js";
import { CLEANUP_TASK_PHOTOS_STORAGE_PATH, NEXT_PUBLIC_SUPABASE_URL } from "../config/index.js";
import multer from 'multer';
import {reportPage} from '../services/report-access.service.js';
import { BEFORE_AFTER_PHOTO_FILE_SIZE } from "../config/index.js";
import { hashBuffer, checkPhotoDuplicate } from '../services/photo_dedup.service.js';
import { validateUploadedPhotoBuffer } from '../services/magic-byte.service.js';


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

export const createCleanupTask = async (req,res,next) => {
  try {
    if (!req.body.cluster_id) return res.status(400).json({message:'cluster_id is required'});
    const {plan}=await generateDispatchPlan(req.user.id,{mode:'standard',cluster_ids:[req.body.cluster_id]});
    const result=await commitAndRoutePlan(plan.id,req.user.id);
    res.status(result.routing_status==='needs_replan'?202:201).json({...result,task:result.tasks[0]??null});
  } catch(error){next(error);}
};
export const createCustomCleanupTask = async (req,res,next) => {
  try {
    if (!Array.isArray(req.body.report_ids)||!req.body.report_ids.length) return res.status(400).json({message:'report_ids are required'});
    
    let fieldCrewId = req.body.field_crew_id || req.body.assigned_field_crew_id || req.body.crew_id || null;
    let crewMemberIds = Array.isArray(req.body.assigned_crew_ids) ? [...req.body.assigned_crew_ids] : [];

    if (fieldCrewId && crewMemberIds.length === 0) {
      const { data: crew } = await supabase
        .from('field_crews')
        .select('*')
        .eq('id', fieldCrewId)
        .single();
      if (crew) {
        const rawMembers = [...(crew.member_profile_ids || []), crew.team_lead_profile_id].filter(Boolean);
        crewMemberIds = [...new Set(rawMembers)];
      }
    }

    if(!Array.isArray(crewMemberIds)) return res.status(400).json({message:'assigned_crew_ids must be an array'});
    const {data,error}=await supabase.rpc('create_manual_cleanup_task',{
      actor:req.user.id,selected_report_ids:req.body.report_ids,task_title:req.body.title,
      task_description:req.body.description??null,crew_member_ids:crewMemberIds,
      task_priority:req.body.priority??null
    });
    if(error) throw error;
    if(data.status==='conflict') return res.status(409).json({message:'Selected reports changed or are blocked; refresh before creating a task',...data});

    if (fieldCrewId && data.task?.id) {
      await supabase
        .from('cleanup_tasks')
        .update({ assigned_field_crew_id: fieldCrewId })
        .eq('id', data.task.id);
      data.task.assigned_field_crew_id = fieldCrewId;
    }

    res.status(201).json({message:'Custom cleanup task created successfully',task:data.task});
  } catch(error){next(error);}
};

async function readCleanupTasks(req, filters = {}) {
  if (!req.user?.id) {
    const error = new Error('Authentication required');
    error.statusCode = 401;
    throw error;
  }
  const {limit, offset} = reportPage(req.query ?? {});
  const {data, error} = await supabase.rpc('read_authorized_cleanup_tasks', {
    actor: req.user.id,
    p_task_id: filters.taskId ?? null,
    p_cluster_id: filters.clusterId ?? null,
    p_assigned_only: req.query?.assigned_to_me === 'true',
    p_limit: filters.taskId ? 1 : limit + 1,
    p_offset: filters.taskId ? 0 : offset,
  });
  if (error) throw error;
  if (!Array.isArray(data)) throw new Error('Invalid authorized task response');
  return {data: data.slice(0, limit), hasMore: data.length > limit};
}

function taskReadError(error, res, next) {
  if ([400, 401].includes(error.statusCode)) {
    return res.status(error.statusCode).json({message: error.message});
  }
  return next(error);
}

export const getAllCleanupTasks = async (req, res, next) => {
  try {
    const {data, hasMore} = await readCleanupTasks(req);
    res.set('Cache-Control', 'private, no-store');
    res.set('X-Has-More', String(hasMore));
    return res.json(data);
  } catch (error) {
    return taskReadError(error, res, next);
  }
};

export const getCleanupTaskById = async (req, res, next) => {
  try {
    const {data} = await readCleanupTasks(req, {taskId: req.params.id});
    res.set('Cache-Control', 'private, no-store');
    if (!data.length) return res.status(404).json({message: 'Cleanup task not found'});
    return res.json(data[0]);
  } catch (error) {
    return taskReadError(error, res, next);
  }
};

function extractValidatedStoragePath(photoUrl,expectedBucket,expectedTaskId,expectedSlot){
 const reference=parseStorageReference(photoUrl,NEXT_PUBLIC_SUPABASE_URL);
 if(!reference||reference.bucket!==expectedBucket) return null;
 const parts=reference.path.split('/');
 return parts[0]===expectedTaskId&&parts[1]===expectedSlot?reference.path:null;
}
// Upload before/after photo for cleanup task
async function photoTask(taskId,user) {
  const {data:task,error}=await supabase.from('cleanup_tasks').select('*').eq('id',taskId).single();
  if(error||!task) { const e=new Error('Task not found');e.statusCode=404;throw e; }
  if(!['created','pending','assigned','en_route','in_progress','partially_completed'].includes(task.status)) {
    const e=new Error('Task is no longer accepting photos');e.statusCode=409;throw e;
  }
  if(!['admin','officer'].includes(user.role)&&(!task.assigned_crew_ids?.includes(user.id)||task.route_status!=='ready')) {
    const e=new Error('Task access denied');e.statusCode=403;throw e;
  }
  return task;
}
export const uploadCleanupPhoto = async (req,res,next) => {
  try {
    const {taskId}=req.params;const {photo_type}=req.body;
    if(!['before','after'].includes(photo_type)||!req.file) return res.status(400).json({message:'An image and before/after photo_type are required'});
    validateUploadedPhotoBuffer(req.file.buffer, req.file.mimetype);
    const task=await photoTask(taskId,req.user);
    const incomingHash=hashBuffer(req.file.buffer);
    const {isDuplicate}=await checkPhotoDuplicate('cleanup_tasks',taskId,photo_type,incomingHash);
    if(isDuplicate) return res.json({duplicate:true,task});
    const filePath=`${taskId}/${photo_type}/${crypto.randomUUID()}`;
    const {error:uploadError}=await supabase.storage.from(CLEANUP_TASK_PHOTOS_STORAGE_PATH).upload(filePath,req.file.buffer,{contentType:req.file.mimetype,upsert:false});
    if(uploadError) throw uploadError;

    const targetUrl=storageReference(CLEANUP_TASK_PHOTOS_STORAGE_PATH,filePath);
    const previousPhotoUrl = task[`${photo_type}_photo_url`];
    let attachment;
    try {
      attachment=await supabase.rpc('set_task_photo',{task_id:taskId,actor:req.user.id,slot:photo_type,url:targetUrl,photo_hash:incomingHash,expected_version:task.fc_version});
    } catch(error) {
      // A transport failure may hide a committed attachment; the worker rechecks references.
      await removeOrQueue(CLEANUP_TASK_PHOTOS_STORAGE_PATH,filePath);
      throw error;
    }
    const {data,error}=attachment;
    if(error||!data||data.status==='conflict') {
      await removeOrQueue(CLEANUP_TASK_PHOTOS_STORAGE_PATH, filePath);
      return res.status(error?.code==='42501'?403:409).json({message:error?.message??'Task changed; retry photo upload'});
    }
    if (previousPhotoUrl) {
      const previousPath = extractValidatedStoragePath(previousPhotoUrl, CLEANUP_TASK_PHOTOS_STORAGE_PATH, taskId, photo_type);
      if (previousPath && previousPath !== filePath) {
        await removeOrQueue(CLEANUP_TASK_PHOTOS_STORAGE_PATH, previousPath);
      }
    }
    res.json({task:data.server_record});
  } catch(error){next(error);}
};
export const deleteCleanupPhoto = async (req,res,next) => {
  try {
    const {taskId}=req.params;const {photo_type}=req.body;
    if(!['before','after'].includes(photo_type)) return res.status(400).json({message:'before/after photo_type required'});
    const task=await photoTask(taskId,req.user);
    const previousPhotoUrl = task[`${photo_type}_photo_url`];
    const {data,error}=await supabase.rpc('set_task_photo',{task_id:taskId,actor:req.user.id,slot:photo_type,url:null,photo_hash:null,expected_version:task.fc_version});
    if(error) throw error;
    if(data.status==='conflict') return res.status(409).json(data);
    if (previousPhotoUrl) {
      const previousPath = extractValidatedStoragePath(previousPhotoUrl, CLEANUP_TASK_PHOTOS_STORAGE_PATH, taskId, photo_type);
      if (previousPath) {
        await removeOrQueue(CLEANUP_TASK_PHOTOS_STORAGE_PATH, previousPath);
      }
    }
    res.json({task:data.server_record});
  } catch(error){next(error);}
};

export const getCleanupPhotoMedia = async (req,res,next) => {
 try {
  const {taskId,slot}=req.params;
  if(!['before','after'].includes(slot)) return res.status(400).json({message:'Invalid photo slot'});
  const {data:task,error}=await supabase.from('cleanup_tasks').select('before_photo_url,after_photo_url').eq('id',taskId).single();
  if(error||!task) return res.status(404).json({message:'Media unavailable'});
  const path=extractValidatedStoragePath(task[`${slot}_photo_url`],CLEANUP_TASK_PHOTOS_STORAGE_PATH,taskId,slot);
  if(!path) return res.status(404).json({message:'Photo reference is not a trusted Storage object'});
  return getStorageMedia({query:{bucket:CLEANUP_TASK_PHOTOS_STORAGE_PATH,path},headers:req.headers},res,next);
 }catch(error){next(error);}
};
export const updateCleanupTaskStatus = async (req, res, next) => {
  try {
    const { id } = req.params;
    const { status } = req.body;
    const user = req.user;

    if (!status) {
      return res.status(400).json({ message: 'status is required' });
    }

    const { data: currentTask, error: fetchErr } = await supabase
      .from('cleanup_tasks')
      .select('id, status, assigned_crew_ids, fc_version')
      .eq('id', id)
      .maybeSingle();

    if (fetchErr || !currentTask) {
      return res.status(404).json({ message: 'Cleanup task not found' });
    }

    // Permission check
    if (!['admin', 'officer'].includes(user.role) && !currentTask.assigned_crew_ids?.includes(user.id)) {
      return res.status(403).json({ message: 'Access denied: you are not assigned to this task' });
    }

    // Idempotent duplicate check
    if (currentTask.status === status) {
      return res.status(200).json({ message: `Task is already ${status}`, task: currentTask });
    }

    // Disallow mutations of terminal tasks
    if (['completed', 'cancelled'].includes(currentTask.status)) {
      return res.status(409).json({ message: `Cannot change status of a ${currentTask.status} task.` });
    }

    if (status === 'en_route') {
      // Allowed from created, pending, assigned
      if (!['created', 'pending', 'assigned'].includes(currentTask.status)) {
        return res.status(409).json({
          message: `Cannot transition task to en_route from current status: ${currentTask.status}`
        });
      }

      const { data: updatedTask, error: updateErr } = await supabase
        .from('cleanup_tasks')
        .update({
          status: 'en_route',
          fc_version: (currentTask.fc_version || 0) + 1,
          updated_at: new Date().toISOString()
        })
        .eq('id', id)
        .select()
        .single();

      if (updateErr) throw updateErr;
      return res.status(200).json({ message: 'Task marked as en route', task: updatedTask });
    }

    if (status === 'completed') {
      // Enforce strict state machine: task must be en_route (or in_progress) before completed
      if (!['en_route', 'in_progress'].includes(currentTask.status)) {
        return res.status(409).json({
          message: 'Task must be en_route before it can be marked as completed.'
        });
      }
      const task = await processTaskFeedback(id, req.body.outcome ?? 'completed', req.body.notes, req.user.id, req.body);
      return res.status(200).json({ message: 'Task marked as complete', task });
    }

    // Desk ops overrides for other statuses
    if (['admin', 'officer'].includes(user.role)) {
      const { data: updatedTask, error: updateErr } = await supabase
        .from('cleanup_tasks')
        .update({
          status,
          fc_version: (currentTask.fc_version || 0) + 1,
          updated_at: new Date().toISOString()
        })
        .eq('id', id)
        .select()
        .single();

      if (updateErr) throw updateErr;
      return res.status(200).json({ message: `Task status updated to ${status}`, task: updatedTask });
    }

    return res.status(400).json({ message: `Invalid status transition to ${status}` });
  } catch (error) {
    next(error);
  }
};

export const markTaskComplete = async (req,res,next) => {
  try {
    const { data: currentTask, error: fetchErr } = await supabase
      .from('cleanup_tasks')
      .select('id, status, assigned_crew_ids')
      .eq('id', req.params.id)
      .maybeSingle();

    if (fetchErr || !currentTask) {
      return res.status(404).json({ message: 'Task not found' });
    }

    if (!['admin', 'officer'].includes(req.user.role) && !currentTask.assigned_crew_ids?.includes(req.user.id)) {
      return res.status(403).json({ message: 'Access denied: you are not assigned to this task' });
    }

    if (currentTask.status === 'completed') {
      return res.status(200).json({ message: 'Task already completed', task: currentTask });
    }

    if (['created', 'pending', 'assigned'].includes(currentTask.status)) {
      return res.status(409).json({
        message: 'Task cannot be completed directly from assigned/pending. Must transition to en_route first.'
      });
    }

    const task=await processTaskFeedback(req.params.id,req.body.outcome??'completed',req.body.notes,req.user.id,req.body);
    res.json({message:'Task outcome recorded',task});
  } catch(error){next(error);}
};

export const getTasksByClusterId = async (req, res, next) => {
  try {
    const {data, hasMore} = await readCleanupTasks(req, {clusterId: req.params.clusterId});
    res.set('Cache-Control', 'private, no-store');
    res.set('X-Has-More', String(hasMore));
    return res.json(data);
  } catch (error) {
    return taskReadError(error, res, next);
  }
};

// Assign cleanup task to a field crew team entity
export const assignCleanupTask = async (req, res, next) => {
    const { id } = req.params;
    const crewId = req.body.crew_id || req.body.assigned_field_crew_id || (Array.isArray(req.body.assigned_crew_ids) && req.body.assigned_crew_ids.length > 0 ? req.body.assigned_crew_ids[0] : null);
    const userId = req.user.id;

    try {
        const { data: currentTask, error: fetchError } = await supabase
            .from('cleanup_tasks')
            .select('*')
            .eq('id', id)
            .single();

        if (fetchError || !currentTask) {
            return res.status(404).json({
                message: 'Cleanup task not found',
                error: fetchError?.message
            });
        }

        const isTaskOwner = currentTask.created_by === userId || currentTask.lgu_user_id === userId;
        if (req.user.role !== 'admin' && (currentTask.created_by || currentTask.lgu_user_id) && !isTaskOwner) {
            return res.status(403).json({
                message: 'Access denied: cannot assign cleanup task belonging to another LGU or officer'
            });
        }

        let updateData = {
            last_assigned_at: new Date().toISOString()
        };

        let newMemberIds = [];

        if (crewId) {
            // Find crew entity
            const { data: crew, error: crewError } = await supabase
                .from('field_crews')
                .select('*')
                .eq('id', crewId)
                .single();

            if (crewError || !crew) {
                return res.status(404).json({
                    message: 'Field crew not found',
                    error: crewError?.message
                });
            }

            const rawMembers = [...(crew.member_profile_ids || []), crew.team_lead_profile_id].filter(Boolean);
            newMemberIds = [...new Set(rawMembers)];

            updateData.assigned_field_crew_id = crew.id;
            updateData.assigned_crew_ids = newMemberIds;
            updateData.assigned_by = userId;

            if (!currentTask.assigned_at) {
                updateData.assigned_at = new Date().toISOString();
            }

            if (currentTask.status === 'created') {
                updateData.status = 'pending';
            }
        } else {
            // Unassign crew
            updateData.assigned_field_crew_id = null;
            updateData.assigned_crew_ids = null;

            if (currentTask.status === 'pending') {
                updateData.status = 'created';
            }
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

        // Notify newly assigned members
        if (newMemberIds.length > 0) {
            for (const memberId of newMemberIds) {
                try {
                    await supabase
                        .from('notifications')
                        .insert({
                            user_id: memberId,
                            report_id: null,
                            cleanup_task_id: id,
                            type: 'task_assigned',
                            title: 'Task Assigned',
                            body: `Your crew has been assigned to cleanup task: ${taskData.title}`
                        });
                } catch (notifErr) {
                    console.error('Failed to notify crew member:', memberId, notifErr);
                }
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

export const getAvailableCrew = async (req, res, next) => {
    try {
        const { data: crews, error } = await supabase
            .from('field_crews')
            .select('*')
            .order('name', { ascending: true });

        if (error) {
            return res.status(400).json({
                message: 'Failed to fetch available crews',
                error: error.message
            });
        }

        // Fetch active cleanup tasks (not completed and not cancelled)
        const { data: activeTasks, error: tasksError } = await supabase
            .from('cleanup_tasks')
            .select('id, title, status, priority_score, scheduled_date, assigned_field_crew_id, assigned_crew_ids')
            .in('status', ['created', 'pending', 'in_progress', 'partially_completed']);

        if (tasksError) {
            console.warn('Failed to fetch active tasks for available crews:', tasksError.message);
        }

        const tasksList = activeTasks || [];

        const enriched = await Promise.all((crews || []).map(async (crew) => {
            const memberIds = crew.member_profile_ids || [];
            let members = [];
            if (memberIds.length > 0) {
                const { data: profiles } = await supabase
                    .from('profiles')
                    .select('id, full_name, avatar_url')
                    .in('id', memberIds);
                members = profiles || [];
            }

            const crewTasks = tasksList.filter((t) =>
                t.assigned_field_crew_id === crew.id ||
                (Array.isArray(t.assigned_crew_ids) && memberIds.some((mId) => t.assigned_crew_ids.includes(mId)))
            );

            const maxTasks = Number(crew.max_tasks_per_shift) || 10;
            const activeTaskCount = crewTasks.length;

            return {
                id: crew.id,
                name: crew.name,
                full_name: crew.name,
                shift_start: crew.shift_start,
                shift_end: crew.shift_end,
                availability_status: crew.availability_status,
                max_tasks_per_shift: maxTasks,
                member_count: members.length,
                members,
                active_task_count: activeTaskCount,
                assigned_tasks_count: activeTaskCount,
                active_tasks: crewTasks.map((t) => ({
                    id: t.id,
                    title: t.title || 'Cleanup Task',
                    status: t.status,
                    priority_score: t.priority_score,
                    scheduled_date: t.scheduled_date
                })),
                is_at_capacity: activeTaskCount >= maxTasks
            };
        }));

        res.status(200).json(enriched);
    } catch (error) {
        next(error);
    }
};

export const updateCleanupTaskTitle = async (req, res, next) => {
    const { id } = req.params;
    const { title } = req.body;

    if (!title || typeof title !== 'string' || title.trim() === '') {
        return res.status(400).json({ message: 'Valid title is required' });
    }

    try {
        const { data: currentTask, error: fetchError } = await supabase
            .from('cleanup_tasks')
            .select('id, created_by, lgu_user_id')
            .eq('id', id)
            .maybeSingle();

        if (fetchError || !currentTask) {
            return res.status(404).json({ message: 'Cleanup task not found' });
        }

        const isTaskOwner = currentTask.created_by === req.user.id || currentTask.lgu_user_id === req.user.id;
        if (req.user.role !== 'admin' && (currentTask.created_by || currentTask.lgu_user_id) && !isTaskOwner) {
            return res.status(403).json({ message: 'Access denied: cannot modify task belonging to another LGU or officer' });
        }

        const { data, error } = await supabase
            .from('cleanup_tasks')
            .update({ title: title.trim() })
            .eq('id', id)
            .select()
            .single();

        if (error) {
            return res.status(400).json({
                message: 'Failed to update task title',
                error: error.message
            });
        }

        res.status(200).json(data);
    } catch (error) {
        next(error);
    }
};
