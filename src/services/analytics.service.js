import { supabaseAdmin as supabase } from '../config/supabase.config.js';

class AnalyticsService {
  async getRouteEfficiency() {
    const { data } = await supabase
      .from('crew_routes')
      .select('*');
    return data;
  }

  async getCrewProductivity() {
    const { data } = await supabase
      .from('cleanup_tasks')
      .select('*')
      .neq('task_type', 'Sweeper');
    return data;
  }

  async getClusterDensity() {
    const { data } = await supabase
      .from('clusters')
      .select('*');
    return data;
  }
}

export const analyticsService = new AnalyticsService();
