// Optimization module configuration — Phase 7 Foundation
// These are compile-time defaults. Runtime values come from optimization_settings table.

export const OPTIMIZATION_CONFIG = {
  // MCDA Weights (sum must equal 1.0)
  // Agreed initial weights from audit decisions
  mcda: {
    weights: {
      severity: 0.40,
      urgency: 0.25,
      report_count: 0.15,
      waiting_time: 0.15,
      weather: 0.05,
    },
    // Priority bucket thresholds
    buckets: {
      urgent: 80,   // score >= 80
      high: 60,      // score >= 60
      medium: 35,    // score >= 35
      // below 35 = low
    },
  },

  // Default SWMO depot coordinates (PLP Center)
  depot: {
    name: 'SWMO Depot (PLP Center)',
    latitude: 14.561433,
    longitude: 121.075636,
  },

  // Crew defaults
  crew: {
    shiftStart: '08:00',
    shiftEnd: '17:00',
    maxTasksPerShift: 10,
  },

  // Solver strategy
  solver: {
    // 'greedy' = pure JS nearest-neighbor (default MVP)
    // 'ortools' = Google OR-Tools (future, requires OPTIMIZATION_VRP_SOLVER env var)
    strategy: process.env.OPTIMIZATION_VRP_SOLVER || 'greedy',
  },

  // Directions provider
  directions: {
    // 'none' = Haversine straight-line (default MVP)
    // 'tomtom' = TomTom Routing API
    provider: process.env.OPTIMIZATION_DIRECTIONS_PROVIDER || 'tomtom',
  },
};
