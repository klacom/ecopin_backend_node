import { supabaseAdmin } from '../config/supabase.config.js';

export const clusterReports = async () => {
  try {
    console.log('Starting report clustering...');

    //Run DBSCAN to find clusters among recent unresolved reports
    const { data: clustered, error: clusterError } = await supabaseAdmin.rpc(
      'dbscan_reports'
    );

    if (clusterError) {
      console.error('Error running DBSCAN:', clusterError);
      throw clusterError;
    }

    if (!clustered || clustered.length === 0) {
      console.log('No reports to cluster.');
      return { message: 'No reports to cluster.', clusters: [] };
    }

    //Group results by DBSCAN cluster_id (null = noise / singleton)
    const groups = new Map();

    for (const row of clustered) {
      if (row.cluster_id === null) continue; // skip noise points

      if (!groups.has(row.cluster_id)) {
        groups.set(row.cluster_id, { ids: [], issue_types: [], locations: [] });
      }
      const g = groups.get(row.cluster_id);
      g.ids.push(row.id);
      g.issue_types.push(row.issue_type);
      g.locations.push(row.location);
    }

    if (groups.size === 0) {
      console.log('No clusters formed (all reports are singletons).');
      return { message: 'No clusters formed (all reports are singletons).', clusters: [] };
    }

    //Upsert each cluster into the clusters table
    const results = [];

    for (const [clusterId, group] of groups) {
      // Determine the dominant issue type in this cluster
      const typeCounts = group.issue_types.reduce(
        (acc, t) => ({ ...acc, [t]: (acc[t] ?? 0) + 1 }),
        {}
      );
      const dominantType = Object.entries(typeCounts).sort((a, b) => b[1] - a[1])[0][0];

      // Determine severity based on report count
      const count = group.ids.length;
      const severity = count >= 5 ? 'high' : count >= 3 ? 'medium' : 'low';

      // Compute centroid & insert cluster row via SQL so PostGIS handles geometry
      const { data: newCluster, error: insertError } = await supabaseAdmin.rpc(
        'upsert_cluster_for_reports',
        {
          p_report_ids: group.ids,
          p_issue_type: dominantType,
          p_severity: severity,
          p_radius_meters: 50,
        }
      );

      if (insertError) {
        console.error(`Failed to upsert cluster ${clusterId}:`, insertError);
        continue;
      }

      results.push({
        cluster_id: clusterId,
        cluster_uuid: newCluster,
        report_count: count,
      });
    }

    console.log(`Created/updated ${results.length} cluster(s).`);
    return {
      message: `Created/updated ${results.length} cluster(s).`,
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

export const updateClusterStatus = async (clusterId, status) => {
  try {
    const { data, error } = await supabaseAdmin
      .from('clusters')
      .update({ status })
      .eq('id', clusterId)
      .select()
      .single();

    if (error) throw error;

    // Also update all member reports to the same status
    await supabaseAdmin
      .from('reports')
      .update({ status })
      .eq('cluster_id', clusterId);

    return data;
  } catch (error) {
    console.error('Error updating cluster status:', error);
    throw error;
  }
};
