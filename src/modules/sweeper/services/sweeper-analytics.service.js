import { supabaseAdmin as supabase } from '../../../config/supabase.config.js';

class SweeperAnalyticsService {
  async getMetrics(startDate, endDate, region) {
    const start = startDate ? new Date(startDate) : new Date(Date.now() - 30 * 24 * 60 * 60 * 1000);
    const end = endDate ? new Date(endDate) : new Date();

    // 1. SLA Compliance
    const reportsQuery = supabase
      .from('reports')
      .select('id, breached_at, sla_started_at')
      .gte('sla_started_at', start.toISOString())
      .lte('sla_started_at', end.toISOString());

    const { data: reports, error: reportsError } = await reportsQuery;
    if (reportsError) throw reportsError;
    const totalReports = reports ? reports.length : 0;
    const breachedReports = reports ? reports.filter(r => r.breached_at != null).length : 0;
    const rate = totalReports > 0 ? ((totalReports - breachedReports) / totalReports) * 100 : 100;

    // 2. Outlier Metrics
    const outliersQuery = supabase
      .from('reports')
      .select('sla_started_at')
      .eq('lifecycle_state', 'sla_breached');
    const { data: currentOutliers, error: outliersError } = await outliersQuery;
    if (outliersError) throw outliersError;
      
    let averageAge = 0;
    if (currentOutliers && currentOutliers.length > 0) {
      const now = new Date();
      const ages = currentOutliers.map(r => (now.getTime() - new Date(r.sla_started_at).getTime()) / (1000 * 60 * 60));
      averageAge = ages.reduce((a, b) => a + b, 0) / ages.length;
    }

    const { data: resolvedTasks, error: resolvedError } = await supabase
      .from('cleanup_tasks')
      .select('id, created_at, completed_at')
      .eq('dispatch_kind', 'sweeper')
      .in('completion_result', ['completed','cleanup_completed'])
      .eq('status', 'completed')
      .gte('created_at', start.toISOString())
      .lte('created_at', end.toISOString());
    if (resolvedError) throw resolvedError;

    let averageResolutionTime = 0;
    if (resolvedTasks && resolvedTasks.length > 0) {
      const resTimes = resolvedTasks.map(t => (new Date(t.completed_at).getTime() - new Date(t.created_at).getTime()) / (1000 * 60 * 60));
      averageResolutionTime = resTimes.reduce((a, b) => a + b, 0) / resTimes.length;
    }

    // 3. Sweeper Tasks
    const { data: allSweeperTasks, error: tasksError } = await supabase
      .from('cleanup_tasks')
      .select('id, status, estimated_duration_min, cluster_ids, report_ids')
      .eq('dispatch_kind', 'sweeper')
      .gte('created_at', start.toISOString())
      .lte('created_at', end.toISOString());
    if (tasksError) throw tasksError;
      
    const totalCreated = allSweeperTasks ? allSweeperTasks.length : 0;
    const completedTasks = allSweeperTasks ? allSweeperTasks.filter(t => t.status === 'completed') : [];
    const totalCompleted = completedTasks.length;
    
    let averageRouteTime = 0;
    let averageClustersPerTask = 0;
    
    if (allSweeperTasks && totalCreated > 0) {
      const totalDurations = allSweeperTasks.reduce((acc, task) => acc + (task.estimated_duration_min || 0), 0);
      averageRouteTime = totalDurations / totalCreated;
      
      const totalClusters = allSweeperTasks.reduce((acc, task) => {
        return acc + (Array.isArray(task.cluster_ids) ? task.cluster_ids.length : 0);
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
        cluster_ids,
        estimated_duration_min,
        estimated_work_minutes,
        report_ids,
        completed_at
      `)
      .eq('dispatch_kind', 'sweeper')
      .gte('created_at', start.toISOString())
      .lte('created_at', end.toISOString());

    if (error) {
      throw error;
    }
    
    // Preserve the existing export-controller contract while querying real columns.
    return tasks?.map(task => ({ ...task, clusters: task.cluster_ids, estimated_duration_minutes: task.estimated_duration_min }));
  }
}

export const sweeperAnalyticsService = new SweeperAnalyticsService();
