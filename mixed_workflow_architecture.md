# Mixed Workflow Architecture

## Overview
The Mixed Workflow Architecture upgrades the dispatch and optimization logic from a strict binary system (Clusters vs. SLA-Breached Outliers) into a dynamic, context-aware routing model. It acknowledges **fleet heterogeneity** and introduces **spatial bundling**, allowing agile sweeper crews to handle isolated points and heavier standard crews to focus on large clusters, while intelligently combining both when routing permits.

## Key Concepts

### 1. Fleet Heterogeneity
Field crews are no longer monolithic entities. The system now differentiates crews by vehicle type, capacity, and operational role:
- **Standard Crews:** Equipped with large compactor trucks, tasked primarily with large Standard Clusters. High payload, low agility.
- **Sweeper Crews:** Equipped with tricycles or motorcycles, tasked primarily with isolated reports. Low payload, high agility.

### 2. The Maturation Window
Rather than waiting for a report to breach the SLA (e.g., 48 hours), an isolated report becomes eligible for the Sweeper queue after a **Maturation Window** (e.g., 24 hours). This ensures isolated reports are addressed proactively before causing an SLA breach, without prematurely sweeping them and preventing natural cluster formation.

### 3. Spatial Buffering & Task Bundling
When a route is generated for a high-priority cluster, the system performs a geographic query (using PostGIS spatial buffers like `ST_DWithin`) to identify maturing isolated reports nearby. These isolated reports are "opportunistically" appended to the standard crew's itinerary as long as capacity allows.

### 4. Operational Modes
The system introduces three administrative routing modes:
- **Mode 1: Pure Standard:** Only targets identified clusters. (Ideal for peak crisis times).
- **Mode 2: Pure Sweeper:** Only targets isolated, maturing points. (Ideal for quiet periods using specialized agile crews).
- **Mode 3: Mixed (Smart Route):** Targets high-priority clusters and spatially bundles nearby maturing single reports into the same dispatch plan.

---

## Required Codebase Modifications

### 1. Database & Migrations
To support this architecture, new data fields are needed in the database.
**Proposed File:** `migrations/add_fleet_and_maturation_metadata.sql`
- Update `field_crews` table to include `vehicle_type` (e.g., compactor, tricycle) and `capacity` metadata.
- Update `sweeper_configuration` to include `maturation_threshold_hours` (e.g., 24 hours).

### 2. Sweeper & SLA Services
**File to Modify:** `src/modules/sweeper/services/sla-detection.service.js`
- **Changes Needed:** Introduce the concept of a maturing report. Instead of just `detect_sla_outliers`, add logic (or update the stored procedure) to flag reports that have passed the `maturation_threshold_hours` but haven't clustered, marking them as `maturing_outlier`.

### 3. Optimization Controller
**File to Modify:** `src/modules/optimization/controllers/optimization.controller.js`
- **Changes Needed:** Update `runOptimization` and `generatePlan` endpoints to accept a `mode` parameter (e.g., `standard`, `sweeper`, `mixed`).
- Based on the `mode`, pass context down to the dispatch planner to filter tasks appropriately.

### 4. Dispatch & Work Queue Services
**Files to Modify:** 
- `src/modules/optimization/services/dispatchPlanner.service.js`
- `src/modules/optimization/services/workQueue.service.js`
- **Changes Needed:** 
  - **For Pure Sweeper:** Allow the work queue to fetch individual reports tagged as `maturing_outlier`.
  - **For Mixed Mode (Smart Route):** Implement a two-pass query.
    1. Fetch highest priority clusters (Anchor Tasks).
    2. Use PostGIS (e.g., `ST_DWithin(clusters.geom, reports.geom, 2000)`) to find maturing outliers within a defined spatial buffer of the anchor tasks.
    3. Bundle these isolated reports with the anchor cluster in the generated dispatch plan.

### 5. Crew Assignment Logic
**File to Modify:** `src/modules/optimization/services/crewAssigner.service.js`
- **Changes Needed:** Enhance the greedy assignment or VRP logic to factor in **fleet heterogeneity**.
  - Prevent large clusters from being assigned to low-capacity tricycle crews.
  - Allow standard crews to accept mixed tasks (cluster + bundled single reports) up to their vehicle capacity limit.

### 6. MCDA Prioritization Update
**File to Modify:** `src/modules/optimization/services/mcdaPrioritizer.service.js`
- **Changes Needed:** Add a new weighting factor: **"Proximity to an Active Cluster."** When prioritizing single reports for a Sweeper or Mixed run, a report gains a higher priority score if it is physically close to an already high-priority cluster, making it mathematically more likely to be bundled.
