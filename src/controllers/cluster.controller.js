import { supabaseAdmin as supabase } from '../supabase_config/supabase.config.js';
import { clusterReports, getClusters, getClusterById, updateClusterStatus } from '../services/clustering.service.js';

/**
 * Manually trigger clustering
 */
export const triggerClustering = async (req, res, next) => {
  try {
    const result = await clusterReports();
    res.status(200).json(result);
  } catch (error) {
    next(error);
  }
};

/**
 * Get all clusters
 */
export const getAllClusters = async (req, res, next) => {
  try {
    const clusters = await getClusters();
    res.status(200).json(clusters);
  } catch (error) {
    next(error);
  }
};

/**
 * Get cluster by ID with member reports
 */
export const getCluster = async (req, res, next) => {
  const { id } = req.params;

  try {
    const cluster = await getClusterById(id);
    res.status(200).json(cluster);
  } catch (error) {
    next(error);
  }
};

/**
 * Update cluster status
 */
export const updateCluster = async (req, res, next) => {
  const { id } = req.params;
  const { status } = req.body;

  // Validate status
  const validStatuses = ['unresolved', 'in_progress', 'resolved'];
  if (!validStatuses.includes(status)) {
    return res.status(400).json({
      message: 'Invalid status. Must be one of: unresolved, in_progress, resolved'
    });
  }

  try {
    const cluster = await updateClusterStatus(id, status);
    res.status(200).json({
      message: 'Cluster status updated successfully',
      cluster
    });
  } catch (error) {
    next(error);
  }
};
