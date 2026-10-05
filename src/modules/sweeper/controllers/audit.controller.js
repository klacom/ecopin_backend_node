import { supabaseAdmin as supabase } from '../../../config/supabase.config.js';

export async function getAuditLogs(req, res) {
  // Check role-based access control
  if (req.user?.role !== 'admin' && req.user?.role !== 'system_administrator') {
    return res.status(403).json({ error: 'Access denied: Admin role required' });
  }

  try {
    const { report_id, cluster_id, task_id, page = 1, limit = 20 } = req.query;
    
    let query = supabase
      .from('sweeper_audit_log')
      .select('*', { count: 'exact' });

    // Apply filtering if provided
    if (report_id) {
      query = query.eq('entity_type', 'REPORT').eq('entity_id', report_id);
    } else if (cluster_id) {
      query = query.eq('entity_type', 'CLUSTER').eq('entity_id', cluster_id);
    } else if (task_id) {
      query = query.eq('entity_type', 'TASK').eq('entity_id', task_id);
    }

    // Apply pagination
    const from = (parseInt(page) - 1) * parseInt(limit);
    const to = from + parseInt(limit) - 1;
    
    query = query
      .order('created_at', { ascending: false })
      .range(from, to);

    const { data, count, error } = await query;

    if (error) {
      throw error;
    }

    res.json({
      data,
      pagination: {
        total: count,
        page: parseInt(page),
        limit: parseInt(limit),
        totalPages: Math.ceil(count / parseInt(limit))
      }
    });
  } catch (error) {
    console.error('Error fetching audit logs:', error);
    res.status(500).json({ error: 'Failed to fetch audit logs' });
  }
}
