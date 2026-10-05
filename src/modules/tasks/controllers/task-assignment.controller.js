import { supabaseAdmin as supabase } from '../../../config/supabase.config.js';

export const assignTask = async (req, res, next) => {
  try {
    const { taskId, crewId } = req.body;
    
    // Fetch task details
    const { data: task, error: fetchError } = await supabase
      .from('cleanup_tasks')
      .select('*, clusters(is_outlier)')
      .eq('id', taskId)
      .single();
      
    if (fetchError || !task) {
      return res.status(404).json({ message: 'Task not found' });
    }

    const isOutlier = task.clusters?.is_outlier || task.is_outlier;
    
    // For sweeper tasks, validate route time against shift duration
    if (isOutlier) {
      const { data: config } = await supabase
        .from('sweeper_config')
        .select('value')
        .eq('key', 'shift_duration_hours')
        .single();
        
      const shiftDuration = config?.value || 8; // Default 8 hours
      const shiftDurationMins = shiftDuration * 60;
      
      // Assume total_route_time is stored in estimated_duration_min or calculated elsewhere
      const totalRouteTime = task.estimated_duration_min || 0;
      
      if (totalRouteTime > shiftDurationMins) {
        return res.status(400).json({ 
          message: 'Assignment failed: total_route_time exceeds shift_duration for sweeper task' 
        });
      }
    }

    // Assign the task
    const { data: updatedTask, error: updateError } = await supabase
      .from('cleanup_tasks')
      .update({
        assigned_crew_ids: [crewId],
        status: 'Assigned',
        assigned_at: new Date().toISOString(),
        assigned_by: req.user?.id || null
      })
      .eq('id', taskId)
      .select()
      .single();

    if (updateError) {
      return res.status(400).json({ message: 'Failed to assign task', error: updateError.message });
    }

    // Trigger notification to field crew
    await supabase.from('notifications').insert({
      user_id: crewId,
      title: 'New Task Assigned',
      message: `You have been assigned a new task: ${task.id}`,
      type: 'task_assignment',
      reference_id: task.id
    });

    res.status(200).json({ message: 'Task assigned successfully', task: updatedTask });
  } catch (error) {
    next(error);
  }
};
