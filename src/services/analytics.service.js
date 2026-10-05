import { supabaseAdmin as supabase } from '../config/supabase.config.js';

class AnalyticsService {
  async getRouteEfficiency() {
    // Explicitly exclude entities where is_outlier = true
    const { data } = await supabase
      .from('crew_routes')
      .select('*')
      .eq('is_outlier', false);
    return data;
  }

  async getCrewProductivity() {
    // Explicitly exclude entities where is_outlier = true
    const { data } = await supabase
      .from('cleanup_tasks')
      .select('*')
      .eq('is_outlier', false); 
    return data;
  }

  async getClusterDensity() {
    // Explicitly exclude entities where is_outlier = true
    const { data } = await supabase
      .from('clusters')
      .select('*')
      .eq('is_outlier', false); 
    return data;
  }
}

export const analyticsService = new AnalyticsService();
