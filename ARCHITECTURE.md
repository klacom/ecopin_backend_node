# Ecopin Data Hierarchy & Architecture

This document defines the core data hierarchy for the Ecopin ecosystem. This architectural standard must be adhered to across all repositories (Web, App, Backend, ML Models) to ensure consistency in data modeling, API design, and UI navigation.

## Core Hierarchy

The operational data model strictly follows this top-down hierarchy (from largest to smallest unit):

**Workflow > Cleanup Tasks > Clusters > Reports**

---

### 1. Workflow (Top Level)
* **Definition:** The overarching operational process, initiative, campaign, or continuous regional mandate.
* **Purpose:** Groups multiple actionable tasks under a single administrative umbrella. Used for high-level tracking, budgeting, and performance analytics (e.g., "Spring Downtown Cleanup 2026", "Zone A Weekly Maintenance").
* **Relationships:** 
  * Has many **Cleanup Tasks**.
* **Key Attributes:** Status, Name, Start/End Dates, Budget/Resources, Overall Completion Metric.

### 2. Cleanup Tasks
* **Definition:** Actionable work items assigned to Field Crews, contractors, or specific officers.
* **Purpose:** Represents an actual unit of physical work (e.g., a shift's dispatch). It defines the operational boundaries, logistics, and resources required to address multiple clustered issues on the ground.
* **Relationships:** 
  * Belongs to one **Workflow**.
  * Has one or more **Clusters**.
* **Key Attributes:** Assignee (Crew/Officer), Scheduled Date, Route Optimization Data, Task Status (Pending, In Progress, Completed), Required Equipment.

### 3. Clusters
* **Definition:** A system-generated or manually curated grouping of geographically and temporally related Reports.
* **Purpose:** Deduplicates individual user submissions and groups nearby issues so they can be addressed efficiently together. Clusters aggregate severity, volume, and spatial data from underlying reports.
* **Relationships:** 
  * Belongs to one **Cleanup Task**.
  * Has many **Reports**.
* **Key Attributes:** Center Coordinates (Centroid), Bounding Box/Radius, Aggregated Severity, Cluster Status, Primary Issue Type.

### 4. Reports (Base Level)
* **Definition:** The atomic unit of data. An individual submission from an end-user, officer, or automated sensor regarding an environmental issue (e.g., litter, illegal dumping, graffiti).
* **Purpose:** The raw data point containing evidence, location coordinates, and metadata.
* **Relationships:** 
  * Belongs to one **Cluster** (can be unassigned initially, but must be clustered for resolution).
* **Key Attributes:** Location Coordinates, Image Evidence, AI Validation Status, Property Owner Consent, User ID, Timestamp.

---

## Architectural Implementation Rules

1. **Database Schema:** 
   * Foreign keys must strictly enforce this top-down relationship. 
   * A `Report` references a `cluster_id`. 
   * A `Cluster` references a `task_id`. 
   * A `Cleanup Task` references a `workflow_id`.
   * *Note: Reports may initially have a null `cluster_id` until processed by the clustering algorithm.*

2. **API Endpoints:** 
   * Routing should intuitively follow the hierarchy.
   * Examples: 
     * `GET /api/workflows/:id/tasks`
     * `GET /api/tasks/:id/clusters`
     * `GET /api/clusters/:id/reports`

3. **UI/UX Navigation (Web & App):** 
   * Dashboards and mobile views must support drill-down navigation mimicking this hierarchy. 
   * Operations managers start at high-level Workflows/Tasks and drill down into Clusters.
   * Field crews view their Cleanup Tasks, then navigate to specific Clusters, and finally review individual Reports to ensure complete resolution.
