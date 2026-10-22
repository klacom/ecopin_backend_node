import { supabaseAdmin } from '../../../config/supabase.config.js';
import { CLUSTERING_CONFIG } from '../config/clustering.config.js';


export const clusterReports = async () => {
  try {
    console.log('Starting report clustering...');

    // One database transaction owns discovery, membership and cluster identity.
    const { data: clustered, error } = await supabaseAdmin.rpc('cluster_reports_incremental', {
      p_eps: CLUSTERING_CONFIG.dbscan.eps,
      p_minpoints: CLUSTERING_CONFIG.dbscan.minpoints,
    });
    if (error) throw error;
    const results = (clustered ?? []).map((row, index) => ({
      cluster_id: index,
      cluster_uuid: row.cluster_uuid,
      report_count: row.report_count,
    }));
    return {
      message: results.length ? `Created/updated ${results.length} cluster(s).` : 'No approved reports to cluster.',
      clusters: results,
    };
  } catch (error) {
    console.error('Clustering error:', error);
    throw error;
  }
};

// Get all clusters
export const getClusters = async () => {
  try {
    const { data, error } = await supabaseAdmin
      .from('clusters')
      .select('*')
      .order('created_at', { ascending: false });

    if (error) throw error;

    return data;
  } catch (error) {
    console.error('Error fetching clusters:', error);
    throw error;
  }
};

// Get cluster by ID with member reports
export const getClusterById = async (clusterId) => {
  try {
    const { data: cluster, error: clusterError } = await supabaseAdmin
      .from('clusters')
      .select('*')
      .eq('id', clusterId)
      .single();

    if (clusterError) throw clusterError;

    // Get member reports
    const { data: reports, error: reportsError } = await supabaseAdmin
      .from('reports')
      .select('*')
      .eq('cluster_id', clusterId);

    if (reportsError) throw reportsError;

    return { ...cluster, reports };
  } catch (error) {
    console.error('Error fetching cluster:', error);
    throw error;
  }
};

export const updateClusterStatus = async (clusterId,status,actor) => {
  const {data,error}=await supabaseAdmin.rpc('set_cluster_queue_status',{cluster_id:clusterId,actor,next_status:status});
  if(error) throw error;return data;
};
