import fetch from 'node-fetch';

const geocodeCache = new Map();
const MAX_CACHE_SIZE = 1000;

export const reverseGeocode = async (locationStr) => {
    if (!locationStr) return null;
    
    let lon, lat;
    if (typeof locationStr === 'string') {
        const match = locationStr.match(/POINT\(([-.\d]+)\s+([-.\d]+)\)/);
        if (!match) return null;
        lon = parseFloat(match[1]);
        lat = parseFloat(match[2]);
    } else if (typeof locationStr === 'object' && locationStr.type === 'Point' && Array.isArray(locationStr.coordinates)) {
        lon = parseFloat(locationStr.coordinates[0]);
        lat = parseFloat(locationStr.coordinates[1]);
    } else {
        return null;
    }
    
    // Round to 4 decimal places for cache key (~11 meters precision)
    const cacheKey = `${lat.toFixed(4)},${lon.toFixed(4)}`;
    
    if (geocodeCache.has(cacheKey)) {
        return geocodeCache.get(cacheKey);
    }
    
    try {
        const url = `https://nominatim.openstreetmap.org/reverse?format=json&lat=${lat}&lon=${lon}&zoom=18&addressdetails=1`;
        
        // Use generic user agent to respect nominatim guidelines (must provide user-agent)
        const response = await fetch(url, {
            headers: { 'User-Agent': 'EcoPinBackend/1.0 (contact@ecopin.local)' }
        });
        
        if (!response.ok) {
            console.error('Nominatim API error:', response.statusText);
            return null;
        }
        
        const data = await response.json();
        const address = data.display_name || null;
        
        if (address) {
            if (geocodeCache.size >= MAX_CACHE_SIZE) {
                const firstKey = geocodeCache.keys().next().value;
                geocodeCache.delete(firstKey);
            }
            geocodeCache.set(cacheKey, address);
        }
        return address;
    } catch (error) {
        console.error('Error in reverse geocoding:', error);
        return null;
    }
};

export const extractLocationStr = (task) => {
    if (!task) return null;
    return task.location || task.clusters?.center || (task.reports?.[0]?.location);
};
