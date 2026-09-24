import { supabaseAdmin as supabase } from '../../../config/supabase.config.js';

// Haversine distance in meters
function haversineDistance(lat1, lon1, lat2, lon2) {
  const R = 6371000;
  const phi1 = lat1 * Math.PI / 180;
  const phi2 = lat2 * Math.PI / 180;
  const deltaPhi = (lat2 - lat1) * Math.PI / 180;
  const deltaLam = (lon2 - lon1) * Math.PI / 180;
  const a = Math.sin(deltaPhi/2)**2 + Math.cos(phi1) * Math.cos(phi2) * Math.sin(deltaLam/2)**2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1-a));
}

function getTaskContext(type) {
  switch(type) {
    case 'Cleanup': return { action: 'Remove and properly dispose of the identified environmental waste/issue.', resources: 'Cleaning tools, disposal bags, transport vehicle' };
    case 'Investigation': return { action: 'Visit the location to investigate the reported issue and determine its scope.', resources: 'Inspection tablet, camera, field notes' };
    case 'Verification': return { action: 'Confirm whether the previously reported environmental issue is valid and active.', resources: 'Tablet, camera' };
    case 'Emergency Response': return { action: 'Respond immediately to contain and resolve a high-severity environmental incident.', resources: 'Emergency kit, PPE, specialized machinery' };
    case 'Reinspection': return { action: 'Verify the outcome and quality of previously completed cleanup work.', resources: 'Previous records, camera' };
    case 'Monitoring': return { action: 'Observe and record the situation without immediate physical intervention.', resources: 'Tablet, sensors if applicable' };
    case 'Escalation': return { action: 'Gather detailed information and evidence required for higher institutional action.', resources: 'Detailed reporting tools, camera' };
    default: return { action: 'Perform general operation at the specified location.', resources: 'Standard field tools' };
  }
}

export async function dispatchClusters(clusterIds, userId) {
  if (!clusterIds || clusterIds.length === 0) return [];

  // 1. Fetch consolidation radius setting
  const { data: settingData } = await supabase.from('optimization_settings').select('value').eq('key', 'dispatch_consolidation_radius').single();
  const radiusThreshold = parseInt(settingData?.value || '200', 10);

  // 2. Fetch full cluster details, ensuring we only grab clusters that haven't been scheduled yet
  const { data: clusters } = await supabase
    .from('clusters')
    .select('id, center, issue_type, recommended_task_type, estimated_effort_minutes, reports(id)')
    .in('id', clusterIds)
    .in('status', ['unresolved', 'prioritized', 'monitoring']);

  if (!clusters || clusters.length === 0) return [];

  // 3. Consolidate nearby clusters
  const consolidatedTasks = [];
  const processed = new Set();

  for (let i = 0; i < clusters.length; i++) {
    if (processed.has(clusters[i].id)) continue;
    
    const baseCluster = clusters[i];
    const group = [baseCluster];
    processed.add(baseCluster.id);
    
    const baseLat = baseCluster.center.coordinates[1];
    const baseLng = baseCluster.center.coordinates[0];

    // Find neighbors to consolidate
    for (let j = i + 1; j < clusters.length; j++) {
      if (processed.has(clusters[j].id)) continue;
      
      const neighbor = clusters[j];
      const nLat = neighbor.center.coordinates[1];
      const nLng = neighbor.center.coordinates[0];
      
      const distance = haversineDistance(baseLat, baseLng, nLat, nLng);
      
      if (distance <= radiusThreshold && neighbor.recommended_task_type === baseCluster.recommended_task_type) {
        group.push(neighbor);
        processed.add(neighbor.id);
      }
    }
    
    consolidatedTasks.push(group);
  }

  // 4. Create cleanup_tasks for each consolidated group
  const createdTasks = [];
  
  for (const group of consolidatedTasks) {
    const taskType = group[0].recommended_task_type || 'Cleanup';
    const totalEffort = group.reduce((sum, c) => sum + (c.estimated_effort_minutes || 60), 0);
    const allClusterIds = group.map(c => c.id);
    
    // Aggregate reports across all grouped clusters
    let allReports = [];
    group.forEach(c => {
      if (c.reports) {
        allReports = allReports.concat(c.reports);
      }
    });
    
    const title = `${taskType} Operation - ${allClusterIds.length > 1 ? 'Consolidated Clusters' : 'Cluster ' + allClusterIds[0].substring(0, 8)}`;
    
    const { action, resources } = getTaskContext(taskType);
    const scheduledDate = new Date().toISOString().split('T')[0];
    const reportedIssues = [...new Set(group.map(c => c.issue_type))].join(', ');
    
    const description = `**Operational Briefing**
Generated from auto-planner. This task was selected based on available capacity and high priority in the operational backlog.

**Evidence & Scope**
This operation covers ${allClusterIds.length} cluster(s) with a total of ${allReports.length} citizen report(s).
Primary issue(s) identified: ${reportedIssues}

**Expected Action**
${action}

**Required Resources**
${resources}`;
    
    const { data: newTask, error } = await supabase
      .from('cleanup_tasks')
      .insert({
        cluster_id: group[0].id, // Keep primary for backwards compat
        cluster_ids: allClusterIds,
        title,
        description,
        status: 'pending',
        task_type: taskType,
        estimated_duration_min: totalEffort,
        expected_action: action,
        required_resources: resources,
        scheduled_date: scheduledDate,
        created_by: userId
      })
      .select()
      .single();

    if (error || !newTask) {
      console.error('Failed to create dispatched task:', error);
      continue;
    }

    // Update reports to point to this task
    if (allReports.length > 0) {
      await supabase
        .from('reports')
        .update({ cleanup_task_id: newTask.id })
        .in('id', allReports.map(r => r.id));
    }
    
    // Update cluster statuses to 'scheduled'
    await supabase
      .from('clusters')
      .update({ status: 'scheduled' })
      .in('id', allClusterIds);

    createdTasks.push(newTask);
  }

  return createdTasks;
}
