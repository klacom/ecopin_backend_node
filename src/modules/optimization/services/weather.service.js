import fetch from 'node-fetch';
import { OPTIMIZATION_CONFIG } from '../config/optimization.config.js';
import { supabaseAdmin as supabase } from '../../../config/supabase.config.js';

/**
 * Fetches real-time weather data from Open-Meteo based on the depot coordinates.
 * @returns {Promise<string>} 'normal', 'rainy', or 'severe'
 */
export async function getLiveWeatherCondition() {
  try {
    // Attempt to get depot from DB first
    const { data: depotSetting } = await supabase.from('optimization_settings').select('value').eq('key', 'swmo_depot').single();
    let lat = OPTIMIZATION_CONFIG.depot.latitude;
    let lng = OPTIMIZATION_CONFIG.depot.longitude;

    if (depotSetting && depotSetting.value) {
      lat = depotSetting.value.latitude || lat;
      lng = depotSetting.value.longitude || lng;
    }

    const url = `https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lng}&current_weather=true`;
    const response = await fetch(url);
    
    if (!response.ok) {
      console.warn('[Optimization] Failed to fetch live weather, falling back to normal');
      return 'normal';
    }

    const data = await response.json();
    const code = data?.current_weather?.weathercode;
    
    // WMO Weather interpretation codes
    // 0-48: clear, cloudy, fog -> normal
    // 51-82: drizzle, rain, showers -> rainy
    // 95-99: thunderstorm -> severe
    
    if (code === undefined || code === null) return 'normal';
    
    if (code >= 95) {
      return 'severe';
    } else if (code >= 51) {
      return 'rainy';
    } else {
      return 'normal';
    }
  } catch (error) {
    console.error('[Optimization] Error fetching live weather:', error);
    return 'normal';
  }
}
