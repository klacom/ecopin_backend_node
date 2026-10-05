import { createClient } from 'redis';

// Haversine distance formula for straight-line approximation
function haversineDistance(coord1, coord2) {
  const R = 6371000; // Earth radius in meters
  const φ1 = coord1.lat * Math.PI / 180;
  const φ2 = coord2.lat * Math.PI / 180;
  const Δφ = (coord2.lat - coord1.lat) * Math.PI / 180;
  const Δλ = (coord2.lng - coord1.lng) * Math.PI / 180;
  
  const a = Math.sin(Δφ/2) * Math.sin(Δφ/2) +
            Math.cos(φ1) * Math.cos(φ2) *
            Math.sin(Δλ/2) * Math.sin(Δλ/2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1-a));
  
  return R * c; // meters
}

// Estimate travel time from straight-line distance
function estimateTravelTime(coord1, coord2) {
  const distance = haversineDistance(coord1, coord2);
  const avgSpeed = 40000 / 60; // 40 km/h in meters/minute (urban traffic)
  const detourFactor = 1.3; // Roads are not straight lines
  
  return Math.ceil((distance * detourFactor) / avgSpeed); // minutes
}

class TravelTimeService {
  constructor() {
    this.apiKey = process.env.TOMTOM_API_KEY;
    this.baseUrl = 'https://api.tomtom.com/routing/1';
    
    // Initialize Redis Client
    this.redisClient = createClient({
      url: process.env.REDIS_URL || 'redis://localhost:6379'
    });
    
    this.redisClient.on('error', (err) => {
      console.error('Redis Client Error', err);
    });
    
    this.isRedisConnected = false;
    this.redisClient.connect().then(() => {
      this.isRedisConnected = true;
      console.log('Redis connected for Travel Time Service');
    }).catch(err => {
      console.error('Failed to connect to Redis', err);
    });
  }
  
  async getCachedTravelTime(from, to) {
    if (!this.isRedisConnected) return null;
    const key = `travel_time:${from.lat},${from.lng}:${to.lat},${to.lng}`;
    try {
      const cached = await this.redisClient.get(key);
      if (cached) {
        return parseInt(cached, 10);
      }
    } catch (error) {
      console.error('Redis get error', error);
    }
    return null;
  }

  async setCachedTravelTime(from, to, timeInMinutes) {
    if (!this.isRedisConnected) return;
    const key = `travel_time:${from.lat},${from.lng}:${to.lat},${to.lng}`;
    try {
      // TTL of 1 hour (3600 seconds)
      await this.redisClient.setEx(key, 3600, timeInMinutes.toString());
    } catch (error) {
      console.error('Redis set error', error);
    }
  }

  async calculateTravelTime(from, to) {
    // Check Cache first
    const cachedTime = await this.getCachedTravelTime(from, to);
    if (cachedTime !== null) {
      return {
        from,
        to,
        distance: null, // Distance might not be cached in this simple structure
        duration: cachedTime,
        route: [] // Fallback structure for cached requests
      };
    }

    try {
      // Format coordinates for TomTom API
      const fromString = `${from.lat},${from.lng}`;
      const toString = `${to.lat},${to.lng}`;
      
      // Call TomTom Routing API
      const url = `${this.baseUrl}/calculateRoute/${fromString}:${toString}/json`;
      const params = new URLSearchParams({
        key: this.apiKey,
        traffic: 'true',
        travelMode: 'car',
        routeType: 'fastest'
      });
      
      const response = await fetch(`${url}?${params}`);
      if (!response.ok) {
        throw new Error(`TomTom API error: ${response.statusText}`);
      }
      
      const data = await response.json();
      const route = data.routes[0];
      
      const durationInMinutes = Math.ceil(route.summary.travelTimeInSeconds / 60);
      
      // Cache the result
      await this.setCachedTravelTime(from, to, durationInMinutes);
      
      return {
        from,
        to,
        distance: route.summary.lengthInMeters,
        duration: durationInMinutes,
        route: route.legs[0].points.map(p => ({
          lat: p.latitude,
          lng: p.longitude
        }))
      };
    } catch (error) {
      console.warn('TomTom Routing API failed, falling back to Haversine estimation:', error.message);
      
      const duration = estimateTravelTime(from, to);
      const distance = haversineDistance(from, to) * 1.3;
      
      return {
        from,
        to,
        distance: Math.ceil(distance),
        duration: duration,
        route: []
      };
    }
  }
  
  async calculateTravelMatrix(waypoints) {
    const n = waypoints.length;
    const matrix = Array(n).fill(null).map(() => Array(n).fill(0));
    
    // Track pairs we need to fetch from TomTom
    const originsToFetch = [];
    const destinationsToFetch = [];
    const fetchMap = new Map(); // Maps new index -> original index
    
    // First pass: try to populate from cache
    let allCached = true;
    for (let i = 0; i < n; i++) {
      for (let j = 0; j < n; j++) {
        if (i === j) {
          matrix[i][j] = 0;
          continue;
        }
        
        const cachedTime = await this.getCachedTravelTime(waypoints[i], waypoints[j]);
        if (cachedTime !== null) {
          matrix[i][j] = cachedTime;
        } else {
          allCached = false;
        }
      }
    }
    
    // If we have any misses, and we just want to fetch the whole matrix using TomTom Matrix API 
    // for efficiency as per the design doc (bulk is better than individual routes)
    // The instructions say: "Add a Redis caching layer for the travel time matrix. Cache the TomTom API responses 
    // with a TTL of 1 hour and strictly use the key format: travel_time:{lat1},{lng1}:{lat2},{lng2}. 
    // The service must check the cache before making external API calls."
    
    // If everything was cached, return immediately
    if (allCached) {
      return matrix;
    }

    try {
      // Use TomTom Matrix Routing API for efficiency for all waypoints
      const url = `${this.baseUrl}/matrix/sync/json`;
      
      const body = {
        origins: waypoints.map(w => ({
          point: {latitude: w.lat, longitude: w.lng}
        })),
        destinations: waypoints.map(w => ({
          point: {latitude: w.lat, longitude: w.lng}
        })),
        options: {
          traffic: 'historical',
          travelMode: 'car',
          routeType: 'fastest'
        }
      };
      
      const response = await fetch(`${url}?key=${this.apiKey}`, {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify(body)
      });
      
      if (!response.ok) {
        throw new Error(`TomTom Matrix API error: ${response.statusText}`);
      }
      
      const data = await response.json();
      
      // Convert to 2D array and cache missing elements
      for (let i = 0; i < n; i++) {
        for (let j = 0; j < n; j++) {
          if (i === j) {
            matrix[i][j] = 0;
            continue;
          }
          
          const cell = data.matrix[i][j];
          if (cell && cell.response && cell.response.routeSummary) {
            const timeInMinutes = Math.ceil(cell.response.routeSummary.travelTimeInSeconds / 60);
            matrix[i][j] = timeInMinutes;
            // Always update cache to refresh TTL
            await this.setCachedTravelTime(waypoints[i], waypoints[j], timeInMinutes);
          } else {
             // Fallback if cell is weirdly missing
             matrix[i][j] = estimateTravelTime(waypoints[i], waypoints[j]);
             console.warn(`Matrix cell [${i}][${j}] missing from TomTom response, using Haversine fallback.`);
          }
        }
      }
      
      return matrix;
    } catch (error) {
      console.warn('TomTom Matrix API failed, falling back to Haversine estimation:', error.message);
      
      for (let i = 0; i < n; i++) {
        for (let j = 0; j < n; j++) {
          if (i !== j && matrix[i][j] === 0) { // Only calculate for ones we didn't get from cache
            matrix[i][j] = estimateTravelTime(waypoints[i], waypoints[j]);
          }
        }
      }
      
      return matrix;
    }
  }
}

export const travelTimeService = new TravelTimeService();
