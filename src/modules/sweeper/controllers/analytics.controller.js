import { sweeperAnalyticsService } from '../services/sweeper-analytics.service.js';

export const getMetrics = async (req, res) => {
  // Check role-based access control (System Administrator)
  if (req.user?.role !== 'system_administrator' && req.user?.role !== 'admin') {
    return res.status(403).json({ error: 'Access denied: System Administrator role required' });
  }

  try {
    const { startDate, endDate, region } = req.query;
    const metrics = await sweeperAnalyticsService.getMetrics(startDate, endDate, region);
    res.json(metrics);
  } catch (error) {
    console.error('Error fetching metrics:', error);
    res.status(500).json({ error: 'Failed to fetch metrics' });
  }
};

export const exportMetrics = async (req, res) => {
  // Check role-based access control (System Administrator)
  if (req.user?.role !== 'system_administrator' && req.user?.role !== 'admin') {
    return res.status(403).json({ error: 'Access denied: System Administrator role required' });
  }

  try {
    const { startDate, endDate, region } = req.query;
    const tasks = await sweeperAnalyticsService.getExportData(startDate, endDate, region);

    // Build CSV
    let csv = 'task_id,creation_timestamp,assigned_crew,outlier_cluster_count,total_travel_time,total_work_time,completion_timestamp,sla_breach_durations\n';
    
    for (const task of tasks || []) {
      const assignedCrew = Array.isArray(task.assigned_crew_ids) ? task.assigned_crew_ids.join(';') : '';
      const clusterCount = Array.isArray(task.clusters) ? task.clusters.length : 0;
      
      const workTime = task.estimated_work_minutes ?? '';
      const travelTime = task.estimated_work_minutes == null ? '' : Math.max(0,(task.estimated_duration_minutes ?? 0)-task.estimated_work_minutes);
      const breachDurations = ''; // Not collected by this export; never fabricate an empty measurement.
      csv += `${task.id},${task.created_at},${assignedCrew},${clusterCount},${travelTime},${workTime},${task.completed_at || ''},"${breachDurations.replace(/"/g, '""')}"\n`;
    }

    res.setHeader('Content-Type', 'text/csv');
    res.setHeader('Content-Disposition', 'attachment; filename="sweeper_metrics.csv"');
    res.send(csv);
  } catch (error) {
    console.error('Error exporting metrics:', error);
    res.status(500).json({ error: 'Failed to export metrics' });
  }
};
