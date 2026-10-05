import { supabaseAdmin as supabase } from '../../../config/supabase.config.js';

class SweeperAnalyticsService {
  async getMetrics(startDate, endDate, region) {
    const start = startDate ? new Date(startDate) : new Date(Date.now() - 30 * 24 * 60 * 60 * 1000);
    const end = endDate ? new Date(endDate) : new Date();

    // 1. SLA Compliance
    let reportsQuery = supabase
      .from('reports')
      .select('id, is_outlier, created_at')
      .gte('created_at', start.toISOString())
      .lte('created_at', end.toISOString());

    const { data: reports } = await reportsQuery;
    const totalReports = reports ? reports.length : 0;
    const breachedReports = reports ? reports.filter(r => r.is_outlier).length : 0;
    const rate = totalReports > 0 ? ((totalReports - breachedReports) / totalReports) * 100 : 100;

    // 2. Outlier Metrics
    const { data: currentOutliers } = await supabase
      .from('reports')
      .select('created_at')
      .eq('is_outlier', true)
      .eq('status', 'pending');
      
    let averageAge = 0;
    if (currentOutliers && currentOutliers.length > 0) {
      const now = new Date();
      const ages = currentOutliers.map(r => (now.getTime() - new Date(r.created_at).getTime()) / (1000 * 60 * 60));
      averageAge = ages.reduce((a, b) => a + b, 0) / ages.length;
    }

    const { data: resolvedTasks } = await supabase
      .from('cleanup_tasks')
      .select('id, created_at, completed_at')
      .eq('is_outlier', true)
      .eq('status', 'completed')
      .gte('created_at', start.toISOString())
      .lte('created_at', end.toISOString());

    let averageResolutionTime = 0;
    if (resolvedTasks && resolvedTasks.length > 0) {
      const resTimes = resolvedTasks.map(t => (new Date(t.completed_at).getTime() - new Date(t.created_at).getTime()) / (1000 * 60 * 60));
      averageResolutionTime = resTimes.reduce((a, b) => a + b, 0) / resTimes.length;
    }

    // 3. Sweeper Tasks
    const { data: allSweeperTasks } = await supabase
      .from('cleanup_tasks')
      .select('id, status, estimated_duration_minutes, clusters')
      .eq('is_outlier', true)
      .gte('created_at', start.toISOString())
      .lte('created_at', end.toISOString());
      
    const totalCreated = allSweeperTasks ? allSweeperTasks.length : 0;
    const completedTasks = allSweeperTasks ? allSweeperTasks.filter(t => t.status === 'completed') : [];
    const totalCompleted = completedTasks.length;
    
    let averageRouteTime = 0;
    let averageClustersPerTask = 0;
    
    if (allSweeperTasks && totalCreated > 0) {
      const totalDurations = allSweeperTasks.reduce((acc, task) => acc + (task.estimated_duration_minutes || 0), 0);
      averageRouteTime = totalDurations / totalCreated;
      
      const totalClusters = allSweeperTasks.reduce((acc, task) => {
        return acc + (Array.isArray(task.clusters) ? task.clusters.length : 0);
      }, 0);
      averageClustersPerTask = totalClusters / totalCreated;
    }

    return {
      period: {
        start: start.toISOString(),
        end: end.toISOString()
      },
      slaCompliance: {
        rate: Number(rate.toFixed(1)),
        totalReports,
        breachedReports
      },
      outlierMetrics: {
        currentFlagged: currentOutliers ? currentOutliers.length : 0,
        averageAge: Number(averageAge.toFixed(1)),
        totalResolved: resolvedTasks ? resolvedTasks.length : 0,
        averageResolutionTime: Number(averageResolutionTime.toFixed(1))
      },
      sweeperTasks: {
        totalCreated,
        totalCompleted,
        averageRouteTime: Number(averageRouteTime.toFixed(1)),
        averageClustersPerTask: Number(averageClustersPerTask.toFixed(1))
      }
    };
  }

  async getExportData(startDate, endDate, region) {
    const start = startDate ? new Date(startDate) : new Date(Date.now() - 30 * 24 * 60 * 60 * 1000);
    const end = endDate ? new Date(endDate) : new Date();

    const { data: tasks, error } = await supabase
      .from('cleanup_tasks')
      .select(`
        id,
        created_at,
        assigned_crew_ids,
        clusters,
        estimated_duration_minutes,
        completed_at
      `)
      .eq('is_outlier', true)
      .gte('created_at', start.toISOString())
      .lte('created_at', end.toISOString());

    if (error) {
      throw error;
    }
    
    return tasks;
  }
}

export const sweeperAnalyticsService = new SweeperAnalyticsService();
