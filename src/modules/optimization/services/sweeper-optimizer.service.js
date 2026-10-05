import { supabaseAdmin as supabase } from '../../../config/supabase.config.js';
import { travelTimeService } from './travel-time.service.js';
import * as configurationService from '../../sweeper/services/configuration.service.js';
import { logSweeperTaskCreation } from '../../sweeper/services/audit-log.service.js';

class SweeperOptimizerService {
  constructor() {
    this.travelTimeService = travelTimeService;
    this.configService = configurationService;
  }

  async getDepotCoordinates() {
    const { data: depotSetting } = await supabase
      .from('optimization_settings')
      .select('value')
      .eq('key', 'swmo_depot')
      .single();
      
    if (depotSetting && depotSetting.value) {
      return { 
        lat: depotSetting.value.latitude, 
        lng: depotSetting.value.longitude 
      };
    }
    
    // Default depot coordinate
    return { lat: 1.3521, lng: 103.8198 };
  }
  
  async fetchClusterData(clusterIds) {
    if (!clusterIds || clusterIds.length === 0) return [];
    
    // In PostgreSQL PostGIS, ST_Y is lat, ST_X is lng
    const { data: clusters, error } = await supabase
      .from('clusters')
      .select(`
        id, 
        severity, 
        issue_type,
        status,
        centroid
      `)
      .in('id', clusterIds);
      
    if (error) {
      throw new Error(`Failed to fetch cluster data: ${error.message}`);
    }
    
    // Transform data
    return Promise.all(clusters.map(async (c) => {
      let lat = 0;
      let lng = 0;
      
      if (c.centroid && c.centroid.coordinates) {
        lng = c.centroid.coordinates[0];
        lat = c.centroid.coordinates[1];
      }
      
      const workTimeEstimate = await this.configService.getWorkTime(c.issue_type);
      
      return {
        id: c.id,
        coordinates: { lat, lng },
        workTime: workTimeEstimate,
        issue_type: c.issue_type,
        severity: c.severity
      };
    }));
  }
  
  async createCleanupTask(route, crewId) {
    const clusterIds = route.clusters.map(c => c.id);
    
    const { data, error } = await supabase
      .from('cleanup_tasks')
      .insert({
        crew_id: crewId,
        clusters: clusterIds,
        status: 'Assigned',
        priority: 'high',
        is_outlier: true,
        estimated_duration_minutes: route.totalRouteTime,
        assigned_at: new Date().toISOString()
      })
      .select('id')
      .single();
      
    if (error) {
      throw new Error(`Failed to create cleanup task: ${error.message}`);
    }
    
    // Update the statuses of the clustered reports to 'Assigned'
    await supabase
      .from('clusters')
      .update({ status: 'Assigned' })
      .in('id', clusterIds);
      
    await supabase
      .from('reports')
      .update({ status: 'in_progress' })
      .in('cluster_id', clusterIds);
      
    // Log audit event
    await logSweeperTaskCreation(data.id, clusterIds);
    
    return data.id;
  }

  async generateSweeperRoutes(clusterIds, crewId) {
    // 1. Fetch cluster data with work times
    const clusters = await this.fetchClusterData(clusterIds);
    if (clusters.length === 0) return [];
    
    // 2. Get configuration parameters
    let shiftDuration = 8; // Default 8 hours
    if (this.configService && this.configService.getShiftDuration) {
      shiftDuration = await this.configService.getShiftDuration(crewId);
    }
    
    let timeBuffer = 10; // Default 10 percent
    if (this.configService && this.configService.getTimeBuffer) {
      timeBuffer = await this.configService.getTimeBuffer();
    }
    
    const maxRouteTime = shiftDuration * 60 * (1 - timeBuffer / 100);
    
    // 3. Get depot coordinates
    const depot = await this.getDepotCoordinates();
    
    // 4. Build travel time matrix
    const travelMatrix = await this.buildTravelTimeMatrix(depot, clusters);
    
    // 5. Apply greedy TSP with time constraints
    const routes = [];
    const unvisited = [...clusters];
    
    while (unvisited.length > 0) {
      const route = this.buildSingleRoute(
        depot, 
        unvisited, 
        travelMatrix, 
        maxRouteTime
      );
      
      if (route.clusters.length === 0) {
        // Cannot fit any more clusters - just take the nearest one and force it (as fallback to prevent infinite loop)
        console.warn('Remaining cluster exceeds shift duration. Forcing creation to avoid deadlock.');
        route.clusters.push(unvisited.shift());
      }
      
      // Create task in database
      const taskId = await this.createCleanupTask(route, crewId);
      
      routes.push({
        taskId,
        ...route
      });
    }
    
    return routes;
  }
  
  buildSingleRoute(depot, unvisited, travelMatrix, maxRouteTime) {
    const route = [];
    let currentLocation = depot;
    let currentTime = 0;
    
    while (unvisited.length > 0) {
      // Find nearest cluster
      let nearestCluster = null;
      let minTravelTime = Infinity;
      let nearestIndex = -1;
      
      for (let i = 0; i < unvisited.length; i++) {
        const cluster = unvisited[i];
        const travelTime = this.getTravelTime(
          travelMatrix, 
          currentLocation, 
          cluster.coordinates
        );
        
        if (travelTime < minTravelTime) {
          minTravelTime = travelTime;
          nearestCluster = cluster;
          nearestIndex = i;
        }
      }
      
      // Check time constraint
      const timeWithNext = currentTime + minTravelTime + nearestCluster.workTime;
      const returnTime = this.getTravelTime(
        travelMatrix, 
        nearestCluster.coordinates, 
        depot
      );
      
      if (timeWithNext + returnTime > maxRouteTime) {
        break; // Cannot add more clusters to this route
      }
      
      // Add to route
      route.push(nearestCluster);
      currentLocation = nearestCluster.coordinates;
      currentTime = timeWithNext;
      unvisited.splice(nearestIndex, 1);
    }
    
    // Calculate final metrics
    const returnTime = route.length > 0 ? this.getTravelTime(travelMatrix, currentLocation, depot) : 0;
    const totalRouteTime = currentTime + returnTime;
    const totalWorkTime = route.reduce((sum, c) => sum + c.workTime, 0);
    const totalTravelTime = totalRouteTime - totalWorkTime;
    
    return {
      clusters: route,
      totalRouteTime,
      totalTravelTime,
      totalWorkTime
    };
  }
  
  async buildTravelTimeMatrix(depot, clusters) {
    const locations = [depot, ...clusters.map(c => c.coordinates)];
    
    // Use the travelTimeService to batch calculate the matrix
    // The travelTimeService.calculateTravelMatrix already handles building the full NxN matrix
    // efficiently, utilizing the cache and TomTom Matrix API.
    return await this.travelTimeService.calculateTravelMatrix(locations);
  }
  
  getTravelTime(matrix, fromCoord, toCoord) {
    // Determine indices in the matrix based on object reference or values
    // To do this properly without modifying `design.md` too much, we'll implement findIndexOfCoordinate
    // Actually, in the matrix we built, the index 0 is depot, 1..n are the clusters in order of `clusters` array.
    // However, since `buildSingleRoute` calls `getTravelTime` with just coordinates, we need a way to look them up.
    
    // The easiest way is to scan the matrix assuming it was built from `[depot, ...clusters]`
    // But since the coordinates might be identical instances or just same lat/lng:
    let fromIndex = -1;
    let toIndex = -1;
    
    // Since we don't have the original array inside getTravelTime, it's better to just re-scan or have it as part of class
    // Wait, `design.md` says:
    // FUNCTION getTravelTime(matrix, fromCoord, toCoord):
    //   fromIndex <- findIndexOfCoordinate(fromCoord)
    //   toIndex <- findIndexOfCoordinate(toCoord)
    //   RETURN matrix[fromIndex][toIndex]
    
    // Let's implement a robust lookup. The matrix is just an NxN array. 
    // We can store the current locations array in the instance or pass it. 
    // Since we can't change the signature of `buildSingleRoute` based on the design outline:
    // Actually `buildSingleRoute(depot, unvisited, travelMatrix, maxRouteTime)` doesn't pass the full locations list.
    // The simplest workaround without changing the signature is to attach the locations list to the matrix array object, 
    // or use a Map cache for coordinates.
    // Let's attach locations to the matrix in `buildTravelTimeMatrix`.
    
    if (!matrix._locations) {
      throw new Error("Locations metadata missing from matrix");
    }
    
    for (let i = 0; i < matrix._locations.length; i++) {
      if (matrix._locations[i].lat === fromCoord.lat && matrix._locations[i].lng === fromCoord.lng) {
        fromIndex = i;
      }
      if (matrix._locations[i].lat === toCoord.lat && matrix._locations[i].lng === toCoord.lng) {
        toIndex = i;
      }
    }
    
    if (fromIndex === -1 || toIndex === -1) {
      return 0; // Fallback
    }
    
    return matrix[fromIndex][toIndex];
  }
}

// Monkey-patch to add locations to matrix
const originalBuildTravelTimeMatrix = SweeperOptimizerService.prototype.buildTravelTimeMatrix;
SweeperOptimizerService.prototype.buildTravelTimeMatrix = async function(depot, clusters) {
  const locations = [depot, ...clusters.map(c => c.coordinates)];
  const matrix = await originalBuildTravelTimeMatrix.call(this, depot, clusters);
  matrix._locations = locations;
  return matrix;
};

export const sweeperOptimizerService = new SweeperOptimizerService();
