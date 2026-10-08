import { generateDispatchPlan } from '../modules/optimization/services/dispatchPlanner.service.js';
import { commitAndRoutePlan } from '../modules/optimization/services/dispatchCommit.service.js';
import { processTaskFeedback } from '../modules/optimization/services/taskFeedback.service.js';
import { supabaseAdmin as supabase } from "../config/supabase.config.js";
import { CLEANUP_TASK_PHOTOS_STORAGE_PATH } from "../config/index.js";
import multer from 'multer';
import { BEFORE_AFTER_PHOTO_FILE_SIZE } from "../config/index.js";
import { hashBuffer, checkPhotoDuplicate } from '../services/photo_dedup.service.js';

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
    if(!Array.isArray(req.body.assigned_crew_ids??[])) return res.status(400).json({message:'assigned_crew_ids must be an array'});
    const {data,error}=await supabase.rpc('create_manual_cleanup_task',{
      actor:req.user.id,selected_report_ids:req.body.report_ids,task_title:req.body.title,
      task_description:req.body.description??null,crew_member_ids:req.body.assigned_crew_ids??[],
      task_priority:req.body.priority??null
    });
    if(error) throw error;
    if(data.status==='conflict') return res.status(409).json({message:'Selected reports changed or are blocked; refresh before creating a task',...data});
    if ((req.body.assigned_crew_ids??[]).length) {
      const {error:noticeError}=await supabase.from('notifications').insert(req.body.assigned_crew_ids.map(user_id=>({
        user_id,report_id:null,cleanup_task_id:data.task.id,type:'task_assigned',
        title:'New Task Assigned',body:`You have been assigned to cleanup task: ${data.task.title}`
      })));
      if(noticeError) console.error('Manual task notification failed',noticeError);
    }
    res.status(201).json({message:'Custom cleanup task created successfully',task:data.task});
  } catch(error){next(error);}
};

export const getAllCleanupTasks = async (req, res, next) => {
    try {
        const { assigned_to_me } = req.query;
        const userId = req.user.id;

        let query = supabase
            .from('cleanup_tasks')
            .select('*, clusters(*), reports(id, title, description, issue_type, location, status, report_claim_generation)')
            .order('created_at', { ascending: false });

        // Filter for tasks assigned to current user if requested
        if (assigned_to_me === 'true' || req.user.role === 'field_crew') {
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

        res.status(200).json(data.map(task => ({
            ...task,
            report_claim_generations: Object.fromEntries((task.reports ?? [])
                .map(report => [report.id, report.report_claim_generation])),
        })));
    } catch (error) {
        next(error);
    }
};

export const getCleanupTaskById = async (req, res, next) => {
    const { id } = req.params;

    try {
        const { data, error } = await supabase
            .from('cleanup_tasks')
            .select('*, clusters(*), reports(id, title, description, issue_type, location, status, report_claim_generation)')
            .eq('id', id)
            .single();

        if (error) {
            return res.status(404).json({
                message: 'Cleanup task not found',
                error: error.message
            });
        }

        if(req.user.role==='field_crew'&&!data.assigned_crew_ids?.includes(req.user.id)) return res.status(403).json({message:'Task access denied'});
        res.status(200).json({
            ...data,
            report_claim_generations: Object.fromEntries((data.reports ?? [])
                .map(report => [report.id, report.report_claim_generation])),
        });
    } catch (error) {
        next(error);
    }
};

// Upload before/after photo for cleanup task
async function photoTask(taskId,user) {
  const {data:task,error}=await supabase.from('cleanup_tasks').select('*').eq('id',taskId).single();
  if(error||!task) { const e=new Error('Task not found');e.statusCode=404;throw e; }
  if(!['admin','officer'].includes(user.role)&&(!task.assigned_crew_ids?.includes(user.id)||task.route_status!=='ready')) {
    const e=new Error('Task access denied');e.statusCode=403;throw e;
  }
  return task;
}
export const uploadCleanupPhoto = async (req,res,next) => {
  try {
    const {taskId}=req.params;const {photo_type}=req.body;
    if(!['before','after'].includes(photo_type)||!req.file) return res.status(400).json({message:'An image and before/after photo_type are required'});
    const task=await photoTask(taskId,req.user);
    const incomingHash=hashBuffer(req.file.buffer);
    const {isDuplicate}=await checkPhotoDuplicate('cleanup_tasks',taskId,photo_type,incomingHash);
    if(isDuplicate) return res.json({duplicate:true,task});
    const filePath=`${taskId}/${photo_type}/${crypto.randomUUID()}`;
    const {error:uploadError}=await supabase.storage.from(CLEANUP_TASK_PHOTOS_STORAGE_PATH).upload(filePath,req.file.buffer,{contentType:req.file.mimetype,upsert:false});
    if(uploadError) throw uploadError;
    const {data:urlData}=supabase.storage.from(CLEANUP_TASK_PHOTOS_STORAGE_PATH).getPublicUrl(filePath);
    const {data,error}=await supabase.rpc('set_task_photo',{task_id:taskId,actor:req.user.id,slot:photo_type,url:urlData.publicUrl,photo_hash:incomingHash,expected_version:task.fc_version});
    if(error||data.status==='conflict') {
      await supabase.storage.from(CLEANUP_TASK_PHOTOS_STORAGE_PATH).remove([filePath]);
      return res.status(error?.code==='42501'?403:409).json({message:error?.message??'Task changed; retry photo upload'});
    }
    res.json({task:data.server_record});
  } catch(error){next(error);}
};
export const deleteCleanupPhoto = async (req,res,next) => {
  try {
    const {taskId}=req.params;const {photo_type}=req.body;
    if(!['before','after'].includes(photo_type)) return res.status(400).json({message:'before/after photo_type required'});
    const task=await photoTask(taskId,req.user);
    const {data,error}=await supabase.rpc('set_task_photo',{task_id:taskId,actor:req.user.id,slot:photo_type,url:null,photo_hash:null,expected_version:task.fc_version});
    if(error) throw error;
    if(data.status==='conflict') return res.status(409).json(data);
    res.json({task:data.server_record});
  } catch(error){next(error);}
};

export const markTaskComplete = async (req,res,next) => {
  try {
    const task=await processTaskFeedback(req.params.id,req.body.outcome??'completed',req.body.notes,req.user.id,req.body);
    res.json({message:'Task outcome recorded',task});
  } catch(error){next(error);}
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
export const assignCleanupTask = async (req,res) => {
  res.status(409).json({message:'Assignments are published atomically from dispatch plans. Cancel with a classified outcome and generate a new plan to change crews.'});
};

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

export const updateCleanupTaskTitle = async (req, res, next) => {
    const { id } = req.params;
    const { title } = req.body;

    if (!title || typeof title !== 'string' || title.trim() === '') {
        return res.status(400).json({ message: 'Valid title is required' });
    }

    try {
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
