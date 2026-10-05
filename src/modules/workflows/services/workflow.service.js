import { supabaseAdmin as supabase } from '../../../config/supabase.config.js';

export const createWorkflow = async (workflowData) => {
  const { name, description, workflow_type = 'standard', created_by } = workflowData;
  
  if (!['standard', 'sweeper'].includes(workflow_type)) {
    throw new Error('Invalid workflow_type. Must be either standard or sweeper.');
  }

  const { data, error } = await supabase
    .from('workflows')
    .insert({
      name,
      description,
      workflow_type,
      created_by,
      status: 'active'
    })
    .select()
    .single();

  if (error) {
    throw new Error(`Failed to create workflow: ${error.message}`);
  }

  return data;
};

export const getWorkflows = async (filters = {}) => {
  let query = supabase.from('workflows').select(`
    *,
    cleanup_tasks (
      id,
      status,
      is_outlier,
      estimated_duration_min
    )
  `);

  if (filters.status) {
    query = query.eq('status', filters.status);
  }

  if (filters.workflow_type) {
    query = query.eq('workflow_type', filters.workflow_type);
  }

  const { data, error } = await query;

  if (error) {
    throw new Error(`Failed to fetch workflows: ${error.message}`);
  }

  return data;
};

export const getWorkflowTasks = async (workflowId, filters = {}) => {
  let query = supabase
    .from('cleanup_tasks')
    .select('*')
    .eq('workflow_id', workflowId);

  // Apply status filters to both standard and sweeper tasks simultaneously
  if (filters.status) {
    query = query.in('status', Array.isArray(filters.status) ? filters.status : [filters.status]);
  }

  const { data, error } = await query;

  if (error) {
    throw new Error(`Failed to fetch workflow tasks: ${error.message}`);
  }

  return data;
};
