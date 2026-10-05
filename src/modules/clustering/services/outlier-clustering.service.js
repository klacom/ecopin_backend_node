import { supabaseAdmin as supabase } from '../../../config/supabase.config.js';
import { logOutlierClusterCreation } from '../../sweeper/services/audit-log.service.js';

class OutlierClusteringService {
  /**
   * Create single-item clusters for all unprocessed outlier reports
   * @returns {Promise<{clusterCount: number, clusters: Array}>}
   */
  async clusterOutliers() {
    // Call the stored procedure to batch insert clusters and update reports
    const { data: createdClusters, error } = await supabase.rpc('create_outlier_clusters');

    if (error) {
      console.error('Error executing create_outlier_clusters procedure:', error);
      throw new Error(`Outlier clustering failed: ${error.message}`);
    }

    const clusters = [];

    // Log audit event for each created outlier cluster
    if (createdClusters && createdClusters.length > 0) {
      for (const cluster of createdClusters) {
        try {
          await logOutlierClusterCreation(cluster.cluster_id, cluster.report_id);
          
          clusters.push({
            clusterId: cluster.cluster_id,
            reportId: cluster.report_id,
            coordinates: cluster.coordinates
          });
        } catch (logError) {
          console.error(`Failed to log audit event for cluster ${cluster.cluster_id}:`, logError);
          // Continue execution despite audit log failure to return correct results
        }
      }
    }

    return {
      clusterCount: clusters.length,
      clusters
    };
  }
  
  /**
   * Ensure flag propagation from reports to clusters
   * @param {string} reportId
   * @returns {Promise<string>} - Created cluster ID
   */
  async createOutlierCluster(reportId) {
    // This provides a fallback to create a single outlier cluster programmatically if needed
    
    // First verify the report is actually an outlier
    const { data: report, error: reportError } = await supabase
      .from('reports')
      .select('location, issue_type, severity, is_outlier, cluster_id')
      .eq('id', reportId)
      .single();
      
    if (reportError || !report) {
      throw new Error(`Failed to find report ${reportId}`);
    }
    
    if (!report.is_outlier) {
      throw new Error(`Report ${reportId} is not flagged as an outlier`);
    }
    
    if (report.cluster_id) {
      return report.cluster_id;
    }
    
    // Generate bounding box for single point (PostGIS logic executed in JS or DB)
    // Here we'll use a raw query or just call the DB procedure, but since we have a procedure,
    // let's rely on the DB to do it properly. We can just call clusterOutliers() which processes all unclustered ones.
    // However, to satisfy the interface, we'll do a direct insert if we want a single one.
    
    // For now, we can just call clusterOutliers() and find the matching one,
    // or run a direct query. Given the requirement to follow the design doc,
    // we should implement this method properly.
    
    const { data: clusterData, error: clusterError } = await supabase
      .from('clusters')
      .insert({
        centroid: report.location,
        // PostGIS ST_Buffer equivalent would be needed here, or handle via DB triggers.
        // As a simplification without direct PostGIS access in JS:
        bounding_box: report.location, // Placeholder, ideally we'd use ST_Buffer on insert
        issue_type: report.issue_type,
        severity: report.severity,
        is_outlier: true,
        status: 'Pending Assignment'
      })
      .select('id')
      .single();
      
    if (clusterError) {
      throw new Error(`Failed to create cluster for report ${reportId}: ${clusterError.message}`);
    }
    
    // Update the report
    await supabase
      .from('reports')
      .update({ cluster_id: clusterData.id })
      .eq('id', reportId);
      
    await logOutlierClusterCreation(clusterData.id, reportId);
    
    return clusterData.id;
  }
}

export const outlierClusteringService = new OutlierClusteringService();
