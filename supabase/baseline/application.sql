-- Schema metadata only. Local bootstrap, NOT a production migration.
BEGIN;
SET LOCAL search_path=public,extensions;
SET LOCAL check_function_bodies=false;
DO $$ BEGIN IF EXISTS(SELECT 1 FROM pg_tables WHERE schemaname='public') THEN RAISE EXCEPTION 'Local application catalog must be empty'; END IF; END $$;
CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA extensions;
DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='ecopin_operational_reader') THEN CREATE ROLE "ecopin_operational_reader" NOLOGIN NOINHERIT NOBYPASSRLS NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION; END IF; END $$;
GRANT "ecopin_operational_reader" TO postgres WITH ADMIN OPTION;
DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='ecopin_public_map_reader') THEN CREATE ROLE "ecopin_public_map_reader" NOLOGIN NOINHERIT NOBYPASSRLS NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION; END IF; END $$;
GRANT "ecopin_public_map_reader" TO postgres WITH ADMIN OPTION;
CREATE SCHEMA IF NOT EXISTS "workflow_private";
ALTER SCHEMA "workflow_private" OWNER TO "postgres";
CREATE SCHEMA IF NOT EXISTS "storage_authority";
ALTER SCHEMA "storage_authority" OWNER TO "postgres";
CREATE SCHEMA IF NOT EXISTS "verification_private";
ALTER SCHEMA "verification_private" OWNER TO "postgres";
CREATE SCHEMA IF NOT EXISTS "public";
ALTER SCHEMA "public" OWNER TO "pg_database_owner";
CREATE SCHEMA IF NOT EXISTS "privacy_private";
ALTER SCHEMA "privacy_private" OWNER TO "postgres";
CREATE SCHEMA IF NOT EXISTS "operational_private";
ALTER SCHEMA "operational_private" OWNER TO "postgres";
CREATE TYPE "public"."cluster_severity" AS ENUM ('low','medium','high');
CREATE TYPE "public"."audit_log_action_type" AS ENUM ('user_created','login','logout','password_change','password_reset','profile_update','account_deletion');
CREATE TYPE "public"."response_log_action_type" AS ENUM ('citizen_close','manual_note','lifecycle_stage_update','status_update','assigned','unassigned');
CREATE TYPE "public"."sync_entity_type" AS ENUM ('report','task','cluster','dispatch_plan');
CREATE TYPE "public"."sync_operation_type" AS ENUM ('fc.report.update_status','fc.report.update_lifecycle_stage','fc.report.update_validation','fc.report.update_details','fc.note.add','fc.task.mark_complete','fc.photo.upload_before','fc.photo.upload_after','fc.photo.delete','task_update','report_create','report_update','fc.report.reconcile','fc.load.record','fc.task.failure');
CREATE TYPE "public"."dispatch_plan_status" AS ENUM ('draft','approved','discarded');
CREATE TYPE "public"."crew_availability_status" AS ENUM ('available','on_route','off_shift','disabled');
CREATE TYPE "public"."role" AS ENUM ('citizen','lgu','admin','officer','field_crew');
CREATE TYPE "public"."notification_type" AS ENUM ('general','pending_validation','approved','rejected','flagged','resolved','in_progress','closed','lifecycle_update','account_warning','account_suspended');
CREATE TYPE "public"."cleanup_task_status" AS ENUM ('created','pending','in_progress','partially_completed','completed','cancelled','failed','assigned','en_route');
CREATE TYPE "public"."cleanup_task_type" AS ENUM ('Cleanup','Investigation','Verification','Emergency Response','Reinspection','Monitoring','Escalation','Deferred','Sweeper','Mixed');
CREATE TYPE "public"."route_waypoint_type" AS ENUM ('depot_start','task','depot_end','bundled_report');
CREATE TYPE "public"."vehicle_type_enum" AS ENUM ('compactor','pickup','tricycle','motorcycle','hazmat_unit','walking','bicycle');
CREATE TYPE "public"."report_validation_status" AS ENUM ('pending','pending_ai_validation','manual_review','approved','rejected');
CREATE TYPE "public"."manual_review_status" AS ENUM ('pending','in_review','reviewed');
CREATE TYPE "public"."manual_review_type" AS ENUM ('severe_violation','report_flag','user_appeal','other');
CREATE TYPE "public"."consent_status" AS ENUM ('not_required','pending','obtained','denied');
CREATE TYPE "public"."report_severity_level" AS ENUM ('Low','Medium','High');
CREATE TYPE "public"."violation_severity" AS ENUM ('normal','severe');
CREATE TYPE "public"."severe_violation_category" AS ENUM ('nudity','pornography','graphic_violence','gore','terrorism','hate_symbols');
CREATE TYPE "public"."report_status" AS ENUM ('unresolved','in_progress','resolved','pending_owner_consent','waiting_for_feedback','closed','completed','rejected');
CREATE TYPE "public"."report_issue_type" AS ENUM ('waste','flooding','pollution','infrastructure','illegal_logging','pending','others');
CREATE TYPE "public"."cluster_status" AS ENUM ('new','unresolved','prioritized','queued','scheduled','in_progress','resolved','needs_verification','monitoring','deferred','escalated','completed','closed');
CREATE TYPE "public"."lifecycle_stage" AS ENUM ('submitted','assigned','acknowledged','in_progress','responded','resolved','closed');
CREATE SEQUENCE "public"."fc_version_seq" AS bigint INCREMENT 1 MINVALUE 1 MAXVALUE 9223372036854775807 START 1 CACHE 1 NO CYCLE;
ALTER SEQUENCE "public"."fc_version_seq" OWNER TO postgres;
CREATE SEQUENCE "public"."support_ticket_number_seq" AS bigint INCREMENT 1 MINVALUE 1 MAXVALUE 9223372036854775807 START 1000 CACHE 1 NO CYCLE;
ALTER SEQUENCE "public"."support_ticket_number_seq" OWNER TO postgres;
CREATE SEQUENCE "public"."sweeper_audit_log_id_seq" AS integer INCREMENT 1 MINVALUE 1 MAXVALUE 2147483647 START 1 CACHE 1 NO CYCLE;
ALTER SEQUENCE "public"."sweeper_audit_log_id_seq" OWNER TO postgres;
CREATE TABLE "public"."field_crews" (
 "id" uuid NOT NULL,
 "name" text NOT NULL,
 "team_lead_profile_id" uuid,
 "member_profile_ids" uuid[],
 "depot_location" geography(Point,4326),
 "shift_start" time without time zone NOT NULL,
 "shift_end" time without time zone NOT NULL,
 "max_tasks_per_shift" integer,
 "availability_status" crew_availability_status,
 "created_at" timestamp with time zone,
 "updated_at" timestamp with time zone,
 "supports_standard" boolean NOT NULL,
 "supports_sweeper" boolean NOT NULL,
 "speed_factor" numeric NOT NULL,
 "service_time_factor" numeric NOT NULL,
 "vehicle_type" vehicle_type_enum NOT NULL,
 "hazmat_certified" boolean NOT NULL,
 "certifications" text[] NOT NULL,
 "max_volume_m3" numeric(8,3),
 "max_weight_kg" numeric(10,2),
 "starting_volume_m3" numeric(8,3),
 "starting_weight_kg" numeric(10,2),
 "load_measured_at" timestamp with time zone,
 "certification_reviewed_by" uuid
);
ALTER TABLE "public"."field_crews" OWNER TO "postgres";
CREATE TABLE "operational_private"."crew_presence" (
 "crew_id" uuid NOT NULL,
 "last_seen_at" timestamp with time zone NOT NULL
);
ALTER TABLE "operational_private"."crew_presence" OWNER TO "postgres";
CREATE TABLE "public"."dispatch_plans" (
 "id" uuid NOT NULL,
 "planned_date" date NOT NULL,
 "total_crews_available" integer NOT NULL,
 "total_capacity_minutes" integer NOT NULL,
 "status" dispatch_plan_status,
 "created_at" timestamp with time zone,
 "created_by" uuid,
 "mode" text NOT NULL,
 "settings_snapshot" jsonb NOT NULL,
 "optimization_run_id" uuid,
 "routing_attempts" integer NOT NULL,
 "routing_token" uuid,
 "routing_lease_until" timestamp with time zone,
 "capacity_breakdown" jsonb NOT NULL,
 "route_proposal" jsonb,
 "rejected_bundles" jsonb NOT NULL,
 "solver_diagnostics" jsonb NOT NULL,
 "planning_as_of" timestamp with time zone,
 "generation_job_id" uuid
);
ALTER TABLE "public"."dispatch_plans" OWNER TO "postgres";
CREATE TABLE "public"."manual_review_queue" (
 "id" uuid NOT NULL,
 "report_id" uuid,
 "strike_id" uuid,
 "review_type" manual_review_type NOT NULL,
 "priority" character varying(20),
 "status" manual_review_status,
 "assigned_to" uuid,
 "assigned_at" timestamp with time zone,
 "reviewed_at" timestamp with time zone,
 "review_notes" text,
 "created_at" timestamp with time zone,
 "updated_at" timestamp with time zone
);
ALTER TABLE "public"."manual_review_queue" OWNER TO "postgres";
CREATE TABLE "public"."audit_logs" (
 "id" uuid NOT NULL,
 "report_id" uuid,
 "user_id" uuid,
 "action_type" response_log_action_type NOT NULL,
 "action_details" text NOT NULL,
 "created_at" timestamp with time zone
);
ALTER TABLE "public"."audit_logs" OWNER TO "postgres";
CREATE TABLE "public"."system_logs" (
 "id" uuid NOT NULL,
 "user_id" uuid,
 "action_type" audit_log_action_type NOT NULL,
 "action_details" text,
 "ip_address" character varying(45),
 "user_agent" text,
 "created_at" timestamp with time zone
);
ALTER TABLE "public"."system_logs" OWNER TO "postgres";
CREATE TABLE "public"."cleanup_tasks" (
 "id" uuid NOT NULL,
 "cluster_id" uuid,
 "lgu_user_id" uuid,
 "title" text,
 "status" cleanup_task_status,
 "before_photo_url" text,
 "after_photo_url" text,
 "notes" text,
 "created_at" timestamp with time zone,
 "completed_at" timestamp with time zone,
 "created_by" uuid,
 "description" text,
 "is_custom" boolean,
 "report_ids" uuid[],
 "assigned_crew_ids" uuid[],
 "assigned_at" timestamp with time zone,
 "assigned_by" uuid,
 "last_assigned_at" timestamp with time zone,
 "priority" text,
 "priority_score" numeric,
 "crew_route_id" uuid,
 "sequence_in_route" integer,
 "estimated_duration_min" integer,
 "task_type" cleanup_task_type,
 "cluster_ids" uuid[],
 "required_resources" text,
 "expected_action" text,
 "scheduled_date" date,
 "completion_result" text,
 "completion_notes" text,
 "report_sequence" uuid[],
 "fc_version" bigint NOT NULL,
 "before_photo_hash" text,
 "after_photo_hash" text,
 "location" geography(Point,4326),
 "street_address" text,
 "source_plan_id" uuid,
 "source_group_key" text,
 "assigned_field_crew_id" uuid,
 "estimated_work_minutes" integer NOT NULL,
 "dispatch_kind" text NOT NULL,
 "route_status" text NOT NULL,
 "routing_deadline_at" timestamp with time zone,
 "routing_escalated_at" timestamp with time zone,
 "failure_class" text,
 "failure_reason" text,
 "completed_by" uuid,
 "completion_operation_id" text,
 "satellite_report_ids" uuid[] NOT NULL,
 "bundle_detour_min" numeric(6,2),
 "estimated_volume_m3" numeric(8,3),
 "estimated_weight_kg" numeric(10,2),
 "load_estimate_confidence" text,
 "route_revision" bigint NOT NULL,
 "assignment_generation" bigint NOT NULL,
 "operational_actor_id" uuid
);
ALTER TABLE "public"."cleanup_tasks" OWNER TO "postgres";
CREATE TABLE "public"."dispatch_plan_items" (
 "id" uuid NOT NULL,
 "dispatch_plan_id" uuid NOT NULL,
 "cluster_id" uuid,
 "is_selected" boolean NOT NULL,
 "reason" text,
 "estimated_duration_minutes" integer,
 "created_at" timestamp with time zone,
 "report_id" uuid,
 "report_ids" uuid[] NOT NULL,
 "item_type" text NOT NULL,
 "group_key" text NOT NULL,
 "planned_crew_id" uuid,
 "estimated_work_minutes" integer NOT NULL,
 "priority_score" numeric,
 "crew_snapshot" jsonb NOT NULL,
 "anchor_cluster_id" uuid,
 "cluster_ids" uuid[] NOT NULL,
 "bundle_order" smallint,
 "detour_minutes" numeric(6,2),
 "estimated_volume_m3" numeric(8,3),
 "estimated_weight_kg" numeric(10,2),
 "load_snapshot" jsonb,
 "commit_disposition" text NOT NULL,
 "commit_reason" text,
 "committed_task_id" uuid
);
ALTER TABLE "public"."dispatch_plan_items" OWNER TO "postgres";
CREATE TABLE "public"."building_structures" (
 "id" uuid NOT NULL,
 "house_number" text,
 "street_name" text,
 "barangay" text,
 "building_name" text,
 "source" text,
 "centroid_lat" double precision,
 "centroid_lng" double precision,
 "boundary" geometry(Geometry,4326) NOT NULL,
 "created_at" timestamp with time zone NOT NULL
);
ALTER TABLE "public"."building_structures" OWNER TO "postgres";
CREATE TABLE "public"."crew_urgency_observations" (
 "operation_id" text NOT NULL,
 "report_id" uuid NOT NULL,
 "task_id" uuid NOT NULL,
 "actor_id" uuid,
 "observed_result" text NOT NULL,
 "conditions" text NOT NULL,
 "evidence_snapshot" jsonb NOT NULL,
 "note_id" text NOT NULL,
 "recorded_at" timestamp with time zone NOT NULL
);
ALTER TABLE "public"."crew_urgency_observations" OWNER TO "postgres";
CREATE TABLE "public"."plan_generation_jobs" (
 "id" uuid NOT NULL,
 "requested_by" uuid NOT NULL,
 "mode" text NOT NULL,
 "status" text NOT NULL,
 "idempotency_key" text,
 "requested_at" timestamp with time zone NOT NULL,
 "started_at" timestamp with time zone,
 "finished_at" timestamp with time zone,
 "lease_until" timestamp with time zone,
 "worker_token" uuid,
 "settings_snapshot" jsonb NOT NULL,
 "plan_id" uuid,
 "error_code" text,
 "solver_diagnostics" jsonb NOT NULL
);
ALTER TABLE "public"."plan_generation_jobs" OWNER TO "postgres";
CREATE TABLE "public"."crew_urgency_reviews" (
 "observation_id" text NOT NULL,
 "operation_id" uuid NOT NULL,
 "actor_id" uuid,
 "reason" text NOT NULL,
 "reviewed_at" timestamp with time zone NOT NULL
);
ALTER TABLE "public"."crew_urgency_reviews" OWNER TO "postgres";
CREATE TABLE "public"."reports" (
 "id" uuid NOT NULL,
 "user_id" uuid,
 "title" text NOT NULL,
 "description" text,
 "issue_type" report_issue_type,
 "location" geography(Point,4326) NOT NULL,
 "validation_status" report_validation_status,
 "status" report_status,
 "cluster_id" uuid,
 "created_at" timestamp with time zone,
 "updated_at" timestamp with time zone,
 "notes" text,
 "before_photo_url" text,
 "after_photo_url" text,
 "on_private_property" boolean,
 "property_owner_consent_status" consent_status,
 "stage" lifecycle_stage,
 "satisfaction_rating" integer,
 "lgu_resolved_at" timestamp with time zone,
 "citizen_closed_at" timestamp with time zone,
 "is_overdue" boolean,
 "ai_score" numeric,
 "flagged_severe" boolean,
 "severe_violation_category" severe_violation_category,
 "manual_review_id" uuid,
 "severity_score" smallint,
 "urgency_score" smallint,
 "ra9003_category" text,
 "ml_predicted_class" text,
 "ml_confidence" real,
 "ml_probabilities" jsonb,
 "cleanup_task_id" uuid,
 "scale_level" character varying(20),
 "obstruction_level" character varying(20),
 "severity_level" report_severity_level,
 "severity_factors" jsonb,
 "idempotency_key" text,
 "deadline_at" timestamp with time zone,
 "fc_version" bigint NOT NULL,
 "before_photo_hash" text,
 "after_photo_hash" text,
 "sla_started_at" timestamp with time zone,
 "lifecycle_state" text,
 "matured_at" timestamp with time zone,
 "breached_at" timestamp with time zone,
 "report_claim_generation" bigint NOT NULL,
 "hazard_class" text NOT NULL,
 "hazard_model_version" text,
 "hazard_confidence" numeric(4,3),
 "hazard_decision_source" text,
 "hazard_classified_at" timestamp with time zone,
 "photo_lat" double precision,
 "photo_lng" double precision,
 "photo_accuracy" double precision,
 "photo_captured_at" timestamp with time zone,
 "photo_source" text,
 "is_mocked" boolean,
 "location_verification_status" text,
 "photo_distance_meters" double precision,
 "before_photos" jsonb NOT NULL,
 "after_photos" jsonb NOT NULL,
 "street_address" text,
 "barangay" text,
 "city" text,
 "hide_identity" boolean NOT NULL,
 "citizen_priority" text,
 "priority_reason" text,
 "priority_explanation" text,
 "submitted_citizen_priority" text,
 "urgency_status" text,
 "urgency_decision_id" uuid,
 "urgency_decided_at" timestamp with time zone,
 "urgency_reason" text,
 "barangay_resolution_status" text NOT NULL,
 "barangay_candidates" text[] NOT NULL,
 "barangay_resolution_checked_at" timestamp with time zone,
 "location_district" text,
 "citizen_landmark" text,
 "cleanup_action_notes" text,
 "operational_actor_id" uuid
);
ALTER TABLE "public"."reports" OWNER TO "postgres";
CREATE TABLE "public"."pasig_barangay_roster" (
 "psgc_code" text NOT NULL,
 "name" text NOT NULL
);
ALTER TABLE "public"."pasig_barangay_roster" OWNER TO "postgres";
CREATE TABLE "public"."fc_operation_log" (
 "operation_id" text NOT NULL,
 "user_id" uuid,
 "operation_type" sync_operation_type NOT NULL,
 "entity_id" text NOT NULL,
 "entity_type" sync_entity_type NOT NULL,
 "status" text NOT NULL,
 "result" jsonb,
 "created_at" timestamp with time zone NOT NULL,
 "expires_at" timestamp with time zone NOT NULL
);
ALTER TABLE "public"."fc_operation_log" OWNER TO "postgres";
CREATE TABLE "public"."fc_conflict_audit" (
 "id" uuid NOT NULL,
 "operation_id" text NOT NULL,
 "user_id" uuid,
 "operation_type" sync_operation_type NOT NULL,
 "entity_id" text NOT NULL,
 "entity_type" sync_entity_type NOT NULL,
 "outcome" text NOT NULL,
 "client_base_version" bigint,
 "server_version" bigint NOT NULL,
 "payload" jsonb NOT NULL,
 "server_state_snapshot" jsonb,
 "reason" text,
 "created_at" timestamp with time zone NOT NULL
);
ALTER TABLE "public"."fc_conflict_audit" OWNER TO "postgres";
CREATE TABLE "public"."profiles" (
 "id" uuid NOT NULL,
 "full_name" text,
 "created_at" timestamp with time zone,
 "role" role,
 "avatar_url" text,
 "data_consent" boolean,
 "suspended_until" timestamp with time zone,
 "strike_count" integer,
 "last_strike_at" timestamp with time zone,
 "is_email_verified" boolean,
 "require_password_change" boolean
);
ALTER TABLE "public"."profiles" OWNER TO "postgres";
CREATE TABLE "public"."hotspot_accuracy" (
 "id" uuid NOT NULL,
 "prediction_id" uuid,
 "actual_reports" integer NOT NULL,
 "predicted_reports" integer NOT NULL,
 "accuracy_score" numeric(5,4),
 "time_horizon" character varying(20) NOT NULL,
 "evaluation_date" date NOT NULL,
 "created_at" timestamp with time zone
);
ALTER TABLE "public"."hotspot_accuracy" OWNER TO "postgres";
CREATE TABLE "public"."dispatch_group_commits" (
 "dispatch_plan_id" uuid NOT NULL,
 "group_key" text NOT NULL,
 "result" jsonb NOT NULL,
 "committed_at" timestamp with time zone NOT NULL
);
ALTER TABLE "public"."dispatch_group_commits" OWNER TO "postgres";
CREATE TABLE "public"."system_settings" (
 "id" uuid NOT NULL,
 "password_min_length" integer,
 "password_require_uppercase" boolean,
 "password_require_lowercase" boolean,
 "password_require_numbers" boolean,
 "password_require_special_chars" boolean,
 "session_timeout_minutes" integer,
 "created_at" timestamp with time zone,
 "updated_at" timestamp with time zone,
 "strike_1_action" character varying(50),
 "strike_2_action" character varying(50),
 "strike_3_action" character varying(50),
 "strike_4_action" character varying(50),
 "strike_2_duration_hours" integer,
 "strike_3_duration_hours" integer,
 "severe_violation_action" character varying(50),
 "severe_violation_duration_hours" integer,
 "severe_violation_auto_reject" boolean,
 "severe_violation_immediate_strike" boolean,
 "daily_report_quota" integer,
 "report_video_max_seconds" smallint NOT NULL
);
ALTER TABLE "public"."system_settings" OWNER TO "postgres";
CREATE TABLE "public"."email_verifications" (
 "id" uuid NOT NULL,
 "user_id" uuid NOT NULL,
 "token" uuid,
 "expires_at" timestamp with time zone NOT NULL,
 "used_at" timestamp with time zone,
 "created_at" timestamp with time zone,
 "token_digest" text,
 "issued_to_email" text
);
ALTER TABLE "public"."email_verifications" OWNER TO "postgres";
CREATE TABLE "public"."dispatch_access_blocks" (
 "id" uuid NOT NULL,
 "cluster_id" uuid,
 "report_id" uuid,
 "task_id" uuid,
 "reason" text NOT NULL,
 "failure_class" text NOT NULL,
 "blocked_by" uuid,
 "blocked_at" timestamp with time zone NOT NULL,
 "cleared_by" uuid,
 "cleared_at" timestamp with time zone,
 "clearance_notes" text
);
ALTER TABLE "public"."dispatch_access_blocks" OWNER TO "postgres";
CREATE TABLE "public"."pasig_barangay_boundary_source" (
 "singleton" boolean NOT NULL,
 "source_url" text NOT NULL,
 "source_sha256" text NOT NULL,
 "imported_at" timestamp with time zone NOT NULL
);
ALTER TABLE "public"."pasig_barangay_boundary_source" OWNER TO "postgres";
CREATE TABLE "public"."field_assignment_receipts" (
 "id" uuid NOT NULL,
 "task_id" uuid NOT NULL,
 "report_id" uuid NOT NULL,
 "crew_id" uuid NOT NULL,
 "assignment_generation" bigint NOT NULL,
 "report_claim_generation" bigint NOT NULL,
 "issued_at" timestamp with time zone NOT NULL
);
ALTER TABLE "public"."field_assignment_receipts" OWNER TO "postgres";
CREATE TABLE "public"."report_resolution_events" (
 "id" uuid NOT NULL,
 "report_id" uuid NOT NULL,
 "task_id" uuid NOT NULL,
 "crew_id" uuid NOT NULL,
 "operation_id" text NOT NULL,
 "resolved_at" timestamp with time zone NOT NULL,
 "report_fc_version" bigint NOT NULL,
 "resolution_kind" text NOT NULL
);
ALTER TABLE "public"."report_resolution_events" OWNER TO "postgres";
CREATE TABLE "public"."notifications" (
 "id" uuid NOT NULL,
 "user_id" uuid NOT NULL,
 "report_id" uuid,
 "type" notification_type NOT NULL,
 "title" text NOT NULL,
 "body" text NOT NULL,
 "is_read" boolean NOT NULL,
 "created_at" timestamp with time zone NOT NULL
);
ALTER TABLE "public"."notifications" OWNER TO "postgres";
CREATE TABLE "public"."optimization_templates" (
 "id" uuid NOT NULL,
 "name" text NOT NULL,
 "description" text,
 "created_by" uuid,
 "is_default" boolean,
 "settings" jsonb NOT NULL,
 "created_at" timestamp with time zone,
 "updated_at" timestamp with time zone
);
ALTER TABLE "public"."optimization_templates" OWNER TO "postgres";
CREATE TABLE "public"."task_report_outcomes" (
 "id" uuid NOT NULL,
 "operation_id" text NOT NULL,
 "task_id" uuid NOT NULL,
 "report_id" uuid NOT NULL,
 "crew_id" uuid NOT NULL,
 "receipt_id" uuid NOT NULL,
 "outcome" text NOT NULL,
 "disposition" text NOT NULL,
 "observed_at" timestamp with time zone NOT NULL,
 "submitted_at" timestamp with time zone NOT NULL,
 "evidence_refs" jsonb NOT NULL,
 "notes" text NOT NULL,
 "resolution_event_id" uuid,
 "evidence_verification" text NOT NULL
);
ALTER TABLE "public"."task_report_outcomes" OWNER TO "postgres";
CREATE TABLE "public"."optimization_settings" (
 "id" uuid NOT NULL,
 "key" text NOT NULL,
 "value" jsonb NOT NULL,
 "description" text,
 "updated_by" uuid,
 "updated_at" timestamp with time zone
);
ALTER TABLE "public"."optimization_settings" OWNER TO "postgres";
CREATE TABLE "public"."defense_seed_staging" (
 "marker" text NOT NULL,
 "payload" jsonb NOT NULL
);
ALTER TABLE "public"."defense_seed_staging" OWNER TO "postgres";
CREATE TABLE "public"."support_tickets" (
 "id" uuid NOT NULL,
 "reference" text NOT NULL,
 "citizen_id" uuid NOT NULL,
 "report_id" uuid,
 "category" text NOT NULL,
 "description" text NOT NULL,
 "status" text NOT NULL,
 "handler_id" uuid,
 "response" text,
 "responded_at" timestamp with time zone,
 "resolved_at" timestamp with time zone,
 "created_at" timestamp with time zone NOT NULL,
 "updated_at" timestamp with time zone NOT NULL
);
ALTER TABLE "public"."support_tickets" OWNER TO "postgres";
CREATE TABLE "public"."route_waypoints" (
 "id" uuid NOT NULL,
 "crew_route_id" uuid NOT NULL,
 "sequence_order" integer NOT NULL,
 "latitude" numeric NOT NULL,
 "longitude" numeric NOT NULL,
 "cleanup_task_id" uuid,
 "waypoint_type" route_waypoint_type,
 "distance_from_previous_meters" numeric,
 "estimated_time_from_previous_min" numeric,
 "created_at" timestamp with time zone,
 "polyline" jsonb,
 "report_id" uuid
);
ALTER TABLE "public"."route_waypoints" OWNER TO "postgres";
CREATE TABLE "public"."optimization_runs" (
 "id" uuid NOT NULL,
 "triggered_by" uuid,
 "status" text,
 "criteria" jsonb NOT NULL,
 "weather_condition" text,
 "traffic_condition" text,
 "num_tasks_optimized" integer,
 "num_crews" integer,
 "total_estimated_distance_meters" numeric,
 "total_estimated_duration_min" numeric,
 "error_message" text,
 "approved_by" uuid,
 "approved_at" timestamp with time zone,
 "created_at" timestamp with time zone
);
ALTER TABLE "public"."optimization_runs" OWNER TO "postgres";
CREATE TABLE "public"."crew_routes" (
 "id" uuid NOT NULL,
 "optimization_run_id" uuid NOT NULL,
 "crew_id" uuid NOT NULL,
 "start_depot" geography(Point,4326) NOT NULL,
 "end_depot" geography(Point,4326) NOT NULL,
 "total_distance_meters" numeric,
 "total_duration_min" numeric,
 "task_count" integer,
 "weather_snapshot" jsonb,
 "traffic_snapshot" jsonb,
 "created_at" timestamp with time zone
);
ALTER TABLE "public"."crew_routes" OWNER TO "postgres";
CREATE TABLE "public"."field_load_events" (
 "id" uuid NOT NULL,
 "operation_id" text NOT NULL,
 "task_id" uuid NOT NULL,
 "field_crew_id" uuid NOT NULL,
 "actor_id" uuid NOT NULL,
 "assignment_generation" bigint NOT NULL,
 "event_type" text NOT NULL,
 "fill_percent" numeric(5,2),
 "actual_volume_m3" numeric(10,3),
 "actual_weight_kg" numeric(12,2),
 "observed_at" timestamp with time zone NOT NULL,
 "submitted_at" timestamp with time zone NOT NULL,
 "notes" text NOT NULL
);
ALTER TABLE "public"."field_load_events" OWNER TO "postgres";
CREATE TABLE "public"."field_task_failure_events" (
 "id" uuid NOT NULL,
 "operation_id" text NOT NULL,
 "task_id" uuid NOT NULL,
 "actor_id" uuid NOT NULL,
 "assignment_generation" bigint NOT NULL,
 "reason_code" text NOT NULL,
 "failure_class" text NOT NULL,
 "evidence_refs" jsonb NOT NULL,
 "notes" text NOT NULL,
 "observed_at" timestamp with time zone NOT NULL,
 "submitted_at" timestamp with time zone NOT NULL
);
ALTER TABLE "public"."field_task_failure_events" OWNER TO "postgres";
CREATE TABLE "public"."sync_conflicts" (
 "id" uuid NOT NULL,
 "user_id" uuid,
 "operation_type" sync_operation_type NOT NULL,
 "operation_payload" jsonb NOT NULL,
 "conflict_reason" text NOT NULL,
 "server_state" jsonb,
 "created_at" timestamp with time zone,
 "resolved_at" timestamp with time zone,
 "resolved_by" uuid,
 "resolution_notes" text
);
ALTER TABLE "public"."sync_conflicts" OWNER TO "postgres";
CREATE TABLE "public"."work_time_configuration" (
 "report_type" character varying(100) NOT NULL,
 "work_time_minutes" integer NOT NULL,
 "updated_at" timestamp with time zone,
 "estimated_volume_m3" numeric(8,3),
 "estimated_weight_kg" numeric(10,2),
 "estimate_source" text,
 "estimate_reviewed_at" timestamp with time zone
);
ALTER TABLE "public"."work_time_configuration" OWNER TO "postgres";
CREATE TABLE "public"."sweeper_configuration" (
 "parameter_name" character varying(100) NOT NULL,
 "parameter_value" jsonb NOT NULL,
 "updated_at" timestamp with time zone,
 "updated_by" character varying(255)
);
ALTER TABLE "public"."sweeper_configuration" OWNER TO "postgres";
CREATE TABLE "public"."sweeper_audit_log" (
 "id" integer NOT NULL,
 "event_type" character varying(100) NOT NULL,
 "entity_type" character varying(100) NOT NULL,
 "entity_id" character varying(255) NOT NULL,
 "user_id" character varying(255),
 "event_data" jsonb,
 "created_at" timestamp with time zone
);
ALTER TABLE "public"."sweeper_audit_log" OWNER TO "postgres";
CREATE TABLE "workflow_private"."report_barangay_reconciliation_log" (
 "report_id" uuid NOT NULL,
 "reconciled_at" timestamp with time zone NOT NULL,
 "old_barangay" text,
 "old_city" text,
 "old_status" text NOT NULL,
 "new_barangay" text,
 "new_city" text,
 "new_status" text NOT NULL,
 "new_candidates" text[] NOT NULL,
 "reason" text NOT NULL
);
ALTER TABLE "workflow_private"."report_barangay_reconciliation_log" OWNER TO "postgres";
CREATE TABLE "workflow_private"."unprocessed_escalation_baseline" (
 "singleton" boolean NOT NULL,
 "cutoff" timestamp with time zone NOT NULL,
 "set_at" timestamp with time zone NOT NULL
);
ALTER TABLE "workflow_private"."unprocessed_escalation_baseline" OWNER TO "postgres";
CREATE TABLE "public"."clusters" (
 "id" uuid NOT NULL,
 "center" geometry(Point,4326) NOT NULL,
 "radius_meters" numeric,
 "report_count" integer NOT NULL,
 "issue_type" report_issue_type,
 "severity" cluster_severity,
 "status" cluster_status,
 "created_at" timestamp with time zone,
 "updated_at" timestamp with time zone,
 "priority_score" numeric,
 "priority" text,
 "estimated_effort_minutes" integer,
 "recommended_task_type" text,
 "label" text
);
ALTER TABLE "public"."clusters" OWNER TO "postgres";
CREATE TABLE "public"."strikes" (
 "id" uuid NOT NULL,
 "user_id" uuid,
 "reason" text NOT NULL,
 "violation_type" character varying(50) NOT NULL,
 "issued_by" uuid,
 "issued_at" timestamp with time zone,
 "expires_at" timestamp with time zone,
 "is_active" boolean,
 "notes" text,
 "severity" violation_severity,
 "severe_category" severe_violation_category,
 "requires_manual_review" boolean,
 "manual_review_status" character varying(50)
);
ALTER TABLE "public"."strikes" OWNER TO "postgres";
CREATE TABLE "privacy_private"."hidden_report_owners" (
 "report_id" uuid NOT NULL,
 "owner_id" uuid NOT NULL
);
ALTER TABLE "privacy_private"."hidden_report_owners" OWNER TO "postgres";
CREATE TABLE "privacy_private"."hidden_report_artifacts" (
 "record_id" uuid NOT NULL,
 "report_id" uuid NOT NULL
);
ALTER TABLE "privacy_private"."hidden_report_artifacts" OWNER TO "postgres";
CREATE TABLE "public"."cleanup_proof_publications" (
 "report_id" uuid NOT NULL,
 "id" uuid NOT NULL,
 "source_fingerprint" text NOT NULL,
 "before_path" text NOT NULL,
 "after_path" text NOT NULL,
 "public_notes" text NOT NULL,
 "redactions" jsonb NOT NULL,
 "completed_at" timestamp with time zone NOT NULL,
 "verified_at" timestamp with time zone NOT NULL,
 "verified_by" uuid NOT NULL,
 "before_paths" jsonb,
 "after_paths" jsonb
);
ALTER TABLE "public"."cleanup_proof_publications" OWNER TO "postgres";
CREATE TABLE "public"."spatial_zones" (
 "id" character varying(64) NOT NULL,
 "zone_name" character varying(100) NOT NULL,
 "zone_type" character varying(20) NOT NULL,
 "boundary_geojson" jsonb NOT NULL,
 "centroid_lat" double precision NOT NULL,
 "centroid_lng" double precision NOT NULL,
 "boundary" geometry(Geometry,4326) GENERATED ALWAYS AS (st_setsrid(st_geomfromgeojson(boundary_geojson), 4326)) STORED,
 "created_at" timestamp with time zone NOT NULL
);
ALTER TABLE "public"."spatial_zones" OWNER TO "postgres";
CREATE TABLE "public"."hotspot_predictions" (
 "id" uuid NOT NULL,
 "region_id" character varying(255) NOT NULL,
 "time_horizon" character varying(50) NOT NULL,
 "prediction_date" date NOT NULL,
 "risk_score" numeric(5,4) NOT NULL,
 "report_count" integer NOT NULL,
 "gi_statistic" numeric(10,6),
 "p_value" numeric(10,8),
 "is_significant" boolean,
 "risk_level" character varying(20) NOT NULL,
 "region_center_lat" numeric(10,8) NOT NULL,
 "region_center_lng" numeric(11,8) NOT NULL,
 "region_radius_meters" numeric(10,2),
 "region_polygon" text,
 "created_at" timestamp with time zone,
 "updated_at" timestamp with time zone,
 "geojson_polygon" jsonb,
 "top_issue_type" report_issue_type,
 "issue_breakdown" jsonb,
 "rank" integer,
 "zone_id" character varying(64),
 "zone_name" character varying(100),
 "horizon_days" integer NOT NULL,
 "forecast_date_start" timestamp with time zone,
 "forecast_date_end" timestamp with time zone,
 "predicted_count" numeric(12,2) NOT NULL,
 "predicted_lower_bound" numeric(12,2) NOT NULL,
 "predicted_upper_bound" numeric(12,2) NOT NULL,
 "growth_velocity_percent" numeric(12,2) NOT NULL,
 "historical_points" jsonb NOT NULL,
 "forecast_points" jsonb NOT NULL,
 "model_version" text
);
ALTER TABLE "public"."hotspot_predictions" OWNER TO "postgres";
CREATE TABLE "public"."operational_events" (
 "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
 "event_key" text NOT NULL,
 "event_type" text NOT NULL,
 "task_id" uuid,
 "report_id" uuid,
 "actor_id" uuid,
 "assignment_generation" bigint,
 "occurred_at" timestamp with time zone NOT NULL,
 "recorded_at" timestamp with time zone NOT NULL,
 "time_basis" text NOT NULL,
 "details" jsonb NOT NULL
);
ALTER TABLE "public"."operational_events" OWNER TO "postgres";
CREATE TABLE "public"."citizen_trust" (
 "user_id" uuid NOT NULL,
 "score" integer NOT NULL,
 "recovery_streak" integer NOT NULL,
 "locked_until" timestamp with time zone,
 "updated_at" timestamp with time zone NOT NULL
);
ALTER TABLE "public"."citizen_trust" OWNER TO "postgres";
CREATE TABLE "public"."citizen_trust_decisions" (
 "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
 "operation_id" uuid NOT NULL,
 "report_id" uuid NOT NULL,
 "user_id" uuid,
 "actor_id" uuid,
 "outcome" text NOT NULL,
 "reason" text NOT NULL,
 "submitted_priority" text,
 "supersedes_id" bigint,
 "recorded_at" timestamp with time zone NOT NULL
);
ALTER TABLE "public"."citizen_trust_decisions" OWNER TO "postgres";
CREATE TABLE "workflow_private"."unprocessed_alert_deliveries" (
 "report_id" uuid NOT NULL,
 "recipient_id" uuid NOT NULL,
 "age_day" integer NOT NULL,
 "delivered_at" timestamp with time zone NOT NULL
);
ALTER TABLE "workflow_private"."unprocessed_alert_deliveries" OWNER TO "postgres";
CREATE TABLE "workflow_private"."lifecycle_deployment" (
 "singleton" boolean NOT NULL,
 "activated_at" timestamp with time zone NOT NULL
);
ALTER TABLE "workflow_private"."lifecycle_deployment" OWNER TO "postgres";
CREATE TABLE "workflow_private"."historical_sla_reset" (
 "report_id" uuid NOT NULL,
 "original_created_at" timestamp with time zone,
 "original_deadline_at" timestamp with time zone,
 "original_is_outlier" boolean,
 "reset_at" timestamp with time zone NOT NULL
);
ALTER TABLE "workflow_private"."historical_sla_reset" OWNER TO "postgres";
CREATE TABLE "public"."report_urgency_decisions" (
 "sequence" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
 "operation_id" uuid NOT NULL,
 "report_id" uuid NOT NULL,
 "actor_id" uuid,
 "outcome" text NOT NULL,
 "reason" text NOT NULL,
 "previous_operation_id" uuid,
 "report_context" jsonb NOT NULL,
 "recorded_at" timestamp with time zone NOT NULL
);
ALTER TABLE "public"."report_urgency_decisions" OWNER TO "postgres";
CREATE TABLE "public"."report_urgency_alerts" (
 "report_id" uuid NOT NULL,
 "recipient_id" uuid NOT NULL
);
ALTER TABLE "public"."report_urgency_alerts" OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.publish_mixed_dispatch_routes(plan_id uuid, actor uuid, token uuid, routes jsonb, depot jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare plan public.dispatch_plans; crew public.field_crews; run public.optimization_runs;
  crew_route public.crew_routes; route jsonb; waypoint jsonb; task public.cleanup_tasks;
  expected_ids uuid[]; route_ids uuid[]; ids uuid[]; expected_reports uuid[]; route_reports uuid[];
  task_satellites uuid[]; waypoint_satellites uuid[]; latitude numeric; longitude numeric;
  work_minutes numeric; travel_minutes numeric; shift_minutes numeric; busy_minutes numeric;
  busy_count integer; busy_volume numeric; busy_weight numeric; route_volume numeric; route_weight numeric;
  members uuid[]; task_index integer;
begin
  perform workflow_private.require_desk_actor(actor);
  select * into plan from public.dispatch_plans where id=plan_id for update;
  if not found or plan.mode<>'mixed' or plan.status::text<>'approved' then raise exception 'Approved Mixed plan required'; end if;
  if plan.optimization_run_id is not null then return jsonb_build_object('run_id',plan.optimization_run_id,'alreadyPublished',true); end if;
  if token is null or plan.routing_token is distinct from token or plan.routing_lease_until<now() then
    raise exception 'Routing lease expired'; end if;
  if jsonb_typeof(routes) is distinct from 'array' then raise exception 'Routes array required'; end if;
  perform id from public.cleanup_tasks where source_plan_id=plan_id order by id for update;
  perform r.id from public.reports r join public.cleanup_tasks t on t.id=r.cleanup_task_id
    where t.source_plan_id=plan_id order by r.id for update of r;
  select coalesce(array_agg(id order by id),'{}'::uuid[]) into expected_ids
    from public.cleanup_tasks where source_plan_id=plan_id;
  select coalesce(array_agg(v::uuid order by v::uuid),'{}'::uuid[]) into route_ids
    from jsonb_array_elements(routes) r cross join lateral jsonb_array_elements_text(r->'task_ids') v;
  if expected_ids<>route_ids then raise exception 'Route task membership differs from commit'; end if;
  select coalesce(array_agg(rid order by rid),'{}'::uuid[]) into expected_reports
    from public.cleanup_tasks t cross join lateral unnest(t.satellite_report_ids) rid
    where t.source_plan_id=plan_id;
  select coalesce(array_agg((w->>'report_id')::uuid order by (w->>'report_id')::uuid),'{}'::uuid[])
    into route_reports from jsonb_array_elements(routes) r
      cross join lateral jsonb_array_elements(r->'waypoints') w
    where w->>'waypoint_type'='bundled_report';
  if expected_reports<>route_reports then raise exception 'Route satellite membership differs from commit'; end if;
  if exists(select 1 from public.cleanup_tasks t where t.source_plan_id=plan_id and
    (t.route_status<>'needs_replan' or t.status::text not in ('created','pending')
      or t.assigned_at is not null or t.routing_deadline_at<=now())) then
    raise exception 'Committed task unavailable or expired'; end if;
  if exists(select 1 from public.cleanup_tasks t cross join lateral unnest(t.report_ids) rid
    left join public.reports r on r.id=rid where t.source_plan_id=plan_id
      and (r.id is null or r.cleanup_task_id is distinct from t.id or r.lifecycle_state='closed')) then
    raise exception 'Claimed report changed before publication'; end if;
  latitude:=(depot->>'latitude')::numeric; longitude:=(depot->>'longitude')::numeric;
  if latitude is null or longitude is null or latitude not between -90 and 90 or longitude not between -180 and 180 then
    raise exception 'Invalid depot'; end if;
  if cardinality(expected_ids)=0 then
    update public.dispatch_plans set routing_token=null,routing_lease_until=null where id=plan_id;
    return jsonb_build_object('run_id',null,'alreadyPublished',false);
  end if;
  insert into public.optimization_runs(triggered_by,status,approved_by,approved_at,criteria,num_tasks_optimized,num_crews)
    values(actor,'approved',actor,now(),jsonb_build_object('mode','mixed','source_plan_id',plan_id),
      cardinality(expected_ids),jsonb_array_length(routes)) returning * into run;
  for route in select value from jsonb_array_elements(routes) order by value->>'crew_id' loop
    select * into crew from public.field_crews where id=(route->>'crew_id')::uuid for update;
    if not found or crew.availability_status::text<>'available' then raise exception 'Crew unavailable'; end if;
    if crew.speed_factor is distinct from (route->>'speed_factor')::numeric
      or crew.service_time_factor is distinct from (route->>'service_time_factor')::numeric then
      raise exception 'Fleet timing factors changed'; end if;
    if exists(select 1 from public.dispatch_plan_items i where i.dispatch_plan_id=plan_id
      and i.is_selected and i.planned_crew_id=crew.id
      and ((i.crew_snapshot->>'speed_factor')::numeric is distinct from crew.speed_factor
        or (i.crew_snapshot->>'service_time_factor')::numeric is distinct from crew.service_time_factor)) then
      raise exception 'Fleet timing factors changed since planning'; end if;
    members:=array(select distinct x from unnest(coalesce(crew.member_profile_ids,'{}'::uuid[])
      ||array_remove(array[crew.team_lead_profile_id],null)) x order by x);
    if cardinality(members)=0 then raise exception 'Crew has no members'; end if;
    select array_agg(value::uuid order by ord) into ids
      from jsonb_array_elements_text(route->'task_ids') with ordinality x(value,ord);
    if cardinality(ids)=0 then raise exception 'Empty route'; end if;
    if exists(select 1 from public.cleanup_tasks t where t.id=any(ids)
      and t.assigned_field_crew_id is distinct from crew.id) then raise exception 'Wrong crew for task'; end if;
    if exists(select 1 from public.cleanup_tasks t where t.id=any(ids)
      and ((t.task_type::text='Mixed' and not crew.supports_standard)
        or (t.task_type::text='Sweeper' and not crew.supports_sweeper))) then
      raise exception 'Crew capability changed'; end if;
    if jsonb_typeof(route->'waypoints') is distinct from 'array'
      or route->'waypoints'->0->>'waypoint_type' is distinct from 'depot_start'
      or route->'waypoints'->-1->>'waypoint_type' is distinct from 'depot_end' then
      raise exception 'Complete route required'; end if;
    if (select array_agg((w->>'cleanup_task_id')::uuid order by ord)
      from jsonb_array_elements(route->'waypoints') with ordinality x(w,ord)
      where w->>'waypoint_type'='task') is distinct from ids then
      raise exception 'Task waypoint order differs from saved route'; end if;
    if exists(select 1 from jsonb_array_elements(route->'waypoints') with ordinality x(w,ord)
      where (w->>'sequence_order')::integer is distinct from ord-1) then
      raise exception 'Invalid waypoint sequence'; end if;
    for task in select * from public.cleanup_tasks where id=any(ids) loop
      select coalesce(array_agg((w->>'report_id')::uuid order by ord),'{}'::uuid[])
        into waypoint_satellites from jsonb_array_elements(route->'waypoints') with ordinality x(w,ord)
        where w->>'waypoint_type'='bundled_report' and (w->>'cleanup_task_id')::uuid=task.id;
      task_satellites:=coalesce(task.satellite_report_ids,'{}'::uuid[]);
      if waypoint_satellites<>task_satellites then raise exception 'Satellite waypoint order differs from committed task'; end if;
    end loop;
    select coalesce(sum(estimated_work_minutes),0),coalesce(sum(estimated_volume_m3),0),
      coalesce(sum(estimated_weight_kg),0) into work_minutes,route_volume,route_weight
      from public.cleanup_tasks where id=any(ids);
    select coalesce(sum((w->>'estimated_time_from_previous_min')::numeric),0)
      into travel_minutes from jsonb_array_elements(route->'waypoints') w;
    if travel_minutes<0 then raise exception 'Invalid route travel'; end if;
    shift_minutes:=extract(epoch from(crew.shift_end-crew.shift_start))/60;
    if shift_minutes<0 then shift_minutes:=shift_minutes+1440; end if;
    select coalesce(sum(coalesce(estimated_duration_min,60)),0),count(*),
      coalesce(sum(estimated_volume_m3),0),coalesce(sum(estimated_weight_kg),0)
      into busy_minutes,busy_count,busy_volume,busy_weight from public.cleanup_tasks
      where status::text not in ('completed','cancelled') and not(id=any(ids))
        and assigned_field_crew_id=crew.id;
    if crew.max_volume_m3 is null or crew.max_weight_kg is null
      or crew.starting_volume_m3 is null or crew.starting_weight_kg is null
      or exists(select 1 from public.cleanup_tasks t where t.assigned_field_crew_id=crew.id
        and t.status::text not in ('completed','cancelled') and
        (t.estimated_volume_m3 is null or t.estimated_weight_kg is null)) then
      raise exception 'Physical load estimate unavailable'; end if;
    if busy_minutes+work_minutes+travel_minutes>greatest(0,(shift_minutes-
      coalesce((plan.settings_snapshot->>'break_duration_min')::numeric,60)+
      coalesce((plan.settings_snapshot->>'overtime_tolerance_min')::numeric,15))
      *coalesce((plan.settings_snapshot->>'capacity_utilization')::numeric,1))
      or busy_count+cardinality(ids)>least(coalesce(crew.max_tasks_per_shift,10),
        coalesce((plan.settings_snapshot->>'max_tasks_per_shift')::integer,15)) then
      raise exception 'Published route exceeds crew time capacity'; end if;
    if crew.starting_volume_m3+busy_volume+route_volume>crew.max_volume_m3
      or crew.starting_weight_kg+busy_weight+route_weight>crew.max_weight_kg then
      raise exception 'Published route exceeds physical capacity'; end if;
    insert into public.crew_routes(optimization_run_id,crew_id,start_depot,end_depot,
      total_distance_meters,total_duration_min,task_count,traffic_snapshot)
      values(run.id,crew.id,extensions.st_setsrid(extensions.st_makepoint(longitude,latitude),4326)::extensions.geography,
        extensions.st_setsrid(extensions.st_makepoint(longitude,latitude),4326)::extensions.geography,
        (route->>'totalDistance')::numeric,work_minutes+travel_minutes,cardinality(ids),
        jsonb_build_object('approximate',coalesce((route->>'approximate')::boolean,true))) returning * into crew_route;
    for waypoint in select value from jsonb_array_elements(route->'waypoints') loop
      if (waypoint->>'latitude')::numeric not between -90 and 90
        or (waypoint->>'longitude')::numeric not between -180 and 180
        or (waypoint->>'estimated_time_from_previous_min')::numeric<0
        or (waypoint->>'distance_from_previous_meters')::numeric<0 then raise exception 'Invalid waypoint'; end if;
      insert into public.route_waypoints(crew_route_id,sequence_order,latitude,longitude,
        cleanup_task_id,report_id,waypoint_type,distance_from_previous_meters,
        estimated_time_from_previous_min,polyline)
      values(crew_route.id,(waypoint->>'sequence_order')::integer,(waypoint->>'latitude')::numeric,
        (waypoint->>'longitude')::numeric,(waypoint->>'cleanup_task_id')::uuid,
        (waypoint->>'report_id')::uuid,(waypoint->>'waypoint_type')::public.route_waypoint_type,
        (waypoint->>'distance_from_previous_meters')::numeric,
        (waypoint->>'estimated_time_from_previous_min')::numeric,waypoint->'polyline');
    end loop;
    for task_index in 1..cardinality(ids) loop
      update public.cleanup_tasks set crew_route_id=crew_route.id,sequence_in_route=task_index,
        assigned_crew_ids=members,assigned_at=now(),assigned_by=actor,last_assigned_at=now(),
        route_status='ready',route_revision=route_revision+1,fc_version=fc_version+1
        where id=ids[task_index];
    end loop;
  end loop;
  update public.dispatch_plans set optimization_run_id=run.id,routing_token=null,routing_lease_until=null
    where id=plan_id;
  return jsonb_build_object('run_id',run.id,'alreadyPublished',false);
end; $function$;
ALTER FUNCTION "public"."publish_mixed_dispatch_routes"(plan_id uuid, actor uuid, token uuid, routes jsonb, depot jsonb) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.upsert_cluster_for_reports_old(p_report_ids uuid[], p_issue_type text, p_severity text, p_radius_meters double precision)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  RAISE EXCEPTION 'Function public.upsert_cluster_for_reports_old is deprecated. Use upsert_cluster_for_reports_v2 instead.';
END;
$function$;
ALTER FUNCTION "public"."upsert_cluster_for_reports_old"(p_report_ids uuid[], p_issue_type text, p_severity text, p_radius_meters double precision) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION workflow_private.guard_cluster_block()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if new.status::text in ('new','unresolved','prioritized','queued','monitoring','scheduled','in_progress')
    and exists(select 1 from public.dispatch_access_blocks where cluster_id=new.id and cleared_at is null) then
    raise exception 'Blocked cluster requires officer clearance';
  end if;
  return new;
end; $function$;
ALTER FUNCTION "workflow_private"."guard_cluster_block"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION workflow_private.bump_report_claim_generation()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if tg_op = 'INSERT' then
    if new.cleanup_task_id is not null then
      new.report_claim_generation := greatest(new.report_claim_generation, 1);
    end if;
  elsif new.cleanup_task_id is distinct from old.cleanup_task_id then
    new.report_claim_generation := old.report_claim_generation + 1;
  else
    new.report_claim_generation := old.report_claim_generation;
  end if;
  return new;
end;
$function$;
ALTER FUNCTION "workflow_private"."bump_report_claim_generation"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.authorize_citizen_trust_review(actor uuid, report_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE r public.reports; actor_role text;
BEGIN
 SELECT * INTO r FROM public.reports WHERE id=report_id FOR SHARE;
 SELECT role::text INTO actor_role FROM public.profiles WHERE id=actor FOR SHARE;
 IF r.id IS NULL OR r.user_id IS NULL OR r.user_id=actor OR actor_role IS NULL OR actor_role NOT IN ('officer','admin') THEN
  RAISE EXCEPTION 'Only SWMO officers/admins may make citizen trust decisions; crew submit observations for review.' USING ERRCODE='42501';
 END IF;
END $function$;
ALTER FUNCTION "public"."authorize_citizen_trust_review"(actor uuid, report_id uuid) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.apply_fc_operation(actor uuid, operation_id text, operation_type text, entity_id uuid, entity_type text, payload jsonb, base_version bigint DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE observation jsonb:=payload->'urgency_observation'; canonical jsonb; result jsonb;
 r public.reports; t public.cleanup_tasks; role_name text; saved public.crew_urgency_observations; label text;
BEGIN PERFORM operational_private.set_context(actor,payload);
 IF NOT coalesce(payload ? 'urgency_observation',false) THEN
  RETURN workflow_private.apply_fc_operation(actor,operation_id,operation_type,entity_id,entity_type,payload,base_version);
 END IF;
 IF operation_type IS DISTINCT FROM 'fc.note.add' OR entity_type IS DISTINCT FROM 'report' OR jsonb_typeof(observation) IS DISTINCT FROM 'object'
   OR jsonb_typeof(observation->'conditions') IS DISTINCT FROM 'string'
   OR char_length(btrim(observation->>'conditions')) NOT BETWEEN 3 AND 1500
   OR observation->>'result' IS NULL OR observation->>'result' NOT IN ('urgent_observed','conditions_differ','unable_to_verify')
   OR coalesce(observation->>'task_id','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
   OR coalesce(observation->>'assignment_generation','') !~ '^[0-9]{1,15}$'
   OR coalesce(observation->>'report_claim_generation','') !~ '^[0-9]{1,15}$' THEN
  RAISE EXCEPTION 'Provide task receipt, observed urgency and conditions (3-1500 characters).' USING ERRCODE='22023';
 END IF;
 IF observation->>'observer_id' IS DISTINCT FROM actor::text THEN RAISE EXCEPTION 'Observation belongs to another signed-in crew member.' USING ERRCODE='42501'; END IF;
 label:=CASE observation->>'result' WHEN 'urgent_observed' THEN 'Urgency observed' WHEN 'conditions_differ' THEN 'Conditions differ' ELSE 'Unable to verify' END;
 canonical:=payload||jsonb_build_object('action','On-site urgency: '||label||'. '||btrim(observation->>'conditions')||' [For officer review; no automatic trust change.]');
 -- The underlying transaction serializes operation IDs and locks task -> report.
 result:=workflow_private.apply_fc_operation(actor,operation_id,operation_type,entity_id,entity_type,canonical,base_version);
 SELECT * INTO saved FROM public.crew_urgency_observations o WHERE o.operation_id=apply_fc_operation.operation_id;
 IF saved.operation_id IS NOT NULL THEN RETURN result; END IF;
 SELECT role::text INTO role_name FROM public.profiles WHERE id=actor FOR SHARE;
 SELECT * INTO r FROM public.reports WHERE id=entity_id;
 SELECT * INTO t FROM public.cleanup_tasks WHERE id=r.cleanup_task_id;
 IF role_name IS DISTINCT FROM 'field_crew' OR r.user_id=actor OR r.citizen_priority IS DISTINCT FROM 'urgent'
   OR r.cleanup_task_id IS DISTINCT FROM (observation->>'task_id')::uuid OR t.id IS NULL
   OR t.status::text NOT IN ('created','pending','assigned','en_route','in_progress','partially_completed')
   OR t.route_status IS DISTINCT FROM 'ready' OR NOT coalesce(workflow_private.can_execute_task(actor,t),false)
   OR (to_jsonb(t)->>'assignment_generation')::bigint IS DISTINCT FROM (observation->>'assignment_generation')::bigint
   OR (to_jsonb(r)->>'report_claim_generation')::bigint IS DISTINCT FROM (observation->>'report_claim_generation')::bigint
   OR result->>'status' IS DISTINCT FROM 'success' THEN
  RAISE EXCEPTION 'Observation requires your current active assignment to an Urgent report. Refresh the task receipt.' USING ERRCODE='42501';
 END IF;
 INSERT INTO public.crew_urgency_observations(operation_id,report_id,task_id,actor_id,observed_result,conditions,evidence_snapshot,note_id)
 VALUES(operation_id,entity_id,t.id,actor,observation->>'result',btrim(observation->>'conditions'),
  jsonb_build_object('before_photos',coalesce(to_jsonb(r)->'before_photos','[]'::jsonb),'after_photos',coalesce(to_jsonb(r)->'after_photos','[]'::jsonb),
    'before_photo_url',to_jsonb(r)->'before_photo_url','after_photo_url',to_jsonb(r)->'after_photo_url'),result->'server_record'->>'id');
 INSERT INTO public.notifications(user_id,report_id,type,title,body,is_read)
 SELECT p.id,r.id,'general','Crew urgency observation awaiting review','Review on-site conditions and evidence in Report Details. No trust score has been changed.',false
 FROM public.profiles p WHERE p.role::text IN ('officer','admin') AND p.id IS DISTINCT FROM r.user_id;
 RETURN result;
END $function$;
ALTER FUNCTION "public"."apply_fc_operation"(actor uuid, operation_id text, operation_type text, entity_id uuid, entity_type text, payload jsonb, base_version bigint) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION workflow_private.can_execute_task(actor uuid, task cleanup_tasks)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
 SELECT EXISTS(SELECT FROM public.profiles p WHERE p.id=actor AND
   (p.role::text IN ('admin','officer') OR
    (p.role::text='field_crew' AND task.route_status='ready'
     AND actor=ANY(coalesce(task.assigned_crew_ids,'{}'::uuid[])))));
$function$;
ALTER FUNCTION "workflow_private"."can_execute_task"(actor uuid, task cleanup_tasks) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.get_barangay_operational_analytics(actor uuid, start_month date, end_month date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE stamp timestamptz := statement_timestamp(); first_at timestamptz; until_at timestamptz; result jsonb; trend_end date; trend_at timestamptz;
BEGIN
 IF actor IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=actor AND p.role::text IN ('admin','officer')) THEN
  RAISE EXCEPTION 'Staff analytics access required' USING ERRCODE='42501';
 END IF;
 IF start_month IS NULL OR end_month IS NULL OR start_month<>date_trunc('month',start_month)::date
   OR end_month<>date_trunc('month',end_month)::date OR start_month>end_month
   OR start_month<date '2000-01-01' OR end_month>date_trunc('month',stamp AT TIME ZONE 'Asia/Manila')::date
   OR end_month >= start_month + interval '24 months' THEN
  RAISE EXCEPTION 'Select a calendar-month range of at most 24 months, ending no later than this month' USING ERRCODE='22023';
 END IF;
 IF (SELECT count(*) FROM public.pasig_barangay_roster)<>30 THEN
  RAISE EXCEPTION 'The official 30-barangay roster must be reconciled first' USING ERRCODE='55000';
 END IF;
 first_at := start_month::timestamp AT TIME ZONE 'Asia/Manila';
 until_at := (end_month + interval '1 month')::timestamp AT TIME ZONE 'Asia/Manila';
 trend_end := least((end_month+interval '1 month')::date,date_trunc('month',stamp AT TIME ZONE 'Asia/Manila')::date);
 IF trend_end<=start_month THEN trend_end:=NULL; END IF;
 trend_at := trend_end::timestamp AT TIME ZONE 'Asia/Manila';
 WITH groups AS (
  SELECT psgc_code AS key,psgc_code,name FROM public.pasig_barangay_roster
  UNION ALL SELECT 'unassigned',NULL,'Unassigned location'
  UNION ALL SELECT 'all',NULL,'All locations'
 ), base AS MATERIALIZED (
  SELECT coalesce(b.psgc_code,'unassigned') AS key,r.created_at,r.lgu_resolved_at,
   coalesce(r.validation_status::text,'unknown') AS validation,
   coalesce(r.status::text,'unknown') IN ('resolved','completed','closed','waiting_for_feedback') AS is_resolved,
   coalesce(r.status::text,'unknown') NOT IN ('resolved','completed','closed','waiting_for_feedback','rejected','withdrawn','cancelled')
     AND coalesce(r.validation_status::text,'unknown')<>'rejected' AS is_open,
   r.created_at>=first_at AND r.created_at<until_at AS cohort,
   stamp-r.created_at AS age,
   CASE WHEN r.lgu_resolved_at>=r.created_at AND r.lgu_resolved_at<=stamp
    THEN extract(epoch FROM (r.lgu_resolved_at-r.created_at))/3600.0 END AS duration_hours
  FROM public.reports r LEFT JOIN public.pasig_barangay_roster b
   ON r.barangay_resolution_status='resolved' AND b.name=r.barangay
  WHERE r.created_at IS NOT NULL AND isfinite(r.created_at) AND r.created_at<=stamp
 ), expanded AS (
  SELECT x.*, x.is_resolved AND x.duration_hours IS NOT NULL AND x.lgu_resolved_at>=first_at AND x.lgu_resolved_at<until_at AS resolved_in_period
  FROM (SELECT * FROM base UNION ALL SELECT 'all',created_at,lgu_resolved_at,validation,is_resolved,is_open,cohort,age,duration_hours FROM base) x
 ), stats AS (
  SELECT key,
   count(*) FILTER(WHERE cohort) AS report_count,
   count(*) FILTER(WHERE cohort AND validation IN ('approved','validated','rejected')) AS verified_count,
   count(*) FILTER(WHERE cohort AND validation IN ('approved','validated')) AS approved_count,
   count(*) FILTER(WHERE cohort AND validation='rejected') AS rejected_count,
   count(*) FILTER(WHERE cohort AND validation NOT IN ('approved','validated','rejected')) AS pending_count,
   count(*) FILTER(WHERE is_open) AS backlog_total,
   count(*) FILTER(WHERE is_open AND age < interval '1 day') AS backlog_under_1_day,
   count(*) FILTER(WHERE is_open AND age >= interval '1 day' AND age < interval '3 days') AS backlog_1_2_days,
   count(*) FILTER(WHERE is_open AND age >= interval '3 days' AND age < interval '7 days') AS backlog_3_6_days,
   count(*) FILTER(WHERE is_open AND age >= interval '7 days' AND age < interval '30 days') AS backlog_7_29_days,
   count(*) FILTER(WHERE is_open AND age >= interval '30 days') AS backlog_30_plus_days,
   count(*) FILTER(WHERE resolved_in_period) AS resolution_count,
   count(*) FILTER(WHERE is_resolved AND lgu_resolved_at IS NULL) AS missing_resolution_count,
   count(*) FILTER(WHERE is_resolved AND lgu_resolved_at IS NOT NULL AND duration_hours IS NULL) AS invalid_resolution_count,
   percentile_cont(0.5) WITHIN GROUP(ORDER BY duration_hours) FILTER(WHERE resolved_in_period) AS median_resolution_hours,
   percentile_cont(0.9) WITHIN GROUP(ORDER BY duration_hours) FILTER(WHERE resolved_in_period) AS p90_resolution_hours,
   avg(duration_hours) FILTER(WHERE resolved_in_period) AS average_resolution_hours
  FROM expanded GROUP BY key
 ), trend_counts AS (
  SELECT a.area AS key,
   count(*) FILTER(WHERE r.created_at>=((trend_end-30)::timestamp AT TIME ZONE 'Asia/Manila')) AS current_count,
   count(*) FILTER(WHERE r.created_at<((trend_end-30)::timestamp AT TIME ZONE 'Asia/Manila')) AS previous_count
  FROM public.reports r LEFT JOIN public.pasig_barangay_roster b
   ON r.barangay_resolution_status='resolved' AND b.name=r.barangay
  CROSS JOIN LATERAL (SELECT coalesce(b.psgc_code,'unassigned') AS area UNION ALL SELECT 'all') a
  WHERE r.created_at>=((trend_end-60)::timestamp AT TIME ZONE 'Asia/Manila') AND r.created_at<trend_at
  GROUP BY a.area
 ), monthly_counts AS (
  SELECT key,date_trunc('month',created_at AT TIME ZONE 'Asia/Manila')::date AS month,count(*) AS report_count
  FROM expanded WHERE cohort GROUP BY key,date_trunc('month',created_at AT TIME ZONE 'Asia/Manila')::date
 ), monthly AS (
  SELECT g.key,jsonb_agg(jsonb_build_object('month',to_char(m,'YYYY-MM'),'report_count',coalesce(c.report_count,0)) ORDER BY m) AS values
  FROM groups g CROSS JOIN generate_series(start_month::timestamp,end_month::timestamp,interval '1 month') m
  LEFT JOIN monthly_counts c ON c.key=g.key AND c.month=m::date GROUP BY g.key
 ), rows AS (
  SELECT g.key,g.name,jsonb_build_object('key',g.key,'name',g.name,'psgc_code',g.psgc_code,
   'trend',CASE WHEN trend_end IS NULL THEN NULL ELSE jsonb_build_object(
    'previous_count',coalesce(t.previous_count,0),'current_count',coalesce(t.current_count,0),
    'change_percent',100.0*(coalesce(t.current_count,0)-coalesce(t.previous_count,0))/nullif(t.previous_count,0),
    'status',CASE WHEN coalesce(t.previous_count,0)=0 THEN CASE WHEN coalesce(t.current_count,0)>0 THEN 'new_activity' ELSE 'no_activity' END ELSE 'comparable' END) END,
   'report_count',coalesce(s.report_count,0),
   'verified_count',coalesce(s.verified_count,0),
   'approved_count',coalesce(s.approved_count,0),
   'rejected_count',coalesce(s.rejected_count,0),
   'pending_count',coalesce(s.pending_count,0),
   'backlog_total',coalesce(s.backlog_total,0),
   'backlog_under_1_day',coalesce(s.backlog_under_1_day,0),
   'backlog_1_2_days',coalesce(s.backlog_1_2_days,0),
   'backlog_3_6_days',coalesce(s.backlog_3_6_days,0),
   'backlog_7_29_days',coalesce(s.backlog_7_29_days,0),
   'backlog_30_plus_days',coalesce(s.backlog_30_plus_days,0),
   'resolution_count',coalesce(s.resolution_count,0),
   'missing_resolution_count',coalesce(s.missing_resolution_count,0),
   'invalid_resolution_count',coalesce(s.invalid_resolution_count,0),
   'verification_rate_percent',round(100.0*s.verified_count/nullif(s.report_count,0),1),
   'median_resolution_hours',s.median_resolution_hours,'p90_resolution_hours',s.p90_resolution_hours,
   'average_resolution_hours',s.average_resolution_hours,'monthly',m.values) AS value
  FROM groups g LEFT JOIN stats s ON s.key=g.key LEFT JOIN trend_counts t ON t.key=g.key JOIN monthly m ON m.key=g.key
 ) SELECT jsonb_build_object(
  'generated_at',stamp,'timezone','Asia/Manila','start_month',to_char(start_month,'YYYY-MM'),'end_month',to_char(end_month,'YYYY-MM'),
  'trend_periods',CASE WHEN trend_end IS NULL THEN NULL ELSE jsonb_build_object('days',30,'anchor_month',to_char(trend_end-1,'YYYY-MM'),
   'previous_start',to_char(trend_end-60,'YYYY-MM-DD'),'previous_end',to_char(trend_end-30,'YYYY-MM-DD'),
   'current_start',to_char(trend_end-30,'YYYY-MM-DD'),'current_end',to_char(trend_end,'YYYY-MM-DD')) END,
  'total',(SELECT value FROM rows WHERE key='all'),
  'groups',(SELECT jsonb_agg(value ORDER BY (key='unassigned'),name) FROM rows WHERE key<>'all'),
  'quality',jsonb_build_object('excluded_creation_timestamps',
    (SELECT count(*) FROM public.reports WHERE created_at IS NULL OR NOT isfinite(created_at) OR created_at>stamp),
   'unassigned_reasons',(SELECT jsonb_build_object(
     'outside_boundaries',count(*) FILTER(WHERE x.barangay_resolution_status='unresolved'),
     'near_boundary',count(*) FILTER(WHERE x.barangay_resolution_status IN ('border','overlap')),
     'pending_reconciliation',count(*) FILTER(WHERE x.barangay_resolution_status='pending_reconciliation'),
     'other',count(*) FILTER(WHERE x.barangay_resolution_status NOT IN ('unresolved','border','overlap','pending_reconciliation')))
    FROM public.reports x WHERE x.created_at>=first_at AND x.created_at<until_at
     AND NOT EXISTS(SELECT 1 FROM public.pasig_barangay_roster b WHERE x.barangay_resolution_status='resolved' AND b.name=x.barangay)))
 ) INTO result;
 RETURN result;
END $function$;
ALTER FUNCTION "public"."get_barangay_operational_analytics"(actor uuid, start_month date, end_month date) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.read_authorized_report_detail(actor uuid, report_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
SELECT to_jsonb(r) || jsonb_build_object('profiles',
 jsonb_build_object('id',owner.id,'full_name',owner.full_name,'data_consent',owner.data_consent))
FROM public.reports r
LEFT JOIN public.profiles owner ON owner.id=r.user_id
WHERE r.id=report_id AND EXISTS(
 SELECT 1 FROM public.profiles viewer
 WHERE viewer.id=actor AND (
  viewer.id=r.user_id OR viewer.role::text IN ('officer','admin') OR
  (viewer.role::text='field_crew' AND EXISTS(
   SELECT 1 FROM public.cleanup_tasks task
   WHERE task.id=r.cleanup_task_id AND task.route_status='ready'
    AND task.status::text IN ('created','pending','in_progress','partially_completed')
    AND actor=ANY(coalesce(task.assigned_crew_ids,'{}'::uuid[]))
  ))
 )
);
$function$;
ALTER FUNCTION "public"."read_authorized_report_detail"(actor uuid, report_id uuid) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.read_hotspot_pattern_history(p_max_reports integer DEFAULT 5000)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE stamp timestamptz:=statement_timestamp(); origin timestamptz; result jsonb; zone_rows jsonb;
BEGIN
 IF p_max_reports IS NULL OR p_max_reports<1 OR p_max_reports>5000 THEN
  RAISE EXCEPTION 'Processing limit must be between 1 and 5000' USING ERRCODE='22023';
 END IF;
 origin:=date_trunc('week',stamp AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
 SELECT jsonb_agg(jsonb_build_object('id',r.psgc_code,'psgc_code',r.psgc_code,'zone_name',r.name,'zone_type','barangay',
  'boundary_geojson',z.boundary_geojson,'centroid_lat',z.centroid_lat,'centroid_lng',z.centroid_lng) ORDER BY r.psgc_code)
 INTO zone_rows FROM public.pasig_barangay_roster r JOIN public.spatial_zones z ON z.zone_type='barangay' AND z.zone_name=r.name
 WHERE z.boundary_geojson->>'type' IN ('Polygon','MultiPolygon') AND z.centroid_lat BETWEEN -90 AND 90 AND z.centroid_lng BETWEEN -180 AND 180;
 IF jsonb_array_length(coalesce(zone_rows,'[]'::jsonb))<>30 THEN
  RAISE EXCEPTION 'Reconcile the complete official 30-barangay baseline first' USING ERRCODE='55000';
 END IF;
 WITH base AS MATERIALIZED (
  SELECT r.id,r.created_at,b.psgc_code,
   CASE WHEN extensions.GeometryType(r.location::extensions.geometry)='POINT' AND extensions.ST_SRID(r.location::extensions.geometry)=4326 THEN extensions.ST_X(r.location::extensions.geometry) END AS longitude,
   CASE WHEN extensions.GeometryType(r.location::extensions.geometry)='POINT' AND extensions.ST_SRID(r.location::extensions.geometry)=4326 THEN extensions.ST_Y(r.location::extensions.geometry) END AS latitude
  FROM public.reports r LEFT JOIN public.pasig_barangay_roster b ON r.barangay_resolution_status='resolved' AND r.barangay=b.name
  WHERE r.created_at>=origin-interval '52 weeks' AND r.created_at<stamp AND isfinite(r.created_at)
   AND r.validation_status::text IN ('approved','validated') AND NOT coalesce(r.flagged_severe,false)
   AND coalesce(r.status::text,'unknown') NOT IN ('rejected','withdrawn','cancelled')
 ), eligible AS MATERIALIZED (
  SELECT *,coalesce(psgc_code IS NOT NULL AND latitude BETWEEN -90 AND 90 AND longitude BETWEEN -180 AND 180,false) AS usable FROM base
 ), weekly AS (
  SELECT psgc_code,date_trunc('week',created_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS week_start,count(*) AS report_count
  FROM eligible WHERE usable AND created_at<origin GROUP BY psgc_code,date_trunc('week',created_at AT TIME ZONE 'UTC')
 ), recent AS (SELECT * FROM eligible WHERE created_at>=stamp-interval '90 days')
 SELECT jsonb_build_object('as_of',stamp,'history_start',stamp-interval '90 days','week_origin',origin,'forecast_history_start',origin-interval '52 weeks',
  'zones',zone_rows,'reports',CASE WHEN (SELECT count(*) FROM recent WHERE usable)>p_max_reports THEN '[]'::jsonb ELSE coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'created_at',created_at,'barangay_code',psgc_code,'latitude',latitude,'longitude',longitude) ORDER BY created_at,id) FROM recent WHERE usable),'[]'::jsonb) END,
  'weekly_history',coalesce((SELECT jsonb_agg(jsonb_build_object('zone_id',psgc_code,'week_start',week_start,'report_count',report_count) ORDER BY psgc_code,week_start) FROM weekly),'[]'::jsonb),
  'quality',jsonb_build_object('eligible_reports_90',(SELECT count(*) FROM recent),'included_reports_90',(SELECT count(*) FROM recent WHERE usable),
    'excluded_unreconciled_90',(SELECT count(*) FROM recent WHERE psgc_code IS NULL),
    'excluded_invalid_location_90',(SELECT count(*) FROM recent WHERE psgc_code IS NOT NULL AND NOT usable))) INTO result;
 IF (result->'quality'->>'included_reports_90')::integer>p_max_reports THEN
  RAISE EXCEPTION 'History exceeds the synchronous processing limit; no points were sampled' USING ERRCODE='54000';
 END IF;
 RETURN result;
END $function$;
ALTER FUNCTION "public"."read_hotspot_pattern_history"(p_max_reports integer) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.clear_dispatch_block(block_id uuid, actor uuid, notes text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare block public.dispatch_access_blocks;
begin
  perform workflow_private.require_desk_actor(actor);
  if nullif(btrim(notes),'') is null then raise exception 'Clearance notes required' using errcode='22023'; end if;
  select * into block from public.dispatch_access_blocks where id=block_id for update;
  if not found then raise exception 'Block not found' using errcode='P0002'; end if;
  if block.cleared_at is null then
    update public.dispatch_access_blocks set cleared_at=now(),cleared_by=actor,clearance_notes=notes where id=block_id returning * into block;
    if block.cluster_id is not null then update public.clusters set status='prioritized' where id=block.cluster_id; end if;
    insert into public.sweeper_audit_log(event_type,entity_type,entity_id,user_id,event_data)
      values('DISPATCH_BLOCK_CLEARED','BLOCK',block_id::text,actor::text,jsonb_build_object('notes',notes));
  end if;
  return to_jsonb(block);
end; $function$;
ALTER FUNCTION "public"."clear_dispatch_block"(block_id uuid, actor uuid, notes text) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION operational_private.emit(kind text, task uuid, report uuid, actor uuid, generation bigint, stamp timestamp with time zone, basis text, dedupe text, metadata jsonb DEFAULT '{}'::jsonb)
 RETURNS void
 LANGUAGE sql
 SET search_path TO ''
AS $function$
 INSERT INTO public.operational_events(event_key,event_type,task_id,report_id,actor_id,assignment_generation,occurred_at,time_basis,details)
 VALUES(md5(dedupe),kind,task,report,actor,generation,stamp,basis,metadata)
 ON CONFLICT(event_key) DO NOTHING;
$function$;
ALTER FUNCTION "operational_private"."emit"(kind text, task uuid, report uuid, actor uuid, generation bigint, stamp timestamp with time zone, basis text, dedupe text, metadata jsonb) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.begin_plan_routing(plan_id uuid, actor uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare plan public.dispatch_plans; token uuid;
begin
  perform workflow_private.require_desk_actor(actor);
  select * into plan from public.dispatch_plans where id=plan_id for update;
  if not found or plan.status::text<>'approved' then raise exception 'Committed plan required'; end if;
  if plan.optimization_run_id is not null then return jsonb_build_object('run_id',plan.optimization_run_id); end if;
  if plan.routing_lease_until>now() then return jsonb_build_object('running',true); end if;
  if plan.routing_attempts>=3 then return jsonb_build_object('exhausted',true); end if;
  token:=gen_random_uuid();
  update public.dispatch_plans set routing_token=token,routing_lease_until=now()+interval '90 seconds',routing_attempts=routing_attempts+1 where id=plan_id;
  return jsonb_build_object('token',token);
end; $function$;
ALTER FUNCTION "public"."begin_plan_routing"(plan_id uuid, actor uuid) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.check_overdue_reports()
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  -- Deprecated: Superseded by public.advance_report_lifecycle() running under pg_cron
  RAISE NOTICE 'Function public.check_overdue_reports is deprecated. Handled by advance_report_lifecycle.';
END;
$function$;
ALTER FUNCTION "public"."check_overdue_reports"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.finish_plan_routing(plan_id uuid, actor uuid, token uuid, failure text)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  perform workflow_private.require_desk_actor(actor);
  update public.dispatch_plans set routing_token=null,routing_lease_until=null where id=plan_id and routing_token=token;
  if found and failure is not null then
    insert into public.sweeper_audit_log(event_type,entity_type,entity_id,user_id,event_data)
      values('PLAN_ROUTING_FAILED','PLAN',plan_id::text,actor::text,jsonb_build_object('reason',left(failure,1000)));
  end if;
end; $function$;
ALTER FUNCTION "public"."finish_plan_routing"(plan_id uuid, actor uuid, token uuid, failure text) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.task_coordinates(task_ids uuid[])
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object('id',t.id,'lat',extensions.st_y(coalesce(t.location::extensions.geometry,c.center)),
    'lng',extensions.st_x(coalesce(t.location::extensions.geometry,c.center)))),'[]'::jsonb)
  from public.cleanup_tasks t left join public.clusters c on c.id=t.cluster_id where t.id=any(task_ids);
$function$;
ALTER FUNCTION "public"."task_coordinates"(task_ids uuid[]) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.publish_dispatch_routes(plan_id uuid, actor uuid, token uuid, routes jsonb, depot jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare plan public.dispatch_plans; crew public.field_crews; run public.optimization_runs; crew_route public.crew_routes;
  route jsonb; waypoint jsonb; ids uuid[]; all_ids uuid[]; expected_ids uuid[]; members uuid[];
  work_minutes numeric; travel_minutes numeric; shift_minutes numeric; busy numeric; busy_count integer; task_index integer;
  current_task public.cleanup_tasks; latitude numeric; longitude numeric;
begin
  perform workflow_private.require_desk_actor(actor);
  select * into plan from public.dispatch_plans where id=plan_id for update;
  if not found then raise exception 'Plan not found'; end if;
  if plan.optimization_run_id is not null then
    return jsonb_build_object('run_id',plan.optimization_run_id,'alreadyPublished',true);
  end if;
  if plan.routing_token is distinct from token or token is null or plan.routing_lease_until<now() then raise exception 'Routing lease expired'; end if;
  if jsonb_typeof(routes) is distinct from 'array' then raise exception 'Routes must be an array'; end if;
  perform id from public.cleanup_tasks where source_plan_id=plan_id order by id for update;
  perform r.id from public.reports r join public.cleanup_tasks t on t.id=r.cleanup_task_id where t.source_plan_id=plan_id order by r.id for update of r;
  select coalesce(array_agg(id order by id),'{}'::uuid[]) into expected_ids from public.cleanup_tasks where source_plan_id=plan_id;
  select coalesce(array_agg(v::uuid order by v::uuid),'{}'::uuid[]) into all_ids from jsonb_array_elements(routes) r
    cross join lateral jsonb_array_elements_text(r->'task_ids') v;
  if expected_ids<>all_ids then raise exception 'Routes must contain every committed task exactly once'; end if;
  if cardinality(expected_ids)=0 then return jsonb_build_object('run_id',null,'alreadyPublished',false); end if;
  if exists(select 1 from public.cleanup_tasks t where source_plan_id=plan_id and
    (t.route_status<>'needs_replan' or t.status::text not in ('created','pending') or t.assigned_at is not null or t.routing_deadline_at<=now())) then
    raise exception 'Committed task is unavailable or expired';
  end if;
  if exists(select 1 from public.cleanup_tasks t cross join lateral unnest(t.report_ids) rid
    left join public.reports r on r.id=rid where t.source_plan_id=plan_id
      and (r.id is null or r.cleanup_task_id is distinct from t.id or r.lifecycle_state='closed')) then
    raise exception 'Report changed before route publication';
  end if;
  if (select count(*) from jsonb_array_elements(routes))<>(select count(distinct r->>'crew_id') from jsonb_array_elements(routes) r) then
    raise exception 'Duplicate route for crew';
  end if;
  latitude:=(depot->>'latitude')::numeric; longitude:=(depot->>'longitude')::numeric;
  if latitude is null or longitude is null or latitude not between -90 and 90 or longitude not between -180 and 180 then raise exception 'Invalid depot'; end if;
  insert into public.optimization_runs(triggered_by,status,approved_by,approved_at,criteria,num_tasks_optimized,num_crews)
    values(actor,'approved',actor,now(),jsonb_build_object('mode',plan.mode,'source_plan_id',plan.id),cardinality(expected_ids),jsonb_array_length(routes)) returning * into run;
  for route in select r from jsonb_array_elements(routes) r order by r->>'crew_id' loop
    select * into crew from public.field_crews where id=(route->>'crew_id')::uuid for update;
    if not found or crew.availability_status::text<>'available' or (plan.mode='standard' and not crew.supports_standard)
      or (plan.mode='sweeper' and not crew.supports_sweeper) then raise exception 'Crew capability changed'; end if;
    members:=array(select distinct x from unnest(coalesce(crew.member_profile_ids,'{}'::uuid[])||array_remove(array[crew.team_lead_profile_id],null)) x order by x);
    if cardinality(members)=0 then raise exception 'Crew has no members'; end if;
    if crew.speed_factor is distinct from (route->>'speed_factor')::numeric or crew.service_time_factor is distinct from (route->>'service_time_factor')::numeric then
      raise exception 'Fleet timing factors changed';
    end if;
    if exists(select 1 from public.dispatch_plan_items where dispatch_plan_id=plan_id and planned_crew_id=crew.id and is_selected
      and ((crew_snapshot->>'speed_factor')::numeric is distinct from crew.speed_factor
        or (crew_snapshot->>'service_time_factor')::numeric is distinct from crew.service_time_factor)) then raise exception 'Fleet timing factors changed since commit'; end if;
    select array_agg(id::uuid order by ord) into ids from jsonb_array_elements_text(route->'task_ids') with ordinality v(id,ord);
    if jsonb_typeof(route->'waypoints') is distinct from 'array' or jsonb_array_length(route->'waypoints')<>cardinality(ids)+2
      or route->'waypoints'->0->>'waypoint_type' is distinct from 'depot_start'
      or route->'waypoints'->-1->>'waypoint_type' is distinct from 'depot_end' then raise exception 'Complete depot-to-depot route required'; end if;
    if (select array_agg((w->>'cleanup_task_id')::uuid order by ord) from jsonb_array_elements(route->'waypoints') with ordinality x(w,ord)
      where w->>'waypoint_type'='task') is distinct from ids then raise exception 'Waypoint order differs from task order'; end if;
    if exists(select 1 from jsonb_array_elements(route->'waypoints') with ordinality x(w,ord) where
      (w->>'sequence_order')::integer is distinct from ord-1) then raise exception 'Invalid waypoint sequence'; end if;
    if exists(select 1 from public.cleanup_tasks where id=any(ids) and assigned_field_crew_id<>crew.id) then raise exception 'Wrong crew for task'; end if;
    select coalesce(sum(estimated_work_minutes),0) into work_minutes from public.cleanup_tasks where id=any(ids);
    select coalesce(sum((w->>'estimated_time_from_previous_min')::numeric),0) into travel_minutes from jsonb_array_elements(route->'waypoints') w;
    if work_minutes<0 or travel_minutes<0 then raise exception 'Invalid route durations'; end if;
    shift_minutes:=extract(epoch from(crew.shift_end-crew.shift_start))/60;
    if shift_minutes<0 then shift_minutes:=shift_minutes+1440; end if;
    select coalesce(sum(coalesce(estimated_duration_min,60)),0),count(*) into busy,busy_count from public.cleanup_tasks
      where status::text not in ('completed','cancelled') and not(id=any(ids))
        and (assigned_field_crew_id=crew.id or coalesce(assigned_crew_ids,'{}'::uuid[])&&members);
    if busy+work_minutes+travel_minutes>greatest(0,(shift_minutes-coalesce((plan.settings_snapshot->>'break_duration_min')::numeric,60)
      +coalesce((plan.settings_snapshot->>'overtime_tolerance_min')::numeric,15))*coalesce((plan.settings_snapshot->>'capacity_utilization')::numeric,1))
      or busy_count+cardinality(ids)>least(coalesce(crew.max_tasks_per_shift,10),coalesce((plan.settings_snapshot->>'max_tasks_per_shift')::integer,15)) then
      raise exception 'Published route exceeds crew capacity';
    end if;
    insert into public.crew_routes(optimization_run_id,crew_id,start_depot,end_depot,total_distance_meters,total_duration_min,task_count,traffic_snapshot)
      values(run.id,crew.id,extensions.st_setsrid(extensions.st_makepoint(longitude,latitude),4326)::extensions.geography,
        extensions.st_setsrid(extensions.st_makepoint(longitude,latitude),4326)::extensions.geography,(route->>'totalDistance')::numeric,
        work_minutes+travel_minutes,cardinality(ids),jsonb_build_object('approximate',coalesce((route->>'approximate')::boolean,false))) returning * into crew_route;
    if (select count(distinct w->>'cleanup_task_id') from jsonb_array_elements(route->'waypoints') w where w->>'waypoint_type'='task')<>cardinality(ids)
      or exists(select 1 from jsonb_array_elements(route->'waypoints') w where w->>'waypoint_type'='task' and not((w->>'cleanup_task_id')::uuid=any(ids))) then
      raise exception 'Route waypoints do not match assigned tasks';
    end if;
    for waypoint in select value from jsonb_array_elements(route->'waypoints') loop
      if waypoint->>'latitude' is null or waypoint->>'longitude' is null or waypoint->>'estimated_time_from_previous_min' is null
        or waypoint->>'distance_from_previous_meters' is null
        or (waypoint->>'latitude')::numeric not between -90 and 90 or (waypoint->>'longitude')::numeric not between -180 and 180
        or (waypoint->>'estimated_time_from_previous_min')::numeric<0 or (waypoint->>'distance_from_previous_meters')::numeric<0 then
        raise exception 'Invalid waypoint';
      end if;
      insert into public.route_waypoints(crew_route_id,sequence_order,latitude,longitude,cleanup_task_id,waypoint_type,
        distance_from_previous_meters,estimated_time_from_previous_min,polyline)
      values(crew_route.id,(waypoint->>'sequence_order')::integer,(waypoint->>'latitude')::numeric,(waypoint->>'longitude')::numeric,
        (waypoint->>'cleanup_task_id')::uuid,(waypoint->>'waypoint_type')::public.route_waypoint_type,
        (waypoint->>'distance_from_previous_meters')::numeric,(waypoint->>'estimated_time_from_previous_min')::numeric,waypoint->'polyline');
    end loop;
    for task_index in 1..cardinality(ids) loop
      select * into current_task from public.cleanup_tasks where id=ids[task_index];
      update public.cleanup_tasks set crew_route_id=crew_route.id,sequence_in_route=task_index,assigned_crew_ids=members,
        assigned_at=now(),assigned_by=actor,last_assigned_at=now(),route_status='ready',fc_version=fc_version+1,
        estimated_duration_min=estimated_work_minutes+
          ceil((select (w->>'estimated_time_from_previous_min')::numeric from jsonb_array_elements(route->'waypoints') w where w->>'cleanup_task_id'=current_task.id::text))+
          case when task_index=cardinality(ids) then ceil((select coalesce(sum((w->>'estimated_time_from_previous_min')::numeric),0) from jsonb_array_elements(route->'waypoints') w where w->>'waypoint_type'='depot_end')) else 0 end
        where id=current_task.id;
    end loop;
  end loop;
  update public.dispatch_plans set optimization_run_id=run.id,routing_token=null,routing_lease_until=null where id=plan_id;
  insert into public.sweeper_audit_log(event_type,entity_type,entity_id,user_id,event_data)
    values('DISPATCH_ROUTES_PUBLISHED','PLAN',plan_id::text,actor::text,jsonb_build_object('run_id',run.id,'tasks',expected_ids));
  return jsonb_build_object('run_id',run.id,'alreadyPublished',false);
end; $function$;
ALTER FUNCTION "public"."publish_dispatch_routes"(plan_id uuid, actor uuid, token uuid, routes jsonb, depot jsonb) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.set_report_photo(report_id uuid, actor uuid, slot text, url text, photo_hash text, expected_version bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare claim uuid; task public.cleanup_tasks; report public.reports; prior_url text;
BEGIN PERFORM operational_private.set_context(actor);
  if slot not in ('before','after') or expected_version is null or expected_version<0 then
    raise exception 'Invalid report photo request' using errcode='22023';
  end if;
  select cleanup_task_id into claim from public.reports where id=report_id;
  if claim is null then raise exception 'Report is not assigned' using errcode='42501'; end if;
  select * into task from public.cleanup_tasks where id=claim for update;
  select * into report from public.reports where id=report_id for update;
  if not found or report.cleanup_task_id is distinct from claim or task.status::text in ('completed','cancelled')
    or not workflow_private.can_execute_task(actor,task) then
    raise exception 'Report is not assigned to this crew' using errcode='42501';
  end if;
  if report.status::text in ('resolved','completed','closed','rejected') and not (
    report.status::text = 'resolved' and slot = 'after' and nullif(url,'') is not null
  ) then
    return jsonb_build_object('status','conflict','error_message','Report is terminal','server_record',to_jsonb(report));
  end if;
  if report.fc_version<>expected_version then
    return jsonb_build_object('status','conflict','error_message','Report version changed','server_record',to_jsonb(report));
  end if;
  prior_url:=case when slot='before' then report.before_photo_url else report.after_photo_url end;
  update public.reports set
    before_photo_url=case when slot='before' then url else before_photo_url end,
    after_photo_url=case when slot='after' then url else after_photo_url end,
    before_photo_hash=case when slot='before' then photo_hash else before_photo_hash end,
    after_photo_hash=case when slot='after' then photo_hash else after_photo_hash end,
    updated_at=now() where id=report_id returning * into report;
  return jsonb_build_object('status','success','server_record',to_jsonb(report),'previous_url',prior_url);
end; $function$;
ALTER FUNCTION "public"."set_report_photo"(report_id uuid, actor uuid, slot text, url text, photo_hash text, expected_version bigint) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION workflow_private.issue_task_report_receipts()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
 IF new.assignment_generation=0 THEN RETURN new; END IF;
 IF tg_op='UPDATE' AND new.assignment_generation IS NOT DISTINCT FROM old.assignment_generation
    AND new.assigned_crew_ids IS NOT DISTINCT FROM old.assigned_crew_ids THEN RETURN new; END IF;
 INSERT INTO public.field_assignment_receipts(task_id,report_id,crew_id,assignment_generation,report_claim_generation)
 SELECT new.id,r.id,crew.id,new.assignment_generation,r.report_claim_generation
 FROM public.reports r
 CROSS JOIN LATERAL unnest(coalesce(new.assigned_crew_ids,'{}'::uuid[])) crew(id)
 WHERE r.cleanup_task_id=new.id AND r.report_claim_generation>0
 ON CONFLICT DO NOTHING;
 RETURN new;
END;
$function$;
ALTER FUNCTION "workflow_private"."issue_task_report_receipts"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION operational_private.row_context()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
 IF NEW.operational_actor_id IS NOT NULL THEN
  PERFORM operational_private.set_context(NEW.operational_actor_id);
  NEW.operational_actor_id:=NULL;
 END IF;
 RETURN NEW;
END; $function$;
ALTER FUNCTION "operational_private"."row_context"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.support_ticket_json(t support_tickets, staff boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
 SELECT jsonb_build_object('id',t.id,'reference',t.reference,'report_id',t.report_id,'category',t.category,
  'description',t.description,'status',t.status,'response',t.response,'responded_at',t.responded_at,
  'resolved_at',t.resolved_at,'created_at',t.created_at,'updated_at',t.updated_at)
  ||CASE WHEN staff THEN jsonb_build_object('handler_id',t.handler_id) ELSE '{}'::jsonb END
$function$;
ALTER FUNCTION "public"."support_ticket_json"(t support_tickets, staff boolean) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION operational_private.capture_receipt()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE receipt jsonb:=coalesce(nullif(current_setting('ecopin.operational_receipt',true),''),'{}')::jsonb;
 generation bigint;
BEGIN
 SELECT ar.assignment_generation INTO generation FROM public.field_assignment_receipts ar WHERE ar.id=NEW.receipt_id;
 PERFORM operational_private.arrival(receipt->'investigation',NEW.task_id,NEW.report_id,NEW.crew_id,generation,NEW.disposition);
 RETURN NEW;
END; $function$;
ALTER FUNCTION "operational_private"."capture_receipt"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION operational_private.set_context(actor uuid, payload jsonb DEFAULT NULL::jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
 IF current_user NOT IN ('postgres','service_role','supabase_admin') THEN RAISE EXCEPTION 'Trusted operational writer required' USING ERRCODE='42501'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=actor AND p.role::text IN ('officer','admin','field_crew')) THEN
  RAISE EXCEPTION 'Operational actor required' USING ERRCODE='42501';
 END IF;
 IF payload IS NOT NULL OR current_setting('ecopin.operational_actor',true) IS DISTINCT FROM actor::text THEN
  PERFORM set_config('ecopin.operational_receipt',coalesce(payload,'{}'::jsonb)::text,true);
 END IF;
 PERFORM set_config('ecopin.operational_actor',actor::text,true);
END; $function$;
ALTER FUNCTION "operational_private"."set_context"(actor uuid, payload jsonb) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.complete_email_verification(p_verification_id uuid, p_user_id uuid)
 RETURNS boolean
 LANGUAGE sql
 SET search_path TO ''
AS $function$
  SELECT public.complete_email_verification(p_verification_id, p_user_id, NULL::text);
$function$;
ALTER FUNCTION "public"."complete_email_verification"(p_verification_id uuid, p_user_id uuid) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION workflow_private.lifecycle_config()
 RETURNS TABLE(normal_hours numeric, high_hours numeric, sla_hours numeric)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
begin
  select (select (parameter_value->>'hours')::numeric from public.sweeper_configuration where parameter_name='maturation_threshold_hours'),
         (select (parameter_value->>'hours')::numeric from public.sweeper_configuration where parameter_name='high_severity_maturation_hours'),
         (select (parameter_value->>'hours')::numeric from public.sweeper_configuration where parameter_name='sla_threshold')
    into normal_hours, high_hours, sla_hours;
  if normal_hours is null or high_hours is null or sla_hours is null
     or not (0 < high_hours and high_hours < normal_hours and normal_hours < sla_hours and sla_hours <= 168) then
    raise exception 'Require 0 < high maturation < normal maturation < SLA <= 168 hours';
  end if;
  return next;
end;
$function$;
ALTER FUNCTION "workflow_private"."lifecycle_config"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION workflow_private.derive_report_lifecycle(report_status text, cluster uuid, task uuid, clock_start timestamp with time zone, deadline timestamp with time zone, maturation_hours numeric, at_time timestamp with time zone)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select case
    when report_status in ('resolved','completed','closed','rejected') then 'closed'
    when task is not null then 'dispatched'
    when cluster is not null then 'clustered'
    when at_time >= deadline then 'sla_breached'
    when at_time >= clock_start + maturation_hours * interval '1 hour' then 'maturing'
    else 'fresh' end;
$function$;
ALTER FUNCTION "workflow_private"."derive_report_lifecycle"(report_status text, cluster uuid, task uuid, clock_start timestamp with time zone, deadline timestamp with time zone, maturation_hours numeric, at_time timestamp with time zone) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.read_incident_case_record(actor uuid, incident_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE source jsonb; activity jsonb; events jsonb; proof jsonb;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=actor AND p.role::text IN ('officer','admin')) THEN
  RAISE EXCEPTION 'Desk case record access required' USING ERRCODE='42501';
 END IF;
 SELECT to_jsonb(r)||jsonb_build_object('latitude',extensions.ST_Y(r.location::extensions.geometry),'longitude',extensions.ST_X(r.location::extensions.geometry)) INTO source
 FROM public.reports r WHERE r.id=incident_id;
 IF source IS NULL THEN RETURN NULL; END IF;
 -- The privacy-masked activity projection is the source, never raw audit snapshots/metadata.
 -- Owner identity is excluded from portable case copies even when the account disclosed its name.
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',a.id,'actor_id',CASE WHEN a.user_id::text=source->>'user_id' THEN NULL ELSE a.user_id END,'action_type',a.action_type,
  'action_details',a.action_details,'occurred_at',a.created_at) ORDER BY a.created_at,a.id),'[]'::jsonb) INTO activity
 FROM (SELECT * FROM public.report_activity_view a WHERE a.report_id=incident_id ORDER BY a.created_at,a.id LIMIT 10001) a;
 WITH task_ids AS (
  SELECT (source->>'cleanup_task_id')::uuid AS id
  UNION SELECT e.task_id FROM public.operational_events e WHERE e.report_id=incident_id AND e.task_id IS NOT NULL
 ), relevant AS (
  SELECT e.* FROM public.operational_events e WHERE e.report_id=incident_id OR
   (e.report_id IS NULL AND e.task_id IN (SELECT id FROM task_ids)) ORDER BY e.id LIMIT 10001
 )
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',e.id::text,'event_type',e.event_type,'task_id',e.task_id,
  'scope',CASE WHEN e.report_id IS NULL THEN 'task_context' ELSE 'incident' END,
  'actor_id',CASE WHEN e.actor_id::text=source->>'user_id' THEN NULL ELSE e.actor_id END,'assignment_generation',e.assignment_generation,'occurred_at',e.occurred_at,'recorded_at',e.recorded_at,'time_basis',e.time_basis,
  'details',jsonb_strip_nulls(jsonb_build_object('slot',e.details->'slot','disposition',e.details->'disposition','assigned',e.details->'assigned')))
  ORDER BY e.id),'[]'::jsonb) INTO events FROM relevant e;
 IF jsonb_array_length(activity)>10000 OR jsonb_array_length(events)>10000 THEN
  RAISE EXCEPTION 'Case history is too large for one printable record; no partial record was produced' USING ERRCODE='54000';
 END IF;
 proof:=public.read_cleanup_proof(incident_id);
 RETURN jsonb_build_object('version','case-record-v1','snapshot_at',statement_timestamp(),
  'report',jsonb_build_object('id',source->'id','title',source->'title','description',source->'description',
   'created_at',source->'created_at','status',source->'status','stage',source->'stage','validation_status',source->'validation_status',
   'issue_type',source->'issue_type','citizen_priority',source->'citizen_priority','latitude',source->'latitude','longitude',source->'longitude',
   'street_address',source->'street_address','barangay',source->'barangay','city',source->'city',
   'barangay_resolution_status',source->'barangay_resolution_status','location_precision',source->'location_precision',
   'citizen_landmark',source->'citizen_landmark','on_private_property',source->'on_private_property',
   'property_owner_consent_status',source->'property_owner_consent_status','cleanup_task_id',source->'cleanup_task_id'),
  'activity',activity,'events',events,
  'proof',CASE WHEN proof IS NULL THEN NULL ELSE jsonb_build_object('id',proof->'id','public_notes',proof->'public_notes',
   'completed_at',proof->'completed_at','verified_at',proof->'verified_at') END);
END; $function$;
ALTER FUNCTION "public"."read_incident_case_record"(actor uuid, incident_id uuid) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.calculate_report_deadline()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.severity_score = 5 THEN
    NEW.deadline_at := NEW.created_at + INTERVAL '24 hours';
  ELSIF NEW.severity_score = 4 THEN
    NEW.deadline_at := NEW.created_at + INTERVAL '48 hours';
  ELSIF NEW.severity_score IN (2, 3) THEN
    NEW.deadline_at := NEW.created_at + INTERVAL '72 hours';
  ELSE
    NEW.deadline_at := NEW.created_at + INTERVAL '7 days';
  END IF;

  RETURN NEW;
END;
$function$;
ALTER FUNCTION "public"."calculate_report_deadline"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.count_recent_nearby_reports(p_lon double precision, p_lat double precision, p_radius_meters double precision, p_days integer)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
    v_count INTEGER;
BEGIN
    SELECT count(*) INTO v_count
    FROM public.reports
    WHERE extensions.ST_DWithin(
        location::extensions.geography,
        extensions.ST_SetSRID(extensions.ST_MakePoint(p_lon, p_lat), 4326)::extensions.geography,
        p_radius_meters
    )
    AND created_at >= NOW() - (p_days || ' days')::INTERVAL;
    RETURN v_count;
END;
$function$;
ALTER FUNCTION "public"."count_recent_nearby_reports"(p_lon double precision, p_lat double precision, p_radius_meters double precision, p_days integer) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.nextval(seq_name text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  RETURN nextval(seq_name::regclass);
END;
$function$;
ALTER FUNCTION "public"."nextval"(seq_name text) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.reconcile_report_outcome(actor uuid, operation_id text, payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  prior public.fc_operation_log;
  task public.cleanup_tasks;
  report public.reports;
  receipt public.field_assignment_receipts;
  resolution public.report_resolution_events;
  result jsonb;
  disposition text;
  observation timestamptz;
  requested_outcome text;
  v_report_id uuid;
  v_task_id uuid;
  v_crew_id uuid;
BEGIN PERFORM operational_private.set_context(actor,payload);
  if operation_id is null or length(operation_id) not between 1 and 200
    or jsonb_typeof(payload) is distinct from 'object'
    or jsonb_typeof(payload->'evidence_refs') is distinct from 'array'
    or payload->>'outcome' is null
    or payload->>'outcome' not in ('cleaned','already_resolved','unable','skipped') then
    raise exception 'Invalid report outcome operation' using errcode='22023';
  end if;
  v_task_id := (payload->>'task_id')::uuid;
  v_report_id := (payload->>'report_id')::uuid;
  v_crew_id := (payload->>'crew_id')::uuid;
  requested_outcome := payload->>'outcome';
  observation := (payload->>'observed_at')::timestamptz;
  if v_task_id is null or v_report_id is null or v_crew_id is distinct from actor or observation is null
    or observation > now() + interval '5 minutes' then
    raise exception 'Invalid report outcome receipt' using errcode='22023';
  end if;
  if requested_outcome in ('cleaned','already_resolved') and jsonb_array_length(payload->'evidence_refs') = 0 then
    raise exception 'Physical outcome evidence is required' using errcode='22023';
  end if;
  if exists (select 1 from jsonb_array_elements_text(payload->'evidence_refs') e(ref)
    where e.ref !~ '^https://[^[:space:]]+$' AND e.ref !~ '^storage://Cleanup%20Originals/[a-f0-9-]+/after/[a-f0-9-]+[.](jpg|png|webp)$') then
    raise exception 'Outcome evidence must be uploaded first' using errcode='22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(operation_id,72631009));
  select * into prior from public.fc_operation_log l where l.operation_id = reconcile_report_outcome.operation_id;
  if found then
    if prior.user_id <> actor or prior.entity_id <> v_report_id::text or prior.operation_type::text <> 'fc.report.reconcile' then
      raise exception 'Operation ID belongs to another request' using errcode='42501';
    end if;
    return prior.result || jsonb_build_object('replayed',true);
  end if;

  select * into receipt from public.field_assignment_receipts ar
    where ar.task_id = v_task_id
      and ar.report_id = v_report_id
      and ar.crew_id = actor
      and ar.assignment_generation = (payload->>'assignment_generation')::bigint
      and ar.report_claim_generation = (payload->>'report_claim_generation')::bigint;
  if not found then
    result := jsonb_build_object('operation_id',operation_id,'status','rejected',
      'error_message','Assignment receipt is invalid');
    insert into public.fc_operation_log(operation_id,user_id,operation_type,entity_id,entity_type,status,result,expires_at)
      values(operation_id,actor,'fc.report.reconcile',v_report_id::text,'report','rejected',result,'infinity');
    return result;
  end if;

  select * into task from public.cleanup_tasks where id = v_task_id for update;
  select * into report from public.reports where id = v_report_id for update;
  if not found then raise exception 'Report no longer exists' using errcode='P0002'; end if;

  if requested_outcome = 'already_resolved' then
    select * into resolution from public.report_resolution_events e
      where e.report_id = v_report_id order by e.resolved_at desc limit 1;
    if found and report.status::text in ('resolved','completed','closed')
      and report.lgu_resolved_at is not null and report.lgu_resolved_at = resolution.resolved_at then
      disposition := 'acknowledged_already_resolved';
    else
      disposition := 'verification_required';
    end if;
  elsif requested_outcome = 'cleaned' then
    if task.assignment_generation = receipt.assignment_generation
      and task.route_status = 'ready'
      and task.status::text not in ('completed','cancelled')
      and actor = any(coalesce(task.assigned_crew_ids,'{}'::uuid[]))
      and report.report_claim_generation = receipt.report_claim_generation
      and report.cleanup_task_id = v_task_id
      and report.status::text not in ('resolved','completed','closed','rejected') then
      update public.reports set status='resolved',cleanup_action_notes=btrim(payload->>'notes'),lgu_resolved_at=now(),updated_at=now()
        where id=v_report_id returning * into report;
      insert into public.report_resolution_events
        (report_id,task_id,crew_id,operation_id,report_fc_version,resolved_at)
        values(v_report_id,v_task_id,actor,operation_id,report.fc_version,report.lgu_resolved_at)
        returning * into resolution;
      disposition := 'applied';
    else
      disposition := 'contested';
      update public.cleanup_tasks set route_status='needs_replan'
        where id=report.cleanup_task_id and status::text not in ('completed','cancelled')
          and route_status <> 'needs_replan';
    end if;
  else
    disposition := 'applied';
  end if;

  insert into public.task_report_outcomes
    (operation_id,task_id,report_id,crew_id,receipt_id,outcome,disposition,observed_at,evidence_refs,notes,resolution_event_id)
    values(operation_id,v_task_id,v_report_id,actor,receipt.id,requested_outcome,disposition,observation,
      payload->'evidence_refs',coalesce(payload->>'notes',''),resolution.id);
  result := jsonb_build_object('operation_id',operation_id,'status',disposition,
    'server_record',to_jsonb(report));
  insert into public.fc_operation_log(operation_id,user_id,operation_type,entity_id,entity_type,status,result,expires_at)
    values(operation_id,actor,'fc.report.reconcile',v_report_id::text,'report',disposition,result,'infinity');
  return result;
end;
$function$;
ALTER FUNCTION "public"."reconcile_report_outcome"(actor uuid, operation_id text, payload jsonb) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.create_manual_cleanup_task(actor uuid, selected_report_ids uuid[], task_title text, task_description text DEFAULT NULL::text, crew_member_ids uuid[] DEFAULT '{}'::uuid[], task_priority text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  claimed_ids uuid[];
  linked_clusters uuid[];
  first_location extensions.geography;
  task public.cleanup_tasks;
  member_count integer;
BEGIN PERFORM operational_private.set_context(actor);
  perform workflow_private.require_desk_actor(actor);
  if nullif(btrim(task_title),'') is null then
    raise exception 'Task title is required' using errcode='22023';
  end if;
  if selected_report_ids is null or cardinality(selected_report_ids)=0 or
     array_position(selected_report_ids,null) is not null or
     cardinality(selected_report_ids)<>(select count(distinct id) from unnest(selected_report_ids) id) then
    raise exception 'Distinct report IDs are required' using errcode='22023';
  end if;
  if task_priority is not null and task_priority not in ('low','medium','high') then
    raise exception 'Invalid priority' using errcode='22023';
  end if;
  if crew_member_ids is null or array_position(crew_member_ids,null) is not null or
     cardinality(crew_member_ids)<>(select count(distinct id) from unnest(crew_member_ids) id) then
    raise exception 'Distinct crew member IDs are required' using errcode='22023';
  end if;
  select count(*) into member_count from public.profiles p
    where p.id=any(crew_member_ids) and p.role::text='field_crew';
  if member_count<>cardinality(crew_member_ids) then
    raise exception 'All assignees must be field crew members' using errcode='22023';
  end if;

  select coalesce(array_agg(r.id order by r.id),'{}'::uuid[]) into claimed_ids from (
    select id from public.reports where id=any(selected_report_ids)
      and cleanup_task_id is null
      and status::text not in ('resolved','completed','closed','rejected')
      and validation_status::text is distinct from 'manual_review'
      and not exists(select 1 from public.dispatch_access_blocks b
        where b.cleared_at is null and
          (b.report_id=reports.id or b.cluster_id=reports.cluster_id))
    order by id for update skip locked
  ) r;
  if cardinality(claimed_ids)<>cardinality(selected_report_ids) then
    return jsonb_build_object('status','conflict','reason','stale_or_blocked_report');
  end if;
  select coalesce(array_agg(distinct cluster_id) filter(where cluster_id is not null),'{}'::uuid[]),
    (select location from public.reports where id=selected_report_ids[1])
    into linked_clusters,first_location from public.reports where id=any(claimed_ids);

  insert into public.cleanup_tasks(
    cluster_id,cluster_ids,report_ids,report_sequence,title,description,status,
    is_custom,priority,created_by,assigned_crew_ids,assigned_at,assigned_by,
    last_assigned_at,route_status,task_type,location
  ) values (
    case when cardinality(linked_clusters)=1 and
      (select count(*) from public.reports where id=any(claimed_ids) and cluster_id is null)=0
      then linked_clusters[1] else null end,
    linked_clusters,claimed_ids,selected_report_ids,task_title,task_description,
    (case when cardinality(crew_member_ids)>0 then 'pending' else 'created' end)::public.cleanup_task_status,
    true,task_priority,actor,crew_member_ids,
    case when cardinality(crew_member_ids)>0 then now() else null end,
    case when cardinality(crew_member_ids)>0 then actor else null end,
    case when cardinality(crew_member_ids)>0 then now() else null end,
    'ready','Cleanup',first_location
  ) returning * into task;

  update public.reports set cleanup_task_id=task.id,updated_at=now()
    where id=any(claimed_ids) and cleanup_task_id is null;
  if not found or (select count(*) from public.reports where cleanup_task_id=task.id)<>cardinality(claimed_ids) then
    raise exception 'Report claim changed during manual task creation' using errcode='40001';
  end if;
  -- Notification failure rolls back the task, claim and receipts together.
  insert into public.notifications(user_id,report_id,type,title,body)
    select member_id,
      case when cardinality(claimed_ids)=1 then claimed_ids[1] else null end,
      'general'::public.notification_type,'New Task Assigned',
      pg_catalog.format('You have been assigned to cleanup task: %s',task.title)
    from pg_catalog.unnest(crew_member_ids) member_id;
  return jsonb_build_object('status','created','task',to_jsonb(task));
end; $function$;
ALTER FUNCTION "public"."create_manual_cleanup_task"(actor uuid, selected_report_ids uuid[], task_title text, task_description text, crew_member_ids uuid[], task_priority text) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION workflow_private.audit_report_lifecycle()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if new.lifecycle_state is null then return new; end if;
  if old.lifecycle_state is distinct from new.lifecycle_state
     or old.matured_at is distinct from new.matured_at
     or old.breached_at is distinct from new.breached_at then
    insert into public.sweeper_audit_log(event_type,entity_type,entity_id,user_id,event_data)
    values ('REPORT_LIFECYCLE_CHANGE','REPORT',new.id::text,'system',
      jsonb_build_object('from',old.lifecycle_state,'to',new.lifecycle_state,
        'sla_started_at',new.sla_started_at,'matured_at',new.matured_at,'breached_at',new.breached_at));
    if old.breached_at is null and new.breached_at is not null then
      insert into public.sweeper_audit_log(event_type,entity_type,entity_id,user_id,event_data)
      values ('SLA_BREACH_DETECTED','REPORT',new.id::text,'system',
        jsonb_build_object('breached_at',new.breached_at,'sla_started_at',new.sla_started_at));
    end if;
  end if;
  return new;
end;
$function$;
ALTER FUNCTION "workflow_private"."audit_report_lifecycle"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION workflow_private.issue_report_claim_receipts()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if new.cleanup_task_id is null or new.report_claim_generation = 0 then return new; end if;
  if tg_op = 'UPDATE' then
    if new.report_claim_generation is not distinct from old.report_claim_generation then return new; end if;
  end if;
    insert into public.field_assignment_receipts
      (task_id,report_id,crew_id,assignment_generation,report_claim_generation)
    select t.id,new.id,crew.id,t.assignment_generation,new.report_claim_generation
      from public.cleanup_tasks t
      cross join lateral unnest(coalesce(t.assigned_crew_ids,'{}'::uuid[])) crew(id)
      where t.id = new.cleanup_task_id and t.assignment_generation > 0
    on conflict do nothing;
  return new;
end;
$function$;
ALTER FUNCTION "workflow_private"."issue_report_claim_receipts"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  INSERT INTO public.profiles (id, role, is_email_verified)
  VALUES (NEW.id, 'citizen', false);
  RETURN NEW;
END;
$function$;
ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.handle_report_status_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
    -- Only notify if status or validation_status changes
    IF (OLD.status IS DISTINCT FROM NEW.status) OR (OLD.validation_status IS DISTINCT FROM NEW.validation_status) THEN
        INSERT INTO public.notifications (user_id, report_id, title, body)
        VALUES (
            NEW.user_id,
            NEW.id,
            CASE
                WHEN OLD.status IS DISTINCT FROM NEW.status THEN 'Report Status Updated'
                WHEN OLD.validation_status IS DISTINCT FROM NEW.validation_status THEN 'Report Validation Updated'
                ELSE 'Report Updated'
            END,
            CASE
                WHEN OLD.status IS DISTINCT FROM NEW.status THEN 'Your report "' || NEW.title || '" is now ' || NEW.status || '.'
                WHEN OLD.validation_status IS DISTINCT FROM NEW.validation_status THEN 'Your report "' || NEW.title || '" validation status is now ' || NEW.validation_status || '.'
                ELSE 'Your report "' || NEW.title || '" has been updated.'
            END
        );
    END IF;
    RETURN NEW;
END;
$function$;
ALTER FUNCTION "public"."handle_report_status_change"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.commit_dispatch_plan(plan_id uuid, actor uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  plan public.dispatch_plans; item public.dispatch_plan_items; crew public.field_crews;
  anchor public.clusters; task public.cleanup_tasks; locked_ids uuid[]; result jsonb;
  results jsonb:='[]'; budget numeric; busy numeric; busy_count integer; shift_minutes numeric;
  settings jsonb; claim_count integer; task_ids uuid[]:='{}'; group_error text;
BEGIN PERFORM operational_private.set_context(actor);
  perform workflow_private.require_desk_actor(actor);
  select * into plan from public.dispatch_plans where id=plan_id for update;
  if not found then raise exception 'Plan not found' using errcode='P0002'; end if;
  if plan.status::text='discarded' then raise exception 'Plan is discarded'; end if;
  settings := plan.settings_snapshot;
  -- Stable lock order across plans prevents inversions when their crew mappings differ.
  perform id from public.field_crews where id in (select planned_crew_id from public.dispatch_plan_items where dispatch_plan_id=plan_id and is_selected) order by id for update;
  for item in select * from public.dispatch_plan_items where dispatch_plan_id=plan_id and is_selected order by group_key loop
    select c.result into result from public.dispatch_group_commits c where c.dispatch_plan_id=plan_id and c.group_key=item.group_key;
    if found then
      results:=results||jsonb_build_array(result);
      if result->>'task_id' is not null then task_ids:=array_append(task_ids,(result->>'task_id')::uuid); end if;
      continue;
    end if;
    group_error:=null;
    -- Subtransaction releases locks and rolls back every write if any mandatory member is stale.
    begin
      if cardinality(item.report_ids)=0 then raise exception 'legacy_plan_requires_regeneration'; end if;
      select * into crew from public.field_crews where id=item.planned_crew_id for update;
      if not found or crew.availability_status::text<>'available'
         or (plan.mode='standard' and not crew.supports_standard)
         or (plan.mode='sweeper' and not crew.supports_sweeper) then
        raise exception 'crew_unavailable';
      end if;
      if coalesce(cardinality(crew.member_profile_ids),0)=0 and crew.team_lead_profile_id is null then
        raise exception 'crew_has_no_members';
      end if;
      if (item.crew_snapshot->>'speed_factor')::numeric is distinct from crew.speed_factor or (item.crew_snapshot->>'service_time_factor')::numeric is distinct from crew.service_time_factor then raise exception 'crew_timing_changed'; end if;
      if crew.shift_start is null or crew.shift_end is null then raise exception 'crew_unavailable'; end if;
      shift_minutes:=extract(epoch from(crew.shift_end-crew.shift_start))/60;
      if shift_minutes<0 then shift_minutes:=shift_minutes+1440; end if;
      budget:=greatest(0,(shift_minutes-coalesce((settings->>'break_duration_min')::numeric,60)+coalesce((settings->>'overtime_tolerance_min')::numeric,15))*coalesce((settings->>'capacity_utilization')::numeric,1));
      select coalesce(sum(coalesce(estimated_duration_min,60)),0),count(*) into busy,busy_count from public.cleanup_tasks
        where (assigned_field_crew_id=crew.id or coalesce(assigned_crew_ids,'{}'::uuid[]) && (coalesce(crew.member_profile_ids,'{}'::uuid[]) || array_remove(array[crew.team_lead_profile_id],null)))
          and status::text not in ('completed','cancelled');
      if busy+item.estimated_duration_minutes>budget or busy_count>=least(coalesce(crew.max_tasks_per_shift,10),coalesce((settings->>'max_tasks_per_shift')::integer,15)) then
        raise exception 'crew_capacity_changed';
      end if;
      if item.item_type='cluster' then
        select * into anchor from public.clusters where id=item.cluster_id for update skip locked;
        if not found or anchor.status::text not in ('new','unresolved','prioritized','queued','monitoring') then raise exception 'stale_anchor'; end if;
        if exists(select 1 from public.reports where cluster_id=anchor.id and status::text not in ('resolved','completed','closed','rejected')
          and not(id=any(item.report_ids))) then raise exception 'anchor_membership_changed'; end if;
      end if;
      select coalesce(array_agg(r.id order by r.id),'{}'::uuid[]) into locked_ids from (
        select id from public.reports r where id=any(item.report_ids) and cleanup_task_id is null
          and status::text not in ('resolved','completed','closed','rejected')
          and ((item.item_type='cluster' and cluster_id=item.cluster_id)
             or (item.item_type='report' and cluster_id is null and lifecycle_state in ('maturing','sla_breached')))
        order by id for update skip locked
      ) r;
      if cardinality(locked_ids)<>cardinality(item.report_ids) then raise exception 'stale_group'; end if;
      insert into public.cleanup_tasks(cluster_id,cluster_ids,report_ids,report_sequence,title,status,task_type,
        estimated_duration_min,created_by,source_plan_id,source_group_key,assigned_field_crew_id,dispatch_kind,
        route_status,routing_deadline_at,scheduled_date,location,estimated_work_minutes,priority_score)
      values(item.cluster_id,case when item.cluster_id is null then '{}'::uuid[] else array[item.cluster_id] end,
        locked_ids,locked_ids,case when plan.mode='sweeper' then 'Sweeper pickup' else 'Cluster cleanup' end,'pending',
        (case when plan.mode='sweeper' then 'Sweeper' when anchor.recommended_task_type='Scouting' then case when exists(select 1 from public.reports where id=any(locked_ids) and validation_status::text is distinct from 'approved') then 'Verification' else 'Cleanup' end
          when anchor.recommended_task_type in ('Cleanup','Investigation','Verification','Emergency Response','Reinspection','Monitoring','Escalation') then anchor.recommended_task_type else 'Cleanup' end)::public.cleanup_task_type,
        item.estimated_duration_minutes,actor,plan_id,item.group_key,crew.id,plan.mode,'needs_replan',now()+interval '30 minutes',plan.planned_date,
        (select location from public.reports where id=locked_ids[1]),item.estimated_work_minutes,item.priority_score) returning * into task;
      update public.reports set cleanup_task_id=task.id,updated_at=now() where id=any(locked_ids) and cleanup_task_id is null;
      get diagnostics claim_count=row_count;
      if claim_count<>cardinality(locked_ids) then raise exception 'stale_group'; end if;
      if item.cluster_id is not null then update public.clusters set status='scheduled' where id=item.cluster_id; end if;
      result:=jsonb_build_object('status','committed','group_key',item.group_key,'task_id',task.id,'report_ids',locked_ids,'crew_id',crew.id);
      task_ids:=array_append(task_ids,task.id);
    exception when raise_exception then
      get stacked diagnostics group_error=message_text;
      if group_error not in ('legacy_plan_requires_regeneration','crew_unavailable','crew_timing_changed','crew_has_no_members','crew_capacity_changed','stale_anchor','anchor_membership_changed','stale_group','dispatch_blocked') then raise; end if;
      result:=jsonb_build_object('status','skipped','group_key',item.group_key,'reason',group_error);
    end;
    insert into public.dispatch_group_commits(dispatch_plan_id,group_key,result) values(plan_id,item.group_key,result);
    results:=results||jsonb_build_array(result);
  end loop;
  update public.dispatch_plans set status='approved' where id=plan_id;
  return jsonb_build_object('plan_id',plan_id,'results',results,'tasks',
    coalesce((select jsonb_agg(to_jsonb(t)) from public.cleanup_tasks t where id=any(task_ids)),'[]'::jsonb));
end; $function$;
ALTER FUNCTION "public"."commit_dispatch_plan"(plan_id uuid, actor uuid) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.save_dispatch_plan(actor uuid, plan_mode text, settings jsonb, items jsonb, available_crews integer, capacity_minutes integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare plan public.dispatch_plans; item jsonb; ids uuid[]; duplicate_count integer;
begin
  perform workflow_private.require_desk_actor(actor);
  if plan_mode is null or plan_mode not in ('standard','sweeper') or jsonb_typeof(items) is distinct from 'array'
    or jsonb_array_length(items)>400 or available_crews<0 or capacity_minutes<0 then
    raise exception 'Invalid Slice A plan';
  end if;
  insert into public.dispatch_plans(created_by,mode,settings_snapshot,total_crews_available,total_capacity_minutes,status)
    values(actor,plan_mode,settings,available_crews,capacity_minutes,'draft') returning * into plan;
  for item in select value from jsonb_array_elements(items) loop
    select coalesce(array_agg(v::uuid),'{}'::uuid[]) into ids from jsonb_array_elements_text(item->'report_ids') v;
    if cardinality(ids)=0 or cardinality(ids)<>(select count(distinct x) from unnest(ids) x) then
      raise exception 'Plan groups require distinct report snapshots';
    end if;
    if item->>'item_type'='report' and ids<>array[(item->>'report_id')::uuid] then raise exception 'Standalone report snapshot must match target'; end if;
    if (item->>'estimated_work_minutes')::integer<1 or (item->>'estimated_duration_minutes')::integer<(item->>'estimated_work_minutes')::integer then raise exception 'Invalid task estimate'; end if;
    if (plan_mode='standard' and item->>'item_type'<>'cluster')
      or (plan_mode='sweeper' and item->>'item_type'<>'report') then
      raise exception 'Plan item does not match mode';
    end if;
    insert into public.dispatch_plan_items(dispatch_plan_id,cluster_id,report_id,report_ids,item_type,group_key,
      planned_crew_id,is_selected,reason,estimated_duration_minutes,priority_score,estimated_work_minutes,crew_snapshot)
    values(plan.id,(item->>'cluster_id')::uuid,(item->>'report_id')::uuid,ids,item->>'item_type',item->>'group_key',
      (item->>'planned_crew_id')::uuid,(item->>'is_selected')::boolean,item->>'reason',
      (item->>'estimated_duration_minutes')::integer,(item->>'priority_score')::numeric,(item->>'estimated_work_minutes')::integer,coalesce(item->'crew_snapshot','{}'::jsonb));
  end loop;
  select count(*)-count(distinct report) into duplicate_count
    from public.dispatch_plan_items i cross join lateral unnest(i.report_ids) report where i.dispatch_plan_id=plan.id;
  if duplicate_count<>0 then raise exception 'Report appears in multiple plan groups'; end if;
  return to_jsonb(plan);
end; $function$;
ALTER FUNCTION "public"."save_dispatch_plan"(actor uuid, plan_mode text, settings jsonb, items jsonb, available_crews integer, capacity_minutes integer) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
    NEW.updated_at = timezone('utc'::text, now());
    RETURN NEW;
END;
$function$;
ALTER FUNCTION "public"."update_updated_at_column"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.upsert_cluster_for_reports(p_report_ids uuid[], p_issue_type text, p_severity text, p_radius_meters numeric)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  RAISE EXCEPTION 'Function public.upsert_cluster_for_reports is deprecated. Use upsert_cluster_for_reports_v2 instead.';
END;
$function$;
ALTER FUNCTION "public"."upsert_cluster_for_reports"(p_report_ids uuid[], p_issue_type text, p_severity text, p_radius_meters numeric) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION workflow_private.validate_lifecycle_config()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if exists(select 1 from workflow_private.lifecycle_deployment) then
    perform * from workflow_private.lifecycle_config();
  end if;
  return null;
end;
$function$;
ALTER FUNCTION "workflow_private"."validate_lifecycle_config"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.get_auth_user_role()
 RETURNS role
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT role FROM public.profiles WHERE id = (SELECT auth.uid());
$function$;
ALTER FUNCTION "public"."get_auth_user_role"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION workflow_private.severity_tier(score integer)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select case when score is null then 'unknown'
    when score between 0 and 33 then 'low'
    when score between 34 and 66 then 'medium'
    when score between 67 and 100 then 'high'
    else 'invalid' end;
$function$;
ALTER FUNCTION "workflow_private"."severity_tier"(score integer) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.set_cluster_queue_status(cluster_id uuid, actor uuid, next_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare cluster public.clusters;
begin
  perform workflow_private.require_desk_actor(actor);
  if next_status is null or next_status not in ('unresolved','prioritized','queued','monitoring','needs_verification') then raise exception 'Use task outcomes or block review for execution states'; end if;
  select * into cluster from public.clusters where id=cluster_id for update;
  if not found then raise exception 'Cluster not found'; end if;
  if cluster.status::text in ('scheduled','in_progress','deferred') or exists(select 1 from public.reports where reports.cluster_id=cluster.id and cleanup_task_id is not null) then raise exception 'Active or blocked cluster cannot be manually requeued'; end if;
  update public.clusters set status=next_status::public.cluster_status where id=cluster.id returning * into cluster;
  return to_jsonb(cluster);
end; $function$;
ALTER FUNCTION "public"."set_cluster_queue_status"(cluster_id uuid, actor uuid, next_status text) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION privacy_private.protect_report_identity()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
 IF TG_OP='INSERT' AND NEW.hide_identity AND (SELECT auth.role()) IN ('anon','authenticated') THEN
  RAISE EXCEPTION 'Submit hidden reports through the protected API' USING ERRCODE='42501';
 END IF;
 IF TG_OP='INSERT' AND EXISTS(SELECT 1 FROM privacy_private.hidden_report_owners WHERE report_id=NEW.id) THEN
  RAISE EXCEPTION 'Report identity cannot be reused' USING ERRCODE='23505';
 END IF;
 IF TG_OP='UPDATE' AND OLD.hide_identity AND NEW.user_id IS DISTINCT FROM OLD.user_id AND (NEW.user_id IS NOT NULL OR EXISTS(SELECT 1 FROM public.profiles WHERE id=OLD.user_id)) THEN
  RAISE EXCEPTION 'Hidden report ownership cannot be reassigned' USING ERRCODE='22023';
 END IF;
 IF TG_OP='UPDATE' AND NEW.hide_identity IS DISTINCT FROM OLD.hide_identity THEN
  RAISE EXCEPTION 'hide_identity is immutable after submission' USING ERRCODE='22023';
 END IF;
 IF NEW.hide_identity AND NEW.user_id IS NOT NULL THEN
  INSERT INTO privacy_private.hidden_report_owners VALUES(NEW.id,NEW.user_id) ON CONFLICT DO NOTHING;
 END IF;
 RETURN NEW;
END $function$;
ALTER FUNCTION "privacy_private"."protect_report_identity"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION workflow_private.apply_fc_operation(actor uuid, operation_id text, operation_type text, entity_id uuid, entity_type text, payload jsonb, base_version bigint DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  prior public.fc_operation_log;
  report public.reports;
  task public.cleanup_tasks;
  patched public.reports;
  actor_role text;
  claim uuid;
  result jsonb;
  note public.response_log;
  allowed text[];
  key text;
  identical boolean;
BEGIN PERFORM operational_private.set_context(actor,payload);
  if actor is null or entity_id is null or entity_type is null or operation_type is null
    or operation_id is null or length(operation_id) not between 1 and 200 or jsonb_typeof(payload) is distinct from 'object'
    or base_version is null or base_version < 0 then
    raise exception 'Invalid sync operation' using errcode = '22023';
  end if;

  select role::text into actor_role from public.profiles where id = actor;
  if actor_role is null or actor_role not in ('admin', 'officer', 'field_crew') then
    raise exception 'Field operations access required' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(operation_id, 72631009));

  select * into prior from public.fc_operation_log l where l.operation_id = apply_fc_operation.operation_id;
  if found then
    if prior.user_id is distinct from actor or prior.entity_id is distinct from entity_id::text
      or prior.entity_type::text is distinct from entity_type or prior.operation_type::text is distinct from operation_type then
      raise exception 'Operation ID belongs to another request' using errcode = '42501';
    end if;
    -- Unknown legacy identity cannot safely authorize an immutable replay.
    if not (coalesce(prior.result, '{}'::jsonb) ? 'request_base_version') then
      raise exception 'Legacy operation replay requires manual review' using errcode = '22023';
    end if;
    if prior.result->'request_base_version' is distinct from to_jsonb(base_version) then
      raise exception 'Operation ID reused with different base version' using errcode = '22023';
    end if;
    if (prior.result->'payload') is not null and (prior.result->'payload') is distinct from payload then
      raise exception 'Operation ID reused with different payload' using errcode = '22023';
    end if;
    if (prior.result->>'payload_hash') is not null and prior.result->>'payload_hash' <> md5(payload::text) then
      raise exception 'Operation ID reused with different payload' using errcode = '22023';
    end if;
    return prior.result || jsonb_build_object('operation_id', operation_id, 'replayed', true);
  end if;

  if operation_type = 'fc.task.mark_complete' and entity_type = 'task' then
    result := public.submit_task_outcome(
      entity_id, actor, coalesce(payload->>'outcome', 'completed'), coalesce(payload->>'notes', ''),
      payload->>'failure_class', base_version, operation_id
    );
  elsif entity_type = 'report' and operation_type in (
    'fc.report.update_status', 'fc.report.update_lifecycle_stage', 'fc.report.update_validation',
    'fc.report.update_details', 'fc.note.add'
  ) then
    select cleanup_task_id into claim from public.reports where id = entity_id;
    if claim is not null then
      select * into task from public.cleanup_tasks where id = claim for update;
    end if;

    select * into report from public.reports where id = entity_id for update;
    if not found then
      raise exception 'Report not found' using errcode = 'P0002';
    end if;

    if actor_role = 'field_crew' and (
      report.cleanup_task_id is distinct from claim or claim is null
      or task.status::text in ('completed', 'cancelled') or not workflow_private.can_execute_task(actor, task)
    ) then
      raise exception 'Report is not assigned to this crew' using errcode = '42501';
    end if;

    if operation_type = 'fc.note.add' then
      if nullif(btrim(coalesce(payload->>'action', payload->>'action_details')), '') is null then
        raise exception 'Note text required';
      end if;
      insert into public.response_log(report_id, user_id, action_type, action_details)
        values(entity_id, actor, 'manual_note', coalesce(payload->>'action', payload->>'action_details'))
        returning * into note;
      result := jsonb_build_object('status', 'success', 'server_record', to_jsonb(note));
    else
      allowed := case operation_type
        when 'fc.report.update_status' then array['status','cleanup_action_notes']
        when 'fc.report.update_lifecycle_stage' then array['stage']
        when 'fc.report.update_validation' then array['validation_status']
        else array['notes', 'stage']
      end;

      for key in select jsonb_object_keys(payload) loop
        if not (key = any(allowed)) then
          raise exception 'Field is server-owned or unsupported: %', key using errcode = '42501';
        end if;
      end loop;

      if payload ? 'status' and payload->>'status' not in ('in_progress', 'resolved') then
        raise exception 'Use a classified task outcome for closure or failure';
      end if;

      if report.status::text in ('resolved', 'completed', 'closed', 'rejected') then
        result := jsonb_build_object('status', 'conflict', 'server_record', to_jsonb(report), 'error_message', 'Report is terminal');
      else
        select bool_and(to_jsonb(report)->k is not distinct from payload->k) into identical
        from jsonb_object_keys(payload) k;

        if coalesce(identical, false) then
          result := jsonb_build_object('status', 'success', 'server_record', to_jsonb(report));
        elsif base_version <> report.fc_version then
          result := jsonb_build_object(
            'status', 'conflict',
            'server_record', to_jsonb(report),
            'error_message', 'Report version changed',
            'conflict_detail', jsonb_build_object(
              'rule', 'first_accepted_wins',
              'server_version', report.fc_version,
              'client_base_version', base_version
            )
          );
        else
          patched := jsonb_populate_record(report, payload);
          update public.reports set
            status = patched.status,
            stage = patched.stage,
            notes = patched.notes, cleanup_action_notes = patched.cleanup_action_notes,
            validation_status = patched.validation_status,
            lgu_resolved_at = case when patched.status::text = 'resolved' then now() else lgu_resolved_at end,
            updated_at = now()
          where id = entity_id returning * into report;
          result := jsonb_build_object('status', 'success', 'server_record', to_jsonb(report));
        end if;
      end if;
    end if;
  else
    raise exception 'Unsupported sync operation' using errcode = '22023';
  end if;

  result := result || jsonb_build_object('operation_id', operation_id, 'payload', payload, 'payload_hash', md5(payload::text), 'request_base_version', base_version);

  if result->>'status' = 'conflict' then
    insert into public.fc_conflict_audit(
      operation_id, user_id, operation_type, entity_id, entity_type, outcome,
      client_base_version, server_version, payload, server_state_snapshot, reason
    )
    values(
      operation_id, actor, operation_type::public.sync_operation_type, entity_id::text, entity_type::public.sync_entity_type,
      'rejected', base_version, (result->'server_record'->>'fc_version')::bigint, payload, result->'server_record', result->>'error_message'
    );
  end if;

  insert into public.fc_operation_log(operation_id, user_id, operation_type, entity_id, entity_type, status, result)
    values(
      operation_id, actor, operation_type::public.sync_operation_type, entity_id::text,
      entity_type::public.sync_entity_type, result->>'status', result
    );

  return result;
end;
$function$;
ALTER FUNCTION "workflow_private"."apply_fc_operation"(actor uuid, operation_id text, operation_type text, entity_id uuid, entity_type text, payload jsonb, base_version bigint) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.submit_task_outcome(task_id uuid, actor uuid, outcome text, notes text, classification text DEFAULT NULL::text, expected_version bigint DEFAULT NULL::bigint, operation_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare task public.cleanup_tasks; cleaned boolean; terminal boolean; target_status public.cleanup_task_status;
BEGIN PERFORM operational_private.set_context(actor);
  select * into task from public.cleanup_tasks where id=task_id for update;
  if not found then raise exception 'Task not found' using errcode='P0002'; end if;
  if not workflow_private.can_execute_task(actor,task) then raise exception 'Task access denied' using errcode='42501'; end if;
  if outcome not in ('completed','cleanup_completed','report_incorrect','issue_not_found','already_resolved','partially_completed',
    'unable_to_complete','issue_still_exists','requires_follow_up','needs_another_inspection','escalated','requires_institutional_action','cancelled') then
    raise exception 'Unsupported task outcome' using errcode='22023';
  end if;
  if task.status::text in ('completed','cancelled') then
    if task.completion_result=outcome or (task.status::text='completed' and outcome='completed') then
      return jsonb_build_object('status','duplicate','server_record',to_jsonb(task));
    end if;
    return jsonb_build_object('status','conflict','server_record',to_jsonb(task),'error_message','Task already has a terminal outcome');
  end if;
  if expected_version is not null and expected_version<>task.fc_version then
    return jsonb_build_object('status','conflict','server_record',to_jsonb(task),'error_message','Task version changed');
  end if;
  cleaned:=outcome='cleanup_completed' or (outcome='completed' and task.task_type::text in ('Cleanup','Sweeper'));
  terminal:=outcome in ('completed','cleanup_completed','report_incorrect','issue_not_found','already_resolved');
  if not terminal and outcome<>'partially_completed' and (classification is null or classification not in ('transient','site','safety','unclassified') or nullif(btrim(notes),'') is null) then
    raise exception 'Failure classification and notes are required' using errcode='22023';
  end if;
  if cleaned then
    update public.reports set status='resolved',cleanup_action_notes=coalesce(nullif(btrim(submit_task_outcome.notes),''),public.reports.cleanup_action_notes),lgu_resolved_at=now(),updated_at=now() where cleanup_task_id=task_id
      and status::text not in ('resolved','completed','closed','rejected');
  elsif outcome in ('report_incorrect','issue_not_found') then
    update public.reports set status='closed',updated_at=now() where cleanup_task_id=task_id
      and status::text not in ('resolved','completed','closed','rejected');
  elsif outcome='already_resolved' and exists(select 1 from public.reports where cleanup_task_id=task_id
    and status::text not in ('resolved','completed','closed','rejected')) then
    -- A clean-looking site is an observation, not proof this report was cleaned by this crew.
    raise exception 'Already-resolved observation requires verification while reports remain open' using errcode='22023';
  end if;
  target_status:=(case when terminal then 'completed' when outcome='partially_completed' then 'partially_completed' else 'cancelled' end)::public.cleanup_task_status;
  update public.cleanup_tasks set status=target_status,completion_result=outcome,completion_notes=submit_task_outcome.notes,completed_by=actor,
    failure_class=case when terminal or outcome='partially_completed' then null else classification end,
    failure_reason=case when terminal or outcome='partially_completed' then null else submit_task_outcome.notes end,
    completed_at=case when target_status::text in ('completed','cancelled') then now() else null end,
    completion_operation_id=operation_id,fc_version=fc_version+1
    where id=task_id returning * into task;
  return jsonb_build_object('status','success','server_record',to_jsonb(task));
end; $function$;
ALTER FUNCTION "public"."submit_task_outcome"(task_id uuid, actor uuid, outcome text, notes text, classification text, expected_version bigint, operation_id text) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION workflow_private.guard_report_claim()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if new.cluster_id is not null and (tg_op='INSERT' or new.cluster_id is distinct from old.cluster_id)
    and exists(select 1 from public.clusters where id=new.cluster_id and status::text in ('scheduled','in_progress','deferred')) then
    raise exception 'Cannot add reports to an active or blocked cluster';
  end if;
  if tg_op='UPDATE' then
    if old.cleanup_task_id is not null and
      (new.cleanup_task_id is distinct from old.cleanup_task_id or new.cluster_id is distinct from old.cluster_id)
      and exists(select 1 from public.cleanup_tasks where id=old.cleanup_task_id and status::text not in ('completed','cancelled')) then
      raise exception 'Active report claim cannot be replaced or regrouped';
    end if;
    if old.cluster_id is not null and new.cluster_id is distinct from old.cluster_id
      and exists(select 1 from public.clusters where id=old.cluster_id and status::text in ('scheduled','in_progress','deferred')) then
      raise exception 'Active or blocked cluster membership cannot be changed';
    end if;
  end if;
  if new.cleanup_task_id is not null and (tg_op='INSERT' or new.cleanup_task_id is distinct from old.cleanup_task_id) then
    if exists(select 1 from public.dispatch_access_blocks where cleared_at is null and
      (report_id=new.id or cluster_id=new.cluster_id)) then raise exception 'dispatch_blocked'; end if;
  end if;
  return new;
end; $function$;
ALTER FUNCTION "workflow_private"."guard_report_claim"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.change_field_crew_member(crew_id uuid, actor uuid, member_id uuid, action text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  crew public.field_crews;
begin
  perform workflow_private.require_desk_actor(actor);
  if action is null or action not in ('add','remove') or member_id is null then
    raise exception 'Invalid membership action';
  end if;
  perform pg_advisory_xact_lock(72631010);
  select * into crew from public.field_crews where id=crew_id for update;
  if not found then raise exception 'Crew not found'; end if;

  if action='add' then
    if not exists(select 1 from public.profiles where id=member_id and role::text='field_crew') then
      raise exception 'Member must have field_crew role';
    end if;
    if exists(select 1 from public.field_crews where id<>crew_id and (member_id=any(coalesce(member_profile_ids,'{}'::uuid[])) or team_lead_profile_id=member_id)) then
      raise exception 'Member already belongs to another crew';
    end if;
    update public.field_crews
      set member_profile_ids=array(select distinct x from unnest(coalesce(crew.member_profile_ids,'{}'::uuid[])||array[member_id]) x order by x),
          updated_at=now()
      where id=crew_id returning * into crew;

    -- Synchronize active cleanup tasks assigned to this field crew
    update public.cleanup_tasks
      set assigned_crew_ids=array(select distinct x from unnest(coalesce(assigned_crew_ids,'{}'::uuid[])||array[member_id]) x order by x)
      where assigned_field_crew_id=crew_id
        and status::text in ('created','pending','in_progress','partially_completed');
  else
    update public.field_crews
      set member_profile_ids=array_remove(member_profile_ids,member_id),
          team_lead_profile_id=case when team_lead_profile_id=member_id then null else team_lead_profile_id end,
          updated_at=now()
      where id=crew_id returning * into crew;

    -- Synchronize active cleanup tasks assigned to this field crew
    update public.cleanup_tasks
      set assigned_crew_ids=array_remove(assigned_crew_ids,member_id)
      where assigned_field_crew_id=crew_id
        and status::text in ('created','pending','in_progress','partially_completed');
  end if;

  return to_jsonb(crew);
end;
$function$;
ALTER FUNCTION "public"."change_field_crew_member"(crew_id uuid, actor uuid, member_id uuid, action text) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION workflow_private.immutable_group_result()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$ begin
  raise exception 'Dispatch group results are immutable';
end; $function$;
ALTER FUNCTION "workflow_private"."immutable_group_result"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION workflow_private.require_desk_actor(actor uuid)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
begin
  if not exists(select 1 from public.profiles where id=actor and role::text in ('admin','officer')) then
    raise exception 'Desk officer access required' using errcode='42501';
  end if;
end; $function$;
ALTER FUNCTION "workflow_private"."require_desk_actor"(actor uuid) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION workflow_private.bump_report_version()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  -- Server lifecycle/assignment changes invalidate every cached mobile snapshot too.
  new.fc_version:=old.fc_version+1;
  return new;
end; $function$;
ALTER FUNCTION "workflow_private"."bump_report_version"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION workflow_private.release_finished_task()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare target uuid; failure text;
begin
  if new.status::text not in ('completed','cancelled') or old.status is not distinct from new.status then return new; end if;
  failure:=coalesce(new.failure_class,'unclassified');
  if new.status::text='cancelled' then
    if failure<>'transient' then
      for target in select distinct cluster_id from public.reports where cleanup_task_id=new.id and cluster_id is not null loop
        insert into public.dispatch_access_blocks(cluster_id,task_id,reason,failure_class,blocked_by)
        values(target,new.id,coalesce(nullif(btrim(new.failure_reason),''),'Unclassified task cancellation'),failure,new.completed_by)
        on conflict do nothing;
        update public.clusters set status='deferred' where id=target;
      end loop;
      insert into public.dispatch_access_blocks(report_id,task_id,reason,failure_class,blocked_by)
        select id,new.id,coalesce(nullif(btrim(new.failure_reason),''),'Unclassified task cancellation'),failure,new.completed_by
        from public.reports where cleanup_task_id=new.id and cluster_id is null
          and status::text not in ('resolved','completed','closed','rejected')
        on conflict do nothing;
    else
      update public.clusters set status='prioritized' where id in (select cluster_id from public.reports where cleanup_task_id=new.id);
    end if;
  else
    for target in select distinct cluster_id from public.reports where cleanup_task_id=new.id and cluster_id is not null loop
      update public.clusters set status=(case when exists(select 1 from public.reports where cluster_id=target
        and status::text not in ('resolved','completed','closed','rejected')) then 'prioritized' else 'resolved' end)::public.cluster_status where id=target;
    end loop;
  end if;
  update public.reports set cleanup_task_id=null,
    status=(case when status::text='in_progress' then 'unresolved' else status::text end)::public.report_status,updated_at=now()
    where cleanup_task_id=new.id;
  insert into public.sweeper_audit_log(event_type,entity_type,entity_id,user_id,event_data)
    values('TASK_REPORTS_RELEASED','TASK',new.id::text,coalesce(new.completed_by::text,'system'),
      jsonb_build_object('status',new.status,'failure_class',new.failure_class,'reason',new.failure_reason));
  return new;
end; $function$;
ALTER FUNCTION "workflow_private"."release_finished_task"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.set_task_photo(task_id uuid, actor uuid, slot text, url text, photo_hash text, expected_version bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare task public.cleanup_tasks;
BEGIN PERFORM operational_private.set_context(actor);
  select * into task from public.cleanup_tasks where id=task_id for update;
  if not found or not workflow_private.can_execute_task(actor,task) then raise exception 'Task access denied' using errcode='42501'; end if;
  if slot is null or slot not in ('before','after') then raise exception 'Invalid photo slot'; end if;
  if task.status::text in ('completed','cancelled') or expected_version is distinct from task.fc_version then
    return jsonb_build_object('status','conflict','server_record',to_jsonb(task));
  end if;
  update public.cleanup_tasks set before_photo_url=case when slot='before' then url else before_photo_url end,
    after_photo_url=case when slot='after' then url else after_photo_url end,
    before_photo_hash=case when slot='before' then photo_hash else before_photo_hash end,
    after_photo_hash=case when slot='after' then photo_hash else after_photo_hash end,
    status=case when slot='before' and url is not null then 'in_progress'::public.cleanup_task_status else status end,
    fc_version=fc_version+1 where id=task_id returning * into task;
  return jsonb_build_object('status','success','server_record',to_jsonb(task));
end; $function$;
ALTER FUNCTION "public"."set_task_photo"(task_id uuid, actor uuid, slot text, url text, photo_hash text, expected_version bigint) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.prevent_audit_modification()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF TG_OP = 'DELETE' AND current_setting('app.allow_audit_archive', true) = 'true' THEN
    RETURN OLD;
  END IF;

  RAISE EXCEPTION 'Audit records are immutable and cannot be updated or deleted. Table: %, Operation: %', TG_TABLE_NAME, TG_OP
    USING ERRCODE = 'integrity_constraint_violation';
END;
$function$;
ALTER FUNCTION "public"."prevent_audit_modification"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION privacy_private.capture_hidden_report_references()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE t record;
BEGIN
 IF OLD.hide_identity THEN
  FOR t IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname='public' AND c.relkind='r' AND c.relname IN ('audit_logs','manual_review_queue','notifications','evidences','strikes','fc_conflict_audit')
    AND EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid=c.oid AND attname='report_id' AND NOT attisdropped)
    AND EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid=c.oid AND attname='id' AND atttypid='uuid'::regtype AND NOT attisdropped) LOOP
   EXECUTE format('INSERT INTO privacy_private.hidden_report_artifacts SELECT id,$1 FROM public.%I WHERE report_id=$1 ON CONFLICT DO NOTHING',t.relname) USING OLD.id;
  END LOOP;
 END IF;
 RETURN OLD;
END $function$;
ALTER FUNCTION "privacy_private"."capture_hidden_report_references"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.enqueue_plan_generation(actor uuid, plan_mode text, settings jsonb, request_key text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare job public.plan_generation_jobs;
begin
  perform workflow_private.require_desk_actor(actor);
  if plan_mode not in ('standard','sweeper','mixed') or jsonb_typeof(settings) is distinct from 'object'
     or length(coalesce(request_key,''))>120 then raise exception 'Invalid plan generation request'; end if;
  if request_key is null then
    insert into public.plan_generation_jobs(requested_by,mode,settings_snapshot)
      values(actor,plan_mode,settings) returning * into job;
  else
    insert into public.plan_generation_jobs(requested_by,mode,settings_snapshot,idempotency_key)
      values(actor,plan_mode,settings,request_key)
      on conflict(requested_by,idempotency_key) where idempotency_key is not null
      do update set idempotency_key=excluded.idempotency_key returning * into job;
    if job.mode<>plan_mode or job.settings_snapshot<>settings then
      raise exception 'Idempotency key already used for a different request';
    end if;
  end if;
  return jsonb_build_object('jobId',job.id,'status',job.status,'planId',job.plan_id);
end; $function$;
ALTER FUNCTION "public"."enqueue_plan_generation"(actor uuid, plan_mode text, settings jsonb, request_key text) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.claim_plan_generation(worker_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
  RETURN public.claim_plan_generation(worker_id, 'production');
END;
$function$;
ALTER FUNCTION "public"."claim_plan_generation"(worker_id uuid) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.commit_mixed_dispatch_plan(plan_id uuid, actor uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE plan public.dispatch_plans; anchor public.dispatch_plan_items; satellite public.dispatch_plan_items;
  crew public.field_crews; task public.cleanup_tasks; result jsonb; results jsonb:='[]'::jsonb;
  mandatory_ids uuid[]; satellite_ids uuid[]; locked_ids uuid[]; cluster_ids uuid[];
  omitted_ids uuid[]; member_count integer; claimed integer; reason text;
  group_minutes numeric; group_volume numeric; group_weight numeric; busy_minutes numeric; busy_count integer;
  busy_volume numeric; busy_weight numeric; budget numeric; shift_minutes numeric;
  crew_max_vol numeric; crew_max_wt numeric; crew_start_vol numeric; crew_start_wt numeric;
BEGIN
  PERFORM workflow_private.require_desk_actor(actor);
  SELECT * INTO plan FROM public.dispatch_plans WHERE id=plan_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Plan not found'; END IF;
  IF plan.mode<>'mixed' THEN RAISE EXCEPTION 'Mixed plan required'; END IF;
  IF plan.status::text='discarded' THEN RAISE EXCEPTION 'Plan discarded'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.plan_generation_jobs j WHERE j.id=plan.generation_job_id
      AND j.status='completed' AND j.plan_id=plan.id) THEN RAISE EXCEPTION 'Planning job is incomplete'; END IF;
  IF jsonb_typeof(plan.route_proposal->'routes') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Validated route proposal required'; END IF;
  PERFORM id FROM public.field_crews WHERE id IN
    (SELECT planned_crew_id FROM public.dispatch_plan_items WHERE dispatch_plan_id=plan_id AND is_selected)
    ORDER BY id FOR UPDATE;
  FOR anchor IN SELECT DISTINCT ON (group_key) * FROM public.dispatch_plan_items
      WHERE dispatch_plan_id=plan_id AND is_selected AND item_type IN ('cluster','report')
      ORDER BY group_key,id LOOP
    SELECT c.result INTO result FROM public.dispatch_group_commits c
      WHERE c.dispatch_plan_id=plan_id AND c.group_key=anchor.group_key;
    IF FOUND THEN results:=results||jsonb_build_array(result); CONTINUE; END IF;
    reason:=null;
    BEGIN
      SELECT * INTO crew FROM public.field_crews WHERE id=anchor.planned_crew_id FOR UPDATE;
      IF NOT FOUND OR crew.availability_status::text<>'available'
        OR (anchor.item_type='cluster' AND NOT crew.supports_standard)
        OR (anchor.item_type='report' AND NOT crew.supports_sweeper) THEN RAISE EXCEPTION 'crew_unavailable'; END IF;
      IF coalesce(cardinality(crew.member_profile_ids),0)=0 AND crew.team_lead_profile_id IS NULL THEN
        RAISE EXCEPTION 'crew_has_no_members'; END IF;
      IF (anchor.crew_snapshot->>'speed_factor')::numeric IS DISTINCT FROM crew.speed_factor
        OR (anchor.crew_snapshot->>'service_time_factor')::numeric IS DISTINCT FROM crew.service_time_factor THEN
        RAISE EXCEPTION 'crew_timing_changed'; END IF;

      -- Resilient crew capacity defaults by vehicle archetype
      crew_max_vol := coalesce(crew.max_volume_m3,
        CASE crew.vehicle_type::text
          WHEN 'compactor' THEN 15.0
          WHEN 'pickup' THEN 4.0
          WHEN 'tricycle' THEN 1.5
          WHEN 'motorcycle' THEN 0.3
          WHEN 'bicycle' THEN 0.15
          WHEN 'walking' THEN 0.08
          ELSE 5.0
        END);
      crew_max_wt := coalesce(crew.max_weight_kg,
        CASE crew.vehicle_type::text
          WHEN 'compactor' THEN 5000.0
          WHEN 'pickup' THEN 1200.0
          WHEN 'tricycle' THEN 350.0
          WHEN 'motorcycle' THEN 60.0
          WHEN 'bicycle' THEN 30.0
          WHEN 'walking' THEN 15.0
          ELSE 1000.0
        END);
      crew_start_vol := coalesce(crew.starting_volume_m3, 0.0);
      crew_start_wt := coalesce(crew.starting_weight_kg, 0.0);

      cluster_ids:=CASE WHEN anchor.item_type='cluster' THEN
        coalesce(nullif(anchor.cluster_ids,'{}'::uuid[]),array[anchor.cluster_id]) ELSE '{}'::uuid[] END;
      IF anchor.item_type='cluster' THEN
        SELECT count(*) INTO member_count FROM (
          SELECT c.id FROM public.clusters c WHERE c.id=ANY(cluster_ids)
            AND c.status::text IN ('new','unresolved','prioritized','queued','monitoring')
            AND NOT EXISTS(SELECT 1 FROM public.dispatch_access_blocks b WHERE b.cluster_id=c.id AND b.cleared_at IS NULL)
            ORDER BY c.id FOR UPDATE SKIP LOCKED
        ) locked_clusters;
        IF member_count<>cardinality(cluster_ids) THEN RAISE EXCEPTION 'stale_anchor'; END IF;
        IF EXISTS(SELECT 1 FROM public.reports r WHERE r.cluster_id=ANY(cluster_ids)
          AND r.cleanup_task_id IS NULL AND r.status::text NOT IN ('resolved','completed','closed','rejected')
          AND NOT(r.id=ANY(anchor.report_ids))) THEN RAISE EXCEPTION 'anchor_membership_changed'; END IF;
      END IF;
      SELECT coalesce(array_agg(r.id ORDER BY r.id),'{}'::uuid[]) INTO mandatory_ids FROM (
        SELECT id FROM public.reports r WHERE id=ANY(anchor.report_ids) AND cleanup_task_id IS NULL
          AND status::text NOT IN ('resolved','completed','closed','rejected')
          AND ((anchor.item_type='cluster' AND cluster_id=ANY(cluster_ids))
             OR (anchor.item_type='report' AND cluster_id IS NULL AND lifecycle_state IN ('maturing','sla_breached')))
          AND NOT EXISTS(SELECT 1 FROM public.dispatch_access_blocks b WHERE b.report_id=r.id AND b.cleared_at IS NULL)
          ORDER BY id FOR UPDATE SKIP LOCKED
      ) r;
      IF cardinality(mandatory_ids)<>cardinality(anchor.report_ids) THEN RAISE EXCEPTION 'stale_anchor'; END IF;
      satellite_ids:='{}'::uuid[]; omitted_ids:='{}'::uuid[];
      FOR satellite IN SELECT * FROM public.dispatch_plan_items
        WHERE dispatch_plan_id=plan_id AND group_key=anchor.group_key AND item_type='bundled_report' AND is_selected
        ORDER BY bundle_order,id LOOP
        IF satellite.planned_crew_id IS DISTINCT FROM crew.id THEN RAISE EXCEPTION 'crew_assignment_changed'; END IF;
        SELECT array_agg(r.id) INTO locked_ids FROM (
          SELECT id FROM public.reports r WHERE r.id=satellite.report_id AND r.cleanup_task_id IS NULL
            AND r.cluster_id IS NULL AND r.lifecycle_state IN ('maturing','sla_breached')
            AND r.status::text='unresolved'
            AND NOT EXISTS(SELECT 1 FROM public.dispatch_access_blocks b WHERE b.report_id=r.id AND b.cleared_at IS NULL)
            FOR UPDATE SKIP LOCKED
        ) r;
        IF locked_ids IS NULL THEN
          omitted_ids:=array_append(omitted_ids,satellite.report_id);
          UPDATE public.dispatch_plan_items SET commit_disposition='omitted',commit_reason='satellite_unavailable'
            WHERE id=satellite.id;
        ELSE
          satellite_ids:=array_append(satellite_ids,satellite.report_id);
        END IF;
      END LOOP;
      group_minutes:=coalesce(anchor.estimated_duration_minutes,60)+coalesce((SELECT sum(coalesce(i.estimated_duration_minutes,30))
        FROM public.dispatch_plan_items i WHERE i.dispatch_plan_id=plan_id AND i.group_key=anchor.group_key
          AND i.report_id=ANY(satellite_ids)),0);
      group_volume:=coalesce(anchor.estimated_volume_m3,0.1)+coalesce((SELECT sum(coalesce(i.estimated_volume_m3,0.05))
        FROM public.dispatch_plan_items i WHERE i.dispatch_plan_id=plan_id AND i.group_key=anchor.group_key
          AND i.report_id=ANY(satellite_ids)),0);
      group_weight:=coalesce(anchor.estimated_weight_kg,10.0)+coalesce((SELECT sum(coalesce(i.estimated_weight_kg,5.0))
        FROM public.dispatch_plan_items i WHERE i.dispatch_plan_id=plan_id AND i.group_key=anchor.group_key
          AND i.report_id=ANY(satellite_ids)),0);

      SELECT coalesce(sum(coalesce(estimated_duration_min,60)),0),count(*),
        coalesce(sum(coalesce(estimated_volume_m3,0.1)),0),coalesce(sum(coalesce(estimated_weight_kg,10.0)),0)
        INTO busy_minutes,busy_count,busy_volume,busy_weight FROM public.cleanup_tasks
        WHERE assigned_field_crew_id=crew.id AND status::text NOT IN ('completed','cancelled');

      shift_minutes:=extract(epoch from(crew.shift_end-crew.shift_start))/60;
      IF shift_minutes<0 THEN shift_minutes:=shift_minutes+1440; END IF;
      budget:=greatest(0,(shift_minutes-coalesce((plan.settings_snapshot->>'break_duration_min')::numeric,60)
        +coalesce((plan.settings_snapshot->>'overtime_tolerance_min')::numeric,15))
        *coalesce((plan.settings_snapshot->>'capacity_utilization')::numeric,1));
      IF busy_minutes+group_minutes>budget OR busy_count>=least(coalesce(crew.max_tasks_per_shift,10),
        coalesce((plan.settings_snapshot->>'max_tasks_per_shift')::integer,15)) THEN
        RAISE EXCEPTION 'crew_capacity_changed'; END IF;
      IF crew_start_vol+busy_volume+group_volume>crew_max_vol THEN RAISE EXCEPTION 'capacity_volume'; END IF;
      IF crew_start_wt+busy_weight+group_weight>crew_max_wt THEN RAISE EXCEPTION 'capacity_weight'; END IF;
      INSERT INTO public.cleanup_tasks(cluster_id,cluster_ids,report_ids,report_sequence,satellite_report_ids,
        title,status,task_type,estimated_duration_min,estimated_work_minutes,created_by,source_plan_id,
        source_group_key,assigned_field_crew_id,dispatch_kind,route_status,routing_deadline_at,
        scheduled_date,location,priority_score,estimated_volume_m3,estimated_weight_kg)
      VALUES(anchor.cluster_id,cluster_ids,mandatory_ids||satellite_ids,mandatory_ids||satellite_ids,satellite_ids,
        CASE WHEN anchor.item_type='cluster' THEN 'Mixed cluster cleanup' ELSE 'Sweeper pickup' END,
        'pending',CASE WHEN anchor.item_type='cluster' THEN 'Mixed'::public.cleanup_task_type ELSE 'Sweeper'::public.cleanup_task_type END,
        ceil(group_minutes),anchor.estimated_work_minutes+coalesce((SELECT sum(coalesce(i.estimated_work_minutes,30))
          FROM public.dispatch_plan_items i WHERE i.dispatch_plan_id=plan_id AND i.group_key=anchor.group_key
            AND i.report_id=ANY(satellite_ids)),0),actor,plan_id,anchor.group_key,crew.id,'mixed',
        'needs_replan',now()+interval '30 minutes',plan.planned_date,
        (SELECT location FROM public.reports WHERE id=mandatory_ids[1]),
        anchor.priority_score,group_volume,group_weight) RETURNING * INTO task;
      UPDATE public.reports SET cleanup_task_id=task.id,updated_at=now()
        WHERE id=ANY(mandatory_ids||satellite_ids) AND cleanup_task_id IS NULL;
      GET DIAGNOSTICS claimed=row_count;
      IF claimed<>cardinality(mandatory_ids)+cardinality(satellite_ids) THEN RAISE EXCEPTION 'stale_group'; END IF;
      UPDATE public.clusters SET status='scheduled' WHERE id=ANY(cluster_ids);
      UPDATE public.dispatch_plan_items SET commit_disposition='included',committed_task_id=task.id
        WHERE dispatch_plan_id=plan_id AND group_key=anchor.group_key AND is_selected
          AND (item_type<>'bundled_report' OR report_id=ANY(satellite_ids));
      result:=jsonb_build_object('status',CASE WHEN cardinality(omitted_ids)>0 THEN 'partial_commit' ELSE 'committed' END,
        'group_key',anchor.group_key,'task_id',task.id,'crew_id',crew.id,
        'report_ids',mandatory_ids||satellite_ids,'satellite_report_ids',satellite_ids,'omitted_satellite_ids',omitted_ids);
    EXCEPTION WHEN raise_exception THEN
      GET STACKED DIAGNOSTICS reason=message_text;
      IF reason NOT IN ('crew_unavailable','crew_has_no_members','crew_timing_changed','unknown_load',
        'stale_anchor','anchor_membership_changed','crew_assignment_changed','crew_capacity_changed',
        'capacity_volume','capacity_weight','stale_group','dispatch_blocked') THEN RAISE; END IF;
      result:=jsonb_build_object('status','skipped','group_key',anchor.group_key,'reason',reason);
    END;
    INSERT INTO public.dispatch_group_commits(dispatch_plan_id,group_key,result)
      VALUES(plan_id,anchor.group_key,result);
    results:=results||jsonb_build_array(result);
  END LOOP;
  UPDATE public.dispatch_plans SET status='approved' WHERE id=plan_id;
  RETURN jsonb_build_object('plan_id',plan_id,'results',results,'tasks',
    coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.cleanup_tasks t WHERE t.source_plan_id=plan_id),'[]'::jsonb));
END; $function$;
ALTER FUNCTION "public"."commit_mixed_dispatch_plan"(plan_id uuid, actor uuid) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.finish_plan_generation(job_id uuid, worker_id uuid, result_plan_id uuid, failure_code text DEFAULT NULL::text, diagnostics jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare job public.plan_generation_jobs;
begin
  select * into job from public.plan_generation_jobs where id=job_id for update;
  if not found or job.status<>'running' or job.worker_token is distinct from worker_id
    or job.lease_until<now() then raise exception 'Planning job lease expired'; end if;
  if (result_plan_id is null)=(failure_code is null) then raise exception 'Exactly one plan or failure is required'; end if;
  if result_plan_id is not null then
    perform id from public.dispatch_plans where id=result_plan_id and generation_job_id=job_id
      and status='draft' for update;
    if not found then raise exception 'Planning draft is missing or not owned by job'; end if;
  end if;
  update public.plan_generation_jobs set status=case when result_plan_id is null then 'failed' else 'completed' end,
    plan_id=result_plan_id,error_code=left(failure_code,200),finished_at=now(),lease_until=null,
    solver_diagnostics=coalesce(diagnostics,'{}'::jsonb)
    where id=job_id returning * into job;
  return to_jsonb(job);
end; $function$;
ALTER FUNCTION "public"."finish_plan_generation"(job_id uuid, worker_id uuid, result_plan_id uuid, failure_code text, diagnostics jsonb) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION workflow_private.require_completed_plan_job()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare generation_id uuid;
begin
  if new.source_plan_id is null then return new; end if;
  select generation_job_id into generation_id from public.dispatch_plans where id=new.source_plan_id;
  if generation_id is not null and not exists(select 1 from public.plan_generation_jobs
    where id=generation_id and status='completed' and plan_id=new.source_plan_id) then
    raise exception 'Planning job has not completed';
  end if;
  return new;
end; $function$;
ALTER FUNCTION "workflow_private"."require_completed_plan_job"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION storage_authority.can_upload_cleanup_object(bucket text, object_path text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE actor uuid := auth.uid(); actor_role text; entity uuid;
BEGIN
  IF actor IS NULL OR bucket IS NULL OR bucket NOT IN ('Cleanup Task Photos','Report Cleanup')
     OR object_path IS NULL OR length(object_path)>180
     OR object_path !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/(before|after)/[a-zA-Z0-9._-]{1,128}$'
     OR split_part(object_path,'/',3) IN ('.','..') THEN RETURN false; END IF;
  SELECT p.role::text INTO actor_role FROM public.profiles p WHERE p.id=actor;
  IF actor_role IS NULL OR actor_role NOT IN ('field_crew','officer','admin') THEN RETURN false; END IF;
  entity := split_part(object_path,'/',1)::uuid;
  IF bucket='Cleanup Task Photos' THEN
    RETURN EXISTS (SELECT 1 FROM public.cleanup_tasks t WHERE t.id=entity
      AND (actor_role IN ('officer','admin') OR
        (actor=ANY(t.assigned_crew_ids) AND t.route_status='ready'
         AND t.status::text IN ('created','pending','in_progress','partially_completed'))));
  END IF;
  RETURN EXISTS (SELECT 1 FROM public.reports r JOIN public.cleanup_tasks t ON t.id=r.cleanup_task_id
    WHERE r.id=entity AND (actor_role IN ('officer','admin') OR
      (actor=ANY(t.assigned_crew_ids) AND t.route_status='ready'
       AND t.status::text IN ('created','pending','in_progress','partially_completed'))));
END;
$function$;
ALTER FUNCTION "storage_authority"."can_upload_cleanup_object"(bucket text, object_path text) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.issue_email_verification(p_user_id uuid, p_token_digest text, p_ttl_hours integer DEFAULT 24)
 RETURNS uuid
 LANGUAGE sql
 SET search_path TO ''
AS $function$
  SELECT public.issue_email_verification(p_user_id, p_token_digest, p_ttl_hours, NULL::text);
$function$;
ALTER FUNCTION "public"."issue_email_verification"(p_user_id uuid, p_token_digest text, p_ttl_hours integer) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.save_mixed_dispatch_draft(actor uuid, job_id uuid, worker_id uuid, settings jsonb, items jsonb, proposal jsonb, capacity jsonb, rejected jsonb, diagnostics jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare plan public.dispatch_plans; job public.plan_generation_jobs; item jsonb; ids uuid[]; seen uuid[]:='{}';
begin
  perform workflow_private.require_desk_actor(actor);
  select * into job from public.plan_generation_jobs where id=job_id for update;
  if not found or job.requested_by<>actor or job.mode<>'mixed' or job.status<>'running'
    or job.worker_token is distinct from worker_id or job.lease_until<now() then
    raise exception 'Planning job lease expired';
  end if;
  if jsonb_typeof(settings) is distinct from 'object' or jsonb_typeof(items) is distinct from 'array'
     or jsonb_array_length(items)>400 or jsonb_typeof(proposal) is distinct from 'object'
     or jsonb_typeof(proposal->'routes') is distinct from 'array'
     or jsonb_typeof(rejected) is distinct from 'array' then raise exception 'Invalid Mixed draft'; end if;
  insert into public.dispatch_plans(created_by,mode,settings_snapshot,total_crews_available,total_capacity_minutes,
    capacity_breakdown,route_proposal,rejected_bundles,solver_diagnostics,planning_as_of,generation_job_id,status)
  values(actor,'mixed',settings,coalesce((capacity->>'availableCrews')::integer,0),
    coalesce((capacity->>'totalMinutes')::integer,0),coalesce(capacity,'{}'::jsonb),proposal,rejected,
    coalesce(diagnostics,'{}'::jsonb),now(),job_id,'draft') returning * into plan;
  for item in select value from jsonb_array_elements(items) loop
    select coalesce(array_agg(value::uuid),'{}'::uuid[]) into ids from jsonb_array_elements_text(item->'report_ids');
    if cardinality(ids)=0 or cardinality(ids)<>(select count(distinct x) from unnest(ids) x)
      or ids && seen then raise exception 'Duplicate or empty report snapshot'; end if;
    seen:=seen||ids;
    if item->>'item_type' not in ('cluster','report','bundled_report')
      or (item->>'is_selected')::boolean and (item->>'planned_crew_id') is null then
      raise exception 'Invalid Mixed item'; end if;
    if item->>'item_type'='bundled_report' and ids<>array[(item->>'report_id')::uuid] then
      raise exception 'Satellite snapshot must match report target'; end if;
    insert into public.dispatch_plan_items(dispatch_plan_id,cluster_id,cluster_ids,report_id,anchor_cluster_id,
      report_ids,item_type,group_key,planned_crew_id,is_selected,reason,estimated_duration_minutes,
      estimated_work_minutes,priority_score,crew_snapshot,bundle_order,detour_minutes,
      estimated_volume_m3,estimated_weight_kg,load_snapshot)
    values(plan.id,(item->>'cluster_id')::uuid,
      coalesce((select array_agg(value::uuid) from jsonb_array_elements_text(coalesce(item->'cluster_ids','[]'::jsonb))),'{}'::uuid[]),
      (item->>'report_id')::uuid,(item->>'anchor_cluster_id')::uuid,ids,item->>'item_type',item->>'group_key',
      (item->>'planned_crew_id')::uuid,(item->>'is_selected')::boolean,item->>'reason',
      (item->>'estimated_duration_minutes')::integer,(item->>'estimated_work_minutes')::integer,
      (item->>'priority_score')::numeric,coalesce(item->'crew_snapshot','{}'::jsonb),
      (item->>'bundle_order')::smallint,(item->>'detour_minutes')::numeric,
      (item->>'estimated_volume_m3')::numeric,(item->>'estimated_weight_kg')::numeric,item->'load_snapshot');
  end loop;
  return to_jsonb(plan);
end; $function$;
ALTER FUNCTION "public"."save_mixed_dispatch_draft"(actor uuid, job_id uuid, worker_id uuid, settings jsonb, items jsonb, proposal jsonb, capacity jsonb, rejected jsonb, diagnostics jsonb) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.record_field_load(actor uuid, operation_id text, payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  prior public.fc_operation_log;
  task public.cleanup_tasks;
  crew public.field_crews;
  event public.field_load_events;
  result jsonb;
  v_task_id uuid;
  v_type text;
  v_volume numeric;
  v_weight numeric;
  v_fill numeric;
  v_observed timestamptz;
begin
  if operation_id is null or length(operation_id) not between 1 and 200
    or jsonb_typeof(payload) is distinct from 'object' then
    raise exception 'Invalid load event' using errcode='22023';
  end if;
  v_task_id := (payload->>'task_id')::uuid;
  v_type := payload->>'event_type';
  v_volume := nullif(payload->>'actual_volume_m3','')::numeric;
  v_weight := nullif(payload->>'actual_weight_kg','')::numeric;
  v_fill := nullif(payload->>'fill_percent','')::numeric;
  v_observed := (payload->>'observed_at')::timestamptz;
  if v_task_id is null or v_type is null or v_type not in ('load_observation','disposal') or v_observed is null
    or v_observed > now() + interval '5 minutes' or
    (v_type='load_observation' and v_volume is null and v_weight is null and v_fill is null)
    or coalesce(v_volume,0)<0 or coalesce(v_weight,0)<0 or coalesce(v_fill,0)<0 or coalesce(v_fill,0)>100 then
    raise exception 'Load event needs a valid measurement and time' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(operation_id,72631009));
  select * into prior from public.fc_operation_log l where l.operation_id=record_field_load.operation_id;
  if found then
    if prior.user_id<>actor or prior.entity_id<>v_task_id::text or prior.operation_type::text<>'fc.load.record' then
      raise exception 'Operation ID belongs to another request' using errcode='42501';
    end if;
    return prior.result || jsonb_build_object('replayed',true);
  end if;
  select * into task from public.cleanup_tasks where id=v_task_id for update;
  if not found or task.assignment_generation is distinct from (payload->>'assignment_generation')::bigint
    or task.assigned_field_crew_id is null or task.status::text in ('completed','cancelled')
    or not workflow_private.can_execute_task(actor,task) then
    result:=jsonb_build_object('operation_id',operation_id,'status','rejected',
      'error_message','Task assignment is no longer active','server_record',to_jsonb(task));
    insert into public.fc_operation_log(operation_id,user_id,operation_type,entity_id,entity_type,status,result,expires_at)
      values(operation_id,actor,'fc.load.record',v_task_id::text,'task','rejected',result,'infinity');
    return result;
  end if;
  select * into crew from public.field_crews where id=task.assigned_field_crew_id for update;
  if not found then raise exception 'Assigned vehicle not found' using errcode='P0002'; end if;
  if v_type='disposal' then
    v_volume:=0; v_weight:=0; v_fill:=0;
  end if;
  insert into public.field_load_events
    (operation_id,task_id,field_crew_id,actor_id,assignment_generation,event_type,
     fill_percent,actual_volume_m3,actual_weight_kg,observed_at,notes)
    values(operation_id,v_task_id,crew.id,actor,task.assignment_generation,v_type,
      v_fill,v_volume,v_weight,v_observed,coalesce(payload->>'notes',''))
    returning * into event;
  update public.field_crews set
    starting_volume_m3=case when v_volume is not null then least(v_volume,coalesce(max_volume_m3,v_volume))
      when v_fill is not null and max_volume_m3 is not null then max_volume_m3*v_fill/100
      else starting_volume_m3 end,
    starting_weight_kg=case when v_weight is not null then least(v_weight,coalesce(max_weight_kg,v_weight))
      else starting_weight_kg end,
    load_measured_at=now()
    where id=crew.id;
  result:=jsonb_build_object('operation_id',operation_id,'status','applied',
    'server_record',to_jsonb(task),'load_event_id',event.id);
  insert into public.fc_operation_log(operation_id,user_id,operation_type,entity_id,entity_type,status,result,expires_at)
    values(operation_id,actor,'fc.load.record',v_task_id::text,'task','applied',result,'infinity');
  return result;
end;
$function$;
ALTER FUNCTION "public"."record_field_load"(actor uuid, operation_id text, payload jsonb) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.submit_field_failure(actor uuid, operation_id text, payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  prior public.fc_operation_log;
  task public.cleanup_tasks;
  result jsonb;
  v_task_id uuid;
  v_reason text;
  v_class text;
  v_observed timestamptz;
begin
  if operation_id is null or length(operation_id) not between 1 and 200
    or jsonb_typeof(payload) is distinct from 'object'
    or jsonb_typeof(payload->'evidence_refs') is distinct from 'array'
    or jsonb_array_length(payload->'evidence_refs')=0
    or nullif(btrim(payload->>'notes'),'') is null then
    raise exception 'Failure reason, notes and photo evidence are required' using errcode='22023';
  end if;
  if exists(select 1 from jsonb_array_elements_text(payload->'evidence_refs') e(ref)
    where e.ref !~ '^https://[^[:space:]]+$') then
    raise exception 'Failure photo must be uploaded first' using errcode='22023';
  end if;
  v_task_id := (payload->>'task_id')::uuid;
  v_reason := payload->>'reason_code';
  v_observed := (payload->>'observed_at')::timestamptz;
  v_class := case v_reason when 'site_inaccessible' then 'site'
    when 'safety_hazard' then 'safety'
    when 'vehicle_failure' then 'transient'
    when 'crew_unavailable' then 'transient' else null end;
  if v_task_id is null or v_class is null or v_observed is null
    or v_observed > now() + interval '5 minutes' then
    raise exception 'Invalid failure receipt' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(operation_id,72631009));
  select * into prior from public.fc_operation_log l where l.operation_id=submit_field_failure.operation_id;
  if found then
    if prior.user_id<>actor or prior.entity_id<>v_task_id::text or prior.operation_type::text<>'fc.task.failure' then
      raise exception 'Operation ID belongs to another request' using errcode='42501';
    end if;
    return prior.result || jsonb_build_object('replayed',true);
  end if;
  select * into task from public.cleanup_tasks where id=v_task_id for update;
  if not found or task.assignment_generation is distinct from (payload->>'assignment_generation')::bigint
    or task.status::text in ('completed','cancelled') or not workflow_private.can_execute_task(actor,task) then
    result:=jsonb_build_object('operation_id',operation_id,'status','rejected',
      'error_message','Task assignment is no longer active','server_record',to_jsonb(task));
    insert into public.fc_operation_log(operation_id,user_id,operation_type,entity_id,entity_type,status,result,expires_at)
      values(operation_id,actor,'fc.task.failure',v_task_id::text,'task','rejected',result,'infinity');
    return result;
  end if;
  result:=public.submit_task_outcome(v_task_id,actor,'unable_to_complete',
    concat(v_reason,': ',payload->>'notes'),v_class,null,operation_id);
  insert into public.field_task_failure_events
    (operation_id,task_id,actor_id,assignment_generation,reason_code,failure_class,evidence_refs,notes,observed_at)
    values(operation_id,v_task_id,actor,task.assignment_generation,v_reason,v_class,
      payload->'evidence_refs',payload->>'notes',v_observed);
  result:=jsonb_build_object('operation_id',operation_id,'status','applied',
    'server_record',result->'server_record');
  insert into public.fc_operation_log(operation_id,user_id,operation_type,entity_id,entity_type,status,result,expires_at)
    values(operation_id,actor,'fc.task.failure',v_task_id::text,'task','applied',result,'infinity');
  return result;
end;
$function$;
ALTER FUNCTION "public"."submit_field_failure"(actor uuid, operation_id text, payload jsonb) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.activate_report_lifecycle(high_maturation_hours numeric, normal_maturation_hours numeric DEFAULT 24)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  -- Deprecated: One-time activation script already completed and stored in workflow_private.lifecycle_deployment
  RETURN jsonb_build_object(
    'status', 'already_activated',
    'message', 'Lifecycle activation has already been applied.'
  );
END;
$function$;
ALTER FUNCTION "public"."activate_report_lifecycle"(high_maturation_hours numeric, normal_maturation_hours numeric) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.set_report_before_photo(report_id uuid, actor uuid, photo_key text, url text, photo_hash text, expected_version bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare claim uuid; task public.cleanup_tasks; report public.reports; photos jsonb; prior jsonb;
BEGIN PERFORM operational_private.set_context(actor);
  if nullif(photo_key,'') is null or length(photo_key)>80 or expected_version is null or expected_version<0 then
    raise exception 'Invalid before photo request' using errcode='22023';
  end if;
  select cleanup_task_id into claim from public.reports where id=report_id;
  if claim is null then raise exception 'Report is not assigned' using errcode='42501'; end if;
  select * into task from public.cleanup_tasks where id=claim for update;
  select * into report from public.reports where id=report_id for update;
  if not found or report.cleanup_task_id is distinct from claim or task.status::text in ('completed','cancelled')
    or not workflow_private.can_execute_task(actor,task) then
    raise exception 'Report is not assigned to this crew' using errcode='42501';
  end if;
  if report.status::text in ('resolved','completed','closed','rejected') then
    return jsonb_build_object('status','conflict','error_message','Report is terminal','server_record',to_jsonb(report));
  end if;
  photos:=report.before_photos;
  if jsonb_array_length(photos)=0 and nullif(report.before_photo_url,'') is not null then
    photos:=jsonb_build_array(jsonb_build_object('id','legacy','url',report.before_photo_url,'hash',report.before_photo_hash));
  end if;
  select p into prior from jsonb_array_elements(photos) p where p->>'id'=photo_key;
  if url is not null and prior is not null then
    if prior->>'hash' is distinct from photo_hash then raise exception 'Photo ID already used'; end if;
    return jsonb_build_object('status','success','server_record',to_jsonb(report),'photo_id',photo_key,'url',prior->>'url');
  end if;
  if report.fc_version<>expected_version then
    return jsonb_build_object('status','conflict','error_message','Report version changed','server_record',to_jsonb(report));
  end if;
  if url is null then
    select coalesce(jsonb_agg(p),'[]'::jsonb) into photos from jsonb_array_elements(photos) p where p->>'id'<>photo_key;
  else
    if jsonb_array_length(photos)>=5 then raise exception 'Maximum 5 Before photos per report'; end if;
    if exists(select 1 from jsonb_array_elements(photos) p where p->>'hash'=photo_hash) then
      raise exception 'This Before photo has already been uploaded';
    end if;
    photos:=photos||jsonb_build_array(jsonb_build_object('id',photo_key,'url',url,'hash',photo_hash));
  end if;
  update public.reports set before_photos=photos,
    before_photo_url=photos->0->>'url', before_photo_hash=photos->0->>'hash',
    updated_at=now() where id=report_id returning * into report;
  return jsonb_build_object('status','success','server_record',to_jsonb(report),
    'photo_id',photo_key,'url',url,'previous_url',prior->>'url');
end; $function$;
ALTER FUNCTION "public"."set_report_before_photo"(report_id uuid, actor uuid, photo_key text, url text, photo_hash text, expected_version bigint) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION privacy_private.identity_readable(target uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 SELECT NOT EXISTS(SELECT 1 FROM privacy_private.hidden_report_owners h WHERE (h.report_id=target OR h.report_id IN (SELECT report_id FROM privacy_private.hidden_report_artifacts WHERE record_id=target))
  AND h.owner_id IS DISTINCT FROM (SELECT auth.uid()));
$function$;
ALTER FUNCTION "privacy_private"."identity_readable"(target uuid) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION privacy_private.operational_readable(target uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 SELECT (SELECT auth.role())='service_role' OR EXISTS(
  SELECT 1 FROM public.reports r JOIN public.profiles p ON p.id=(SELECT auth.uid())
  WHERE r.id=target AND (r.user_id=p.id OR p.role::text IN ('officer','admin') OR
   (p.role::text='field_crew' AND EXISTS(SELECT 1 FROM public.cleanup_tasks t
    WHERE t.id=r.cleanup_task_id AND t.route_status='ready'
     AND t.status::text IN ('created','pending','in_progress','partially_completed')
     AND (p.id=ANY(coalesce(t.assigned_crew_ids,'{}'::uuid[])) OR EXISTS(
      SELECT 1 FROM public.field_crews f WHERE f.id=t.assigned_field_crew_id
       AND (f.team_lead_profile_id=p.id OR p.id=ANY(coalesce(f.member_profile_ids,'{}'::uuid[])))
     ))))));
$function$;
ALTER FUNCTION "privacy_private"."operational_readable"(target uuid) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION workflow_private.find_email_verification_user(p_email text)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE address text; candidates uuid[];
BEGIN
  IF p_email IS NULL OR length(p_email)>320 THEN RETURN NULL; END IF;
  address:=lower(btrim(p_email));
  IF length(address) NOT BETWEEN 3 AND 254 OR address !~ '^[^[:space:]@]+@[^[:space:]@]+$' THEN
    RETURN NULL;
  END IF;
  -- Keep equality on the indexed Auth email column; two rows prove ambiguity.
  SELECT array_agg(candidate.id) INTO candidates
  FROM (SELECT u.id FROM auth.users u WHERE u.email=address LIMIT 2) candidate;
  IF cardinality(candidates) IS DISTINCT FROM 1 THEN RETURN NULL; END IF;
  IF EXISTS(SELECT FROM public.profiles p WHERE p.id=candidates[1] AND p.is_email_verified IS DISTINCT FROM true) THEN
    RETURN candidates[1];
  END IF;
  RETURN NULL;
END $function$;
ALTER FUNCTION "workflow_private"."find_email_verification_user"(p_email text) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.find_email_verification_user(p_email text)
 RETURNS uuid
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ SELECT workflow_private.find_email_verification_user(p_email); $function$;
ALTER FUNCTION "public"."find_email_verification_user"(p_email text) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION privacy_private.capture_hidden_queue_reference()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE item jsonb; target uuid; strike uuid;
BEGIN
 item:=CASE WHEN TG_OP='INSERT' THEN to_jsonb(NEW) ELSE to_jsonb(OLD) END;
 target:=nullif(item->>'report_id','')::uuid;
 IF target IS NULL THEN SELECT report_id INTO target FROM privacy_private.hidden_report_artifacts WHERE record_id=(item->>'id')::uuid; END IF;
 IF EXISTS(SELECT 1 FROM privacy_private.hidden_report_owners WHERE report_id=target) THEN
  INSERT INTO privacy_private.hidden_report_artifacts VALUES((item->>'id')::uuid,target) ON CONFLICT DO NOTHING;
  strike:=nullif(item->>'strike_id','')::uuid;
  IF strike IS NOT NULL THEN INSERT INTO privacy_private.hidden_report_artifacts VALUES(strike,target) ON CONFLICT DO NOTHING; END IF;
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END $function$;
ALTER FUNCTION "privacy_private"."capture_hidden_queue_reference"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.get_barangay_executive_analytics(actor uuid, report_month date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE monthly jsonb; comparison jsonb;
BEGIN
 -- Existing aggregate validates desk role, month bounds and reconciled 30-barangay roster.
 monthly:=public.get_barangay_operational_analytics(actor,report_month,report_month);
 comparison:=public.get_barangay_operational_analytics(actor,greatest(date '2000-01-01',(report_month-interval '1 month')::date),report_month);
 RETURN jsonb_build_object('version','barangay-executive-v1','generated_at',monthly->'generated_at','monthly',monthly,'comparison',comparison);
END; $function$;
ALTER FUNCTION "public"."get_barangay_executive_analytics"(actor uuid, report_month date) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.read_report_identity_context(report_ids uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE result jsonb;
BEGIN
 IF report_ids IS NULL OR cardinality(report_ids)>1000 THEN RAISE EXCEPTION 'Invalid report context batch' USING ERRCODE='22023'; END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',i.id,'user_id',coalesce(h.owner_id,r.user_id),
  'hide_identity',h.report_id IS NOT NULL OR coalesce(r.hide_identity,false))),'[]'::jsonb) INTO result
 FROM (SELECT DISTINCT unnest(report_ids) AS id) i LEFT JOIN public.reports r ON r.id=i.id
 LEFT JOIN privacy_private.hidden_report_artifacts a ON a.record_id=i.id
 LEFT JOIN privacy_private.hidden_report_owners h ON h.report_id=coalesce(a.report_id,i.id) WHERE r.id IS NOT NULL OR h.report_id IS NOT NULL;
 RETURN result;
END $function$;
ALTER FUNCTION "public"."read_report_identity_context"(report_ids uuid[]) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION workflow_private.cleanup_proof_photo_urls(r reports, slot text)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
 SELECT CASE
  WHEN jsonb_array_length(s.photos)>0 THEN coalesce((SELECT jsonb_agg(e.p->>'url' ORDER BY e.ord) FROM jsonb_array_elements(s.photos) WITH ORDINALITY e(p,ord)
   WHERE e.ord<=5 AND nullif(btrim(e.p->>'url'),'') IS NOT NULL),'[]'::jsonb)
  WHEN nullif(btrim(s.single),'') IS NOT NULL THEN jsonb_build_array(s.single)
  ELSE '[]'::jsonb END
 FROM (SELECT CASE WHEN slot='before' THEN r.before_photos ELSE r.after_photos END AS photos,
              CASE WHEN slot='before' THEN r.before_photo_url ELSE r.after_photo_url END AS single) s;
$function$;
ALTER FUNCTION "workflow_private"."cleanup_proof_photo_urls"(r reports, slot text) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.get_structure_address(lat double precision, lng double precision, buffer_meters double precision DEFAULT 25.0)
 RETURNS TABLE(house_number text, street_name text, building_name text, barangay text, distance_meters double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
  SELECT
    b.house_number,
    b.street_name,
    b.building_name,
    b.barangay,
    extensions.ST_Distance(
      b.boundary::extensions.geography,
      extensions.ST_SetSRID(extensions.ST_MakePoint(lng, lat), 4326)::extensions.geography
    ) AS distance_meters
  FROM public.building_structures b
  WHERE extensions.ST_DWithin(
    b.boundary::extensions.geography,
    extensions.ST_SetSRID(extensions.ST_MakePoint(lng, lat), 4326)::extensions.geography,
    buffer_meters
  )
  ORDER BY distance_meters ASC
  LIMIT 1;
$function$;
ALTER FUNCTION "public"."get_structure_address"(lat double precision, lng double precision, buffer_meters double precision) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.redeem_email_verification_atomic(p_verification_id uuid, p_user_id uuid, p_expected_email text)
 RETURNS boolean
 LANGUAGE sql
 SET search_path TO ''
AS $function$
 SELECT verification_private.redeem_email(p_verification_id,p_user_id,p_expected_email);
$function$;
ALTER FUNCTION "public"."redeem_email_verification_atomic"(p_verification_id uuid, p_user_id uuid, p_expected_email text) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.get_report_barangay(lat double precision, lng double precision)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
 SELECT public.resolve_report_barangay(lat,lng)->>'barangay';
$function$;
ALTER FUNCTION "public"."get_report_barangay"(lat double precision, lng double precision) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.set_report_after_photo(report_id uuid, actor uuid, photo_key text, url text, photo_hash text, expected_version bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare claim uuid; task public.cleanup_tasks; report public.reports; photos jsonb; prior jsonb;
BEGIN PERFORM operational_private.set_context(actor);
  if nullif(photo_key,'') is null or length(photo_key)>80 or expected_version is null or expected_version<0 then
    raise exception 'Invalid after photo request' using errcode='22023';
  end if;
  select cleanup_task_id into claim from public.reports where id=report_id;
  if claim is null then raise exception 'Report is not assigned' using errcode='42501'; end if;
  select * into task from public.cleanup_tasks where id=claim for update;
  select * into report from public.reports where id=report_id for update;
  if not found or report.cleanup_task_id is distinct from claim or task.status::text in ('completed','cancelled')
    or not workflow_private.can_execute_task(actor,task) then
    raise exception 'Report is not assigned to this crew' using errcode='42501';
  end if;
  if report.status::text in ('resolved','completed','closed','rejected') and not (
    report.status::text = 'resolved' and nullif(url,'') is not null
  ) then
    return jsonb_build_object('status','conflict','error_message','Report is terminal','server_record',to_jsonb(report));
  end if;
  photos:=report.after_photos;
  if jsonb_array_length(photos)=0 and nullif(report.after_photo_url,'') is not null then
    photos:=jsonb_build_array(jsonb_build_object('id','legacy','url',report.after_photo_url,'hash',report.after_photo_hash));
  end if;
  select p into prior from jsonb_array_elements(photos) p where p->>'id'=photo_key;
  if url is not null and prior is not null then
    if prior->>'hash' is distinct from photo_hash then raise exception 'Photo ID already used'; end if;
    return jsonb_build_object('status','success','server_record',to_jsonb(report),'photo_id',photo_key,'url',prior->>'url');
  end if;
  if report.fc_version<>expected_version then
    return jsonb_build_object('status','conflict','error_message','Report version changed','server_record',to_jsonb(report));
  end if;
  if url is null then
    select coalesce(jsonb_agg(p),'[]'::jsonb) into photos from jsonb_array_elements(photos) p where p->>'id'<>photo_key;
  else
    if jsonb_array_length(photos)>=5 then raise exception 'Maximum 5 After photos per report'; end if;
    if exists(select 1 from jsonb_array_elements(photos) p where p->>'hash'=photo_hash) then
      raise exception 'This After photo has already been uploaded';
    end if;
    photos:=photos||jsonb_build_array(jsonb_build_object('id',photo_key,'url',url,'hash',photo_hash));
  end if;
  update public.reports set after_photos=photos,
    after_photo_url=photos->0->>'url', after_photo_hash=photos->0->>'hash',
    updated_at=now() where id=report_id returning * into report;
  return jsonb_build_object('status','success','server_record',to_jsonb(report),
    'photo_id',photo_key,'url',url,'previous_url',prior->>'url');
end; $function$;
ALTER FUNCTION "public"."set_report_after_photo"(report_id uuid, actor uuid, photo_key text, url text, photo_hash text, expected_version bigint) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.cleanup_expired_email_verifications(p_batch_limit integer DEFAULT 500)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO ''
 SET statement_timeout TO '15s'
 SET lock_timeout TO '2s'
AS $function$
DECLARE
  v_cutoff timestamptz;
  v_deleted integer := 0;
BEGIN
  IF p_batch_limit IS NULL OR p_batch_limit < 1 OR p_batch_limit > 1000 THEN
    RAISE EXCEPTION 'Batch limit must be between 1 and 1000';
  END IF;

  v_cutoff := statement_timestamp() - interval '30 days';

  WITH candidates AS (
    SELECT id
    FROM public.email_verifications
    WHERE expires_at <= v_cutoff
    ORDER BY expires_at ASC, id ASC
    LIMIT p_batch_limit
    FOR UPDATE SKIP LOCKED
  ),
  removed AS (
    DELETE FROM public.email_verifications v
    USING candidates c
    WHERE v.id = c.id
    RETURNING v.id
  )
  SELECT count(*)::integer INTO v_deleted FROM removed;

  RETURN v_deleted;
END;
$function$;
ALTER FUNCTION "public"."cleanup_expired_email_verifications"(p_batch_limit integer) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.citizen_trust_snapshot(target uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE s public.citizen_trust; t timestamptz := clock_timestamp();
BEGIN
  PERFORM public.ensure_citizen_trust(target);
  SELECT * INTO STRICT s FROM public.citizen_trust WHERE user_id=target;
  RETURN jsonb_build_object('score',s.score,'score_threshold',70,'max_score',100,
    'urgent_allowed',s.score>=70 AND (s.locked_until IS NULL OR (s.locked_until<=t AND s.recovery_streak>=3)),
    'locked_until',s.locked_until,'recovery_reports_remaining',CASE WHEN s.locked_until IS NULL THEN 0 ELSE 3-s.recovery_streak END,
    'valid_report_points',10,'false_urgency_penalty',30,'cooldown_days',7,'server_time',t);
END $function$;
ALTER FUNCTION "public"."citizen_trust_snapshot"(target uuid) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.get_field_crew_operations_summary(actor uuid, start_day date, end_day date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE first_at timestamptz; until_at timestamptz; result jsonb; size integer;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=actor AND role::text IN ('officer','admin')) THEN RAISE EXCEPTION 'Desk operations access required' USING ERRCODE='42501'; END IF;
 IF start_day IS NULL OR end_day IS NULL OR start_day<date '2000-01-01' OR end_day<start_day OR end_day-start_day>365 OR end_day>(statement_timestamp() AT TIME ZONE 'Asia/Manila')::date THEN RAISE EXCEPTION 'Choose 1-366 Manila calendar days ending no later than today' USING ERRCODE='22023'; END IF;
 first_at:=start_day::timestamp AT TIME ZONE 'Asia/Manila';until_at:=(end_day+1)::timestamp AT TIME ZONE 'Asia/Manila';
 WITH events AS MATERIALIZED (
  SELECT * FROM public.operational_events e WHERE e.time_basis='server' AND e.occurred_at>=first_at AND e.occurred_at<until_at AND e.event_type IN ('assignment','completion','verification')
 ), assignments AS (SELECT * FROM events WHERE event_type='assignment' ORDER BY id LIMIT 1001),
 completions AS (
  SELECT 'journal:'||e.id AS ref,e.task_id,e.report_id,e.actor_id,e.occurred_at FROM events e WHERE event_type='completion' AND report_id IS NULL
  UNION ALL SELECT 'task:'||t.id,t.id,NULL::uuid,t.completed_by,t.completed_at FROM public.cleanup_tasks t
   WHERE t.status::text='completed' AND t.completed_at>=first_at AND t.completed_at<until_at
    AND NOT EXISTS(SELECT 1 FROM events e WHERE e.event_type='completion' AND e.report_id IS NULL AND e.task_id=t.id AND e.occurred_at=t.completed_at)
  UNION ALL SELECT 'resolution:'||r.id,r.task_id,r.report_id,r.crew_id,r.resolved_at FROM public.report_resolution_events r WHERE r.resolved_at>=first_at AND r.resolved_at<until_at
 ), waypoint_records AS (
  SELECT DISTINCT ON(w.id) w.id AS waypoint_id,w.crew_route_id,w.sequence_order,w.waypoint_type,c.*,
   cr.crew_id,fc.name AS crew_name
  FROM completions c JOIN public.route_waypoints w ON w.cleanup_task_id=c.task_id AND w.report_id IS NOT DISTINCT FROM c.report_id
  JOIN public.crew_routes cr ON cr.id=w.crew_route_id JOIN public.optimization_runs run ON run.id=cr.optimization_run_id AND run.status::text='approved' AND run.approved_at IS NOT NULL
  LEFT JOIN public.field_crews fc ON fc.id=cr.crew_id ORDER BY w.id,c.occurred_at DESC,c.ref DESC LIMIT 1001
 ), verified AS (SELECT * FROM events WHERE event_type='verification' ORDER BY id LIMIT 1001),
 obstacles AS (
  SELECT * FROM (
   SELECT 'block:'||b.id AS ref,'access_block'::text AS source,b.task_id,b.report_id,b.blocked_by AS actor_id,
    b.blocked_at AS occurred_at,b.blocked_at AS recorded_at,b.failure_class AS kind,b.reason AS notes,
    NULL::text AS disposition,b.cleared_at,b.clearance_notes,b.cleared_by,
    (b.blocked_at>=first_at OR (b.cleared_at>=first_at AND b.cleared_at<until_at)) AS activity_in_period
   FROM public.dispatch_access_blocks b WHERE b.blocked_at<until_at AND (b.blocked_at>=first_at OR (b.cleared_at>=first_at AND b.cleared_at<until_at) OR b.cleared_at IS NULL)
   UNION ALL SELECT 'outcome:'||o.id,'outcome',o.task_id,o.report_id,o.crew_id,o.observed_at,o.submitted_at,o.outcome,o.notes,o.disposition,NULL::timestamptz,NULL::text,NULL::uuid,true
    FROM public.task_report_outcomes o WHERE o.submitted_at>=first_at AND o.submitted_at<until_at AND (o.outcome IN ('unable','skipped') OR o.disposition IN ('contested','verification_required'))
   UNION ALL SELECT 'failure:'||t.id,'task_failure',t.id,NULL::uuid,t.completed_by,t.completed_at,t.completed_at,t.failure_class,t.failure_reason,NULL::text,NULL::timestamptz,NULL::text,NULL::uuid,true
    FROM public.cleanup_tasks t WHERE nullif(btrim(t.failure_reason),'') IS NOT NULL AND t.completed_at>=first_at AND t.completed_at<until_at
  ) b ORDER BY recorded_at,ref LIMIT 1001
 ), task_scope AS (
  SELECT id FROM (
   SELECT t.id FROM public.cleanup_tasks t WHERE (t.created_at>=first_at AND t.created_at<until_at) OR (t.created_at<until_at AND coalesce(t.status::text,'unknown') NOT IN ('completed','cancelled'))
   UNION SELECT task_id FROM events UNION SELECT task_id FROM completions UNION SELECT task_id FROM obstacles
  ) q WHERE id IS NOT NULL ORDER BY id LIMIT 1001
 ), links AS (
  SELECT r.cleanup_task_id AS task_id,r.id AS report_id FROM public.reports r WHERE r.cleanup_task_id IN (SELECT id FROM task_scope)
  UNION SELECT a.task_id,a.report_id FROM public.field_assignment_receipts a WHERE a.task_id IN (SELECT id FROM task_scope)
  UNION SELECT r.task_id,r.report_id FROM public.report_resolution_events r WHERE r.task_id IN (SELECT id FROM task_scope)
  UNION SELECT b.task_id,b.report_id FROM obstacles b WHERE b.report_id IS NOT NULL
 ), owners AS MATERIALIZED (
  SELECT l.task_id,l.report_id,coalesce(h.owner_id,r.user_id) AS owner_id FROM links l LEFT JOIN public.reports r ON r.id=l.report_id LEFT JOIN privacy_private.hidden_report_owners h ON h.report_id=l.report_id
 )
 SELECT jsonb_build_object('version','crew-operations-v1','generated_at',statement_timestamp(),'timezone','Asia/Manila','start_day',start_day,'end_day',end_day,
 'tasks',coalesce((SELECT jsonb_agg(jsonb_build_object('task_id',t.id,'title',t.title,'status',t.status,'created_at',t.created_at,'completed_at',t.completed_at,
  'scheduled_date',t.scheduled_date,'assignment_generation',t.assignment_generation,'current_crew_id',t.assigned_field_crew_id,'current_crew_name',fc.name,
  'current_accounts',coalesce((SELECT jsonb_agg(CASE WHEN EXISTS(SELECT 1 FROM owners o WHERE o.task_id=t.id AND o.owner_id=x) THEN NULL ELSE to_jsonb(x) END) FROM unnest(t.assigned_crew_ids) x),'[]'::jsonb),
  'current_failure_class',t.failure_class,'current_failure_reason',t.failure_reason) ORDER BY t.created_at,t.id)
  FROM public.cleanup_tasks t LEFT JOIN public.field_crews fc ON fc.id=t.assigned_field_crew_id WHERE t.id IN (SELECT id FROM task_scope)),'[]'::jsonb),
 'assignments',coalesce((SELECT jsonb_agg(jsonb_build_object('event_ref','journal:'||e.id,'task_id',e.task_id,'occurred_at',e.occurred_at,'assignment_generation',e.assignment_generation,
  'assigned',e.details->'assigned','actor_id',CASE WHEN EXISTS(SELECT 1 FROM owners o WHERE o.task_id=e.task_id AND o.owner_id=e.actor_id) THEN NULL ELSE e.actor_id END,
  'receipt_accounts',coalesce((SELECT jsonb_agg(DISTINCT CASE WHEN EXISTS(SELECT 1 FROM owners o WHERE o.task_id=e.task_id AND o.owner_id=a.crew_id) THEN NULL ELSE to_jsonb(a.crew_id) END)
   FROM public.field_assignment_receipts a WHERE a.task_id=e.task_id AND a.assignment_generation=e.assignment_generation),'[]'::jsonb)) ORDER BY e.id) FROM assignments e),'[]'::jsonb),
 'waypoints',coalesce((SELECT jsonb_agg(jsonb_build_object('waypoint_id',w.waypoint_id,'route_id',w.crew_route_id,'sequence',w.sequence_order,'waypoint_type',w.waypoint_type,'crew_id',w.crew_id,'crew_name',w.crew_name,
  'task_id',w.task_id,'report_id',w.report_id,'completion_ref',w.ref,'completed_at',w.occurred_at,
  'actor_id',CASE WHEN EXISTS(SELECT 1 FROM owners o WHERE o.task_id=w.task_id AND o.owner_id=w.actor_id) THEN NULL ELSE w.actor_id END) ORDER BY w.crew_route_id,w.sequence_order,w.waypoint_id) FROM waypoint_records w),'[]'::jsonb),
 'verified',coalesce((SELECT jsonb_agg(jsonb_build_object('event_ref','journal:'||e.id,'task_id',e.task_id,'report_id',e.report_id,'verified_at',e.occurred_at,'assignment_generation',e.assignment_generation,
  'actor_id',CASE WHEN EXISTS(SELECT 1 FROM owners o WHERE (o.task_id=e.task_id OR o.report_id=e.report_id) AND o.owner_id=e.actor_id) THEN NULL ELSE e.actor_id END,
  'source_matches',coalesce(p.source_fingerprint=workflow_private.cleanup_proof_fingerprint(r) AND r.status::text IN ('resolved','completed','closed','waiting_for_feedback'),false)) ORDER BY e.id)
  FROM verified e LEFT JOIN public.cleanup_proof_publications p ON p.id::text=e.details->>'publication_id' AND p.report_id=e.report_id LEFT JOIN public.reports r ON r.id=e.report_id),'[]'::jsonb),
 'obstacles',coalesce((SELECT jsonb_agg(jsonb_build_object('event_ref',b.ref,'source',b.source,'task_id',b.task_id,'report_id',b.report_id,
  'actor_id',CASE WHEN EXISTS(SELECT 1 FROM owners o WHERE (o.task_id=b.task_id OR o.report_id=b.report_id) AND o.owner_id=b.actor_id) THEN NULL ELSE b.actor_id END,
  'occurred_at',b.occurred_at,'recorded_at',b.recorded_at,'kind',b.kind,'notes',b.notes,'disposition',b.disposition,'cleared_at',b.cleared_at,'cleared_by',CASE WHEN EXISTS(SELECT 1 FROM owners o WHERE (o.task_id=b.task_id OR o.report_id=b.report_id) AND o.owner_id=b.cleared_by) THEN NULL ELSE b.cleared_by END,'clearance_notes',b.clearance_notes,'activity_in_period',b.activity_in_period) ORDER BY b.recorded_at,b.ref) FROM obstacles b),'[]'::jsonb)
 ) INTO result;
 SELECT sum(jsonb_array_length(result->k)) INTO size FROM unnest(ARRAY['tasks','assignments','waypoints','verified','obstacles']) k;
 IF size>1000 THEN RAISE EXCEPTION 'Operations summary is too large; narrow the dates. No partial export was produced' USING ERRCODE='54000'; END IF;
 RETURN result;
END; $function$;
ALTER FUNCTION "public"."get_field_crew_operations_summary"(actor uuid, start_day date, end_day date) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.publish_cleanup_proof_photos(report_id uuid, actor uuid, expected_version bigint, expected_fingerprint text, before_paths jsonb, after_paths jsonb, public_notes text, expected_publication_id uuid, redactions jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE r public.reports; t public.cleanup_tasks; role_name text; proof public.cleanup_proof_publications; slot_name text; slot_paths jsonb;
BEGIN
 SELECT role::text INTO role_name FROM public.profiles WHERE id=actor;
 IF role_name IS NULL OR role_name NOT IN ('admin','officer') THEN RAISE EXCEPTION 'Officer review required' USING ERRCODE='42501'; END IF;
 SELECT * INTO r FROM public.reports WHERE id=report_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Report not found' USING ERRCODE='P0002'; END IF;
 IF r.cleanup_task_id IS NOT NULL THEN
  SELECT * INTO t FROM public.cleanup_tasks WHERE id=r.cleanup_task_id;
  IF role_name<>'admin' AND coalesce(t.created_by,t.lgu_user_id) IS NOT NULL AND
    actor IS DISTINCT FROM t.created_by AND actor IS DISTINCT FROM t.lgu_user_id THEN
   RAISE EXCEPTION 'Report belongs to another officer' USING ERRCODE='42501';
  END IF;
 END IF;
 IF r.fc_version IS DISTINCT FROM expected_version OR workflow_private.cleanup_proof_fingerprint(r) IS DISTINCT FROM expected_fingerprint THEN
  RAISE EXCEPTION 'Proof changed; reload before reviewing' USING ERRCODE='40001';
 END IF;
 SELECT * INTO proof FROM public.cleanup_proof_publications p WHERE p.report_id=publish_cleanup_proof_photos.report_id;
 IF proof.id IS DISTINCT FROM expected_publication_id THEN
  RAISE EXCEPTION 'Proof changed; reload before reviewing' USING ERRCODE='40001';
 END IF;
 PERFORM workflow_private.assert_cleanup_photo_pair(to_jsonb(r));
 IF r.status::text NOT IN ('resolved','completed','closed','waiting_for_feedback') OR r.lgu_resolved_at IS NULL THEN
  RAISE EXCEPTION 'Cleanup must have a recorded completion time before verification' USING ERRCODE='22023';
 END IF;
 IF nullif(btrim(public_notes),'') IS NULL OR length(public_notes)>2000 THEN
  RAISE EXCEPTION 'Redacted proof and public action notes are required' USING ERRCODE='22023';
 END IF;
 FOREACH slot_name IN ARRAY ARRAY['before','after'] LOOP
  slot_paths:=CASE WHEN slot_name='before' THEN before_paths ELSE after_paths END;
  IF jsonb_typeof(slot_paths) IS DISTINCT FROM 'array' OR
     jsonb_array_length(slot_paths)<>jsonb_array_length(workflow_private.cleanup_proof_photo_urls(r,slot_name)) OR
     jsonb_array_length(slot_paths)=0 OR jsonb_array_length(slot_paths)>5 OR
     EXISTS(SELECT 1 FROM jsonb_array_elements(slot_paths) e WHERE jsonb_typeof(e)<>'string' OR
      (e#>>'{}') !~ ('^'||report_id::text||'/'||slot_name||'/[a-f0-9-]+[.]jpg$')) OR
     (SELECT count(DISTINCT e#>>'{}') FROM jsonb_array_elements(slot_paths) e)<>jsonb_array_length(slot_paths) THEN
   RAISE EXCEPTION 'A redacted copy of every % photo is required',slot_name USING ERRCODE='22023';
  END IF;
 END LOOP;
 INSERT INTO public.cleanup_proof_publications(report_id,source_fingerprint,before_path,after_path,before_paths,after_paths,public_notes,redactions,completed_at,verified_by)
 VALUES(report_id,expected_fingerprint,before_paths->>0,after_paths->>0,before_paths,after_paths,btrim(public_notes),redactions,r.lgu_resolved_at,actor)
 ON CONFLICT ON CONSTRAINT cleanup_proof_publications_pkey DO UPDATE SET id=gen_random_uuid(),source_fingerprint=excluded.source_fingerprint,
  before_path=excluded.before_path,after_path=excluded.after_path,before_paths=excluded.before_paths,after_paths=excluded.after_paths,
  public_notes=excluded.public_notes,redactions=excluded.redactions,completed_at=excluded.completed_at,verified_at=now(),verified_by=actor RETURNING * INTO proof;
 RETURN to_jsonb(proof);
END; $function$;
ALTER FUNCTION "public"."publish_cleanup_proof_photos"(report_id uuid, actor uuid, expected_version bigint, expected_fingerprint text, before_paths jsonb, after_paths jsonb, public_notes text, expected_publication_id uuid, redactions jsonb) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.publish_cleanup_proof(report_id uuid, actor uuid, expected_version bigint, expected_fingerprint text, before_path text, after_path text, public_notes text, expected_publication_id uuid, redactions jsonb)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$
 SELECT public.publish_cleanup_proof_photos(report_id,actor,expected_version,expected_fingerprint,
  jsonb_build_array(before_path),jsonb_build_array(after_path),public_notes,expected_publication_id,redactions);
$function$;
ALTER FUNCTION "public"."publish_cleanup_proof"(report_id uuid, actor uuid, expected_version bigint, expected_fingerprint text, before_path text, after_path text, public_notes text, expected_publication_id uuid, redactions jsonb) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.read_cleanup_proof(report_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
 SELECT jsonb_build_object('id',p.id,'public_notes',p.public_notes,'completed_at',p.completed_at,'verified_at',p.verified_at,
  'before_path',p.before_path,'after_path',p.after_path,
  'before_paths',coalesce(p.before_paths,jsonb_build_array(p.before_path)),'after_paths',coalesce(p.after_paths,jsonb_build_array(p.after_path)))
 FROM public.cleanup_proof_publications p JOIN public.public_reports visible ON visible.id=p.report_id
 JOIN public.reports r ON r.id=p.report_id
 WHERE p.report_id=read_cleanup_proof.report_id AND p.source_fingerprint=workflow_private.cleanup_proof_fingerprint(r)
 AND r.status::text IN ('resolved','completed','closed','waiting_for_feedback');
$function$;
ALTER FUNCTION "public"."read_cleanup_proof"(report_id uuid) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION workflow_private.purge_completed_cron_job_runs(p_batch_limit integer DEFAULT 500)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
 SET statement_timeout TO '15s'
 SET lock_timeout TO '2s'
AS $function$
DECLARE
  v_cutoff timestamptz;
  v_deleted integer := 0;
BEGIN
  IF p_batch_limit IS NULL OR p_batch_limit < 1 OR p_batch_limit > 1000 THEN
    RAISE EXCEPTION 'Batch limit must be between 1 and 1000';
  END IF;

  v_cutoff := statement_timestamp() - interval '30 days';

  WITH candidates AS (
    SELECT runid
    FROM cron.job_run_details
    WHERE end_time IS NOT NULL
      AND status IN ('succeeded', 'failed')
      AND end_time <= v_cutoff
    ORDER BY end_time ASC, runid ASC
    LIMIT p_batch_limit
    FOR UPDATE SKIP LOCKED
  ),
  removed AS (
    DELETE FROM cron.job_run_details j
    USING candidates c
    WHERE j.runid = c.runid
    RETURNING j.runid
  )
  SELECT count(*)::integer INTO v_deleted FROM removed;

  RETURN v_deleted;
END;
$function$;
ALTER FUNCTION "workflow_private"."purge_completed_cron_job_runs"(p_batch_limit integer) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION workflow_private.run_retention_maintenance(p_batch_limit integer DEFAULT 500)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
 SET statement_timeout TO '30s'
 SET lock_timeout TO '2s'
AS $function$
DECLARE
  v_tokens integer := 0;
  v_runs integer := 0;
BEGIN
  IF NOT pg_catalog.pg_try_advisory_xact_lock(72631017) THEN
    RETURN jsonb_build_object('skipped', true, 'reason', 'advisory_lock_held');
  END IF;

  v_tokens := public.cleanup_expired_email_verifications(p_batch_limit);
  v_runs := workflow_private.purge_completed_cron_job_runs(p_batch_limit);

  RETURN jsonb_build_object(
    'skipped', false,
    'deleted_tokens', v_tokens,
    'deleted_cron_runs', v_runs
  );
END;
$function$;
ALTER FUNCTION "workflow_private"."run_retention_maintenance"(p_batch_limit integer) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION operational_private.capture_task_transition()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE previous text:=CASE WHEN TG_OP='UPDATE' THEN OLD.status::text END;
BEGIN
 IF TG_OP='INSERT' OR NEW.status::text IS DISTINCT FROM previous THEN
  PERFORM operational_private.emit('task_transition',NEW.id,NULL,
   nullif(current_setting('ecopin.operational_actor',true),'')::uuid,NEW.assignment_generation,
   clock_timestamp(),'server',gen_random_uuid()::text,
   jsonb_build_object('from_status',previous,'to_status',NEW.status::text));
 END IF;
 RETURN NEW;
END; $function$;
ALTER FUNCTION "operational_private"."capture_task_transition"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.read_authorized_report_evidence_ids(actor uuid, report_ids uuid[])
 RETURNS TABLE(id uuid)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
WITH requested AS MATERIALIZED (
  SELECT DISTINCT report_id AS id
  FROM unnest(report_ids) AS input(report_id)
  WHERE report_id IS NOT NULL
  LIMIT 100
)
SELECT requested.id
FROM requested
WHERE public.read_authorized_report_detail(actor, requested.id) IS NOT NULL
   OR EXISTS (
     SELECT 1 FROM public.public_reports AS report
     WHERE report.id=requested.id AND report.location_precision='exact'
   );
$function$;
ALTER FUNCTION "public"."read_authorized_report_evidence_ids"(actor uuid, report_ids uuid[]) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.mixed_planning_snapshot()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
 SELECT payload||jsonb_build_object('urgency_decisions',coalesce((
   SELECT jsonb_object_agg(r.id::text,r.urgency_decision_id::text) FROM public.reports r
   WHERE r.urgency_status='approved' AND r.urgency_decision_id IS NOT NULL AND r.id IN (
     SELECT member.value::uuid FROM jsonb_array_elements(payload->'anchors') a(value) CROSS JOIN LATERAL jsonb_array_elements_text(a.value->'report_ids') member(value)
     UNION SELECT (s.value->>'id')::uuid FROM jsonb_array_elements(payload->'satellites') s(value)
   )), '{}'::jsonb))
 FROM workflow_private.mixed_planning_snapshot() AS payload;
$function$;
ALTER FUNCTION "public"."mixed_planning_snapshot"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION workflow_private.bump_task_assignment_generation()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if tg_op = 'INSERT' then
    if new.assigned_field_crew_id is not null and (new.assigned_crew_ids is null or cardinality(new.assigned_crew_ids) = 0) then
      select array(select distinct x from unnest(coalesce(c.member_profile_ids, '{}'::uuid[]) || array_remove(array[c.team_lead_profile_id], null)) x order by x)
      into new.assigned_crew_ids
      from public.field_crews c where c.id = new.assigned_field_crew_id;
    end if;
    if new.assigned_field_crew_id is not null
       or cardinality(coalesce(new.assigned_crew_ids, '{}'::uuid[])) > 0 then
      new.assignment_generation := greatest(new.assignment_generation, 1);
    end if;
  elsif (new.assigned_field_crew_id is distinct from old.assigned_field_crew_id) then
    if new.assigned_field_crew_id is not null and (new.assigned_crew_ids is null or new.assigned_crew_ids = old.assigned_crew_ids) then
      select array(select distinct x from unnest(coalesce(c.member_profile_ids, '{}'::uuid[]) || array_remove(array[c.team_lead_profile_id], null)) x order by x)
      into new.assigned_crew_ids
      from public.field_crews c where c.id = new.assigned_field_crew_id;
    end if;
    new.assignment_generation := old.assignment_generation + 1;
  elsif new.assigned_crew_ids is distinct from old.assigned_crew_ids
     or new.crew_route_id is distinct from old.crew_route_id
     or new.route_revision is distinct from old.route_revision then
    new.assignment_generation := old.assignment_generation + 1;
  else
    new.assignment_generation := old.assignment_generation;
  end if;
  return new;
end;
$function$;
ALTER FUNCTION "workflow_private"."bump_task_assignment_generation"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.dbscan_reports(p_eps double precision, p_minpoints integer)
 RETURNS TABLE(id uuid, issue_type text, location geometry, cluster_id integer)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if p_eps is null or p_eps<=0 or p_eps>10000 or p_minpoints is null or p_minpoints<2 or p_minpoints>100 then
    raise exception 'Invalid clustering parameters';
  end if;
  return query select r.id,r.issue_type::text,r.location::extensions.geometry,
    extensions.st_clusterdbscan(extensions.st_transform(r.location::extensions.geometry,32651),eps:=p_eps,minpoints:=p_minpoints)
      over(partition by r.issue_type order by r.id)
    from public.reports r
    where r.status::text='unresolved' and r.validation_status::text='approved'
      and r.cluster_id is null and r.cleanup_task_id is null and r.lifecycle_state='fresh'
      and r.location is not null and r.issue_type::text<>'pending'
      and not exists(select 1 from public.dispatch_access_blocks b where b.report_id=r.id and b.cleared_at is null);
end; $function$;
ALTER FUNCTION "public"."dbscan_reports"(p_eps double precision, p_minpoints integer) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.upsert_cluster_for_reports_v2(p_report_ids uuid[], p_issue_type text, p_severity text, p_radius_meters double precision)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  locked_ids uuid[]; centroid extensions.geometry; cluster uuid; existing_ids uuid[];
  members integer; actual_radius double precision;
begin
  if p_radius_meters is null or p_radius_meters<=0 or p_radius_meters>10000 then raise exception 'Invalid clustering radius'; end if;
  if coalesce(cardinality(p_report_ids),0)=0 or cardinality(p_report_ids)<>(select count(distinct x) from unnest(p_report_ids) x) then
    raise exception 'Distinct approved reports required';
  end if;
  perform p_issue_type::public.report_issue_type, p_severity::public.cluster_severity;
  perform pg_advisory_xact_lock(884201,1);

  -- An identical retry returns the original identity without touching dispatched work.
  select array_agg(distinct r.cluster_id) into existing_ids from public.reports r
    where r.id=any(p_report_ids) and r.validation_status::text='approved' and r.issue_type::text=p_issue_type;
  if cardinality(existing_ids)=1 and existing_ids[1] is not null
    and (select count(*) from public.reports r where r.id=any(p_report_ids) and r.cluster_id=existing_ids[1]
      and r.validation_status::text='approved' and r.issue_type::text=p_issue_type)=cardinality(p_report_ids) then
    return existing_ids[1];
  end if;

  select extensions.st_centroid(extensions.st_collect(r.location::extensions.geometry)),count(*) into centroid,members
    from public.reports r where r.id=any(p_report_ids) and r.status::text='unresolved'
      and r.validation_status::text='approved' and r.issue_type::text=p_issue_type
      and r.cluster_id is null and r.cleanup_task_id is null and r.lifecycle_state='fresh' and r.location is not null
      and not exists(select 1 from public.dispatch_access_blocks b where b.report_id=r.id and b.cleared_at is null);
  if members<>cardinality(p_report_ids) then raise exception 'Clustering snapshot is stale or unapproved'; end if;

  -- Lock the cluster before its reports, matching dispatch's lock order.
  select c.id into cluster from public.clusters c
    where c.issue_type::text=p_issue_type and c.status::text in ('new','unresolved','prioritized')
      and extensions.st_dwithin(c.center::extensions.geography,centroid::extensions.geography,p_radius_meters)
      and not exists(select 1 from public.cleanup_tasks t where t.cluster_id=c.id or c.id=any(t.cluster_ids))
      and not exists(select 1 from public.dispatch_plan_items i where i.is_selected
        and (i.cluster_id=c.id or i.anchor_cluster_id=c.id or c.id=any(i.cluster_ids)))
      and not exists(select 1 from public.dispatch_access_blocks b where b.cluster_id=c.id and b.cleared_at is null)
      and not exists(select 1 from public.reports r where r.cluster_id=c.id
        and (r.validation_status::text is distinct from 'approved' or r.status::text is distinct from 'unresolved' or r.cleanup_task_id is not null))
    order by extensions.st_distance(c.center::extensions.geography,centroid::extensions.geography),c.created_at,c.id
    limit 1 for update of c;

  select array_agg(r.id order by r.id) into locked_ids from (
    select r.id from public.reports r where r.id=any(p_report_ids) and r.status::text='unresolved'
      and r.validation_status::text='approved' and r.issue_type::text=p_issue_type
      and r.cluster_id is null and r.cleanup_task_id is null and r.lifecycle_state='fresh' and r.location is not null
      and not exists(select 1 from public.dispatch_access_blocks b where b.report_id=r.id and b.cleared_at is null)
    order by r.id for update skip locked
  ) r;
  if coalesce(cardinality(locked_ids),0)<>cardinality(p_report_ids) then return null; end if;
  if cluster is null then
    -- A singleton may expand an existing cluster, but cannot create a new one.
    if cardinality(locked_ids)<2 then return null; end if;
    insert into public.clusters(center,issue_type,severity,status,radius_meters,report_count)
      values(centroid,p_issue_type::public.report_issue_type,p_severity::public.cluster_severity,'new',p_radius_meters,0)
      returning id into cluster;
  end if;
  update public.reports r set cluster_id=cluster,updated_at=now() where r.id=any(locked_ids);
  select extensions.st_centroid(extensions.st_collect(r.location::extensions.geometry)),count(*) into centroid,members
    from public.reports r where r.cluster_id=cluster;
  select coalesce(max(extensions.st_distance(r.location,centroid::extensions.geography)),0) into actual_radius
    from public.reports r where r.cluster_id=cluster;
  update public.clusters c set center=centroid,report_count=members,
    radius_meters=greatest(p_radius_meters,actual_radius),
    severity=(case when members>=5 then 'high' when members>=3 then 'medium' else 'low' end)::public.cluster_severity,
    updated_at=now() where c.id=cluster;
  return cluster;
end; $function$;
ALTER FUNCTION "public"."upsert_cluster_for_reports_v2"(p_report_ids uuid[], p_issue_type text, p_severity text, p_radius_meters double precision) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.cluster_reports_incremental(p_eps double precision, p_minpoints integer)
 RETURNS TABLE(cluster_uuid uuid, report_count integer)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare candidate record; cluster uuid; touched uuid[]:='{}';
begin
  if p_eps is null or p_eps<=0 or p_eps>10000 or p_minpoints is null or p_minpoints<2 or p_minpoints>100 then
    raise exception 'Invalid clustering parameters';
  end if;
  perform pg_advisory_xact_lock(884201,1);
  -- Attach new single reports first; DBSCAN's minimum must not force a second nearby cluster.
  for candidate in select r.id,r.issue_type::text as issue_type from public.reports r
    where r.status::text='unresolved' and r.validation_status::text='approved'
      and r.cluster_id is null and r.cleanup_task_id is null and r.lifecycle_state='fresh'
      and r.location is not null and r.issue_type::text<>'pending'
      and not exists(select 1 from public.dispatch_access_blocks b where b.report_id=r.id and b.cleared_at is null)
    order by r.created_at,r.id
  loop
    cluster:=public.upsert_cluster_for_reports_v2(array[candidate.id],candidate.issue_type,'low',p_eps);
    if cluster is not null then touched:=array_append(touched,cluster); end if;
  end loop;
  for candidate in select d.issue_type,d.cluster_id,array_agg(d.id order by d.id) as ids
    from public.dbscan_reports(p_eps,p_minpoints) d where d.cluster_id is not null
    group by d.issue_type,d.cluster_id order by d.issue_type,d.cluster_id
  loop
    cluster:=public.upsert_cluster_for_reports_v2(candidate.ids,candidate.issue_type,'low',p_eps);
    if cluster is not null then touched:=array_append(touched,cluster); end if;
  end loop;
  return query select c.id,c.report_count from public.clusters c where c.id=any(touched) order by c.id;
end; $function$;
ALTER FUNCTION "public"."cluster_reports_incremental"(p_eps double precision, p_minpoints integer) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION workflow_private.urgency_report_context(r reports)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
 SELECT jsonb_build_object('title',r.title,'description',r.description,
   'location',to_jsonb(r)->'location','issue_type',to_jsonb(r)->'issue_type',
   'severity_score',r.severity_score,'validation_status',r.validation_status,
   'on_private_property',r.on_private_property,'consent',r.property_owner_consent_status,'hazard_class',r.hazard_class);
$function$;
ALTER FUNCTION "workflow_private"."urgency_report_context"(r reports) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.expire_unpublished_dispatch_claims()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  task public.cleanup_tasks;
  expired integer := 0;
  escalated integer := 0;
  recovered_plans integer := 0;
begin
  -- Proactively recover expired running plan generation jobs
  with recovered as (
    update public.plan_generation_jobs
    set status = 'failed',
        finished_at = now(),
        error_code = 'worker_lease_expired'
    where status = 'running'
      and lease_until < now()
    returning id
  )
  select count(*)::integer into recovered_plans from recovered;

  for task in select * from public.cleanup_tasks where route_status = 'needs_replan'
    and routing_deadline_at <= now() + interval '15 minutes' order by id for update skip locked loop
    if task.routing_deadline_at <= now() and task.assigned_at is null and coalesce(cardinality(task.assigned_crew_ids), 0) = 0 and task.status::text in ('created', 'pending') then
      update public.cleanup_tasks set route_status = 'expired', status = 'cancelled', failure_class = 'transient',
        failure_reason = 'Unpublished route planning expired', completion_result = 'routing_expired' where id = task.id;
      expired := expired + 1;
    elsif task.routing_escalated_at is null then
      update public.cleanup_tasks set routing_escalated_at = now() where id = task.id;
      insert into public.sweeper_audit_log(event_type, entity_type, entity_id, user_id, event_data)
        values('ROUTING_ESCALATION', 'TASK', task.id::text, 'system', jsonb_build_object('routing_deadline_at', task.routing_deadline_at, 'assigned_at', task.assigned_at));
      escalated := escalated + 1;
    end if;
  end loop;

  return jsonb_build_object(
    'expiredCount', expired,
    'escalatedCount', escalated,
    'recoveredPlanningJobs', recovered_plans
  );
end; $function$;
ALTER FUNCTION "public"."expire_unpublished_dispatch_claims"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.read_authorized_cleanup_tasks(actor uuid, p_task_id uuid DEFAULT NULL::uuid, p_cluster_id uuid DEFAULT NULL::uuid, p_assigned_only boolean DEFAULT false, p_limit integer DEFAULT 201, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
WITH viewer AS (
 SELECT id,role::text AS role FROM public.profiles WHERE id=actor
), allowed AS (
 SELECT task.*,viewer.role AS viewer_role,
   (viewer.role IN ('officer','admin') OR
    (viewer.role='field_crew' AND task.route_status='ready'
      AND task.status::text IN ('created','pending','in_progress','partially_completed')
      AND actor=ANY(coalesce(task.assigned_crew_ids,'{}'::uuid[])))) AS full_access
 FROM public.cleanup_tasks task CROSS JOIN viewer
 WHERE (p_task_id IS NULL OR task.id=p_task_id)
   AND (p_cluster_id IS NULL OR task.cluster_id=p_cluster_id)
   AND (NOT p_assigned_only OR actor=ANY(coalesce(task.assigned_crew_ids,'{}'::uuid[])))
   AND (
    viewer.role IN ('officer','admin')
    OR (viewer.role='field_crew' AND actor=ANY(coalesce(task.assigned_crew_ids,'{}'::uuid[])))
    OR (viewer.role='citizen' AND p_cluster_id IS NOT NULL AND EXISTS(
     SELECT 1 FROM public.reports r
     WHERE (r.cleanup_task_id=task.id OR r.id=ANY(coalesce(task.report_ids,'{}'::uuid[])))
       AND (r.user_id=actor OR (r.validation_status='approved' AND r.status<>'rejected'
        AND (r.on_private_property IS FALSE OR
          (r.on_private_property IS TRUE AND r.property_owner_consent_status='obtained'))))
    ))
   )
   AND p_limit BETWEEN 1 AND 501 AND p_offset BETWEEN 0 AND 250000
 ORDER BY task.created_at DESC NULLS LAST,task.id DESC
 LIMIT greatest(1,least(coalesce(p_limit,1),501))
 OFFSET greatest(0,least(coalesce(p_offset,0),250000))
), projected AS (
 SELECT task.created_at,task.id,
 CASE WHEN task.full_access THEN
   (to_jsonb(task)-'viewer_role'-'full_access') || jsonb_build_object(
    'clusters',CASE WHEN task.viewer_role IN ('officer','admin') THEN
       (SELECT to_jsonb(c) FROM public.clusters c WHERE c.id=task.cluster_id)
     ELSE jsonb_build_object('id',task.cluster_id) END,
    'reports',coalesce((SELECT jsonb_agg(jsonb_build_object(
     'id',r.id,'title',r.title,'description',r.description,'issue_type',r.issue_type,
     'location',r.location,'status',r.status,'report_claim_generation',r.report_claim_generation)
     ORDER BY r.id) FROM public.reports r WHERE r.cleanup_task_id=task.id),'[]'::jsonb),
    'report_claim_generations',coalesce((SELECT jsonb_object_agg(r.id::text,r.report_claim_generation)
     FROM public.reports r WHERE r.cleanup_task_id=task.id),'{}'::jsonb),
    'access_level','detail')
 ELSE jsonb_build_object(
    'id',task.id,'cluster_id',task.cluster_id,'title','Cleanup progress',
    'status',task.status,'created_at',task.created_at,'completed_at',task.completed_at,
    'is_custom',task.is_custom,'access_level','summary',
    'before_photo_url',CASE WHEN NOT EXISTS(SELECT 1
      FROM unnest(coalesce(task.report_ids,'{}'::uuid[])) AS membership(report_id)
      LEFT JOIN public.reports member_report ON member_report.id=membership.report_id
      WHERE member_report.id IS NULL)
      AND EXISTS(SELECT 1 FROM public.reports r
      WHERE r.cleanup_task_id=task.id OR r.id=ANY(coalesce(task.report_ids,'{}'::uuid[])))
      AND NOT EXISTS(SELECT 1 FROM public.reports r
       WHERE (r.cleanup_task_id=task.id OR r.id=ANY(coalesce(task.report_ids,'{}'::uuid[])))
        AND NOT coalesce(r.user_id=actor OR
          (r.validation_status='approved' AND r.status<>'rejected' AND r.on_private_property IS FALSE),false))
      THEN task.before_photo_url ELSE NULL END,
    'after_photo_url',CASE WHEN NOT EXISTS(SELECT 1
      FROM unnest(coalesce(task.report_ids,'{}'::uuid[])) AS membership(report_id)
      LEFT JOIN public.reports member_report ON member_report.id=membership.report_id
      WHERE member_report.id IS NULL)
      AND EXISTS(SELECT 1 FROM public.reports r
      WHERE r.cleanup_task_id=task.id OR r.id=ANY(coalesce(task.report_ids,'{}'::uuid[])))
      AND NOT EXISTS(SELECT 1 FROM public.reports r
       WHERE (r.cleanup_task_id=task.id OR r.id=ANY(coalesce(task.report_ids,'{}'::uuid[])))
        AND NOT coalesce(r.user_id=actor OR
          (r.validation_status='approved' AND r.status<>'rejected' AND r.on_private_property IS FALSE),false))
      THEN task.after_photo_url ELSE NULL END)
 END AS data FROM allowed task
)
SELECT coalesce(jsonb_agg(data ORDER BY created_at DESC NULLS LAST,id DESC),'[]'::jsonb)
FROM projected;
$function$;
ALTER FUNCTION "public"."read_authorized_cleanup_tasks"(actor uuid, p_task_id uuid, p_cluster_id uuid, p_assigned_only boolean, p_limit integer, p_offset integer) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.claim_plan_generation(worker_id uuid, worker_env text DEFAULT 'production'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  job public.plan_generation_jobs;
BEGIN
  IF worker_id IS NULL THEN
    RAISE EXCEPTION 'Worker token required';
  END IF;

  -- Expire any stale leases
  UPDATE public.plan_generation_jobs
  SET status = 'failed',
      finished_at = now(),
      error_code = 'worker_lease_expired'
  WHERE status = 'running'
    AND lease_until < now();

  -- Claim the next queued job matching the worker environment
  UPDATE public.plan_generation_jobs
  SET status = 'running',
      started_at = now(),
      lease_until = now() + interval '3 minutes',
      worker_token = worker_id
  WHERE id = (
    SELECT id
    FROM public.plan_generation_jobs
    WHERE status = 'queued'
      AND (
        (worker_env = 'development')
        OR (worker_env = 'mixed_bridge')
        OR (coalesce(settings_snapshot->>'environment', 'production') <> 'development')
      )
    ORDER BY requested_at, id
    FOR UPDATE SKIP LOCKED
    LIMIT 1
  )
  RETURNING * INTO job;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN to_jsonb(job);
END;
$function$;
ALTER FUNCTION "public"."claim_plan_generation"(worker_id uuid, worker_env text) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.issue_email_verification(p_user_id uuid, p_token_digest text, p_ttl_hours integer, p_email text)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
  profile public.profiles%ROWTYPE;
  issuance_id uuid;
  clean_email text := NULL;
BEGIN
  IF p_token_digest IS NULL OR p_token_digest !~ '^[0-9a-f]{64}$'
     OR p_ttl_hours IS NULL OR p_ttl_hours < 1 OR p_ttl_hours > 24 THEN
    RAISE EXCEPTION 'Invalid verification issuance parameters' USING ERRCODE='22023';
  END IF;

  IF p_email IS NOT NULL THEN
    clean_email := pg_catalog.lower(pg_catalog.btrim(p_email));
    IF pg_catalog.length(clean_email) > 320 OR clean_email !~ '^[^\s@]+@[^\s@]+$' THEN
      RAISE EXCEPTION 'Invalid verification email parameter' USING ERRCODE='22023';
    END IF;
  END IF;

  -- This profile lock serializes issuance across all application processes.
  SELECT * INTO profile FROM public.profiles WHERE id = p_user_id FOR UPDATE;
  IF NOT FOUND OR profile.is_email_verified IS TRUE THEN RETURN NULL; END IF;
  IF EXISTS(SELECT FROM public.email_verifications WHERE user_id = p_user_id
      AND created_at > pg_catalog.clock_timestamp() - interval '60 seconds') THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.email_verifications(user_id, token, token_digest, issued_to_email, expires_at, created_at)
  VALUES(p_user_id, NULL, p_token_digest, clean_email, pg_catalog.clock_timestamp() + pg_catalog.make_interval(hours => p_ttl_hours), pg_catalog.clock_timestamp())
  RETURNING id INTO issuance_id;
  RETURN issuance_id;
END;
$function$;
ALTER FUNCTION "public"."issue_email_verification"(p_user_id uuid, p_token_digest text, p_ttl_hours integer, p_email text) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.complete_email_verification(p_verification_id uuid, p_user_id uuid, p_expected_email text)
 RETURNS boolean
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
  verification public.email_verifications%ROWTYPE;
  matched_profile uuid;
  clean_expected text := NULL;
BEGIN
  -- Serialize redemption, then check expiry after any lock wait.
  SELECT * INTO verification FROM public.email_verifications
  WHERE id = p_verification_id AND user_id = p_user_id FOR UPDATE;
  IF NOT FOUND OR verification.used_at IS NOT NULL
     OR verification.expires_at <= pg_catalog.clock_timestamp() THEN
    RETURN false;
  END IF;

  -- Validate bound email address if recorded
  IF verification.issued_to_email IS NOT NULL THEN
    IF p_expected_email IS NULL THEN
      RETURN false;
    END IF;
    clean_expected := pg_catalog.lower(pg_catalog.btrim(p_expected_email));
    IF clean_expected <> verification.issued_to_email THEN
      RETURN false;
    END IF;
  END IF;

  -- Atomic update of profile with self-healing fallback
  UPDATE public.profiles SET is_email_verified = true
  WHERE id = verification.user_id RETURNING id INTO matched_profile;

  IF NOT FOUND THEN
    INSERT INTO public.profiles (id, full_name, role, is_email_verified)
    VALUES (verification.user_id, coalesce(clean_expected, 'Citizen'), 'citizen', true)
    ON CONFLICT (id) DO UPDATE SET is_email_verified = true
    RETURNING id INTO matched_profile;
  END IF;

  IF matched_profile IS NULL THEN
    RETURN false;
  END IF;

  UPDATE public.email_verifications SET used_at = pg_catalog.clock_timestamp()
  WHERE id = verification.id;
  RETURN true;
END;
$function$;
ALTER FUNCTION "public"."complete_email_verification"(p_verification_id uuid, p_user_id uuid, p_expected_email text) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION verification_private.redeem_email(p_verification_id uuid, p_user_id uuid, p_expected_email text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE account auth.users%ROWTYPE; verification public.email_verifications%ROWTYPE;
BEGIN
 -- No HTTP calls under locks. NO KEY UPDATE permits concurrent FK checks.
 SELECT * INTO account FROM auth.users WHERE id=p_user_id FOR NO KEY UPDATE;
 IF NOT FOUND THEN RETURN false; END IF;
 PERFORM 1 FROM public.profiles WHERE id=p_user_id FOR UPDATE;
 SELECT * INTO verification FROM public.email_verifications
 WHERE id=p_verification_id AND user_id=p_user_id FOR UPDATE;
 IF NOT FOUND OR verification.used_at IS NOT NULL
   OR verification.expires_at IS NULL OR verification.created_at IS NULL
   OR verification.issued_to_email IS NULL
   OR pg_catalog.lower(pg_catalog.btrim(account.email)) IS DISTINCT FROM verification.issued_to_email
   OR pg_catalog.lower(pg_catalog.btrim(p_expected_email)) IS DISTINCT FROM verification.issued_to_email THEN RETURN false; END IF;
 -- Recover an old partial completion only when Auth recorded confirmation
 -- inside this bound token's validity window. Expiry cannot authorize new confirmation.
 IF verification.expires_at<=pg_catalog.clock_timestamp() AND NOT (
   account.email_confirmed_at IS NOT NULL
   AND account.email_confirmed_at>=verification.created_at
   AND account.email_confirmed_at<=verification.expires_at
 ) THEN RETURN false; END IF;
 IF account.email_confirmed_at IS NULL THEN
   -- Match GoTrue v2.197.0 User.Confirm semantics for this custom-email flow.
   UPDATE auth.users SET email_confirmed_at=pg_catalog.clock_timestamp(),
     confirmation_token='',updated_at=pg_catalog.clock_timestamp(),
     raw_user_meta_data=coalesce(raw_user_meta_data,'{}'::jsonb)||'{"email_verified":true}'::jsonb
   WHERE id=p_user_id;
   DELETE FROM auth.one_time_tokens WHERE user_id=p_user_id;
 END IF;
 INSERT INTO public.profiles(id,full_name,role,is_email_verified)
 VALUES(p_user_id,coalesce(account.email,'Citizen'),'citizen',true)
 ON CONFLICT(id) DO UPDATE SET is_email_verified=true;
 UPDATE public.email_verifications SET used_at=pg_catalog.clock_timestamp() WHERE id=p_verification_id;
 RETURN true;
END;
$function$;
ALTER FUNCTION "verification_private"."redeem_email"(p_verification_id uuid, p_user_id uuid, p_expected_email text) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION workflow_private.urgency_maturation_bypass(r reports)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
 SELECT coalesce(r.urgency_status='approved' AND r.validation_status::text='approved'
   AND (NOT coalesce(r.on_private_property,false) OR r.property_owner_consent_status::text='obtained')
   AND coalesce(r.hazard_class,'standard') NOT IN ('suspected_hazard','hazmat_required','hazard_review')
   AND EXISTS(SELECT 1 FROM public.report_urgency_decisions d WHERE d.operation_id=r.urgency_decision_id
     AND d.report_id=r.id AND d.outcome='approved' AND d.report_context=workflow_private.urgency_report_context(r)),false);
$function$;
ALTER FUNCTION "workflow_private"."urgency_maturation_bypass"(r reports) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.ensure_citizen_trust(target uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=target AND role::text='citizen') THEN
    RAISE EXCEPTION 'Citizen trust is available only for citizen accounts.' USING ERRCODE='42501';
  END IF;
  INSERT INTO public.citizen_trust(user_id) VALUES(target) ON CONFLICT DO NOTHING;
END $function$;
ALTER FUNCTION "public"."ensure_citizen_trust"(target uuid) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.rebuild_citizen_trust(target uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE points integer := 50; streak integer := 0; deadline timestamptz; e record;
BEGIN
  PERFORM public.ensure_citizen_trust(target);
  PERFORM 1 FROM public.citizen_trust WHERE user_id=target FOR UPDATE;
  FOR e IN SELECT d.* FROM public.citizen_trust_decisions d
    WHERE d.user_id=target AND NOT EXISTS(SELECT 1 FROM public.citizen_trust_decisions newer WHERE newer.supersedes_id=d.id)
    ORDER BY d.id
  LOOP
    IF e.outcome='false_urgency' THEN
      points:=greatest(0,points-30); streak:=0; deadline:=e.recorded_at+interval '168 hours';
    ELSIF e.outcome='valid' THEN
      points:=least(100,points+10);
      IF deadline IS NOT NULL THEN streak:=least(3,streak+1); END IF;
    ELSIF e.outcome='neutral' AND streak<3 THEN
      streak:=0;
    END IF;
  END LOOP;
  UPDATE public.citizen_trust SET score=points,recovery_streak=streak,locked_until=deadline,updated_at=clock_timestamp() WHERE user_id=target;
  RETURN public.citizen_trust_snapshot(target);
END $function$;
ALTER FUNCTION "public"."rebuild_citizen_trust"(target uuid) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.read_citizen_trust_review(actor uuid, report_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE r public.reports; decision public.citizen_trust_decisions; actor_role text; citizen boolean;
BEGIN
  SELECT * INTO r FROM public.reports WHERE id=report_id FOR SHARE;
  SELECT * INTO decision FROM public.citizen_trust_decisions d WHERE d.report_id=read_citizen_trust_review.report_id ORDER BY id DESC LIMIT 1;
  SELECT role::text INTO actor_role FROM public.profiles WHERE id=actor FOR SHARE;
  IF (r.id IS NULL OR r.user_id IS NULL) AND actor_role='admin' AND decision.id IS NOT NULL AND decision.user_id IS DISTINCT FROM actor THEN
    r.submitted_citizen_priority:=decision.submitted_priority;
  ELSE
    PERFORM public.authorize_citizen_trust_review(actor,report_id);
  END IF;
  citizen:=EXISTS(SELECT 1 FROM public.profiles WHERE id=r.user_id AND role::text='citizen');
  RETURN jsonb_build_object('reviewable',citizen,'submitted_priority',r.submitted_citizen_priority,'priority_reason',r.priority_reason,
    'priority_explanation',r.priority_explanation,'decision',CASE WHEN decision.id IS NULL THEN NULL ELSE to_jsonb(decision)-'user_id'-'actor_id'-'operation_id' END);
END $function$;
ALTER FUNCTION "public"."read_citizen_trust_review"(actor uuid, report_id uuid) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.record_citizen_trust_review(actor uuid, report_id uuid, outcome text, reason text, operation_id uuid, expected_decision_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE r public.reports; prior public.citizen_trust_decisions; retry public.citizen_trust_decisions;
  saved public.citizen_trust_decisions; actor_role text; normalized_reason text := btrim(reason);
BEGIN
  IF operation_id IS NULL OR outcome IS NULL OR outcome NOT IN ('valid','neutral','false_urgency','withdrawn')
    OR normalized_reason IS NULL OR char_length(normalized_reason) NOT BETWEEN 3 AND 1000 THEN
    RAISE EXCEPTION 'Choose a review outcome and give a reason (3-1000 characters).' USING ERRCODE='22023';
  END IF;
  SELECT * INTO r FROM public.reports WHERE id=report_id FOR UPDATE;
  SELECT role::text INTO actor_role FROM public.profiles WHERE id=actor FOR SHARE;
  IF (r.id IS NULL OR r.user_id IS NULL) AND expected_decision_id IS NOT NULL AND actor_role='admin' THEN
    -- Deleted/anonymized reports must not strand an erroneous penalty.
    SELECT * INTO prior FROM public.citizen_trust_decisions d WHERE d.report_id=record_citizen_trust_review.report_id ORDER BY id DESC LIMIT 1;
    IF prior.user_id IS NULL OR prior.user_id=actor THEN
      RAISE EXCEPTION 'Not authorized to correct this trust review.' USING ERRCODE='42501';
    END IF;
    r.user_id:=prior.user_id; r.submitted_citizen_priority:=prior.submitted_priority;
  ELSE
    PERFORM public.authorize_citizen_trust_review(actor,report_id);
  END IF;
  IF (expected_decision_id IS NOT NULL OR outcome='withdrawn') AND actor_role<>'admin' THEN
    RAISE EXCEPTION 'Only an administrator may correct a trust review.' USING ERRCODE='42501';
  END IF;
  IF outcome='false_urgency' AND r.submitted_citizen_priority IS DISTINCT FROM 'urgent' THEN
    RAISE EXCEPTION 'A false urgency finding requires an originally Urgent report.' USING ERRCODE='22023';
  END IF;
  PERFORM public.ensure_citizen_trust(r.user_id);
  PERFORM 1 FROM public.citizen_trust WHERE user_id=r.user_id FOR UPDATE;
  SELECT * INTO retry FROM public.citizen_trust_decisions d WHERE d.operation_id=record_citizen_trust_review.operation_id;
  IF retry.id IS NOT NULL THEN
    IF retry.report_id IS DISTINCT FROM report_id OR retry.actor_id IS DISTINCT FROM actor OR retry.outcome IS DISTINCT FROM outcome
      OR retry.reason IS DISTINCT FROM normalized_reason OR retry.supersedes_id IS DISTINCT FROM expected_decision_id THEN
      RAISE EXCEPTION 'Review operation conflict; use a new operation ID.' USING ERRCODE='23505';
    END IF;
    RETURN jsonb_build_object('decision',to_jsonb(retry)-'user_id'-'actor_id'-'operation_id','trust',public.citizen_trust_snapshot(r.user_id));
  END IF;
  SELECT * INTO prior FROM public.citizen_trust_decisions d WHERE d.report_id=record_citizen_trust_review.report_id ORDER BY id DESC LIMIT 1;
  IF prior.id IS NOT NULL AND expected_decision_id IS NULL THEN
    IF prior.supersedes_id IS NULL AND prior.actor_id=actor AND prior.outcome=outcome AND prior.reason=normalized_reason THEN
      RETURN jsonb_build_object('decision',to_jsonb(prior)-'user_id'-'actor_id'-'operation_id','trust',public.citizen_trust_snapshot(r.user_id));
    END IF;
    RAISE EXCEPTION 'Report already reviewed; an administrator must correct it.' USING ERRCODE='23505';
  END IF;
  IF expected_decision_id IS DISTINCT FROM prior.id OR (prior.id IS NULL AND outcome='withdrawn') THEN
    RAISE EXCEPTION 'Review conflict; refresh before correcting this decision.' USING ERRCODE='23505';
  END IF;
  INSERT INTO public.citizen_trust_decisions(operation_id,report_id,user_id,actor_id,outcome,reason,submitted_priority,supersedes_id)
    VALUES(operation_id,report_id,r.user_id,actor,outcome,normalized_reason,r.submitted_citizen_priority,expected_decision_id)
    RETURNING * INTO saved;
  RETURN jsonb_build_object('decision',to_jsonb(saved)-'user_id'-'actor_id'-'operation_id','trust',public.rebuild_citizen_trust(r.user_id));
END $function$;
ALTER FUNCTION "public"."record_citizen_trust_review"(actor uuid, report_id uuid, outcome text, reason text, operation_id uuid, expected_decision_id bigint) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.gate_citizen_urgent_report()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE allowed boolean;
BEGIN
  IF TG_OP='INSERT' THEN
    NEW.submitted_citizen_priority:=NEW.citizen_priority;
  ELSE
    IF NEW.submitted_citizen_priority IS DISTINCT FROM OLD.submitted_citizen_priority THEN
      RAISE EXCEPTION 'Submitted citizen priority is immutable.' USING ERRCODE='22023';
    END IF;
    IF NEW.user_id IS DISTINCT FROM OLD.user_id AND NEW.user_id IS NOT NULL THEN
      RAISE EXCEPTION 'The report owner cannot be reassigned.' USING ERRCODE='22023';
    END IF;
    IF NEW.user_id IS DISTINCT FROM OLD.user_id AND NEW.user_id IS NULL AND current_user NOT IN ('service_role','postgres','supabase_admin') THEN
      RAISE EXCEPTION 'Only account administration may anonymize a report.' USING ERRCODE='42501';
    END IF;
    -- Existing urgent reports keep normal edits; account deletion may anonymize them.
    IF NEW.citizen_priority IS NOT DISTINCT FROM OLD.citizen_priority THEN RETURN NEW; END IF;
    -- Submitted priority is immutable: changing citizen intent after submission needs a separate request.
    RAISE EXCEPTION 'Submitted citizen priority is immutable.' USING ERRCODE='22023';
  END IF;
  IF NEW.citizen_priority IS DISTINCT FROM 'urgent' THEN RETURN NEW; END IF;
  PERFORM public.ensure_citizen_trust(NEW.user_id);
  PERFORM 1 FROM public.citizen_trust WHERE user_id=NEW.user_id FOR UPDATE;
  allowed:=(public.citizen_trust_snapshot(NEW.user_id)->>'urgent_allowed')::boolean;
  IF NOT allowed THEN
    RAISE EXCEPTION 'Urgent is locked. Check your trust score and recovery requirements in Profile. You can still submit Non-urgent reports.' USING ERRCODE='P0001',HINT='URGENT_TRUST_LOCKED';
  END IF;
  RETURN NEW;
END $function$;
ALTER FUNCTION "public"."gate_citizen_urgent_report"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION workflow_private.mixed_planning_snapshot()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
WITH anchors AS (
  SELECT c.id, c.priority_score, c.estimated_effort_minutes, c.recommended_task_type,
    c.created_at, extensions.st_y(c.center) AS lat, extensions.st_x(c.center) AS lng,
    coalesce((SELECT sum(coalesce(w.estimated_volume_m3, 0.10)) FROM public.reports r LEFT JOIN public.work_time_configuration w ON w.report_type=r.issue_type::text
      WHERE r.cluster_id=c.id AND r.cleanup_task_id IS NULL AND r.status::text NOT IN ('resolved','completed','closed','rejected')), 0.20) AS estimated_volume_m3,
    coalesce((SELECT sum(coalesce(w.estimated_weight_kg, 10.00)) FROM public.reports r LEFT JOIN public.work_time_configuration w ON w.report_type=r.issue_type::text
      WHERE r.cluster_id=c.id AND r.cleanup_task_id IS NULL AND r.status::text NOT IN ('resolved','completed','closed','rejected')), 20.00) AS estimated_weight_kg,
    array(SELECT r.id FROM public.reports r WHERE r.cluster_id=c.id
      AND r.cleanup_task_id IS NULL AND r.status::text NOT IN ('resolved','completed','closed','rejected')
      ORDER BY r.id) AS report_ids
  FROM public.clusters c
  WHERE c.status::text IN ('new','unresolved','prioritized','queued','monitoring')
    AND NOT EXISTS(SELECT 1 FROM public.dispatch_access_blocks b WHERE b.cluster_id=c.id AND b.cleared_at IS NULL)
    AND NOT EXISTS(SELECT 1 FROM public.reports r JOIN public.dispatch_access_blocks b ON b.report_id=r.id
      WHERE r.cluster_id=c.id AND b.cleared_at IS NULL)
  ORDER BY c.priority_score DESC NULLS LAST,c.id LIMIT 200
),
satellites AS (
  SELECT r.id, r.issue_type::text, r.lifecycle_state::text, r.severity_score, r.urgency_score,
    r.created_at, r.sla_started_at, r.deadline_at,
    extensions.st_y(r.location::extensions.geometry) AS lat,
    extensions.st_x(r.location::extensions.geometry) AS lng,
    coalesce(w.work_time_minutes, 30) AS work_time_minutes,
    coalesce(w.estimated_volume_m3, 0.05) AS estimated_volume_m3,
    coalesce(w.estimated_weight_kg, 5.00) AS estimated_weight_kg,
    exists(SELECT 1 FROM public.dispatch_access_blocks b WHERE b.report_id=r.id AND b.cleared_at IS NULL) AS blocked
  FROM public.reports r LEFT JOIN public.work_time_configuration w ON w.report_type=r.issue_type::text
  WHERE r.status::text='unresolved' AND r.cluster_id IS NULL AND r.cleanup_task_id IS NULL
    AND r.lifecycle_state IN ('maturing','sla_breached') AND r.location IS NOT NULL
  ORDER BY r.deadline_at NULLS LAST,r.id LIMIT 200
)
SELECT jsonb_build_object(
  'anchors',coalesce((SELECT jsonb_agg(to_jsonb(a)) FROM anchors a WHERE cardinality(a.report_ids)>0),'[]'::jsonb),
  'satellites',coalesce((SELECT jsonb_agg(to_jsonb(s)) FROM satellites s),'[]'::jsonb)
);
$function$;
ALTER FUNCTION "workflow_private"."mixed_planning_snapshot"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION workflow_private.apply_report_lifecycle()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE deployed timestamptz; cfg record; maturation numeric; bypass boolean; stamp timestamptz:=statement_timestamp();
BEGIN
  SELECT activated_at INTO deployed FROM workflow_private.lifecycle_deployment WHERE singleton;
  IF deployed IS NULL THEN NEW.sla_started_at:=NULL; NEW.lifecycle_state:=NULL; NEW.matured_at:=NULL; NEW.breached_at:=NULL; RETURN NEW; END IF;
  SELECT * INTO cfg FROM workflow_private.lifecycle_config();
  bypass:=workflow_private.urgency_maturation_bypass(NEW);
  maturation:=CASE WHEN bypass THEN 0 WHEN workflow_private.severity_tier(NEW.severity_score)='high' THEN cfg.high_hours ELSE cfg.normal_hours END;
  IF TG_OP='INSERT' THEN
    NEW.sla_started_at:=stamp; NEW.deadline_at:=stamp+cfg.sla_hours*interval '1 hour'; NEW.matured_at:=NULL; NEW.breached_at:=NULL;
  ELSE
    NEW.sla_started_at:=coalesce(OLD.sla_started_at,CASE WHEN OLD.status::text='unresolved' THEN deployed ELSE coalesce(OLD.created_at,deployed) END);
    NEW.deadline_at:=CASE WHEN OLD.sla_started_at IS NOT NULL THEN OLD.deadline_at WHEN OLD.status::text='unresolved' THEN deployed+cfg.sla_hours*interval '1 hour'
      ELSE coalesce(OLD.deadline_at,NEW.sla_started_at+cfg.sla_hours*interval '1 hour') END;
    -- First observed eligibility and breach are historical; current eligibility is lifecycle_state.
    NEW.matured_at:=OLD.matured_at; NEW.breached_at:=OLD.breached_at;
  END IF;
  -- Include closure transitions so closing an overdue report cannot erase the elapsed breach.
  IF TG_OP='INSERT' OR coalesce(OLD.status::text,'unresolved') NOT IN ('resolved','completed','closed','rejected') THEN
    IF stamp>=NEW.sla_started_at+maturation*interval '1 hour' THEN
      NEW.matured_at:=coalesce(NEW.matured_at,CASE WHEN bypass THEN NEW.urgency_decided_at ELSE NEW.sla_started_at+maturation*interval '1 hour' END);
    END IF;
    IF stamp>=NEW.deadline_at THEN NEW.breached_at:=coalesce(NEW.breached_at,NEW.deadline_at); END IF;
  END IF;
  NEW.lifecycle_state:=workflow_private.derive_report_lifecycle(NEW.status::text,NEW.cluster_id,NEW.cleanup_task_id,NEW.sla_started_at,NEW.deadline_at,maturation,stamp);
  RETURN NEW;
END $function$;
ALTER FUNCTION "workflow_private"."apply_report_lifecycle"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION workflow_private.guard_report_urgency()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE latest public.report_urgency_decisions; plan_settings jsonb; expected text;
BEGIN
  IF TG_OP='INSERT' THEN
    NEW.urgency_status:=CASE WHEN NEW.citizen_priority='urgent' THEN 'pending' END;
    NEW.urgency_decision_id:=NULL; NEW.urgency_decided_at:=NULL; NEW.urgency_reason:=NULL;
    RETURN NEW;
  END IF;
  IF ROW(NEW.urgency_status,NEW.urgency_decision_id,NEW.urgency_decided_at,NEW.urgency_reason)
     IS DISTINCT FROM ROW(OLD.urgency_status,OLD.urgency_decision_id,OLD.urgency_decided_at,OLD.urgency_reason) THEN
    IF current_user NOT IN ('postgres','service_role','supabase_admin') THEN
      RAISE EXCEPTION 'Only the officer urgency service can update a decision.' USING ERRCODE='42501';
    END IF;
    IF OLD.urgency_status IS NULL AND NEW.citizen_priority='urgent' AND NEW.urgency_status='pending'
      AND NEW.urgency_decision_id IS NULL AND NEW.urgency_decided_at IS NULL AND NEW.urgency_reason IS NULL THEN RETURN NEW; END IF;
    SELECT * INTO latest FROM public.report_urgency_decisions WHERE report_id=NEW.id ORDER BY sequence DESC LIMIT 1;
    IF latest.operation_id IS NULL OR NEW.citizen_priority IS DISTINCT FROM 'urgent'
      OR ROW(NEW.urgency_status,NEW.urgency_decision_id,NEW.urgency_decided_at,NEW.urgency_reason)
      IS DISTINCT FROM ROW(latest.outcome,latest.operation_id,latest.recorded_at,latest.reason) THEN
      RAISE EXCEPTION 'Urgency decision must match the latest auditable officer review.' USING ERRCODE='42501';
    END IF;
  END IF;
  -- Focused plans snapshot approvals. A changed/withdrawn approval cannot commit an old draft.
  IF NEW.cleanup_task_id IS NOT NULL AND NEW.cleanup_task_id IS DISTINCT FROM OLD.cleanup_task_id THEN
    SELECT p.settings_snapshot INTO plan_settings FROM public.cleanup_tasks t JOIN public.dispatch_plans p ON p.id=t.source_plan_id WHERE t.id=NEW.cleanup_task_id;
    expected:=plan_settings->'urgency_decisions'->>NEW.id::text;
    IF expected IS NOT NULL AND (NEW.urgency_decision_id::text IS DISTINCT FROM expected OR NOT workflow_private.urgency_maturation_bypass(NEW)) THEN
      RAISE EXCEPTION 'stale_group' USING ERRCODE='P0001',DETAIL='Urgency changed; generate a new dispatch plan.';
    END IF;
  END IF;
  RETURN NEW;
END $function$;
ALTER FUNCTION "workflow_private"."guard_report_urgency"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION workflow_private.notify_urgent_report()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
  IF NEW.urgency_status='pending' AND NEW.user_id IS NOT NULL AND NEW.status::text='unresolved'
    AND NEW.cleanup_task_id IS NULL AND NEW.validation_status::text<>'rejected'
    AND (TG_OP='INSERT' OR OLD.urgency_status IS NULL) THEN
    WITH recipients AS (
      INSERT INTO public.report_urgency_alerts(report_id,recipient_id)
      SELECT NEW.id,p.id FROM public.profiles p WHERE p.role::text IN ('officer','admin') AND p.id<>NEW.user_id
      ON CONFLICT DO NOTHING RETURNING recipient_id
    )
    INSERT INTO public.notifications(user_id,report_id,type,title,body,is_read)
      SELECT recipient_id,NEW.id,'general','Urgent report awaiting verification',
        'A citizen requested urgent review. Verify the report in the Urgent verification queue before dispatch.',false FROM recipients;
  END IF;
  RETURN NEW;
END $function$;
ALTER FUNCTION "workflow_private"."notify_urgent_report"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.advance_report_lifecycle()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE cfg record; changed integer; breaches jsonb;
BEGIN
  IF NOT pg_catalog.pg_try_advisory_xact_lock(72631008) THEN RETURN jsonb_build_object('skipped',true,'changedCount',0,'newlyBreached','[]'::jsonb); END IF;
  IF NOT EXISTS(SELECT 1 FROM workflow_private.lifecycle_deployment) THEN RAISE EXCEPTION 'Report lifecycle has not been activated'; END IF;
  SELECT * INTO cfg FROM workflow_private.lifecycle_config();
  WITH candidates AS MATERIALIZED (
    SELECT r.id,r.breached_at AS old_breached FROM public.reports r
    WHERE r.lifecycle_state IS DISTINCT FROM 'closed' AND (
      r.lifecycle_state IS DISTINCT FROM workflow_private.derive_report_lifecycle(r.status::text,r.cluster_id,r.cleanup_task_id,r.sla_started_at,r.deadline_at,
        CASE WHEN workflow_private.urgency_maturation_bypass(r) THEN 0 WHEN workflow_private.severity_tier(r.severity_score)='high' THEN cfg.high_hours ELSE cfg.normal_hours END,statement_timestamp())
      OR (r.breached_at IS NULL AND statement_timestamp()>=r.deadline_at)
      OR (r.matured_at IS NULL AND statement_timestamp()>=r.sla_started_at+
        (CASE WHEN workflow_private.urgency_maturation_bypass(r) THEN 0 WHEN workflow_private.severity_tier(r.severity_score)='high' THEN cfg.high_hours ELSE cfg.normal_hours END)*interval '1 hour'))
    FOR UPDATE SKIP LOCKED
  ),updated AS (
    UPDATE public.reports r SET updated_at=statement_timestamp() FROM candidates c WHERE r.id=c.id RETURNING r.id,r.breached_at,c.old_breached,r.sla_started_at
  ) SELECT count(*)::integer,coalesce(jsonb_agg(jsonb_build_object('id',u.id,'breachDuration',extract(epoch FROM(statement_timestamp()-u.sla_started_at))/3600,'timestamp',u.breached_at))
      FILTER(WHERE u.old_breached IS NULL AND u.breached_at IS NOT NULL),'[]'::jsonb) INTO changed,breaches FROM updated u;
  INSERT INTO public.sweeper_audit_log(event_type,entity_type,entity_id,user_id,event_data) VALUES('LIFECYCLE_RUN_COMPLETED','SYSTEM','report_lifecycle','system',
    jsonb_build_object('changedCount',changed,'newlyBreachedCount',jsonb_array_length(breaches)));
  RETURN jsonb_build_object('skipped',false,'changedCount',changed,'newlyBreached',breaches);
END $function$;
ALTER FUNCTION "public"."advance_report_lifecycle"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.record_report_urgency_decision(actor uuid, report_id uuid, outcome text, reason text, operation_id uuid, expected_decision_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE r public.reports; prior public.report_urgency_decisions; saved public.report_urgency_decisions; actor_role text; normalized text:=btrim(reason);
BEGIN
  SELECT * INTO r FROM public.reports WHERE id=report_id FOR UPDATE;
  SELECT role::text INTO actor_role FROM public.profiles WHERE id=actor FOR SHARE;
  IF actor_role IS NULL OR actor_role NOT IN ('officer','admin') THEN RAISE EXCEPTION 'Desk officer access required.' USING ERRCODE='42501'; END IF;
  IF r.id IS NULL THEN RAISE EXCEPTION 'Report not found.' USING ERRCODE='P0002'; END IF;
  IF r.user_id=actor THEN RAISE EXCEPTION 'You cannot verify urgency on your own report.' USING ERRCODE='42501'; END IF;
  IF outcome IS NULL OR outcome NOT IN ('approved','declined') OR operation_id IS NULL OR normalized IS NULL OR char_length(normalized) NOT BETWEEN 3 AND 1000 THEN
    RAISE EXCEPTION 'Choose an urgency outcome and provide a reason (3-1000 characters).' USING ERRCODE='22023';
  END IF;
  SELECT * INTO prior FROM public.report_urgency_decisions d WHERE d.operation_id=record_report_urgency_decision.operation_id;
  IF prior.operation_id IS NOT NULL THEN
    IF ROW(prior.report_id,prior.actor_id,prior.outcome,prior.reason,prior.previous_operation_id)
      IS DISTINCT FROM ROW(report_id,actor,outcome,normalized,expected_decision_id) THEN
      RAISE EXCEPTION 'Urgency operation conflict; use a new operation ID.' USING ERRCODE='23505';
    END IF;
    IF r.urgency_decision_id IS DISTINCT FROM prior.operation_id THEN
      RAISE EXCEPTION 'Urgency decision was superseded; refresh before reviewing.' USING ERRCODE='23505';
    END IF;
    RETURN to_jsonb(r);
  END IF;
  IF r.citizen_priority IS DISTINCT FROM 'urgent' OR r.urgency_status IS NULL OR r.user_id IS NULL
    OR r.status::text<>'unresolved' OR r.cleanup_task_id IS NOT NULL OR r.validation_status::text='rejected' THEN
    RAISE EXCEPTION 'Report is not actionable, is closed/rejected, or is already assigned.' USING ERRCODE='23505';
  END IF;
  IF r.urgency_decision_id IS DISTINCT FROM expected_decision_id THEN RAISE EXCEPTION 'Urgency decision conflict; refresh before reviewing.' USING ERRCODE='23505'; END IF;
  IF outcome='approved' THEN
    IF r.validation_status::text IS DISTINCT FROM 'approved' THEN RAISE EXCEPTION 'Approve report validation before urgency.' USING ERRCODE='22023'; END IF;
    IF coalesce(r.on_private_property,false) AND r.property_owner_consent_status::text IS DISTINCT FROM 'obtained' THEN RAISE EXCEPTION 'Property consent is required before approval.' USING ERRCODE='22023'; END IF;
    IF coalesce(r.hazard_class,'standard') IN ('suspected_hazard','hazmat_required','hazard_review') THEN RAISE EXCEPTION 'Complete safety review before urgency approval.' USING ERRCODE='22023'; END IF;
    IF r.sla_started_at IS NULL THEN RAISE EXCEPTION 'Report lifecycle must be activated before urgency approval.' USING ERRCODE='22023'; END IF;
  END IF;
  INSERT INTO public.report_urgency_decisions(operation_id,report_id,actor_id,outcome,reason,previous_operation_id,report_context)
    VALUES(operation_id,report_id,actor,outcome,normalized,expected_decision_id,workflow_private.urgency_report_context(r)) RETURNING * INTO saved;
  UPDATE public.reports SET urgency_status=outcome,urgency_decision_id=operation_id,urgency_decided_at=saved.recorded_at,urgency_reason=normalized,updated_at=clock_timestamp()
    WHERE id=report_id RETURNING * INTO r;
  RETURN to_jsonb(r);
END $function$;
ALTER FUNCTION "public"."record_report_urgency_decision"(actor uuid, report_id uuid, outcome text, reason text, operation_id uuid, expected_decision_id uuid) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.read_report_urgency_queue(actor uuid, queue_status text DEFAULT 'pending'::text, page_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE actor_role text; result jsonb; total integer;
BEGIN
  SELECT role::text INTO actor_role FROM public.profiles WHERE id=actor;
  IF actor_role IS NULL OR actor_role NOT IN ('officer','admin') THEN RAISE EXCEPTION 'Desk officer access required.' USING ERRCODE='42501'; END IF;
  IF queue_status IS NULL OR queue_status NOT IN ('pending','approved','declined') OR page_limit IS NULL OR page_limit NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'Invalid urgency queue filter or limit.' USING ERRCODE='22023';
  END IF;
  SELECT count(*) INTO total FROM public.reports r WHERE r.citizen_priority='urgent' AND (CASE WHEN r.urgency_status='approved' AND NOT workflow_private.urgency_maturation_bypass(r) THEN 'pending' ELSE r.urgency_status END)=queue_status
    AND r.user_id IS NOT NULL AND r.status::text='unresolved' AND r.cleanup_task_id IS NULL AND r.validation_status::text<>'rejected';
  SELECT coalesce(jsonb_agg(q ORDER BY q.created_at,q.id),'[]'::jsonb) INTO result FROM (
    SELECT r.id,r.title,r.description,r.created_at,r.priority_reason,r.priority_explanation,r.validation_status,
      r.on_private_property,r.property_owner_consent_status,r.hazard_class,r.cluster_id,r.lifecycle_state,
      r.urgency_status,r.urgency_decision_id,r.urgency_decided_at,r.urgency_reason,r.sla_started_at,
      r.user_id<>actor AS review_allowed,
      r.urgency_status='approved' AND NOT workflow_private.urgency_maturation_bypass(r) AS needs_reverification,
      workflow_private.urgency_maturation_bypass(r) AND r.lifecycle_state IN ('maturing','sla_breached','clustered')
        AND NOT EXISTS(SELECT 1 FROM public.dispatch_access_blocks b WHERE (b.report_id=r.id OR b.cluster_id=r.cluster_id) AND b.cleared_at IS NULL)
        AND (r.cluster_id IS NULL OR (
          EXISTS(SELECT 1 FROM public.clusters c WHERE c.id=r.cluster_id AND c.status::text IN ('new','unresolved','prioritized','queued','monitoring'))
          AND NOT EXISTS(SELECT 1 FROM public.reports sibling WHERE sibling.cluster_id=r.cluster_id
            AND sibling.status::text NOT IN ('resolved','completed','closed','rejected')
            AND (sibling.cleanup_task_id IS NOT NULL OR EXISTS(SELECT 1 FROM public.dispatch_access_blocks b WHERE b.report_id=sibling.id AND b.cleared_at IS NULL)))
        )) AS dispatchable
    FROM public.reports r WHERE r.citizen_priority='urgent' AND (CASE WHEN r.urgency_status='approved' AND NOT workflow_private.urgency_maturation_bypass(r) THEN 'pending' ELSE r.urgency_status END)=queue_status AND r.user_id IS NOT NULL
      AND r.status::text='unresolved' AND r.cleanup_task_id IS NULL AND r.validation_status::text<>'rejected'
    ORDER BY r.created_at,r.id LIMIT page_limit
  ) q;
  RETURN jsonb_build_object('reports',result,'total',total,'limit',page_limit);
END $function$;
ALTER FUNCTION "public"."read_report_urgency_queue"(actor uuid, queue_status text, page_limit integer) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.read_crew_urgency_observations(actor uuid, report_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE role_name text; items jsonb;
BEGIN
 SELECT role::text INTO role_name FROM public.profiles WHERE id=actor;
 IF role_name IS NULL OR role_name NOT IN ('officer','admin','field_crew') THEN RAISE EXCEPTION 'Staff access required.' USING ERRCODE='42501'; END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY q.recorded_at DESC,q.operation_id),'[]'::jsonb) INTO items FROM (
  SELECT o.operation_id,o.report_id,o.task_id,o.observed_result,o.conditions,o.evidence_snapshot,o.recorded_at,
    CASE WHEN v.observation_id IS NOT NULL THEN jsonb_build_object('reason',v.reason,'reviewed_at',v.reviewed_at) END AS review
  FROM public.crew_urgency_observations o LEFT JOIN public.crew_urgency_reviews v ON v.observation_id=o.operation_id
  WHERE o.report_id=read_crew_urgency_observations.report_id AND (role_name IN ('officer','admin') OR o.actor_id=actor)
  ORDER BY o.recorded_at DESC,o.operation_id LIMIT 50
 ) q;
 RETURN jsonb_build_object('observations',items,'limit',50);
END $function$;
ALTER FUNCTION "public"."read_crew_urgency_observations"(actor uuid, report_id uuid) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.review_crew_urgency_observation(actor uuid, report_id uuid, observation_id text, reason text, operation_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE role_name text; o public.crew_urgency_observations; prior public.crew_urgency_reviews; normalized text:=btrim(reason);
BEGIN
 -- Serialize reviews without granting UPDATE on immutable observations.
 PERFORM pg_advisory_xact_lock(hashtextextended(observation_id,72631011));
 SELECT * INTO o FROM public.crew_urgency_observations WHERE crew_urgency_observations.operation_id=observation_id;
 SELECT role::text INTO role_name FROM public.profiles WHERE id=actor FOR SHARE;
 IF role_name IS NULL OR role_name NOT IN ('officer','admin') OR o.actor_id=actor THEN RAISE EXCEPTION 'Officer review required; no self-review.' USING ERRCODE='42501'; END IF;
 IF o.operation_id IS NULL OR o.report_id IS DISTINCT FROM report_id THEN RAISE EXCEPTION 'Observation not found.' USING ERRCODE='P0002'; END IF;
 IF EXISTS(SELECT 1 FROM public.reports WHERE id=report_id AND user_id=actor) THEN RAISE EXCEPTION 'No review of your own report.' USING ERRCODE='42501'; END IF;
 IF operation_id IS NULL OR normalized IS NULL OR char_length(normalized) NOT BETWEEN 3 AND 1500 THEN RAISE EXCEPTION 'Provide a review reason (3-1500 characters) and operation ID.' USING ERRCODE='22023'; END IF;
 SELECT * INTO prior FROM public.crew_urgency_reviews v WHERE v.observation_id=review_crew_urgency_observation.observation_id;
 IF prior.observation_id IS NOT NULL THEN
  IF prior.operation_id IS DISTINCT FROM operation_id OR prior.actor_id IS DISTINCT FROM actor OR prior.reason IS DISTINCT FROM normalized THEN
   RAISE EXCEPTION 'Observation already reviewed; refresh the saved review.' USING ERRCODE='23505';
  END IF;
  RETURN to_jsonb(prior)-'actor_id';
 END IF;
 INSERT INTO public.crew_urgency_reviews(observation_id,operation_id,actor_id,reason) VALUES(observation_id,operation_id,actor,normalized) RETURNING * INTO prior;
 RETURN to_jsonb(prior)-'actor_id';
END $function$;
ALTER FUNCTION "public"."review_crew_urgency_observation"(actor uuid, report_id uuid, observation_id text, reason text, operation_id uuid) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION workflow_private.resolve_report_barangay_fields()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE result jsonb;
BEGIN
 result:=public.resolve_report_barangay(extensions.ST_Y(NEW.location::extensions.geometry),extensions.ST_X(NEW.location::extensions.geometry));
 NEW.barangay:=result->>'barangay';NEW.barangay_resolution_status:=result->>'status';
 SELECT coalesce(array_agg(value),'{}'::text[]) INTO NEW.barangay_candidates FROM jsonb_array_elements_text(result->'candidates');
 NEW.barangay_resolution_checked_at:=statement_timestamp();RETURN NEW;
END $function$;
ALTER FUNCTION "workflow_private"."resolve_report_barangay_fields"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.get_report_lifecycle_summary()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
 WITH classified AS MATERIALIZED (
  SELECT coalesce(status::text,'(missing)') AS raw_status,
   CASE
    WHEN status IS NULL OR status::text NOT IN ('unresolved','pending','submitted','verified','assigned','in_progress','resolved','closed','completed','waiting_for_feedback','pending_owner_consent','rejected') THEN 'uncategorized'
    WHEN status::text IN ('resolved','closed','completed','waiting_for_feedback') THEN 'resolved'
    WHEN status::text='rejected' OR validation_status::text='rejected' THEN 'rejected'
    WHEN status::text='in_progress' OR stage::text='in_progress' THEN 'in_progress'
    WHEN cleanup_task_id IS NOT NULL OR status::text='assigned' OR stage::text='assigned' THEN 'assigned'
    WHEN validation_status::text IN ('approved','validated') OR status::text='verified' OR stage::text='acknowledged' THEN 'verified'
    ELSE 'submitted'
   END AS bucket
  FROM public.reports
 ) SELECT jsonb_build_object(
  'total',count(*),'snapshotAt',statement_timestamp(),'classificationVersion','pdt25-v1',
  'byLifecycle',jsonb_build_object(
   'submitted',count(*) FILTER(WHERE bucket='submitted'),
   'verified',count(*) FILTER(WHERE bucket='verified'),
   'assigned',count(*) FILTER(WHERE bucket='assigned'),
   'in_progress',count(*) FILTER(WHERE bucket='in_progress'),
   'resolved',count(*) FILTER(WHERE bucket='resolved'),
   'rejected',count(*) FILTER(WHERE bucket='rejected'),
   'uncategorized',count(*) FILTER(WHERE bucket='uncategorized')),
  'byStatus',coalesce((SELECT jsonb_object_agg(raw_status,n) FROM (SELECT raw_status,count(*) AS n FROM classified GROUP BY raw_status) s),'{}'::jsonb),
  'uncategorizedByStatus',coalesce((SELECT jsonb_object_agg(raw_status,n) FROM (SELECT raw_status,count(*) AS n FROM classified WHERE bucket='uncategorized' GROUP BY raw_status) s),'{}'::jsonb)
 ) FROM classified;
$function$;
ALTER FUNCTION "public"."get_report_lifecycle_summary"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.resolve_report_barangay(lat double precision, lng double precision)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE p extensions.geometry; candidates text[]; interiors integer; covered integer; nearby integer; assigned text; code text; source_hash text;
BEGIN
 IF lat IS NULL OR lng IS NULL OR NOT(lat BETWEEN -90 AND 90) OR NOT(lng BETWEEN -180 AND 180) THEN
  RETURN jsonb_build_object('status','invalid_coordinates','barangay',NULL,'candidates','[]'::jsonb);
 END IF;
 -- Fail closed for missing, duplicate, invalid or unexpected administrative polygons.
 IF (SELECT count(*) FROM public.spatial_zones WHERE zone_type='barangay')<>30
   OR EXISTS(SELECT 1 FROM public.pasig_barangay_roster r WHERE
    (SELECT count(*) FROM public.spatial_zones z WHERE z.zone_type='barangay' AND z.zone_name=r.name AND z.boundary IS NOT NULL
     AND extensions.ST_SRID(z.boundary)=4326 AND NOT extensions.ST_IsEmpty(z.boundary)
     AND extensions.ST_IsValid(z.boundary) AND extensions.GeometryType(z.boundary) IN ('POLYGON','MULTIPOLYGON'))<>1) THEN
  RETURN jsonb_build_object('status','dataset_incomplete','barangay',NULL,'candidates','[]'::jsonb);
 END IF;
 p:=extensions.ST_SetSRID(extensions.ST_Point(lng,lat),4326);
 SELECT array_agg(zone_name ORDER BY zone_name),count(*) FILTER(WHERE inside),count(*) FILTER(WHERE covers),count(*) FILTER(WHERE near_edge)
 INTO candidates,interiors,covered,nearby FROM (
  SELECT z.zone_name,extensions.ST_Contains(z.boundary,p) AS inside,extensions.ST_Covers(z.boundary,p) AS covers,
   extensions.ST_DWithin(extensions.ST_Boundary(z.boundary)::extensions.geography,p::extensions.geography,25) AS near_edge
  FROM public.spatial_zones z WHERE z.zone_type='barangay' AND
   (extensions.ST_Covers(z.boundary,p) OR extensions.ST_DWithin(extensions.ST_Boundary(z.boundary)::extensions.geography,p::extensions.geography,25))
 ) matches;
 candidates:=coalesce(candidates,'{}'::text[]);
 SELECT source_sha256 INTO source_hash FROM public.pasig_barangay_boundary_source WHERE singleton;
 IF interiors>1 THEN
  RETURN jsonb_build_object('status','overlap','barangay',NULL,'candidates',candidates,'border_buffer_m',25,'source','spatial_zones','dataset_sha256',source_hash);
 ELSIF covered>1 OR nearby>0 THEN
  RETURN jsonb_build_object('status','border','barangay',NULL,'candidates',candidates,'border_buffer_m',25,'source','spatial_zones','dataset_sha256',source_hash);
 ELSIF interiors=1 AND covered=1 THEN
  assigned:=candidates[1];SELECT psgc_code INTO code FROM public.pasig_barangay_roster WHERE name=assigned;
  RETURN jsonb_build_object('status','resolved','barangay',assigned,'psgc_code',code,'candidates',candidates,'border_buffer_m',25,'source','spatial_zones','dataset_sha256',source_hash);
 END IF;
 RETURN jsonb_build_object('status','unresolved','barangay',NULL,'candidates',candidates,'border_buffer_m',25,'source','spatial_zones','dataset_sha256',source_hash);
END $function$;
ALTER FUNCTION "public"."resolve_report_barangay"(lat double precision, lng double precision) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.import_pasig_barangay_boundaries(rows jsonb, source_url text, source_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE row jsonb; g extensions.geometry; geoms extensions.geometry[]:='{}'; raw_geoms jsonb[]:='{}'; names text[]:='{}'; ids text[]:='{}'; expected_name text; i integer; j integer; anchor extensions.geometry;
BEGIN
 IF jsonb_typeof(rows) IS DISTINCT FROM 'array' OR jsonb_array_length(rows)<>30
  OR source_url IS NULL OR source_url !~ '^https://' OR source_sha256 IS NULL OR source_sha256 !~ '^[a-f0-9]{64}$' THEN
  RAISE EXCEPTION 'A complete 30-polygon source with HTTPS provenance and SHA-256 is required.' USING ERRCODE='22023';
 END IF;
 FOR row IN SELECT value FROM jsonb_array_elements(rows) LOOP
  SELECT name INTO expected_name FROM public.pasig_barangay_roster WHERE psgc_code=row->>'psgc_code';
  IF expected_name IS NULL OR expected_name IS DISTINCT FROM row->>'name' OR expected_name=ANY(names) THEN
   RAISE EXCEPTION 'Missing, duplicate or mismatched Pasig PSGC/name.' USING ERRCODE='22023';
  END IF;
  g:=extensions.ST_GeomFromGeoJSON(row->'geometry');
  IF g IS NULL OR extensions.ST_SRID(g)<>4326 OR extensions.ST_IsEmpty(g) OR NOT extensions.ST_IsValid(g)
   OR extensions.GeometryType(g) NOT IN ('POLYGON','MULTIPOLYGON') THEN RAISE EXCEPTION 'Invalid WGS84 polygon: %',expected_name USING ERRCODE='22023'; END IF;
  IF NOT extensions.ST_CoveredBy(g,extensions.ST_MakeEnvelope(121.0,14.49,121.17,14.66,4326)) THEN
   RAISE EXCEPTION 'Polygon lies outside the Pasig validation envelope: %',expected_name USING ERRCODE='22023';
  END IF;
  geoms:=array_append(geoms,g);raw_geoms:=array_append(raw_geoms,row->'geometry');names:=array_append(names,expected_name);ids:=array_append(ids,'barangay_'||regexp_replace(lower(expected_name),'[^a-z0-9]+','_','g'));
 END LOOP;
 FOR i IN 1..30 LOOP
  FOR j IN (i+1)..30 LOOP
   IF extensions.ST_Area(extensions.ST_Intersection(geoms[i],geoms[j]))>0 THEN RAISE EXCEPTION 'Overlapping polygons: % / %',names[i],names[j] USING ERRCODE='22023'; END IF;
  END LOOP;
 END LOOP;
 LOCK TABLE public.spatial_zones IN SHARE ROW EXCLUSIVE MODE;
 IF EXISTS(SELECT 1 FROM public.spatial_zones WHERE zone_type='barangay' AND NOT(id=ANY(ids)))
  OR EXISTS(SELECT 1 FROM public.spatial_zones WHERE id=ANY(ids) AND zone_type<>'barangay') THEN
  RAISE EXCEPTION 'Existing zone IDs need manual reconciliation; no data was removed.' USING ERRCODE='23505';
 END IF;
 FOR i IN 1..30 LOOP
  anchor:=extensions.ST_PointOnSurface(geoms[i]);
  INSERT INTO public.spatial_zones(id,zone_name,zone_type,boundary_geojson,centroid_lat,centroid_lng)
   VALUES(ids[i],names[i],'barangay',raw_geoms[i],extensions.ST_Y(anchor),extensions.ST_X(anchor))
  ON CONFLICT(id) DO UPDATE SET zone_name=excluded.zone_name,boundary_geojson=excluded.boundary_geojson,centroid_lat=excluded.centroid_lat,centroid_lng=excluded.centroid_lng;
 END LOOP;
 INSERT INTO public.pasig_barangay_boundary_source(singleton,source_url,source_sha256) VALUES(true,source_url,source_sha256)
 ON CONFLICT(singleton) DO UPDATE SET source_url=excluded.source_url,source_sha256=excluded.source_sha256,imported_at=clock_timestamp();
 RETURN jsonb_build_object('imported',30,'source_sha256',source_sha256,'report_reconciliation_required',true);
END $function$;
ALTER FUNCTION "public"."import_pasig_barangay_boundaries"(rows jsonb, source_url text, source_sha256 text) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION workflow_private.assert_cleanup_photo_pair(r jsonb)
 RETURNS void
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
BEGIN
 IF coalesce(r->>'issue_type','') IN ('scouting','acknowledge_only') THEN RETURN; END IF;
 IF nullif(btrim(r->>'before_photo_url'),'') IS NULL OR nullif(btrim(r->>'after_photo_url'),'') IS NULL THEN
  RAISE EXCEPTION 'Before and After photos are required for physical cleanup' USING ERRCODE='22023';
 END IF;
 IF r->>'before_photo_url'=r->>'after_photo_url' OR
  (nullif(r->>'before_photo_hash','') IS NOT NULL AND r->>'before_photo_hash'=r->>'after_photo_hash') THEN
  RAISE EXCEPTION 'Before and After must be different photos' USING ERRCODE='22023';
 END IF;
END; $function$;
ALTER FUNCTION "workflow_private"."assert_cleanup_photo_pair"(r jsonb) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION workflow_private.guard_cleanup_resolution()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
 IF NEW.status::text IN ('resolved','completed','waiting_for_feedback') AND
    OLD.status::text NOT IN ('resolved','completed','closed','waiting_for_feedback') THEN
  PERFORM workflow_private.assert_cleanup_photo_pair(to_jsonb(NEW));
  IF coalesce(NEW.issue_type::text,'') NOT IN ('scouting','acknowledge_only') AND
    (nullif(btrim(NEW.cleanup_action_notes),'') IS NULL OR length(NEW.cleanup_action_notes)>2000) THEN
   RAISE EXCEPTION 'Action notes are required (maximum 2000 characters)' USING ERRCODE='22023';
  END IF;
  NEW.lgu_resolved_at:=now();
 ELSIF OLD.status::text IN ('resolved','completed','closed','waiting_for_feedback') AND
   (NEW.before_photo_url IS NULL AND OLD.before_photo_url IS NOT NULL OR
    NEW.after_photo_url IS NULL AND OLD.after_photo_url IS NOT NULL OR
    jsonb_array_length(NEW.before_photos)<jsonb_array_length(OLD.before_photos) OR
    jsonb_array_length(NEW.after_photos)<jsonb_array_length(OLD.after_photos)) THEN
  RAISE EXCEPTION 'Completed cleanup photos cannot be deleted' USING ERRCODE='22023';
 END IF;
 IF OLD.status::text IN ('resolved','completed','closed','waiting_for_feedback') AND
   NEW.status::text IN ('resolved','completed','closed','waiting_for_feedback') THEN
  NEW.lgu_resolved_at:=OLD.lgu_resolved_at;
  IF OLD.before_photo_url IS NOT NULL AND OLD.after_photo_url IS NOT NULL THEN
   PERFORM workflow_private.assert_cleanup_photo_pair(to_jsonb(NEW));
  END IF;
 END IF;
 RETURN NEW;
END; $function$;
ALTER FUNCTION "workflow_private"."guard_cleanup_resolution"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION workflow_private.guard_cleanup_receipt()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE r public.reports; matches_current boolean;
BEGIN
 IF NEW.outcome NOT IN ('cleaned','already_resolved') THEN RETURN NEW; END IF;
 SELECT * INTO r FROM public.reports WHERE id=NEW.report_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Report no longer exists'; END IF;
 IF nullif(btrim(NEW.notes),'') IS NULL OR length(NEW.notes)>2000 THEN
  RAISE EXCEPTION 'Action notes are required (maximum 2000 characters)' USING ERRCODE='22023';
 END IF;
 matches_current:=jsonb_array_length(NEW.evidence_refs)>0 AND NOT EXISTS(
    SELECT 1 FROM jsonb_array_elements_text(NEW.evidence_refs) e(ref)
    WHERE nullif(btrim(ref),'') IS NULL OR NOT (
      ref=coalesce(r.after_photo_url,'') OR EXISTS(
       SELECT 1 FROM jsonb_array_elements(coalesce(r.after_photos,'[]')) p WHERE p->>'url'=ref)));
 NEW.evidence_verification:=CASE WHEN matches_current THEN 'verified' ELSE 'unverified' END;
 -- Historical claims remain reviewable, but cannot become accepted cleanup proof.
 IF NEW.disposition IN ('contested','verification_required') THEN RETURN NEW; END IF;
 IF NEW.outcome='cleaned' THEN PERFORM workflow_private.assert_cleanup_photo_pair(to_jsonb(r)); END IF;
 IF coalesce(r.issue_type::text,'') NOT IN ('scouting','acknowledge_only') AND NOT matches_current THEN
  RAISE EXCEPTION 'Outcome evidence must reference this report''s uploaded After photos' USING ERRCODE='22023';
 END IF;
 RETURN NEW;
END; $function$;
ALTER FUNCTION "workflow_private"."guard_cleanup_receipt"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION workflow_private.guard_cleanup_task_completion()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE r public.reports; linked boolean:=false;
BEGIN
 IF NEW.status::text<>'completed' OR OLD.status::text='completed' OR
  NOT (NEW.completion_result='cleanup_completed' OR
       (NEW.completion_result='completed' AND NEW.task_type::text IN ('Cleanup','Sweeper'))) THEN RETURN NEW; END IF;
 FOR r IN SELECT * FROM public.reports WHERE cleanup_task_id=NEW.id AND status::text<>'rejected' ORDER BY id FOR UPDATE LOOP
  linked:=true;
  IF NOT EXISTS(SELECT 1 FROM public.task_report_outcomes o WHERE o.report_id=r.id AND o.task_id=NEW.id
   AND o.outcome='already_resolved' AND o.disposition='acknowledged_already_resolved' AND o.evidence_verification='verified') THEN
   PERFORM workflow_private.assert_cleanup_photo_pair(to_jsonb(r));
  END IF;
  IF nullif(btrim(NEW.completion_notes),'') IS NULL AND NOT EXISTS(
   SELECT 1 FROM public.task_report_outcomes o WHERE o.report_id=r.id AND o.task_id=NEW.id
    AND o.outcome IN ('cleaned','already_resolved') AND o.disposition IN ('applied','acknowledged_already_resolved')
    AND o.evidence_verification='verified' AND nullif(btrim(o.notes),'') IS NOT NULL) THEN
   RAISE EXCEPTION 'Action notes are required for each cleanup report' USING ERRCODE='22023';
  END IF;
 END LOOP;
 IF NOT linked THEN
  PERFORM workflow_private.assert_cleanup_photo_pair(to_jsonb(NEW));
  IF nullif(btrim(NEW.completion_notes),'') IS NULL THEN
   RAISE EXCEPTION 'Action notes are required for cleanup completion' USING ERRCODE='22023';
  END IF;
 END IF;
 RETURN NEW;
END; $function$;
ALTER FUNCTION "workflow_private"."guard_cleanup_task_completion"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION workflow_private.cleanup_proof_fingerprint(r reports)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
 SELECT md5(jsonb_build_array(r.before_photo_url,r.after_photo_url,r.before_photo_hash,r.after_photo_hash,r.before_photos,r.after_photos,extract(epoch from r.lgu_resolved_at),r.cleanup_action_notes)::text);
$function$;
ALTER FUNCTION "workflow_private"."cleanup_proof_fingerprint"(r reports) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.read_operational_events(actor uuid, p_task_id uuid DEFAULT NULL::uuid, p_report_id uuid DEFAULT NULL::uuid, p_before_id bigint DEFAULT NULL::bigint, p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=actor AND p.role::text IN ('officer','admin')) THEN
  RAISE EXCEPTION 'Desk audit access required' USING ERRCODE='42501';
 END IF;
 IF p_limit IS NULL OR p_limit<1 OR p_limit>100 OR p_before_id<1 THEN RAISE EXCEPTION 'Invalid event page' USING ERRCODE='22023'; END IF;
 RETURN (
 WITH scoped AS NOT MATERIALIZED (
  SELECT e.* FROM public.operational_events e WHERE (p_task_id IS NULL OR e.task_id=p_task_id) AND (p_report_id IS NULL OR e.report_id=p_report_id)
 ), page AS (
  SELECT e.* FROM scoped e WHERE p_before_id IS NULL OR e.id<p_before_id ORDER BY e.id DESC LIMIT p_limit+1
 ), visible AS (SELECT * FROM page ORDER BY id DESC LIMIT p_limit), last_assignment AS (
  SELECT * FROM scoped WHERE event_type='assignment' AND report_id IS NULL ORDER BY id DESC LIMIT 1
 ), milestones AS (
  SELECT a.occurred_at assigned_at,
   min(e.occurred_at) FILTER(WHERE e.event_type='acknowledgement') acknowledged_at,
   min(e.occurred_at) FILTER(WHERE e.event_type='completion') completed_at
  FROM last_assignment a LEFT JOIN scoped e ON e.task_id=a.task_id AND e.report_id IS NULL AND e.assignment_generation=a.assignment_generation AND e.id>=a.id AND e.time_basis='server'
  WHERE coalesce((a.details->>'assigned')::boolean,true) GROUP BY a.occurred_at
 ) SELECT jsonb_build_object(
  'events',coalesce((SELECT jsonb_agg(jsonb_build_object('id',e.id::text,'event_type',e.event_type,'task_id',e.task_id,'report_id',e.report_id,
   'actor_id',e.actor_id,'assignment_generation',e.assignment_generation,'occurred_at',e.occurred_at,'recorded_at',e.recorded_at,'time_basis',e.time_basis,'details',e.details,
   'completion_to_verification_seconds',CASE WHEN e.event_type='verification' THEN (
    SELECT extract(epoch FROM e.occurred_at-c.occurred_at) FROM public.operational_events c
    WHERE c.event_type='completion' AND c.report_id=e.report_id AND c.occurred_at=(e.details->>'source_completed_at')::timestamptz
     AND c.occurred_at<=e.occurred_at AND c.time_basis='server' ORDER BY c.id DESC LIMIT 1) END) ORDER BY e.id DESC) FROM visible e),'[]'::jsonb),
  'has_more',(SELECT count(*)>p_limit FROM page),
  'next_cursor',CASE WHEN (SELECT count(*)>p_limit FROM page) THEN (SELECT min(id)::text FROM visible) END,
  'server_turnaround',CASE WHEN p_task_id IS NOT NULL AND p_report_id IS NULL THEN coalesce((
   SELECT jsonb_build_object('assignment_to_acknowledgement_seconds',CASE WHEN acknowledged_at>=assigned_at THEN extract(epoch FROM acknowledged_at-assigned_at) END,
    'acknowledgement_to_completion_seconds',CASE WHEN completed_at>=acknowledged_at THEN extract(epoch FROM completed_at-acknowledged_at) END) FROM milestones),
    jsonb_build_object('assignment_to_acknowledgement_seconds',NULL,'acknowledgement_to_completion_seconds',NULL)) END
 )
 );
END; $function$;
ALTER FUNCTION "public"."read_operational_events"(actor uuid, p_task_id uuid, p_report_id uuid, p_before_id bigint, p_limit integer) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION operational_private.immutable_event()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN RAISE EXCEPTION 'Operational events are append-only' USING ERRCODE='42501'; END; $function$;
ALTER FUNCTION "operational_private"."immutable_event"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION operational_private.arrival(receipt jsonb, task uuid, report uuid, actor uuid, generation bigint, disposition text)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE stamp timestamptz; received timestamptz:=clock_timestamp();
BEGIN
 IF receipt IS NULL OR receipt->>'verification' IS DISTINCT FROM 'device_gps' OR
  receipt->>'crew_id' IS DISTINCT FROM actor::text OR receipt->>'task_id' IS DISTINCT FROM task::text OR
  receipt->>'assignment_generation' IS DISTINCT FROM generation::text OR
  (report IS NOT NULL AND receipt->>'incident_id' IS DISTINCT FROM report::text) THEN RETURN; END IF;
 BEGIN stamp:=(receipt->>'arrived_at')::timestamptz; EXCEPTION WHEN invalid_datetime_format OR datetime_field_overflow THEN RETURN; END;
 -- Operational receipts predate neither the system nor the browser-compatible calendar range.
 IF stamp IS NULL OR NOT isfinite(stamp) OR stamp<'2020-01-01T00:00:00Z'::timestamptz OR stamp>received+interval '5 minutes' THEN RETURN; END IF;
 PERFORM operational_private.emit('arrival',task,report,actor,generation,stamp,'device_reported',
  concat('arrival:',task,':',report,':',actor,':',generation,':',receipt->>'report_claim_generation',':',extract(epoch FROM stamp)),
  jsonb_build_object('provenance','device_gps_receipt','disposition',disposition));
END; $function$;
ALTER FUNCTION "operational_private"."arrival"(receipt jsonb, task uuid, report uuid, actor uuid, generation bigint, disposition text) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION operational_private.capture_row()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE n jsonb:=to_jsonb(NEW); o jsonb:=CASE WHEN TG_OP='UPDATE' THEN to_jsonb(OLD) ELSE '{}'::jsonb END;
 actor uuid:=nullif(current_setting('ecopin.operational_actor',true),'')::uuid;
 receipt jsonb:=coalesce(nullif(current_setting('ecopin.operational_receipt',true),''),'{}')::jsonb;
 task uuid; report uuid; generation bigint; stamp timestamptz:=clock_timestamp(); slot text; photo jsonb; photos jsonb; previous jsonb; assigned boolean;
BEGIN
 IF TG_TABLE_NAME='cleanup_tasks' THEN
  task:=NEW.id;generation:=coalesce((n->>'assignment_generation')::bigint,0);
  assigned:=(CASE WHEN jsonb_typeof(n->'assigned_crew_ids')='array' THEN jsonb_array_length(n->'assigned_crew_ids')>0 ELSE false END) OR n->>'assigned_field_crew_id' IS NOT NULL;
  IF (TG_OP='UPDATE' OR assigned) AND
    (n->'assigned_crew_ids' IS DISTINCT FROM o->'assigned_crew_ids' OR n->'assigned_field_crew_id' IS DISTINCT FROM o->'assigned_field_crew_id') THEN
   PERFORM operational_private.emit('assignment',task,NULL,actor,generation,stamp,'server',concat(task,':assignment:',generation,':',n->>'fc_version'),
    jsonb_build_object('attribution',CASE WHEN actor IS NULL THEN 'not_recorded' ELSE 'authenticated_writer' END,
     'assigned',assigned));
  END IF;
  IF n->>'status' IN ('en_route','in_progress') AND coalesce(o->>'status','') NOT IN ('en_route','in_progress','completed','cancelled') THEN
   PERFORM operational_private.emit('acknowledgement',task,NULL,actor,generation,stamp,'server',concat(task,':ack:',generation),jsonb_build_object('status',n->>'status'));
  END IF;
  IF n->>'status'='completed' AND o->>'status' IS DISTINCT FROM 'completed' THEN
   PERFORM operational_private.emit('completion',task,NULL,coalesce(actor,(n->>'completed_by')::uuid),generation,
    coalesce((n->>'completed_at')::timestamptz,stamp),'server',concat(task,':completion:',generation,':',n->>'fc_version'),jsonb_build_object('outcome',n->>'completion_result'));
   FOR photo IN SELECT value FROM jsonb_array_elements(CASE WHEN jsonb_typeof(receipt->'investigations')='array' THEN receipt->'investigations' ELSE '[]'::jsonb END) LOOP
    report:=NULL;
    IF photo->>'incident_id'=task::text THEN
     IF EXISTS(SELECT 1 FROM public.reports r WHERE r.cleanup_task_id=task) THEN CONTINUE; END IF;
    ELSE
     SELECT r.id INTO report FROM public.reports r WHERE r.id::text=photo->>'incident_id' AND r.cleanup_task_id=task;
     IF report IS NULL THEN CONTINUE; END IF;
    END IF;
    PERFORM operational_private.arrival(photo,task,report,actor,generation,'submitted_with_completion');
   END LOOP;
  END IF;
 ELSE
  report:=NEW.id;task:=(n->>'cleanup_task_id')::uuid;
  SELECT t.assignment_generation INTO generation FROM public.cleanup_tasks t WHERE t.id=task;
  IF n->>'stage'='acknowledged' AND o->>'stage' IS DISTINCT FROM 'acknowledged' THEN
   PERFORM operational_private.emit('acknowledgement',task,report,actor,generation,stamp,'server',concat(report,':ack:',n->>'report_claim_generation'),jsonb_build_object('stage','acknowledged'));
  END IF;
  IF n->>'status' IN ('resolved','completed','waiting_for_feedback') AND coalesce(o->>'status','') NOT IN ('resolved','completed','closed','waiting_for_feedback') THEN
   PERFORM operational_private.emit('completion',task,report,actor,generation,coalesce((n->>'lgu_resolved_at')::timestamptz,stamp),'server',
    concat(report,':completion:',n->>'lgu_resolved_at',':',n->>'fc_version'),jsonb_build_object('status',n->>'status','canonical_time_recorded',n->>'lgu_resolved_at' IS NOT NULL));
  END IF;
 END IF;
 FOREACH slot IN ARRAY ARRAY['before','after'] LOOP
  photos:=coalesce(n->(slot||'_photos'),'[]');previous:=coalesce(o->(slot||'_photos'),'[]');
  IF nullif(n->>(slot||'_photo_url'),'') IS NOT NULL AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(photos) p WHERE p->>'url'=n->>(slot||'_photo_url')) THEN
   photos:=photos||jsonb_build_array(jsonb_build_object('url',n->>(slot||'_photo_url')));
  END IF;
  FOR photo IN SELECT value FROM jsonb_array_elements(photos) LOOP
   IF nullif(photo->>'url','') IS NOT NULL AND photo->>'url' IS DISTINCT FROM o->>(slot||'_photo_url') AND
    NOT EXISTS(SELECT 1 FROM jsonb_array_elements(previous) p WHERE p->>'url'=photo->>'url') THEN
    PERFORM operational_private.emit('evidence_submission',task,CASE WHEN TG_TABLE_NAME='reports' THEN NEW.id END,actor,generation,stamp,'server',
     concat(TG_TABLE_NAME,':',NEW.id,':evidence:',slot,':',photo->>'url'),jsonb_build_object('slot',slot));
   END IF;
  END LOOP;
 END LOOP;
 RETURN NEW;
END; $function$;
ALTER FUNCTION "operational_private"."capture_row"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION operational_private.capture_verification()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE task uuid; generation bigint;
BEGIN
 SELECT e.task_id,e.assignment_generation INTO task,generation FROM public.operational_events e
 WHERE e.report_id=NEW.report_id AND e.event_type='completion' AND e.occurred_at=NEW.completed_at ORDER BY e.id DESC LIMIT 1;
 IF task IS NULL THEN SELECT r.cleanup_task_id,t.assignment_generation INTO task,generation FROM public.reports r LEFT JOIN public.cleanup_tasks t ON t.id=r.cleanup_task_id WHERE r.id=NEW.report_id; END IF;
 PERFORM operational_private.emit('verification',task,NEW.report_id,NEW.verified_by,generation,NEW.verified_at,'server',
  concat('verification:',NEW.id),jsonb_build_object('publication_id',NEW.id,'source_completed_at',NEW.completed_at));
 RETURN NEW;
END; $function$;
ALTER FUNCTION "operational_private"."capture_verification"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.read_unprocessed_report_alerts(actor uuid, cursor_created timestamp with time zone DEFAULT NULL::timestamp with time zone, cursor_id uuid DEFAULT NULL::uuid, page_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE result jsonb;
BEGIN
 IF actor IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=actor AND p.role::text IN ('officer','admin')
  AND (p.suspended_until IS NULL OR p.suspended_until<=statement_timestamp())) THEN
  RAISE EXCEPTION 'Active staff access required' USING ERRCODE='42501';
 END IF;
 IF page_limit IS NULL OR page_limit<1 OR page_limit>100 OR (cursor_created IS NULL)<>(cursor_id IS NULL)
  OR (cursor_created IS NOT NULL AND NOT isfinite(cursor_created)) THEN
  RAISE EXCEPTION 'Invalid alert pagination' USING ERRCODE='22023';
 END IF;
 WITH base AS MATERIALIZED (SELECT * FROM workflow_private.unprocessed_report_alerts),
 page AS (SELECT * FROM base WHERE cursor_created IS NULL OR (created_at,report_id)>(cursor_created,cursor_id)
  ORDER BY created_at,report_id LIMIT page_limit+1),
 shown AS (SELECT * FROM page ORDER BY created_at,report_id LIMIT page_limit)
 SELECT jsonb_build_object('version','unprocessed-alerts-v1','generated_at',statement_timestamp(),
  'total',(SELECT count(*) FROM base),'overdue_count',(SELECT count(*) FROM base WHERE state='overdue'),
  'approaching_count',(SELECT count(*) FROM base WHERE state='approaching'),
  'reports',coalesce((SELECT jsonb_agg(to_jsonb(s) ORDER BY created_at,report_id) FROM shown s),'[]'::jsonb),
  'next_cursor',CASE WHEN (SELECT count(*) FROM page)>page_limit THEN
   (SELECT jsonb_build_object('created_at',created_at,'report_id',report_id) FROM shown ORDER BY created_at DESC,report_id DESC LIMIT 1) END)
 INTO result;
 RETURN result;
END; $function$;
ALTER FUNCTION "public"."read_unprocessed_report_alerts"(actor uuid, cursor_created timestamp with time zone, cursor_id uuid, page_limit integer) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.escalate_unprocessed_reports()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE result jsonb; locked_ids uuid[];
BEGIN
 SELECT coalesce(array_agg(id),'{}'::uuid[]) INTO locked_ids FROM (
  SELECT r.id FROM public.reports r JOIN workflow_private.unprocessed_report_alerts q ON q.report_id=r.id
  WHERE q.age_days>=5 AND q.created_at>(SELECT coalesce(max(b.cutoff),'-infinity'::timestamptz) FROM workflow_private.unprocessed_escalation_baseline b) AND EXISTS(SELECT 1 FROM public.profiles p WHERE p.role::text IN ('officer','admin')
   AND (p.suspended_until IS NULL OR p.suspended_until<=statement_timestamp()) AND NOT EXISTS(
    SELECT 1 FROM workflow_private.unprocessed_alert_deliveries d WHERE d.report_id=r.id AND d.recipient_id=p.id AND d.age_day=q.age_days))
  ORDER BY r.created_at,r.id LIMIT 500 FOR UPDATE OF r SKIP LOCKED
 ) locked;
 WITH recipients AS MATERIALIZED (
  SELECT id FROM public.profiles WHERE role::text IN ('officer','admin')
   AND (suspended_until IS NULL OR suspended_until<=statement_timestamp())
 ), candidates AS MATERIALIZED (
  SELECT q.report_id AS id,q.age_days,q.missing_acknowledgement,q.missing_assignment
  FROM workflow_private.unprocessed_report_alerts q WHERE q.report_id=ANY(locked_ids) AND q.age_days>=5 AND q.created_at>(SELECT coalesce(max(b.cutoff),'-infinity'::timestamptz) FROM workflow_private.unprocessed_escalation_baseline b)
 ), claims AS (
  INSERT INTO workflow_private.unprocessed_alert_deliveries(report_id,recipient_id,age_day)
  SELECT c.id,p.id,c.age_days FROM candidates c CROSS JOIN recipients p
  ON CONFLICT DO NOTHING RETURNING *
 ), inserted AS (
  INSERT INTO public.notifications(user_id,report_id,type,title,body)
  SELECT d.recipient_id,d.report_id,'general'::public.notification_type,
   CASE WHEN EXISTS(SELECT 1 FROM workflow_private.unprocessed_alert_deliveries old WHERE old.report_id=d.report_id AND old.recipient_id=d.recipient_id)
    THEN 'Unprocessed incident reminder' ELSE '5-day incident escalation' END,
   format('Report %s has waited %s days since submission. Missing: %s. Review the incident and coordinate action.',d.report_id,d.age_day,
    concat_ws(' and ',CASE WHEN c.missing_acknowledgement THEN 'acknowledgement' END,CASE WHEN c.missing_assignment THEN 'crew assignment' END))
  FROM claims d JOIN candidates c ON c.id=d.report_id RETURNING report_id
 ) SELECT jsonb_build_object('reports_checked',(SELECT count(*) FROM candidates),'notifications_created',(SELECT count(*) FROM inserted)) INTO result;
 RETURN result;
END; $function$;
ALTER FUNCTION "public"."escalate_unprocessed_reports"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.touch_crew_presence(actor uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE seen timestamptz;
BEGIN
 IF actor IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=actor AND p.role::text='field_crew'
  AND (p.suspended_until IS NULL OR p.suspended_until<=statement_timestamp())) THEN
  RAISE EXCEPTION 'Active field crew required' USING ERRCODE='42501';
 END IF;
 INSERT INTO operational_private.crew_presence(crew_id,last_seen_at) VALUES(actor,statement_timestamp())
 ON CONFLICT(crew_id) DO UPDATE SET last_seen_at=excluded.last_seen_at
  WHERE crew_presence.last_seen_at<excluded.last_seen_at-interval '20 seconds' RETURNING last_seen_at INTO seen;
 IF seen IS NULL THEN SELECT last_seen_at INTO seen FROM operational_private.crew_presence WHERE crew_id=actor; END IF;
 RETURN jsonb_build_object('seen_at',seen);
END; $function$;
ALTER FUNCTION "public"."touch_crew_presence"(actor uuid) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.read_live_operations(actor uuid, before_id bigint DEFAULT NULL::bigint, page_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE result jsonb;
BEGIN
 IF actor IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=actor AND p.role::text IN ('officer','admin')
  AND (p.suspended_until IS NULL OR p.suspended_until<=statement_timestamp())) THEN
  RAISE EXCEPTION 'Active staff access required' USING ERRCODE='42501';
 END IF;
 IF page_limit IS NULL OR page_limit<1 OR page_limit>100 OR before_id<1 THEN RAISE EXCEPTION 'Invalid feed page' USING ERRCODE='22023'; END IF;
 IF (SELECT count(*) FROM public.field_crews)>500 THEN RAISE EXCEPTION 'Crew roster exceeds feed capacity; no partial roster returned' USING ERRCODE='54000'; END IF;
 WITH page AS (
  SELECT * FROM public.operational_events e WHERE e.task_id IS NOT NULL AND (before_id IS NULL OR e.id<before_id)
  ORDER BY e.id DESC LIMIT page_limit+1
 ), visible AS (SELECT * FROM page ORDER BY id DESC LIMIT page_limit), people AS MATERIALIZED (
  SELECT p.id,h.last_seen_at FROM public.profiles p LEFT JOIN operational_private.crew_presence h ON h.crew_id=p.id
  WHERE p.role::text='field_crew' AND (p.suspended_until IS NULL OR p.suspended_until<=statement_timestamp())
 ), membership AS (
  SELECT DISTINCT f.id AS crew_id,p.id AS member_id,p.last_seen_at FROM public.field_crews f
  CROSS JOIN LATERAL unnest(coalesce(f.member_profile_ids,'{}'::uuid[])||ARRAY[f.team_lead_profile_id]) u(id)
  JOIN people p ON p.id=u.id
 ), groups AS (
  SELECT f.id AS crew_id,f.name FROM public.field_crews f
  UNION ALL SELECT NULL,'Other field crew' WHERE EXISTS(SELECT 1 FROM people p WHERE NOT EXISTS(SELECT 1 FROM membership m WHERE m.member_id=p.id))
 ), members AS (
  SELECT * FROM membership UNION ALL SELECT NULL,p.id,p.last_seen_at FROM people p WHERE NOT EXISTS(SELECT 1 FROM membership m WHERE m.member_id=p.id)
 ), roster AS (
  SELECT g.crew_id,g.name,count(m.member_id) AS member_count,
   count(m.member_id) FILTER(WHERE m.last_seen_at>=statement_timestamp()-interval '90 seconds') AS recent_members,
   count(m.member_id) FILTER(WHERE m.last_seen_at<statement_timestamp()-interval '90 seconds') AS quiet_members,
   count(m.member_id) FILTER(WHERE m.last_seen_at IS NULL) AS unknown_members,max(m.last_seen_at) AS last_seen_at
  FROM groups g LEFT JOIN members m ON m.crew_id IS NOT DISTINCT FROM g.crew_id GROUP BY g.crew_id,g.name
 ) SELECT jsonb_build_object('version','live-operations-v1','generated_at',statement_timestamp(),'presence_window_seconds',90,
  'latest_event_id',(SELECT max(id)::text FROM public.operational_events WHERE task_id IS NOT NULL),
  'events',coalesce((SELECT jsonb_agg(jsonb_build_object('event_id',e.id::text,'event_type',e.event_type,'task_id',e.task_id,
   'occurred_at',e.occurred_at,'recorded_at',e.recorded_at,'time_basis',e.time_basis,
   'details',jsonb_strip_nulls(jsonb_build_object('from_status',e.details->'from_status','to_status',e.details->'to_status','assigned',e.details->'assigned','slot',e.details->'slot','disposition',e.details->'disposition')))
   ORDER BY e.id DESC) FROM visible e),'[]'::jsonb),
  'has_more',(SELECT count(*)>page_limit FROM page),'next_cursor',CASE WHEN (SELECT count(*)>page_limit FROM page) THEN (SELECT min(id)::text FROM visible) END,
  'crew_count',(SELECT count(*) FROM people),'recent_members',(SELECT count(*) FROM people WHERE last_seen_at>=statement_timestamp()-interval '90 seconds'),
  'quiet_members',(SELECT count(*) FROM people WHERE last_seen_at<statement_timestamp()-interval '90 seconds'),'unknown_members',(SELECT count(*) FROM people WHERE last_seen_at IS NULL),
  'crews',coalesce((SELECT jsonb_agg(to_jsonb(r) ORDER BY name,crew_id) FROM roster r),'[]'::jsonb)) INTO result;
 RETURN result;
END; $function$;
ALTER FUNCTION "public"."read_live_operations"(actor uuid, before_id bigint, page_limit integer) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.create_support_ticket(actor uuid, ticket_category text, ticket_description text, ticket_report_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE t public.support_tickets;
BEGIN
 IF actor IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=actor AND p.role::text='citizen'
  AND (p.suspended_until IS NULL OR p.suspended_until<=statement_timestamp())) THEN
  RAISE EXCEPTION 'Active citizen access required' USING ERRCODE='42501';
 END IF;
 IF ticket_report_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.reports r WHERE r.id=ticket_report_id AND r.user_id=actor) THEN
  RAISE EXCEPTION 'Report not found' USING ERRCODE='P0002';
 END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('support_ticket:'||actor::text,0));
 IF (SELECT count(*) FROM public.support_tickets s WHERE s.citizen_id=actor AND s.status IN ('open','in_progress'))>=5 THEN
  RAISE EXCEPTION 'Too many open tickets' USING ERRCODE='53400';
 END IF;
 INSERT INTO public.support_tickets(citizen_id,report_id,category,description)
 VALUES(actor,ticket_report_id,ticket_category,btrim(ticket_description)) RETURNING * INTO t;
 RETURN public.support_ticket_json(t);
END; $function$;
ALTER FUNCTION "public"."create_support_ticket"(actor uuid, ticket_category text, ticket_description text, ticket_report_id uuid) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.read_my_support_tickets(actor uuid, cursor_created timestamp with time zone DEFAULT NULL::timestamp with time zone, cursor_id uuid DEFAULT NULL::uuid, page_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE result jsonb;
BEGIN
 IF actor IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=actor AND p.role::text='citizen') THEN
  RAISE EXCEPTION 'Citizen access required' USING ERRCODE='42501';
 END IF;
 IF page_limit IS NULL OR page_limit<1 OR page_limit>50 OR (cursor_created IS NULL)<>(cursor_id IS NULL)
  OR (cursor_created IS NOT NULL AND NOT isfinite(cursor_created)) THEN
  RAISE EXCEPTION 'Invalid ticket pagination' USING ERRCODE='22023';
 END IF;
 WITH page AS (SELECT * FROM public.support_tickets s WHERE s.citizen_id=actor
   AND (cursor_created IS NULL OR (s.created_at,s.id)<(cursor_created,cursor_id))
   ORDER BY s.created_at DESC,s.id DESC LIMIT page_limit+1),
 shown AS (SELECT * FROM page ORDER BY created_at DESC,id DESC LIMIT page_limit)
 SELECT jsonb_build_object('version','support-tickets-v1',
  'tickets',coalesce((SELECT jsonb_agg(public.support_ticket_json(s) ORDER BY s.created_at DESC,s.id DESC) FROM shown s),'[]'::jsonb),
  'next_cursor',CASE WHEN (SELECT count(*) FROM page)>page_limit THEN
   (SELECT jsonb_build_object('created_at',created_at,'id',id) FROM shown ORDER BY created_at,id LIMIT 1) END)
 INTO result;
 RETURN result;
END; $function$;
ALTER FUNCTION "public"."read_my_support_tickets"(actor uuid, cursor_created timestamp with time zone, cursor_id uuid, page_limit integer) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.read_my_support_ticket(actor uuid, ticket_ref text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE t public.support_tickets;
BEGIN
 IF actor IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=actor AND p.role::text='citizen') THEN
  RAISE EXCEPTION 'Citizen access required' USING ERRCODE='42501';
 END IF;
 SELECT * INTO t FROM public.support_tickets s WHERE s.citizen_id=actor AND s.reference=upper(btrim(ticket_ref));
 IF NOT FOUND THEN RAISE EXCEPTION 'Ticket not found' USING ERRCODE='P0002'; END IF;
 RETURN public.support_ticket_json(t);
END; $function$;
ALTER FUNCTION "public"."read_my_support_ticket"(actor uuid, ticket_ref text) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.read_support_ticket_queue(actor uuid, status_filter text DEFAULT NULL::text, cursor_created timestamp with time zone DEFAULT NULL::timestamp with time zone, cursor_id uuid DEFAULT NULL::uuid, page_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE result jsonb;
BEGIN
 IF actor IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=actor AND p.role::text IN ('officer','admin')
  AND (p.suspended_until IS NULL OR p.suspended_until<=statement_timestamp())) THEN
  RAISE EXCEPTION 'Active staff access required' USING ERRCODE='42501';
 END IF;
 IF page_limit IS NULL OR page_limit<1 OR page_limit>100 OR (cursor_created IS NULL)<>(cursor_id IS NULL)
  OR (cursor_created IS NOT NULL AND NOT isfinite(cursor_created))
  OR (status_filter IS NOT NULL AND status_filter NOT IN ('open','in_progress','resolved','closed')) THEN
  RAISE EXCEPTION 'Invalid ticket queue request' USING ERRCODE='22023';
 END IF;
 WITH page AS (SELECT * FROM public.support_tickets s WHERE (status_filter IS NULL OR s.status=status_filter)
   AND (cursor_created IS NULL OR (s.created_at,s.id)>(cursor_created,cursor_id))
   ORDER BY s.created_at,s.id LIMIT page_limit+1),
 shown AS (SELECT * FROM page ORDER BY created_at,id LIMIT page_limit)
 SELECT jsonb_build_object('version','support-tickets-v1',
  'open_count',(SELECT count(*) FROM public.support_tickets WHERE status IN ('open','in_progress')),
  'tickets',coalesce((SELECT jsonb_agg(public.support_ticket_json(s,true) ORDER BY s.created_at,s.id) FROM shown s),'[]'::jsonb),
  'next_cursor',CASE WHEN (SELECT count(*) FROM page)>page_limit THEN
   (SELECT jsonb_build_object('created_at',created_at,'id',id) FROM shown ORDER BY created_at DESC,id DESC LIMIT 1) END)
 INTO result;
 RETURN result;
END; $function$;
ALTER FUNCTION "public"."read_support_ticket_queue"(actor uuid, status_filter text, cursor_created timestamp with time zone, cursor_id uuid, page_limit integer) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.respond_support_ticket(actor uuid, ticket_id uuid, reply text, new_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE t public.support_tickets;
BEGIN
 IF actor IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=actor AND p.role::text IN ('officer','admin')
  AND (p.suspended_until IS NULL OR p.suspended_until<=statement_timestamp())) THEN
  RAISE EXCEPTION 'Active staff access required' USING ERRCODE='42501';
 END IF;
 IF new_status NOT IN ('in_progress','resolved','closed') OR reply IS NULL OR char_length(btrim(reply)) NOT BETWEEN 1 AND 2000 THEN
  RAISE EXCEPTION 'Invalid ticket response' USING ERRCODE='22023';
 END IF;
 UPDATE public.support_tickets s SET response=btrim(reply),status=new_status,handler_id=actor,
  responded_at=statement_timestamp(),updated_at=statement_timestamp(),
  resolved_at=CASE WHEN new_status IN ('resolved','closed') THEN statement_timestamp() ELSE NULL END
 WHERE s.id=ticket_id RETURNING * INTO t;
 IF NOT FOUND THEN RAISE EXCEPTION 'Ticket not found' USING ERRCODE='P0002'; END IF;
 RETURN public.support_ticket_json(t,true);
END; $function$;
ALTER FUNCTION "public"."respond_support_ticket"(actor uuid, ticket_id uuid, reply text, new_status text) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION public.read_cleanup_proof_source(report_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
 SELECT jsonb_build_object('report_id',r.id,'version',r.fc_version,'fingerprint',workflow_private.cleanup_proof_fingerprint(r),
  'before_url',r.before_photo_url,'after_url',r.after_photo_url,
  'before_urls',workflow_private.cleanup_proof_photo_urls(r,'before'),'after_urls',workflow_private.cleanup_proof_photo_urls(r,'after'),
  'completed_at',r.lgu_resolved_at,
  'action_notes',coalesce(nullif(btrim(r.cleanup_action_notes),''),(SELECT o.notes FROM public.task_report_outcomes o WHERE o.report_id=r.id AND o.outcome='cleaned' AND o.disposition='applied' ORDER BY o.submitted_at DESC LIMIT 1)),
  'publication_id',p.id,
  'existing_public_notes',CASE WHEN p.source_fingerprint=workflow_private.cleanup_proof_fingerprint(r) THEN p.public_notes END,
  'existing_redactions',CASE WHEN p.source_fingerprint=workflow_private.cleanup_proof_fingerprint(r) THEN p.redactions END)
 FROM public.reports r LEFT JOIN public.cleanup_proof_publications p ON p.report_id=r.id WHERE r.id=read_cleanup_proof_source.report_id;
$function$;
ALTER FUNCTION "public"."read_cleanup_proof_source"(report_id uuid) OWNER TO "postgres";
ALTER TABLE "public"."field_crews" ALTER COLUMN "id" SET DEFAULT gen_random_uuid();
ALTER TABLE "public"."field_crews" ALTER COLUMN "member_profile_ids" SET DEFAULT '{}'::uuid[];
ALTER TABLE "public"."field_crews" ALTER COLUMN "shift_start" SET DEFAULT '08:00:00'::time without time zone;
ALTER TABLE "public"."field_crews" ALTER COLUMN "shift_end" SET DEFAULT '17:00:00'::time without time zone;
ALTER TABLE "public"."field_crews" ALTER COLUMN "max_tasks_per_shift" SET DEFAULT 10;
ALTER TABLE "public"."field_crews" ALTER COLUMN "availability_status" SET DEFAULT 'available'::crew_availability_status;
ALTER TABLE "public"."field_crews" ALTER COLUMN "created_at" SET DEFAULT now();
ALTER TABLE "public"."field_crews" ALTER COLUMN "updated_at" SET DEFAULT now();
ALTER TABLE "public"."field_crews" ALTER COLUMN "supports_standard" SET DEFAULT true;
ALTER TABLE "public"."field_crews" ALTER COLUMN "supports_sweeper" SET DEFAULT false;
ALTER TABLE "public"."field_crews" ALTER COLUMN "speed_factor" SET DEFAULT 1;
ALTER TABLE "public"."field_crews" ALTER COLUMN "service_time_factor" SET DEFAULT 1;
ALTER TABLE "public"."field_crews" ALTER COLUMN "vehicle_type" SET DEFAULT 'compactor'::vehicle_type_enum;
ALTER TABLE "public"."field_crews" ALTER COLUMN "hazmat_certified" SET DEFAULT false;
ALTER TABLE "public"."field_crews" ALTER COLUMN "certifications" SET DEFAULT '{}'::text[];
ALTER TABLE "public"."dispatch_plans" ALTER COLUMN "id" SET DEFAULT uuid_generate_v4();
ALTER TABLE "public"."dispatch_plans" ALTER COLUMN "planned_date" SET DEFAULT CURRENT_DATE;
ALTER TABLE "public"."dispatch_plans" ALTER COLUMN "total_crews_available" SET DEFAULT 0;
ALTER TABLE "public"."dispatch_plans" ALTER COLUMN "total_capacity_minutes" SET DEFAULT 0;
ALTER TABLE "public"."dispatch_plans" ALTER COLUMN "status" SET DEFAULT 'draft'::dispatch_plan_status;
ALTER TABLE "public"."dispatch_plans" ALTER COLUMN "created_at" SET DEFAULT now();
ALTER TABLE "public"."dispatch_plans" ALTER COLUMN "mode" SET DEFAULT 'standard'::text;
ALTER TABLE "public"."dispatch_plans" ALTER COLUMN "settings_snapshot" SET DEFAULT '{}'::jsonb;
ALTER TABLE "public"."dispatch_plans" ALTER COLUMN "routing_attempts" SET DEFAULT 0;
ALTER TABLE "public"."dispatch_plans" ALTER COLUMN "capacity_breakdown" SET DEFAULT '{}'::jsonb;
ALTER TABLE "public"."dispatch_plans" ALTER COLUMN "rejected_bundles" SET DEFAULT '[]'::jsonb;
ALTER TABLE "public"."dispatch_plans" ALTER COLUMN "solver_diagnostics" SET DEFAULT '{}'::jsonb;
ALTER TABLE "public"."manual_review_queue" ALTER COLUMN "id" SET DEFAULT gen_random_uuid();
ALTER TABLE "public"."manual_review_queue" ALTER COLUMN "priority" SET DEFAULT 'normal'::character varying;
ALTER TABLE "public"."manual_review_queue" ALTER COLUMN "status" SET DEFAULT 'pending'::manual_review_status;
ALTER TABLE "public"."manual_review_queue" ALTER COLUMN "created_at" SET DEFAULT timezone('utc'::text, now());
ALTER TABLE "public"."manual_review_queue" ALTER COLUMN "updated_at" SET DEFAULT timezone('utc'::text, now());
ALTER TABLE "public"."audit_logs" ALTER COLUMN "id" SET DEFAULT gen_random_uuid();
ALTER TABLE "public"."audit_logs" ALTER COLUMN "created_at" SET DEFAULT now();
ALTER TABLE "public"."system_logs" ALTER COLUMN "id" SET DEFAULT gen_random_uuid();
ALTER TABLE "public"."system_logs" ALTER COLUMN "created_at" SET DEFAULT timezone('utc'::text, now());
ALTER TABLE "public"."cleanup_tasks" ALTER COLUMN "id" SET DEFAULT gen_random_uuid();
ALTER TABLE "public"."cleanup_tasks" ALTER COLUMN "status" SET DEFAULT 'created'::cleanup_task_status;
ALTER TABLE "public"."cleanup_tasks" ALTER COLUMN "created_at" SET DEFAULT now();
ALTER TABLE "public"."cleanup_tasks" ALTER COLUMN "is_custom" SET DEFAULT false;
ALTER TABLE "public"."cleanup_tasks" ALTER COLUMN "task_type" SET DEFAULT 'Cleanup'::cleanup_task_type;
ALTER TABLE "public"."cleanup_tasks" ALTER COLUMN "cluster_ids" SET DEFAULT '{}'::uuid[];
ALTER TABLE "public"."cleanup_tasks" ALTER COLUMN "report_sequence" SET DEFAULT '{}'::uuid[];
ALTER TABLE "public"."cleanup_tasks" ALTER COLUMN "fc_version" SET DEFAULT 0;
ALTER TABLE "public"."cleanup_tasks" ALTER COLUMN "estimated_work_minutes" SET DEFAULT 0;
ALTER TABLE "public"."cleanup_tasks" ALTER COLUMN "dispatch_kind" SET DEFAULT 'standard'::text;
ALTER TABLE "public"."cleanup_tasks" ALTER COLUMN "route_status" SET DEFAULT 'ready'::text;
ALTER TABLE "public"."cleanup_tasks" ALTER COLUMN "satellite_report_ids" SET DEFAULT '{}'::uuid[];
ALTER TABLE "public"."cleanup_tasks" ALTER COLUMN "route_revision" SET DEFAULT 0;
ALTER TABLE "public"."cleanup_tasks" ALTER COLUMN "assignment_generation" SET DEFAULT 0;
ALTER TABLE "public"."dispatch_plan_items" ALTER COLUMN "id" SET DEFAULT uuid_generate_v4();
ALTER TABLE "public"."dispatch_plan_items" ALTER COLUMN "is_selected" SET DEFAULT false;
ALTER TABLE "public"."dispatch_plan_items" ALTER COLUMN "created_at" SET DEFAULT now();
ALTER TABLE "public"."dispatch_plan_items" ALTER COLUMN "report_ids" SET DEFAULT '{}'::uuid[];
ALTER TABLE "public"."dispatch_plan_items" ALTER COLUMN "item_type" SET DEFAULT 'cluster'::text;
ALTER TABLE "public"."dispatch_plan_items" ALTER COLUMN "group_key" SET DEFAULT (gen_random_uuid())::text;
ALTER TABLE "public"."dispatch_plan_items" ALTER COLUMN "estimated_work_minutes" SET DEFAULT 0;
ALTER TABLE "public"."dispatch_plan_items" ALTER COLUMN "crew_snapshot" SET DEFAULT '{}'::jsonb;
ALTER TABLE "public"."dispatch_plan_items" ALTER COLUMN "cluster_ids" SET DEFAULT '{}'::uuid[];
ALTER TABLE "public"."dispatch_plan_items" ALTER COLUMN "commit_disposition" SET DEFAULT 'pending'::text;
ALTER TABLE "public"."building_structures" ALTER COLUMN "id" SET DEFAULT gen_random_uuid();
ALTER TABLE "public"."building_structures" ALTER COLUMN "source" SET DEFAULT 'qgis_import'::text;
ALTER TABLE "public"."building_structures" ALTER COLUMN "created_at" SET DEFAULT now();
ALTER TABLE "public"."crew_urgency_observations" ALTER COLUMN "recorded_at" SET DEFAULT clock_timestamp();
ALTER TABLE "public"."plan_generation_jobs" ALTER COLUMN "id" SET DEFAULT gen_random_uuid();
ALTER TABLE "public"."plan_generation_jobs" ALTER COLUMN "status" SET DEFAULT 'queued'::text;
ALTER TABLE "public"."plan_generation_jobs" ALTER COLUMN "requested_at" SET DEFAULT now();
ALTER TABLE "public"."plan_generation_jobs" ALTER COLUMN "solver_diagnostics" SET DEFAULT '{}'::jsonb;
ALTER TABLE "public"."crew_urgency_reviews" ALTER COLUMN "reviewed_at" SET DEFAULT clock_timestamp();
ALTER TABLE "public"."reports" ALTER COLUMN "id" SET DEFAULT gen_random_uuid();
ALTER TABLE "public"."reports" ALTER COLUMN "validation_status" SET DEFAULT 'pending'::report_validation_status;
ALTER TABLE "public"."reports" ALTER COLUMN "status" SET DEFAULT 'unresolved'::report_status;
ALTER TABLE "public"."reports" ALTER COLUMN "created_at" SET DEFAULT now();
ALTER TABLE "public"."reports" ALTER COLUMN "updated_at" SET DEFAULT now();
ALTER TABLE "public"."reports" ALTER COLUMN "on_private_property" SET DEFAULT false;
ALTER TABLE "public"."reports" ALTER COLUMN "property_owner_consent_status" SET DEFAULT 'not_required'::consent_status;
ALTER TABLE "public"."reports" ALTER COLUMN "stage" SET DEFAULT 'submitted'::lifecycle_stage;
ALTER TABLE "public"."reports" ALTER COLUMN "is_overdue" SET DEFAULT false;
ALTER TABLE "public"."reports" ALTER COLUMN "flagged_severe" SET DEFAULT false;
ALTER TABLE "public"."reports" ALTER COLUMN "scale_level" SET DEFAULT 'medium'::character varying;
ALTER TABLE "public"."reports" ALTER COLUMN "obstruction_level" SET DEFAULT 'none'::character varying;
ALTER TABLE "public"."reports" ALTER COLUMN "fc_version" SET DEFAULT 0;
ALTER TABLE "public"."reports" ALTER COLUMN "report_claim_generation" SET DEFAULT 0;
ALTER TABLE "public"."reports" ALTER COLUMN "hazard_class" SET DEFAULT 'unknown'::text;
ALTER TABLE "public"."reports" ALTER COLUMN "is_mocked" SET DEFAULT false;
ALTER TABLE "public"."reports" ALTER COLUMN "location_verification_status" SET DEFAULT 'unverified_gallery'::text;
ALTER TABLE "public"."reports" ALTER COLUMN "before_photos" SET DEFAULT '[]'::jsonb;
ALTER TABLE "public"."reports" ALTER COLUMN "after_photos" SET DEFAULT '[]'::jsonb;
ALTER TABLE "public"."reports" ALTER COLUMN "city" SET DEFAULT 'Pasig City'::text;
ALTER TABLE "public"."reports" ALTER COLUMN "hide_identity" SET DEFAULT false;
ALTER TABLE "public"."reports" ALTER COLUMN "barangay_resolution_status" SET DEFAULT 'pending_reconciliation'::text;
ALTER TABLE "public"."reports" ALTER COLUMN "barangay_candidates" SET DEFAULT '{}'::text[];
ALTER TABLE "public"."fc_operation_log" ALTER COLUMN "status" SET DEFAULT 'success'::text;
ALTER TABLE "public"."fc_operation_log" ALTER COLUMN "created_at" SET DEFAULT now();
ALTER TABLE "public"."fc_operation_log" ALTER COLUMN "expires_at" SET DEFAULT (now() + '30 days'::interval);
ALTER TABLE "public"."fc_conflict_audit" ALTER COLUMN "id" SET DEFAULT gen_random_uuid();
ALTER TABLE "public"."fc_conflict_audit" ALTER COLUMN "created_at" SET DEFAULT now();
ALTER TABLE "public"."profiles" ALTER COLUMN "created_at" SET DEFAULT now();
ALTER TABLE "public"."profiles" ALTER COLUMN "role" SET DEFAULT 'citizen'::role;
ALTER TABLE "public"."profiles" ALTER COLUMN "strike_count" SET DEFAULT 0;
ALTER TABLE "public"."profiles" ALTER COLUMN "is_email_verified" SET DEFAULT false;
ALTER TABLE "public"."profiles" ALTER COLUMN "require_password_change" SET DEFAULT false;
ALTER TABLE "public"."hotspot_accuracy" ALTER COLUMN "id" SET DEFAULT gen_random_uuid();
ALTER TABLE "public"."hotspot_accuracy" ALTER COLUMN "created_at" SET DEFAULT now();
ALTER TABLE "public"."dispatch_group_commits" ALTER COLUMN "committed_at" SET DEFAULT now();
ALTER TABLE "public"."system_settings" ALTER COLUMN "id" SET DEFAULT gen_random_uuid();
ALTER TABLE "public"."system_settings" ALTER COLUMN "password_min_length" SET DEFAULT 8;
ALTER TABLE "public"."system_settings" ALTER COLUMN "password_require_uppercase" SET DEFAULT true;
ALTER TABLE "public"."system_settings" ALTER COLUMN "password_require_lowercase" SET DEFAULT true;
ALTER TABLE "public"."system_settings" ALTER COLUMN "password_require_numbers" SET DEFAULT true;
ALTER TABLE "public"."system_settings" ALTER COLUMN "password_require_special_chars" SET DEFAULT true;
ALTER TABLE "public"."system_settings" ALTER COLUMN "session_timeout_minutes" SET DEFAULT 60;
ALTER TABLE "public"."system_settings" ALTER COLUMN "created_at" SET DEFAULT timezone('utc'::text, now());
ALTER TABLE "public"."system_settings" ALTER COLUMN "updated_at" SET DEFAULT timezone('utc'::text, now());
ALTER TABLE "public"."system_settings" ALTER COLUMN "strike_1_action" SET DEFAULT 'warning'::character varying;
ALTER TABLE "public"."system_settings" ALTER COLUMN "strike_2_action" SET DEFAULT 'suspend_24h'::character varying;
ALTER TABLE "public"."system_settings" ALTER COLUMN "strike_3_action" SET DEFAULT 'suspend_7d'::character varying;
ALTER TABLE "public"."system_settings" ALTER COLUMN "strike_4_action" SET DEFAULT 'permanent_ban'::character varying;
ALTER TABLE "public"."system_settings" ALTER COLUMN "strike_2_duration_hours" SET DEFAULT 24;
ALTER TABLE "public"."system_settings" ALTER COLUMN "strike_3_duration_hours" SET DEFAULT 168;
ALTER TABLE "public"."system_settings" ALTER COLUMN "severe_violation_action" SET DEFAULT 'suspend_7d'::character varying;
ALTER TABLE "public"."system_settings" ALTER COLUMN "severe_violation_duration_hours" SET DEFAULT 168;
ALTER TABLE "public"."system_settings" ALTER COLUMN "severe_violation_auto_reject" SET DEFAULT true;
ALTER TABLE "public"."system_settings" ALTER COLUMN "severe_violation_immediate_strike" SET DEFAULT true;
ALTER TABLE "public"."system_settings" ALTER COLUMN "daily_report_quota" SET DEFAULT 10;
ALTER TABLE "public"."system_settings" ALTER COLUMN "report_video_max_seconds" SET DEFAULT 10;
ALTER TABLE "public"."email_verifications" ALTER COLUMN "id" SET DEFAULT gen_random_uuid();
ALTER TABLE "public"."email_verifications" ALTER COLUMN "created_at" SET DEFAULT now();
ALTER TABLE "public"."dispatch_access_blocks" ALTER COLUMN "id" SET DEFAULT gen_random_uuid();
ALTER TABLE "public"."dispatch_access_blocks" ALTER COLUMN "blocked_at" SET DEFAULT now();
ALTER TABLE "public"."pasig_barangay_boundary_source" ALTER COLUMN "singleton" SET DEFAULT true;
ALTER TABLE "public"."pasig_barangay_boundary_source" ALTER COLUMN "imported_at" SET DEFAULT now();
ALTER TABLE "public"."field_assignment_receipts" ALTER COLUMN "id" SET DEFAULT gen_random_uuid();
ALTER TABLE "public"."field_assignment_receipts" ALTER COLUMN "issued_at" SET DEFAULT now();
ALTER TABLE "public"."report_resolution_events" ALTER COLUMN "id" SET DEFAULT gen_random_uuid();
ALTER TABLE "public"."report_resolution_events" ALTER COLUMN "resolved_at" SET DEFAULT now();
ALTER TABLE "public"."report_resolution_events" ALTER COLUMN "resolution_kind" SET DEFAULT 'cleaned'::text;
ALTER TABLE "public"."notifications" ALTER COLUMN "id" SET DEFAULT gen_random_uuid();
ALTER TABLE "public"."notifications" ALTER COLUMN "type" SET DEFAULT 'general'::notification_type;
ALTER TABLE "public"."notifications" ALTER COLUMN "is_read" SET DEFAULT false;
ALTER TABLE "public"."notifications" ALTER COLUMN "created_at" SET DEFAULT timezone('utc'::text, now());
ALTER TABLE "public"."optimization_templates" ALTER COLUMN "id" SET DEFAULT uuid_generate_v4();
ALTER TABLE "public"."optimization_templates" ALTER COLUMN "is_default" SET DEFAULT false;
ALTER TABLE "public"."optimization_templates" ALTER COLUMN "settings" SET DEFAULT '{}'::jsonb;
ALTER TABLE "public"."optimization_templates" ALTER COLUMN "created_at" SET DEFAULT now();
ALTER TABLE "public"."optimization_templates" ALTER COLUMN "updated_at" SET DEFAULT now();
ALTER TABLE "public"."task_report_outcomes" ALTER COLUMN "id" SET DEFAULT gen_random_uuid();
ALTER TABLE "public"."task_report_outcomes" ALTER COLUMN "submitted_at" SET DEFAULT now();
ALTER TABLE "public"."task_report_outcomes" ALTER COLUMN "evidence_refs" SET DEFAULT '[]'::jsonb;
ALTER TABLE "public"."task_report_outcomes" ALTER COLUMN "notes" SET DEFAULT ''::text;
ALTER TABLE "public"."task_report_outcomes" ALTER COLUMN "evidence_verification" SET DEFAULT 'unverified'::text;
ALTER TABLE "public"."optimization_settings" ALTER COLUMN "id" SET DEFAULT gen_random_uuid();
ALTER TABLE "public"."optimization_settings" ALTER COLUMN "updated_at" SET DEFAULT now();
ALTER TABLE "public"."support_tickets" ALTER COLUMN "id" SET DEFAULT gen_random_uuid();
ALTER TABLE "public"."support_tickets" ALTER COLUMN "reference" SET DEFAULT ('TCK-'::text || lpad((nextval('public.support_ticket_number_seq'::text))::text, 6, '0'::text));
ALTER TABLE "public"."support_tickets" ALTER COLUMN "status" SET DEFAULT 'open'::text;
ALTER TABLE "public"."support_tickets" ALTER COLUMN "created_at" SET DEFAULT statement_timestamp();
ALTER TABLE "public"."support_tickets" ALTER COLUMN "updated_at" SET DEFAULT statement_timestamp();
ALTER TABLE "public"."route_waypoints" ALTER COLUMN "id" SET DEFAULT gen_random_uuid();
ALTER TABLE "public"."route_waypoints" ALTER COLUMN "waypoint_type" SET DEFAULT 'task'::route_waypoint_type;
ALTER TABLE "public"."route_waypoints" ALTER COLUMN "created_at" SET DEFAULT now();
ALTER TABLE "public"."optimization_runs" ALTER COLUMN "id" SET DEFAULT gen_random_uuid();
ALTER TABLE "public"."optimization_runs" ALTER COLUMN "status" SET DEFAULT 'draft'::text;
ALTER TABLE "public"."optimization_runs" ALTER COLUMN "weather_condition" SET DEFAULT 'normal'::text;
ALTER TABLE "public"."optimization_runs" ALTER COLUMN "traffic_condition" SET DEFAULT 'low'::text;
ALTER TABLE "public"."optimization_runs" ALTER COLUMN "num_tasks_optimized" SET DEFAULT 0;
ALTER TABLE "public"."optimization_runs" ALTER COLUMN "num_crews" SET DEFAULT 2;
ALTER TABLE "public"."optimization_runs" ALTER COLUMN "created_at" SET DEFAULT now();
ALTER TABLE "public"."crew_routes" ALTER COLUMN "id" SET DEFAULT gen_random_uuid();
ALTER TABLE "public"."crew_routes" ALTER COLUMN "task_count" SET DEFAULT 0;
ALTER TABLE "public"."crew_routes" ALTER COLUMN "created_at" SET DEFAULT now();
ALTER TABLE "public"."field_load_events" ALTER COLUMN "id" SET DEFAULT gen_random_uuid();
ALTER TABLE "public"."field_load_events" ALTER COLUMN "submitted_at" SET DEFAULT now();
ALTER TABLE "public"."field_load_events" ALTER COLUMN "notes" SET DEFAULT ''::text;
ALTER TABLE "public"."field_task_failure_events" ALTER COLUMN "id" SET DEFAULT gen_random_uuid();
ALTER TABLE "public"."field_task_failure_events" ALTER COLUMN "submitted_at" SET DEFAULT now();
ALTER TABLE "public"."sync_conflicts" ALTER COLUMN "id" SET DEFAULT gen_random_uuid();
ALTER TABLE "public"."sync_conflicts" ALTER COLUMN "created_at" SET DEFAULT now();
ALTER TABLE "public"."work_time_configuration" ALTER COLUMN "updated_at" SET DEFAULT CURRENT_TIMESTAMP;
ALTER TABLE "public"."sweeper_configuration" ALTER COLUMN "updated_at" SET DEFAULT CURRENT_TIMESTAMP;
ALTER TABLE "public"."sweeper_audit_log" ALTER COLUMN "id" SET DEFAULT nextval('sweeper_audit_log_id_seq'::regclass);
ALTER TABLE "public"."sweeper_audit_log" ALTER COLUMN "created_at" SET DEFAULT CURRENT_TIMESTAMP;
ALTER TABLE "workflow_private"."unprocessed_escalation_baseline" ALTER COLUMN "singleton" SET DEFAULT true;
ALTER TABLE "workflow_private"."unprocessed_escalation_baseline" ALTER COLUMN "set_at" SET DEFAULT statement_timestamp();
ALTER TABLE "public"."clusters" ALTER COLUMN "id" SET DEFAULT gen_random_uuid();
ALTER TABLE "public"."clusters" ALTER COLUMN "radius_meters" SET DEFAULT 50;
ALTER TABLE "public"."clusters" ALTER COLUMN "status" SET DEFAULT 'unresolved'::cluster_status;
ALTER TABLE "public"."clusters" ALTER COLUMN "created_at" SET DEFAULT now();
ALTER TABLE "public"."clusters" ALTER COLUMN "updated_at" SET DEFAULT now();
ALTER TABLE "public"."clusters" ALTER COLUMN "estimated_effort_minutes" SET DEFAULT 60;
ALTER TABLE "public"."clusters" ALTER COLUMN "recommended_task_type" SET DEFAULT 'Cleanup'::text;
ALTER TABLE "public"."strikes" ALTER COLUMN "id" SET DEFAULT gen_random_uuid();
ALTER TABLE "public"."strikes" ALTER COLUMN "issued_at" SET DEFAULT timezone('utc'::text, now());
ALTER TABLE "public"."strikes" ALTER COLUMN "is_active" SET DEFAULT true;
ALTER TABLE "public"."strikes" ALTER COLUMN "severity" SET DEFAULT 'normal'::violation_severity;
ALTER TABLE "public"."strikes" ALTER COLUMN "requires_manual_review" SET DEFAULT false;
ALTER TABLE "public"."cleanup_proof_publications" ALTER COLUMN "id" SET DEFAULT gen_random_uuid();
ALTER TABLE "public"."cleanup_proof_publications" ALTER COLUMN "verified_at" SET DEFAULT now();
ALTER TABLE "public"."spatial_zones" ALTER COLUMN "zone_type" SET DEFAULT 'h3'::character varying;
ALTER TABLE "public"."spatial_zones" ALTER COLUMN "created_at" SET DEFAULT now();
ALTER TABLE "public"."hotspot_predictions" ALTER COLUMN "id" SET DEFAULT gen_random_uuid();
ALTER TABLE "public"."hotspot_predictions" ALTER COLUMN "is_significant" SET DEFAULT false;
ALTER TABLE "public"."hotspot_predictions" ALTER COLUMN "created_at" SET DEFAULT now();
ALTER TABLE "public"."hotspot_predictions" ALTER COLUMN "updated_at" SET DEFAULT now();
ALTER TABLE "public"."hotspot_predictions" ALTER COLUMN "horizon_days" SET DEFAULT 30;
ALTER TABLE "public"."hotspot_predictions" ALTER COLUMN "predicted_count" SET DEFAULT 0;
ALTER TABLE "public"."hotspot_predictions" ALTER COLUMN "predicted_lower_bound" SET DEFAULT 0;
ALTER TABLE "public"."hotspot_predictions" ALTER COLUMN "predicted_upper_bound" SET DEFAULT 0;
ALTER TABLE "public"."hotspot_predictions" ALTER COLUMN "growth_velocity_percent" SET DEFAULT 0;
ALTER TABLE "public"."hotspot_predictions" ALTER COLUMN "historical_points" SET DEFAULT '[]'::jsonb;
ALTER TABLE "public"."hotspot_predictions" ALTER COLUMN "forecast_points" SET DEFAULT '[]'::jsonb;
ALTER TABLE "public"."operational_events" ALTER COLUMN "recorded_at" SET DEFAULT clock_timestamp();
ALTER TABLE "public"."operational_events" ALTER COLUMN "details" SET DEFAULT '{}'::jsonb;
ALTER TABLE "public"."citizen_trust" ALTER COLUMN "score" SET DEFAULT 50;
ALTER TABLE "public"."citizen_trust" ALTER COLUMN "recovery_streak" SET DEFAULT 0;
ALTER TABLE "public"."citizen_trust" ALTER COLUMN "updated_at" SET DEFAULT clock_timestamp();
ALTER TABLE "public"."citizen_trust_decisions" ALTER COLUMN "recorded_at" SET DEFAULT clock_timestamp();
ALTER TABLE "workflow_private"."unprocessed_alert_deliveries" ALTER COLUMN "delivered_at" SET DEFAULT statement_timestamp();
ALTER TABLE "workflow_private"."lifecycle_deployment" ALTER COLUMN "singleton" SET DEFAULT true;
ALTER TABLE "public"."report_urgency_decisions" ALTER COLUMN "recorded_at" SET DEFAULT clock_timestamp();
ALTER SEQUENCE "public"."sweeper_audit_log_id_seq" OWNED BY public.sweeper_audit_log.id;
CREATE VIEW "public"."public_reports" WITH (security_barrier=true,security_invoker=false) AS  SELECT v.id,
    v.title,
    v.description,
    v.issue_type,
    v.status,
    v.cluster_id,
    v.created_at,
    v.updated_at,
    v.stage,
    v.is_overdue,
    v.severity_score,
    v.severity_level,
    v.lifecycle_state,
    v.breached_at,
    v.validation_status,
    v.location,
    v.latitude,
    v.longitude,
    v.location_precision,
    v.street_address,
    v.barangay,
    v.city,
    r.sla_started_at,
    r.deadline_at
   FROM ( SELECT reports.id,
            reports.title,
            reports.description,
            reports.issue_type,
            reports.status,
            reports.cluster_id,
            reports.created_at,
            reports.updated_at,
            reports.stage,
            reports.is_overdue,
            reports.severity_score,
            reports.severity_level,
            reports.lifecycle_state,
            reports.breached_at,
            reports.validation_status,
            st_asgeojson(
                CASE
                    WHEN reports.on_private_property THEN st_setsrid(st_makepoint(round(st_x(reports.location::geometry)::numeric, 3)::double precision, round(st_y(reports.location::geometry)::numeric, 3)::double precision), 4326)
                    ELSE reports.location::geometry
                END, 9, 0)::jsonb AS location,
                CASE
                    WHEN reports.on_private_property THEN round(st_y(reports.location::geometry)::numeric, 3)::double precision
                    ELSE st_y(reports.location::geometry)
                END AS latitude,
                CASE
                    WHEN reports.on_private_property THEN round(st_x(reports.location::geometry)::numeric, 3)::double precision
                    ELSE st_x(reports.location::geometry)
                END AS longitude,
                CASE
                    WHEN reports.on_private_property THEN 'approximate'::text
                    ELSE 'exact'::text
                END AS location_precision,
            reports.street_address,
            reports.barangay,
            reports.city
           FROM reports
          WHERE reports.validation_status = 'approved'::report_validation_status AND reports.status <> 'rejected'::report_status AND (reports.on_private_property IS FALSE OR reports.on_private_property IS TRUE AND reports.property_owner_consent_status = 'obtained'::consent_status)) v
     JOIN reports r ON r.id = v.id;
ALTER VIEW "public"."public_reports" OWNER TO "ecopin_public_map_reader";
CREATE VIEW "public"."response_log" WITH (security_invoker=true,security_barrier=true) AS  SELECT id,
    report_id,
    user_id,
    action_type,
    action_details,
    created_at
   FROM audit_logs;
ALTER VIEW "public"."response_log" OWNER TO "postgres";
CREATE VIEW "public"."reports_view" WITH (security_barrier=true,security_invoker=false) AS  SELECT v.id,
    v.user_id,
    v.title,
    v.description,
    v.issue_type,
    v.location,
    v.validation_status,
    v.status,
    v.cluster_id,
    v.created_at,
    v.updated_at,
    v.notes,
    v.before_photo_url,
    v.after_photo_url,
    v.on_private_property,
    v.property_owner_consent_status,
    v.stage,
    v.satisfaction_rating,
    v.lgu_resolved_at,
    v.citizen_closed_at,
    v.is_overdue,
    v.severity_score,
    v.urgency_score,
    v.ra9003_category,
    v.ml_predicted_class,
    v.ml_confidence,
    v.ml_probabilities,
    v.photo_lat,
    v.photo_lng,
    v.photo_accuracy,
    v.photo_captured_at,
    v.photo_source,
    v.is_mocked,
    v.location_verification_status,
    v.photo_distance_meters,
    v.street_address,
    v.barangay,
    v.city,
    v.sla_started_at,
    v.deadline_at,
    v.hide_identity,
    r.citizen_landmark
   FROM ( SELECT v_1.id,
                CASE
                    WHEN r_1.hide_identity THEN NULL::uuid
                    ELSE v_1.user_id
                END AS user_id,
            v_1.title,
            v_1.description,
            v_1.issue_type,
            v_1.location,
            v_1.validation_status,
            v_1.status,
            v_1.cluster_id,
            v_1.created_at,
            v_1.updated_at,
            v_1.notes,
            v_1.before_photo_url,
            v_1.after_photo_url,
            v_1.on_private_property,
            v_1.property_owner_consent_status,
            v_1.stage,
            v_1.satisfaction_rating,
            v_1.lgu_resolved_at,
            v_1.citizen_closed_at,
            v_1.is_overdue,
            v_1.severity_score,
            v_1.urgency_score,
            v_1.ra9003_category,
            v_1.ml_predicted_class,
            v_1.ml_confidence,
            v_1.ml_probabilities,
                CASE
                    WHEN r_1.hide_identity THEN NULL::double precision
                    ELSE v_1.photo_lat
                END AS photo_lat,
                CASE
                    WHEN r_1.hide_identity THEN NULL::double precision
                    ELSE v_1.photo_lng
                END AS photo_lng,
                CASE
                    WHEN r_1.hide_identity THEN NULL::double precision
                    ELSE v_1.photo_accuracy
                END AS photo_accuracy,
                CASE
                    WHEN r_1.hide_identity THEN NULL::timestamp with time zone
                    ELSE v_1.photo_captured_at
                END AS photo_captured_at,
                CASE
                    WHEN r_1.hide_identity THEN NULL::text
                    ELSE v_1.photo_source
                END AS photo_source,
                CASE
                    WHEN r_1.hide_identity THEN NULL::boolean
                    ELSE v_1.is_mocked
                END AS is_mocked,
            v_1.location_verification_status,
            v_1.photo_distance_meters,
            v_1.street_address,
            v_1.barangay,
            v_1.city,
            v_1.sla_started_at,
            v_1.deadline_at,
            r_1.hide_identity
           FROM ( SELECT v_1_1.id,
                    v_1_1.user_id,
                    v_1_1.title,
                    v_1_1.description,
                    v_1_1.issue_type,
                    v_1_1.location,
                    v_1_1.validation_status,
                    v_1_1.status,
                    v_1_1.cluster_id,
                    v_1_1.created_at,
                    v_1_1.updated_at,
                    v_1_1.notes,
                    v_1_1.before_photo_url,
                    v_1_1.after_photo_url,
                    v_1_1.on_private_property,
                    v_1_1.property_owner_consent_status,
                    v_1_1.stage,
                    v_1_1.satisfaction_rating,
                    v_1_1.lgu_resolved_at,
                    v_1_1.citizen_closed_at,
                    v_1_1.is_overdue,
                    v_1_1.severity_score,
                    v_1_1.urgency_score,
                    v_1_1.ra9003_category,
                    v_1_1.ml_predicted_class,
                    v_1_1.ml_confidence,
                    v_1_1.ml_probabilities,
                    v_1_1.photo_lat,
                    v_1_1.photo_lng,
                    v_1_1.photo_accuracy,
                    v_1_1.photo_captured_at,
                    v_1_1.photo_source,
                    v_1_1.is_mocked,
                    v_1_1.location_verification_status,
                    v_1_1.photo_distance_meters,
                    v_1_1.street_address,
                    v_1_1.barangay,
                    v_1_1.city,
                    r_1_1.sla_started_at,
                    r_1_1.deadline_at
                   FROM ( SELECT reports.id,
                            reports.user_id,
                            reports.title,
                            reports.description,
                            reports.issue_type,
                            reports.location,
                            reports.validation_status,
                            reports.status,
                            reports.cluster_id,
                            reports.created_at,
                            reports.updated_at,
                            reports.notes,
                            reports.before_photo_url,
                            reports.after_photo_url,
                            reports.on_private_property,
                            reports.property_owner_consent_status,
                            reports.stage,
                            reports.satisfaction_rating,
                            reports.lgu_resolved_at,
                            reports.citizen_closed_at,
                            reports.is_overdue,
                            reports.severity_score,
                            reports.urgency_score,
                            reports.ra9003_category,
                            reports.ml_predicted_class,
                            reports.ml_confidence,
                            reports.ml_probabilities,
                            reports.photo_lat,
                            reports.photo_lng,
                            reports.photo_accuracy,
                            reports.photo_captured_at,
                            reports.photo_source,
                            reports.is_mocked,
                            reports.location_verification_status,
                            reports.photo_distance_meters,
                            reports.street_address,
                            reports.barangay,
                            reports.city
                           FROM reports) v_1_1
                     JOIN reports r_1_1 ON r_1_1.id = v_1_1.id) v_1
             JOIN reports r_1 ON r_1.id = v_1.id) v
     JOIN reports r ON r.id = v.id;
ALTER VIEW "public"."reports_view" OWNER TO "ecopin_operational_reader";
CREATE VIEW "public"."report_activity_view" WITH (security_barrier=true,security_invoker=false) AS  SELECT a.id,
    a.report_id,
        CASE
            WHEN h.report_id IS NOT NULL AND ('user_id'::text = 'metadata'::text OR a.user_id = h.owner_id) THEN NULL::uuid
            ELSE a.user_id
        END AS user_id,
    a.action_type,
        CASE
            WHEN h.report_id IS NOT NULL AND ('action_details'::text = 'metadata'::text OR a.user_id = h.owner_id) THEN NULL::text
            ELSE a.action_details
        END AS action_details,
    a.created_at
   FROM audit_logs a
     LEFT JOIN privacy_private.hidden_report_owners h ON h.report_id = COALESCE(a.report_id, ( SELECT x.report_id
           FROM privacy_private.hidden_report_artifacts x
          WHERE x.record_id = a.id));
ALTER VIEW "public"."report_activity_view" OWNER TO "ecopin_operational_reader";
CREATE VIEW "public"."staff_visible_strikes" WITH (security_barrier=true,security_invoker=false) AS  SELECT id,
    user_id,
    reason,
    violation_type,
    issued_by,
    issued_at,
    expires_at,
    is_active,
    notes,
    severity,
    severe_category,
    requires_manual_review,
    manual_review_status
   FROM strikes s
  WHERE NOT (EXISTS ( SELECT 1
           FROM privacy_private.hidden_report_artifacts x
          WHERE x.record_id = s.id)) AND NOT (EXISTS ( SELECT 1
           FROM manual_review_queue q
             JOIN privacy_private.hidden_report_owners h ON h.report_id = COALESCE(q.report_id, ( SELECT x.report_id
                   FROM privacy_private.hidden_report_artifacts x
                  WHERE x.record_id = q.id))
          WHERE q.strike_id = s.id));
ALTER VIEW "public"."staff_visible_strikes" OWNER TO "postgres";
CREATE VIEW "public"."zone_weekly_report_history" WITH (security_invoker=true) AS  SELECT zone.id AS zone_id,
    (date_trunc('week'::text, (r.created_at AT TIME ZONE 'UTC'::text)) AT TIME ZONE 'UTC'::text) AS week_start,
    count(*)::integer AS report_count,
    COALESCE(avg(r.severity_score), 0::numeric) AS avg_severity
   FROM reports r
     CROSS JOIN LATERAL ( SELECT z.id
           FROM spatial_zones z
          WHERE st_covers(z.boundary, r.location::geometry)
          ORDER BY z.id
         LIMIT 1) zone
  WHERE r.validation_status = 'approved'::report_validation_status AND r.status IS DISTINCT FROM 'rejected'::report_status AND NOT COALESCE(r.flagged_severe, false) AND r.created_at IS NOT NULL AND r.created_at <= now()
  GROUP BY zone.id, ((date_trunc('week'::text, (r.created_at AT TIME ZONE 'UTC'::text)) AT TIME ZONE 'UTC'::text));
ALTER VIEW "public"."zone_weekly_report_history" OWNER TO "postgres";
CREATE VIEW "workflow_private"."unprocessed_report_alerts" WITH (security_invoker=true) AS  SELECT report_id,
    created_at,
    age_days,
    missing_acknowledgement,
    missing_assignment,
        CASE
            WHEN age_days >= 5 THEN 'overdue'::text
            ELSE 'approaching'::text
        END AS state
   FROM ( SELECT r.id AS report_id,
            r.created_at,
            floor(EXTRACT(epoch FROM statement_timestamp() - r.created_at) / 86400::numeric)::integer AS age_days,
            NOT ((COALESCE(r.stage::text, ''::text) = ANY (ARRAY['acknowledged'::text, 'responded'::text, 'in_progress'::text])) OR (COALESCE(r.status::text, ''::text) = ANY (ARRAY['acknowledged'::text, 'responded'::text, 'in_progress'::text])) OR (EXISTS ( SELECT 1
                   FROM operational_events e
                  WHERE e.report_id = r.id AND e.event_type = 'acknowledgement'::text AND e.time_basis = 'server'::text)) OR (COALESCE(t.status::text, ''::text) = ANY (ARRAY['en_route'::text, 'in_progress'::text, 'partially_completed'::text]))) AS missing_acknowledgement,
            NOT (t.id IS NOT NULL AND (COALESCE(t.status::text, ''::text) = ANY (ARRAY['created'::text, 'pending'::text, 'assigned'::text, 'en_route'::text, 'in_progress'::text, 'partially_completed'::text])) AND (COALESCE(cardinality(t.assigned_crew_ids), 0) > 0 OR t.assigned_field_crew_id IS NOT NULL)) AS missing_assignment
           FROM reports r
             LEFT JOIN cleanup_tasks t ON t.id = r.cleanup_task_id
          WHERE r.created_at IS NOT NULL AND isfinite(r.created_at) AND r.created_at >= '2000-01-01 00:00:00+00'::timestamp with time zone AND r.created_at <= (statement_timestamp() - '96:00:00'::interval) AND (COALESCE(r.status::text, ''::text) <> ALL (ARRAY['resolved'::text, 'completed'::text, 'closed'::text, 'waiting_for_feedback'::text, 'rejected'::text, 'withdrawn'::text, 'cancelled'::text])) AND (COALESCE(r.stage::text, ''::text) <> ALL (ARRAY['resolved'::text, 'completed'::text, 'closed'::text, 'waiting_for_feedback'::text, 'rejected'::text, 'withdrawn'::text, 'cancelled'::text])) AND COALESCE(r.validation_status::text, ''::text) <> 'rejected'::text) s
  WHERE missing_acknowledgement OR missing_assignment;
ALTER VIEW "workflow_private"."unprocessed_report_alerts" OWNER TO "postgres";
ALTER TABLE "public"."field_crews" ADD CONSTRAINT "field_crews_load_has_measurement" CHECK (starting_volume_m3 IS NULL AND starting_weight_kg IS NULL OR load_measured_at IS NOT NULL);
ALTER TABLE "public"."field_crews" ADD CONSTRAINT "field_crews_max_volume_m3_check" CHECK (max_volume_m3 > 0::numeric);
ALTER TABLE "public"."field_crews" ADD CONSTRAINT "field_crews_max_weight_kg_check" CHECK (max_weight_kg > 0::numeric);
ALTER TABLE "public"."field_crews" ADD CONSTRAINT "field_crews_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."field_crews" ADD CONSTRAINT "field_crews_service_time_factor_check" CHECK (service_time_factor > 0::numeric AND service_time_factor <= 3::numeric);
ALTER TABLE "public"."field_crews" ADD CONSTRAINT "field_crews_speed_factor_check" CHECK (speed_factor > 0::numeric AND speed_factor <= 3::numeric);
ALTER TABLE "public"."field_crews" ADD CONSTRAINT "field_crews_starting_volume_m3_check" CHECK (starting_volume_m3 >= 0::numeric);
ALTER TABLE "public"."field_crews" ADD CONSTRAINT "field_crews_starting_weight_kg_check" CHECK (starting_weight_kg >= 0::numeric);
ALTER TABLE "public"."field_crews" ADD CONSTRAINT "field_crews_volume_not_overfilled" CHECK (starting_volume_m3 IS NULL OR max_volume_m3 IS NULL OR starting_volume_m3 <= max_volume_m3);
ALTER TABLE "public"."field_crews" ADD CONSTRAINT "field_crews_weight_not_overfilled" CHECK (starting_weight_kg IS NULL OR max_weight_kg IS NULL OR starting_weight_kg <= max_weight_kg);
ALTER TABLE "operational_private"."crew_presence" ADD CONSTRAINT "crew_presence_last_seen_at_check" CHECK (isfinite(last_seen_at) AND last_seen_at >= '2020-01-01 00:00:00+00'::timestamp with time zone AND last_seen_at < '10000-01-01 00:00:00+00'::timestamp with time zone);
ALTER TABLE "operational_private"."crew_presence" ADD CONSTRAINT "crew_presence_pkey" PRIMARY KEY (crew_id);
ALTER TABLE "public"."dispatch_plans" ADD CONSTRAINT "dispatch_plans_mode_check" CHECK (mode = ANY (ARRAY['standard'::text, 'sweeper'::text, 'mixed'::text]));
ALTER TABLE "public"."dispatch_plans" ADD CONSTRAINT "dispatch_plans_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."dispatch_plans" ADD CONSTRAINT "dispatch_plans_routing_attempts_check" CHECK (routing_attempts >= 0 AND routing_attempts <= 3);
ALTER TABLE "public"."manual_review_queue" ADD CONSTRAINT "manual_review_queue_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."audit_logs" ADD CONSTRAINT "response_log_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."system_logs" ADD CONSTRAINT "audit_logs_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."cleanup_tasks" ADD CONSTRAINT "cleanup_tasks_bundle_detour_min_check" CHECK (bundle_detour_min >= 0::numeric);
ALTER TABLE "public"."cleanup_tasks" ADD CONSTRAINT "cleanup_tasks_dispatch_kind_check" CHECK (dispatch_kind = ANY (ARRAY['standard'::text, 'sweeper'::text, 'mixed'::text]));
ALTER TABLE "public"."cleanup_tasks" ADD CONSTRAINT "cleanup_tasks_estimated_work_minutes_check" CHECK (estimated_work_minutes >= 0);
ALTER TABLE "public"."cleanup_tasks" ADD CONSTRAINT "cleanup_tasks_failure_class_check" CHECK (failure_class = ANY (ARRAY['transient'::text, 'site'::text, 'safety'::text, 'unclassified'::text]));
ALTER TABLE "public"."cleanup_tasks" ADD CONSTRAINT "cleanup_tasks_operational_actor_id_check" CHECK (operational_actor_id IS NULL);
ALTER TABLE "public"."cleanup_tasks" ADD CONSTRAINT "cleanup_tasks_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."cleanup_tasks" ADD CONSTRAINT "cleanup_tasks_priority_check" CHECK (priority = ANY (ARRAY['urgent'::text, 'high'::text, 'medium'::text, 'low'::text]));
ALTER TABLE "public"."cleanup_tasks" ADD CONSTRAINT "cleanup_tasks_route_status_check" CHECK (route_status = ANY (ARRAY['needs_replan'::text, 'ready'::text, 'expired'::text]));
ALTER TABLE "public"."dispatch_plan_items" ADD CONSTRAINT "dispatch_item_target" CHECK (item_type = 'cluster'::text AND cluster_id IS NOT NULL AND report_id IS NULL AND anchor_cluster_id IS NULL OR item_type = 'report'::text AND report_id IS NOT NULL AND cluster_id IS NULL AND anchor_cluster_id IS NULL OR item_type = 'bundled_report'::text AND report_id IS NOT NULL AND cluster_id IS NULL AND anchor_cluster_id IS NOT NULL);
ALTER TABLE "public"."dispatch_plan_items" ADD CONSTRAINT "dispatch_plan_items_commit_disposition_check" CHECK (commit_disposition = ANY (ARRAY['pending'::text, 'included'::text, 'omitted'::text]));
ALTER TABLE "public"."dispatch_plan_items" ADD CONSTRAINT "dispatch_plan_items_detour_minutes_check" CHECK (detour_minutes >= 0::numeric);
ALTER TABLE "public"."dispatch_plan_items" ADD CONSTRAINT "dispatch_plan_items_estimated_work_minutes_check" CHECK (estimated_work_minutes >= 0);
ALTER TABLE "public"."dispatch_plan_items" ADD CONSTRAINT "dispatch_plan_items_item_type_check" CHECK (item_type = ANY (ARRAY['cluster'::text, 'report'::text, 'bundled_report'::text]));
ALTER TABLE "public"."dispatch_plan_items" ADD CONSTRAINT "dispatch_plan_items_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."building_structures" ADD CONSTRAINT "building_structures_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."crew_urgency_observations" ADD CONSTRAINT "crew_urgency_observations_conditions_check" CHECK (char_length(conditions) >= 3 AND char_length(conditions) <= 1500);
ALTER TABLE "public"."crew_urgency_observations" ADD CONSTRAINT "crew_urgency_observations_observed_result_check" CHECK (observed_result = ANY (ARRAY['urgent_observed'::text, 'conditions_differ'::text, 'unable_to_verify'::text]));
ALTER TABLE "public"."crew_urgency_observations" ADD CONSTRAINT "crew_urgency_observations_pkey" PRIMARY KEY (operation_id);
ALTER TABLE "public"."plan_generation_jobs" ADD CONSTRAINT "plan_generation_jobs_mode_check" CHECK (mode = ANY (ARRAY['standard'::text, 'sweeper'::text, 'mixed'::text]));
ALTER TABLE "public"."plan_generation_jobs" ADD CONSTRAINT "plan_generation_jobs_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."plan_generation_jobs" ADD CONSTRAINT "plan_generation_jobs_plan_id_key" UNIQUE (plan_id);
ALTER TABLE "public"."plan_generation_jobs" ADD CONSTRAINT "plan_generation_jobs_status_check" CHECK (status = ANY (ARRAY['queued'::text, 'running'::text, 'completed'::text, 'failed'::text]));
ALTER TABLE "public"."crew_urgency_reviews" ADD CONSTRAINT "crew_urgency_reviews_operation_id_key" UNIQUE (operation_id);
ALTER TABLE "public"."crew_urgency_reviews" ADD CONSTRAINT "crew_urgency_reviews_pkey" PRIMARY KEY (observation_id);
ALTER TABLE "public"."crew_urgency_reviews" ADD CONSTRAINT "crew_urgency_reviews_reason_check" CHECK (char_length(reason) >= 3 AND char_length(reason) <= 1500);
ALTER TABLE "public"."reports" ADD CONSTRAINT "reports_after_photos_check" CHECK (jsonb_typeof(after_photos) = 'array'::text AND jsonb_array_length(after_photos) <= 5);
ALTER TABLE "public"."reports" ADD CONSTRAINT "reports_barangay_resolution_status_check" CHECK (barangay_resolution_status = ANY (ARRAY['pending_reconciliation'::text, 'resolved'::text, 'border'::text, 'overlap'::text, 'unresolved'::text, 'dataset_incomplete'::text, 'invalid_coordinates'::text, 'unavailable'::text]));
ALTER TABLE "public"."reports" ADD CONSTRAINT "reports_before_photos_check" CHECK (jsonb_typeof(before_photos) = 'array'::text AND jsonb_array_length(before_photos) <= 5);
ALTER TABLE "public"."reports" ADD CONSTRAINT "reports_citizen_landmark_check" CHECK (citizen_landmark IS NULL OR char_length(citizen_landmark) >= 1 AND char_length(citizen_landmark) <= 300);
ALTER TABLE "public"."reports" ADD CONSTRAINT "reports_citizen_priority_check" CHECK (citizen_priority IS NULL AND priority_reason IS NULL AND priority_explanation IS NULL OR citizen_priority IS NOT NULL AND citizen_priority = 'non_urgent'::text AND priority_reason IS NULL AND priority_explanation IS NULL OR citizen_priority IS NOT NULL AND citizen_priority = 'urgent'::text AND priority_reason IS NOT NULL AND (priority_reason = ANY (ARRAY['community_event'::text, 'school_hospital_zone'::text, 'severe_obstruction'::text, 'public_health_hazard'::text])) AND (priority_explanation IS NULL OR char_length(priority_explanation) <= 1000));
ALTER TABLE "public"."reports" ADD CONSTRAINT "reports_hazard_class_check" CHECK (hazard_class = ANY (ARRAY['unknown'::text, 'standard'::text, 'suspected_hazard'::text, 'hazmat_required'::text]));
ALTER TABLE "public"."reports" ADD CONSTRAINT "reports_hazard_confidence_check" CHECK (hazard_confidence IS NULL OR hazard_confidence >= 0::numeric AND hazard_confidence <= 1::numeric);
ALTER TABLE "public"."reports" ADD CONSTRAINT "reports_hazard_metadata_check" CHECK (hazard_class = 'unknown'::text OR hazard_model_version IS NOT NULL AND hazard_confidence IS NOT NULL AND hazard_decision_source IS NOT NULL AND hazard_classified_at IS NOT NULL);
ALTER TABLE "public"."reports" ADD CONSTRAINT "reports_idempotency_key_key" UNIQUE (idempotency_key);
ALTER TABLE "public"."reports" ADD CONSTRAINT "reports_lifecycle_state_check" CHECK (lifecycle_state = ANY (ARRAY['fresh'::text, 'clustered'::text, 'maturing'::text, 'sla_breached'::text, 'dispatched'::text, 'closed'::text]));
ALTER TABLE "public"."reports" ADD CONSTRAINT "reports_operational_actor_id_check" CHECK (operational_actor_id IS NULL);
ALTER TABLE "public"."reports" ADD CONSTRAINT "reports_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."reports" ADD CONSTRAINT "reports_ra9003_category_check" CHECK (ra9003_category = ANY (ARRAY['solid'::text, 'bulky'::text, 'special'::text, 'na'::text]));
ALTER TABLE "public"."reports" ADD CONSTRAINT "reports_satisfaction_rating_check" CHECK (satisfaction_rating >= 1 AND satisfaction_rating <= 5);
ALTER TABLE "public"."reports" ADD CONSTRAINT "reports_severity_score_check" CHECK (severity_score >= 0 AND severity_score <= 100);
ALTER TABLE "public"."reports" ADD CONSTRAINT "reports_urgency_score_check" CHECK (urgency_score = ANY (ARRAY[1, 2, 3]));
ALTER TABLE "public"."reports" ADD CONSTRAINT "reports_urgency_status_check" CHECK (urgency_status = ANY (ARRAY['pending'::text, 'approved'::text, 'declined'::text]));
ALTER TABLE "public"."pasig_barangay_roster" ADD CONSTRAINT "pasig_barangay_roster_name_key" UNIQUE (name);
ALTER TABLE "public"."pasig_barangay_roster" ADD CONSTRAINT "pasig_barangay_roster_pkey" PRIMARY KEY (psgc_code);
ALTER TABLE "public"."fc_operation_log" ADD CONSTRAINT "fc_operation_log_pkey" PRIMARY KEY (operation_id);
ALTER TABLE "public"."fc_conflict_audit" ADD CONSTRAINT "fc_conflict_audit_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."profiles" ADD CONSTRAINT "profiles_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."hotspot_accuracy" ADD CONSTRAINT "hotspot_accuracy_accuracy_score_check" CHECK (accuracy_score >= 0::numeric AND accuracy_score <= 1::numeric);
ALTER TABLE "public"."hotspot_accuracy" ADD CONSTRAINT "hotspot_accuracy_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."hotspot_accuracy" ADD CONSTRAINT "hotspot_accuracy_time_horizon_check" CHECK (time_horizon::text = ANY (ARRAY['daily'::character varying, 'weekly'::character varying, 'monthly'::character varying]::text[]));
ALTER TABLE "public"."dispatch_group_commits" ADD CONSTRAINT "dispatch_group_commits_pkey" PRIMARY KEY (dispatch_plan_id, group_key);
ALTER TABLE "public"."system_settings" ADD CONSTRAINT "system_settings_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."system_settings" ADD CONSTRAINT "system_settings_report_video_max_seconds_check" CHECK (report_video_max_seconds >= 5 AND report_video_max_seconds <= 10);
ALTER TABLE "public"."email_verifications" ADD CONSTRAINT "email_verifications_digest_format" CHECK (token_digest IS NULL OR token IS NULL AND token_digest ~ '^[0-9a-f]{64}$'::text);
ALTER TABLE "public"."email_verifications" ADD CONSTRAINT "email_verifications_issued_email_format" CHECK (issued_to_email IS NULL OR length(issued_to_email) <= 320 AND issued_to_email ~ '^[^\s@]+@[^\s@]+$'::text);
ALTER TABLE "public"."email_verifications" ADD CONSTRAINT "email_verifications_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."dispatch_access_blocks" ADD CONSTRAINT "dispatch_access_blocks_check" CHECK (((cluster_id IS NOT NULL)::integer + (report_id IS NOT NULL)::integer) = 1);
ALTER TABLE "public"."dispatch_access_blocks" ADD CONSTRAINT "dispatch_access_blocks_check1" CHECK (cleared_at IS NULL AND cleared_by IS NULL OR cleared_at IS NOT NULL AND cleared_by IS NOT NULL);
ALTER TABLE "public"."dispatch_access_blocks" ADD CONSTRAINT "dispatch_access_blocks_failure_class_check" CHECK (failure_class = ANY (ARRAY['site'::text, 'safety'::text, 'unclassified'::text]));
ALTER TABLE "public"."dispatch_access_blocks" ADD CONSTRAINT "dispatch_access_blocks_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."dispatch_access_blocks" ADD CONSTRAINT "dispatch_access_blocks_reason_check" CHECK (length(btrim(reason)) > 0);
ALTER TABLE "public"."pasig_barangay_boundary_source" ADD CONSTRAINT "pasig_barangay_boundary_source_pkey" PRIMARY KEY (singleton);
ALTER TABLE "public"."pasig_barangay_boundary_source" ADD CONSTRAINT "pasig_barangay_boundary_source_singleton_check" CHECK (singleton);
ALTER TABLE "public"."field_assignment_receipts" ADD CONSTRAINT "field_assignment_receipts_assignment_generation_check" CHECK (assignment_generation > 0);
ALTER TABLE "public"."field_assignment_receipts" ADD CONSTRAINT "field_assignment_receipts_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."field_assignment_receipts" ADD CONSTRAINT "field_assignment_receipts_report_claim_generation_check" CHECK (report_claim_generation > 0);
ALTER TABLE "public"."field_assignment_receipts" ADD CONSTRAINT "field_assignment_receipts_task_id_report_id_crew_id_assignm_key" UNIQUE (task_id, report_id, crew_id, assignment_generation, report_claim_generation);
ALTER TABLE "public"."report_resolution_events" ADD CONSTRAINT "report_resolution_events_operation_id_key" UNIQUE (operation_id);
ALTER TABLE "public"."report_resolution_events" ADD CONSTRAINT "report_resolution_events_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."report_resolution_events" ADD CONSTRAINT "report_resolution_events_resolution_kind_check" CHECK (resolution_kind = 'cleaned'::text);
ALTER TABLE "public"."notifications" ADD CONSTRAINT "notifications_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."optimization_templates" ADD CONSTRAINT "optimization_templates_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."task_report_outcomes" ADD CONSTRAINT "task_report_outcomes_disposition_check" CHECK (disposition = ANY (ARRAY['applied'::text, 'acknowledged_already_resolved'::text, 'verification_required'::text, 'contested'::text]));
ALTER TABLE "public"."task_report_outcomes" ADD CONSTRAINT "task_report_outcomes_evidence_refs_check" CHECK (jsonb_typeof(evidence_refs) = 'array'::text);
ALTER TABLE "public"."task_report_outcomes" ADD CONSTRAINT "task_report_outcomes_evidence_verification_check" CHECK (evidence_verification = ANY (ARRAY['verified'::text, 'unverified'::text]));
ALTER TABLE "public"."task_report_outcomes" ADD CONSTRAINT "task_report_outcomes_operation_id_key" UNIQUE (operation_id);
ALTER TABLE "public"."task_report_outcomes" ADD CONSTRAINT "task_report_outcomes_outcome_check" CHECK (outcome = ANY (ARRAY['cleaned'::text, 'already_resolved'::text, 'unable'::text, 'skipped'::text]));
ALTER TABLE "public"."task_report_outcomes" ADD CONSTRAINT "task_report_outcomes_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."optimization_settings" ADD CONSTRAINT "optimization_settings_key_key" UNIQUE (key);
ALTER TABLE "public"."optimization_settings" ADD CONSTRAINT "optimization_settings_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."defense_seed_staging" ADD CONSTRAINT "defense_seed_staging_pkey" PRIMARY KEY (marker);
ALTER TABLE "public"."support_tickets" ADD CONSTRAINT "support_tickets_category_check" CHECK (category = ANY (ARRAY['status_inquiry'::text, 'location_mismatch'::text, 're_inspection'::text, 'hazard_escalation'::text, 'account_help'::text, 'other'::text]));
ALTER TABLE "public"."support_tickets" ADD CONSTRAINT "support_tickets_description_check" CHECK (char_length(btrim(description)) >= 10 AND char_length(btrim(description)) <= 2000);
ALTER TABLE "public"."support_tickets" ADD CONSTRAINT "support_tickets_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."support_tickets" ADD CONSTRAINT "support_tickets_reference_key" UNIQUE (reference);
ALTER TABLE "public"."support_tickets" ADD CONSTRAINT "support_tickets_response_check" CHECK (response IS NULL OR char_length(btrim(response)) >= 1 AND char_length(btrim(response)) <= 2000);
ALTER TABLE "public"."support_tickets" ADD CONSTRAINT "support_tickets_status_check" CHECK (status = ANY (ARRAY['open'::text, 'in_progress'::text, 'resolved'::text, 'closed'::text]));
ALTER TABLE "public"."route_waypoints" ADD CONSTRAINT "route_waypoints_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."optimization_runs" ADD CONSTRAINT "optimization_runs_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."optimization_runs" ADD CONSTRAINT "optimization_runs_status_check" CHECK (status = ANY (ARRAY['draft'::text, 'proposed'::text, 'approved'::text, 'discarded'::text, 'failed'::text]));
ALTER TABLE "public"."optimization_runs" ADD CONSTRAINT "optimization_runs_traffic_condition_check" CHECK (traffic_condition = ANY (ARRAY['low'::text, 'moderate'::text, 'heavy'::text]));
ALTER TABLE "public"."optimization_runs" ADD CONSTRAINT "optimization_runs_weather_condition_check" CHECK (weather_condition = ANY (ARRAY['normal'::text, 'heavy_rain'::text, 'storm'::text]));
ALTER TABLE "public"."crew_routes" ADD CONSTRAINT "crew_routes_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."field_load_events" ADD CONSTRAINT "field_load_events_actual_volume_m3_check" CHECK (actual_volume_m3 >= 0::numeric);
ALTER TABLE "public"."field_load_events" ADD CONSTRAINT "field_load_events_actual_weight_kg_check" CHECK (actual_weight_kg >= 0::numeric);
ALTER TABLE "public"."field_load_events" ADD CONSTRAINT "field_load_events_assignment_generation_check" CHECK (assignment_generation > 0);
ALTER TABLE "public"."field_load_events" ADD CONSTRAINT "field_load_events_event_type_check" CHECK (event_type = ANY (ARRAY['load_observation'::text, 'disposal'::text]));
ALTER TABLE "public"."field_load_events" ADD CONSTRAINT "field_load_events_fill_percent_check" CHECK (fill_percent >= 0::numeric AND fill_percent <= 100::numeric);
ALTER TABLE "public"."field_load_events" ADD CONSTRAINT "field_load_events_operation_id_key" UNIQUE (operation_id);
ALTER TABLE "public"."field_load_events" ADD CONSTRAINT "field_load_events_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."field_task_failure_events" ADD CONSTRAINT "field_task_failure_events_assignment_generation_check" CHECK (assignment_generation > 0);
ALTER TABLE "public"."field_task_failure_events" ADD CONSTRAINT "field_task_failure_events_evidence_refs_check" CHECK (jsonb_typeof(evidence_refs) = 'array'::text);
ALTER TABLE "public"."field_task_failure_events" ADD CONSTRAINT "field_task_failure_events_failure_class_check" CHECK (failure_class = ANY (ARRAY['site'::text, 'safety'::text, 'transient'::text]));
ALTER TABLE "public"."field_task_failure_events" ADD CONSTRAINT "field_task_failure_events_notes_check" CHECK (length(btrim(notes)) > 0);
ALTER TABLE "public"."field_task_failure_events" ADD CONSTRAINT "field_task_failure_events_operation_id_key" UNIQUE (operation_id);
ALTER TABLE "public"."field_task_failure_events" ADD CONSTRAINT "field_task_failure_events_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."field_task_failure_events" ADD CONSTRAINT "field_task_failure_events_reason_code_check" CHECK (reason_code = ANY (ARRAY['site_inaccessible'::text, 'safety_hazard'::text, 'vehicle_failure'::text, 'crew_unavailable'::text]));
ALTER TABLE "public"."sync_conflicts" ADD CONSTRAINT "sync_conflicts_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."work_time_configuration" ADD CONSTRAINT "work_time_configuration_estimated_volume_m3_check" CHECK (estimated_volume_m3 >= 0::numeric);
ALTER TABLE "public"."work_time_configuration" ADD CONSTRAINT "work_time_configuration_estimated_weight_kg_check" CHECK (estimated_weight_kg >= 0::numeric);
ALTER TABLE "public"."work_time_configuration" ADD CONSTRAINT "work_time_configuration_pkey" PRIMARY KEY (report_type);
ALTER TABLE "public"."sweeper_configuration" ADD CONSTRAINT "sweeper_configuration_pkey" PRIMARY KEY (parameter_name);
ALTER TABLE "public"."sweeper_audit_log" ADD CONSTRAINT "sweeper_audit_log_pkey" PRIMARY KEY (id);
ALTER TABLE "workflow_private"."report_barangay_reconciliation_log" ADD CONSTRAINT "report_barangay_reconciliation_log_pkey" PRIMARY KEY (report_id, reconciled_at);
ALTER TABLE "workflow_private"."report_barangay_reconciliation_log" ADD CONSTRAINT "report_barangay_reconciliation_log_reason_check" CHECK (reason = ANY (ARRAY['polygon_resolved'::text, 'polygon_flagged'::text, 'outside_boundaries'::text, 'city_text_conflict'::text, 'invalid_location'::text]));
ALTER TABLE "workflow_private"."unprocessed_escalation_baseline" ADD CONSTRAINT "unprocessed_escalation_baseline_pkey" PRIMARY KEY (singleton);
ALTER TABLE "workflow_private"."unprocessed_escalation_baseline" ADD CONSTRAINT "unprocessed_escalation_baseline_singleton_check" CHECK (singleton);
ALTER TABLE "public"."clusters" ADD CONSTRAINT "clusters_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."clusters" ADD CONSTRAINT "clusters_priority_check" CHECK (priority = ANY (ARRAY['urgent'::text, 'high'::text, 'medium'::text, 'low'::text]));
ALTER TABLE "public"."strikes" ADD CONSTRAINT "strikes_pkey" PRIMARY KEY (id);
ALTER TABLE "privacy_private"."hidden_report_owners" ADD CONSTRAINT "hidden_report_owners_pkey" PRIMARY KEY (report_id);
ALTER TABLE "privacy_private"."hidden_report_artifacts" ADD CONSTRAINT "hidden_report_artifacts_pkey" PRIMARY KEY (record_id);
ALTER TABLE "public"."cleanup_proof_publications" ADD CONSTRAINT "cleanup_proof_first_paths_match" CHECK ((before_paths IS NULL OR (before_paths ->> 0) = before_path) AND (after_paths IS NULL OR (after_paths ->> 0) = after_path));
ALTER TABLE "public"."cleanup_proof_publications" ADD CONSTRAINT "cleanup_proof_publications_after_paths_check" CHECK (after_paths IS NULL OR jsonb_typeof(after_paths) = 'array'::text AND jsonb_array_length(after_paths) >= 1 AND jsonb_array_length(after_paths) <= 5);
ALTER TABLE "public"."cleanup_proof_publications" ADD CONSTRAINT "cleanup_proof_publications_before_paths_check" CHECK (before_paths IS NULL OR jsonb_typeof(before_paths) = 'array'::text AND jsonb_array_length(before_paths) >= 1 AND jsonb_array_length(before_paths) <= 5);
ALTER TABLE "public"."cleanup_proof_publications" ADD CONSTRAINT "cleanup_proof_publications_id_key" UNIQUE (id);
ALTER TABLE "public"."cleanup_proof_publications" ADD CONSTRAINT "cleanup_proof_publications_pkey" PRIMARY KEY (report_id);
ALTER TABLE "public"."cleanup_proof_publications" ADD CONSTRAINT "cleanup_proof_publications_public_notes_check" CHECK (length(btrim(public_notes)) >= 1 AND length(btrim(public_notes)) <= 2000);
ALTER TABLE "public"."spatial_zones" ADD CONSTRAINT "spatial_zones_centroid_lat_check" CHECK (centroid_lat >= '-90'::integer::double precision AND centroid_lat <= 90::double precision);
ALTER TABLE "public"."spatial_zones" ADD CONSTRAINT "spatial_zones_centroid_lng_check" CHECK (centroid_lng >= '-180'::integer::double precision AND centroid_lng <= 180::double precision);
ALTER TABLE "public"."spatial_zones" ADD CONSTRAINT "spatial_zones_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."spatial_zones" ADD CONSTRAINT "spatial_zones_valid_boundary" CHECK (boundary IS NOT NULL AND NOT st_isempty(boundary) AND st_isvalid(boundary) AND (geometrytype(boundary) = ANY (ARRAY['POLYGON'::text, 'MULTIPOLYGON'::text])));
ALTER TABLE "public"."spatial_zones" ADD CONSTRAINT "spatial_zones_zone_type_check" CHECK (zone_type::text = ANY (ARRAY['h3'::character varying, 'barangay'::character varying]::text[]));
ALTER TABLE "public"."hotspot_predictions" ADD CONSTRAINT "hotspot_predictions_forward_counts" CHECK (predicted_count >= 0::numeric AND predicted_lower_bound >= 0::numeric AND predicted_lower_bound <= predicted_count AND predicted_count <= predicted_upper_bound);
ALTER TABLE "public"."hotspot_predictions" ADD CONSTRAINT "hotspot_predictions_forward_dates" CHECK (zone_id IS NULL OR forecast_date_start IS NOT NULL AND forecast_date_end IS NOT NULL AND (forecast_date_end - forecast_date_start) = make_interval(days => horizon_days));
ALTER TABLE "public"."hotspot_predictions" ADD CONSTRAINT "hotspot_predictions_forward_horizon" CHECK (horizon_days = ANY (ARRAY[7, 30, 90]));
ALTER TABLE "public"."hotspot_predictions" ADD CONSTRAINT "hotspot_predictions_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."hotspot_predictions" ADD CONSTRAINT "hotspot_predictions_series_arrays" CHECK (jsonb_typeof(historical_points) = 'array'::text AND jsonb_typeof(forecast_points) = 'array'::text);
ALTER TABLE "public"."operational_events" ADD CONSTRAINT "operational_event_clock_range" CHECK (isfinite(occurred_at) AND occurred_at >= '2020-01-01 00:00:00+00'::timestamp with time zone AND occurred_at < '10000-01-01 00:00:00+00'::timestamp with time zone AND isfinite(recorded_at) AND recorded_at >= '2020-01-01 00:00:00+00'::timestamp with time zone AND recorded_at < '10000-01-01 00:00:00+00'::timestamp with time zone);
ALTER TABLE "public"."operational_events" ADD CONSTRAINT "operational_events_check" CHECK (task_id IS NOT NULL OR report_id IS NOT NULL);
ALTER TABLE "public"."operational_events" ADD CONSTRAINT "operational_events_event_key_key" UNIQUE (event_key);
ALTER TABLE "public"."operational_events" ADD CONSTRAINT "operational_events_event_type_check" CHECK (event_type = ANY (ARRAY['assignment'::text, 'acknowledgement'::text, 'arrival'::text, 'evidence_submission'::text, 'completion'::text, 'verification'::text, 'task_transition'::text]));
ALTER TABLE "public"."operational_events" ADD CONSTRAINT "operational_events_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."operational_events" ADD CONSTRAINT "operational_events_time_basis_check" CHECK (time_basis = ANY (ARRAY['server'::text, 'device_reported'::text]));
ALTER TABLE "public"."citizen_trust" ADD CONSTRAINT "citizen_trust_pkey" PRIMARY KEY (user_id);
ALTER TABLE "public"."citizen_trust" ADD CONSTRAINT "citizen_trust_recovery_streak_check" CHECK (recovery_streak >= 0 AND recovery_streak <= 3);
ALTER TABLE "public"."citizen_trust" ADD CONSTRAINT "citizen_trust_score_check" CHECK (score >= 0 AND score <= 100);
ALTER TABLE "public"."citizen_trust_decisions" ADD CONSTRAINT "citizen_trust_decisions_operation_id_key" UNIQUE (operation_id);
ALTER TABLE "public"."citizen_trust_decisions" ADD CONSTRAINT "citizen_trust_decisions_outcome_check" CHECK (outcome = ANY (ARRAY['valid'::text, 'neutral'::text, 'false_urgency'::text, 'withdrawn'::text]));
ALTER TABLE "public"."citizen_trust_decisions" ADD CONSTRAINT "citizen_trust_decisions_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."citizen_trust_decisions" ADD CONSTRAINT "citizen_trust_decisions_reason_check" CHECK (char_length(btrim(reason)) >= 3 AND char_length(btrim(reason)) <= 1000);
ALTER TABLE "public"."citizen_trust_decisions" ADD CONSTRAINT "citizen_trust_decisions_supersedes_id_key" UNIQUE (supersedes_id);
ALTER TABLE "workflow_private"."unprocessed_alert_deliveries" ADD CONSTRAINT "unprocessed_alert_deliveries_age_day_check" CHECK (age_day >= 5);
ALTER TABLE "workflow_private"."unprocessed_alert_deliveries" ADD CONSTRAINT "unprocessed_alert_deliveries_pkey" PRIMARY KEY (report_id, recipient_id, age_day);
ALTER TABLE "workflow_private"."lifecycle_deployment" ADD CONSTRAINT "lifecycle_deployment_pkey" PRIMARY KEY (singleton);
ALTER TABLE "workflow_private"."lifecycle_deployment" ADD CONSTRAINT "lifecycle_deployment_singleton_check" CHECK (singleton);
ALTER TABLE "workflow_private"."historical_sla_reset" ADD CONSTRAINT "historical_sla_reset_pkey" PRIMARY KEY (report_id);
ALTER TABLE "public"."report_urgency_decisions" ADD CONSTRAINT "report_urgency_decisions_outcome_check" CHECK (outcome = ANY (ARRAY['approved'::text, 'declined'::text]));
ALTER TABLE "public"."report_urgency_decisions" ADD CONSTRAINT "report_urgency_decisions_pkey" PRIMARY KEY (operation_id);
ALTER TABLE "public"."report_urgency_decisions" ADD CONSTRAINT "report_urgency_decisions_reason_check" CHECK (char_length(btrim(reason)) >= 3 AND char_length(btrim(reason)) <= 1000);
ALTER TABLE "public"."report_urgency_decisions" ADD CONSTRAINT "report_urgency_decisions_sequence_key" UNIQUE (sequence);
ALTER TABLE "public"."report_urgency_alerts" ADD CONSTRAINT "report_urgency_alerts_pkey" PRIMARY KEY (report_id, recipient_id);
ALTER TABLE "public"."field_crews" ADD CONSTRAINT "field_crews_certification_reviewed_by_fkey" FOREIGN KEY (certification_reviewed_by) REFERENCES profiles(id);
ALTER TABLE "public"."field_crews" ADD CONSTRAINT "field_crews_team_lead_profile_id_fkey" FOREIGN KEY (team_lead_profile_id) REFERENCES profiles(id);
ALTER TABLE "operational_private"."crew_presence" ADD CONSTRAINT "crew_presence_crew_id_fkey" FOREIGN KEY (crew_id) REFERENCES profiles(id) ON DELETE CASCADE;
ALTER TABLE "public"."dispatch_plans" ADD CONSTRAINT "dispatch_plans_created_by_fkey" FOREIGN KEY (created_by) REFERENCES auth.users(id);
ALTER TABLE "public"."dispatch_plans" ADD CONSTRAINT "dispatch_plans_generation_job_id_fkey" FOREIGN KEY (generation_job_id) REFERENCES plan_generation_jobs(id);
ALTER TABLE "public"."dispatch_plans" ADD CONSTRAINT "dispatch_plans_optimization_run_id_fkey" FOREIGN KEY (optimization_run_id) REFERENCES optimization_runs(id);
ALTER TABLE "public"."manual_review_queue" ADD CONSTRAINT "manual_review_queue_assigned_to_fkey" FOREIGN KEY (assigned_to) REFERENCES profiles(id) ON DELETE SET NULL;
ALTER TABLE "public"."manual_review_queue" ADD CONSTRAINT "manual_review_queue_report_id_fkey" FOREIGN KEY (report_id) REFERENCES reports(id) ON DELETE CASCADE;
ALTER TABLE "public"."manual_review_queue" ADD CONSTRAINT "manual_review_queue_strike_id_fkey" FOREIGN KEY (strike_id) REFERENCES strikes(id) ON DELETE SET NULL;
ALTER TABLE "public"."audit_logs" ADD CONSTRAINT "response_log_report_id_fkey" FOREIGN KEY (report_id) REFERENCES reports(id) ON DELETE CASCADE;
ALTER TABLE "public"."audit_logs" ADD CONSTRAINT "response_log_user_id_fkey" FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE SET NULL;
ALTER TABLE "public"."system_logs" ADD CONSTRAINT "audit_logs_user_id_fkey" FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE SET NULL;
ALTER TABLE "public"."cleanup_tasks" ADD CONSTRAINT "cleanup_tasks_assigned_by_fkey" FOREIGN KEY (assigned_by) REFERENCES profiles(id);
ALTER TABLE "public"."cleanup_tasks" ADD CONSTRAINT "cleanup_tasks_assigned_field_crew_id_fkey" FOREIGN KEY (assigned_field_crew_id) REFERENCES field_crews(id);
ALTER TABLE "public"."cleanup_tasks" ADD CONSTRAINT "cleanup_tasks_cluster_id_fkey" FOREIGN KEY (cluster_id) REFERENCES clusters(id);
ALTER TABLE "public"."cleanup_tasks" ADD CONSTRAINT "cleanup_tasks_completed_by_fkey" FOREIGN KEY (completed_by) REFERENCES profiles(id);
ALTER TABLE "public"."cleanup_tasks" ADD CONSTRAINT "cleanup_tasks_created_by_fkey" FOREIGN KEY (created_by) REFERENCES auth.users(id);
ALTER TABLE "public"."cleanup_tasks" ADD CONSTRAINT "cleanup_tasks_crew_route_id_fkey" FOREIGN KEY (crew_route_id) REFERENCES crew_routes(id) ON DELETE SET NULL;
ALTER TABLE "public"."cleanup_tasks" ADD CONSTRAINT "cleanup_tasks_lgu_user_id_fkey" FOREIGN KEY (lgu_user_id) REFERENCES profiles(id);
ALTER TABLE "public"."cleanup_tasks" ADD CONSTRAINT "cleanup_tasks_source_plan_id_fkey" FOREIGN KEY (source_plan_id) REFERENCES dispatch_plans(id);
ALTER TABLE "public"."dispatch_plan_items" ADD CONSTRAINT "dispatch_plan_items_anchor_cluster_id_fkey" FOREIGN KEY (anchor_cluster_id) REFERENCES clusters(id);
ALTER TABLE "public"."dispatch_plan_items" ADD CONSTRAINT "dispatch_plan_items_cluster_id_fkey" FOREIGN KEY (cluster_id) REFERENCES clusters(id) ON DELETE CASCADE;
ALTER TABLE "public"."dispatch_plan_items" ADD CONSTRAINT "dispatch_plan_items_committed_task_id_fkey" FOREIGN KEY (committed_task_id) REFERENCES cleanup_tasks(id);
ALTER TABLE "public"."dispatch_plan_items" ADD CONSTRAINT "dispatch_plan_items_dispatch_plan_id_fkey" FOREIGN KEY (dispatch_plan_id) REFERENCES dispatch_plans(id) ON DELETE CASCADE;
ALTER TABLE "public"."dispatch_plan_items" ADD CONSTRAINT "dispatch_plan_items_planned_crew_id_fkey" FOREIGN KEY (planned_crew_id) REFERENCES field_crews(id);
ALTER TABLE "public"."dispatch_plan_items" ADD CONSTRAINT "dispatch_plan_items_report_id_fkey" FOREIGN KEY (report_id) REFERENCES reports(id);
ALTER TABLE "public"."crew_urgency_observations" ADD CONSTRAINT "crew_urgency_observations_actor_id_fkey" FOREIGN KEY (actor_id) REFERENCES profiles(id) ON DELETE SET NULL;
ALTER TABLE "public"."plan_generation_jobs" ADD CONSTRAINT "plan_generation_jobs_plan_id_fkey" FOREIGN KEY (plan_id) REFERENCES dispatch_plans(id);
ALTER TABLE "public"."plan_generation_jobs" ADD CONSTRAINT "plan_generation_jobs_requested_by_fkey" FOREIGN KEY (requested_by) REFERENCES profiles(id);
ALTER TABLE "public"."crew_urgency_reviews" ADD CONSTRAINT "crew_urgency_reviews_actor_id_fkey" FOREIGN KEY (actor_id) REFERENCES profiles(id) ON DELETE SET NULL;
ALTER TABLE "public"."crew_urgency_reviews" ADD CONSTRAINT "crew_urgency_reviews_observation_id_fkey" FOREIGN KEY (observation_id) REFERENCES crew_urgency_observations(operation_id);
ALTER TABLE "public"."reports" ADD CONSTRAINT "reports_cleanup_task_id_fkey" FOREIGN KEY (cleanup_task_id) REFERENCES cleanup_tasks(id);
ALTER TABLE "public"."reports" ADD CONSTRAINT "reports_cluster_id_fkey" FOREIGN KEY (cluster_id) REFERENCES clusters(id) ON UPDATE CASCADE ON DELETE SET NULL;
ALTER TABLE "public"."reports" ADD CONSTRAINT "reports_manual_review_id_fkey" FOREIGN KEY (manual_review_id) REFERENCES manual_review_queue(id) ON DELETE SET NULL;
ALTER TABLE "public"."reports" ADD CONSTRAINT "reports_user_id_fkey" FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE SET NULL;
ALTER TABLE "public"."fc_operation_log" ADD CONSTRAINT "fc_operation_log_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
ALTER TABLE "public"."fc_conflict_audit" ADD CONSTRAINT "fc_conflict_audit_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;
ALTER TABLE "public"."profiles" ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY (id) REFERENCES auth.users(id);
ALTER TABLE "public"."dispatch_group_commits" ADD CONSTRAINT "dispatch_group_commits_dispatch_plan_id_fkey" FOREIGN KEY (dispatch_plan_id) REFERENCES dispatch_plans(id);
ALTER TABLE "public"."email_verifications" ADD CONSTRAINT "email_verifications_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
ALTER TABLE "public"."dispatch_access_blocks" ADD CONSTRAINT "dispatch_access_blocks_blocked_by_fkey" FOREIGN KEY (blocked_by) REFERENCES profiles(id);
ALTER TABLE "public"."dispatch_access_blocks" ADD CONSTRAINT "dispatch_access_blocks_cleared_by_fkey" FOREIGN KEY (cleared_by) REFERENCES profiles(id);
ALTER TABLE "public"."dispatch_access_blocks" ADD CONSTRAINT "dispatch_access_blocks_cluster_id_fkey" FOREIGN KEY (cluster_id) REFERENCES clusters(id);
ALTER TABLE "public"."dispatch_access_blocks" ADD CONSTRAINT "dispatch_access_blocks_report_id_fkey" FOREIGN KEY (report_id) REFERENCES reports(id);
ALTER TABLE "public"."dispatch_access_blocks" ADD CONSTRAINT "dispatch_access_blocks_task_id_fkey" FOREIGN KEY (task_id) REFERENCES cleanup_tasks(id);
ALTER TABLE "public"."field_assignment_receipts" ADD CONSTRAINT "field_assignment_receipts_crew_id_fkey" FOREIGN KEY (crew_id) REFERENCES profiles(id);
ALTER TABLE "public"."field_assignment_receipts" ADD CONSTRAINT "field_assignment_receipts_report_id_fkey" FOREIGN KEY (report_id) REFERENCES reports(id);
ALTER TABLE "public"."field_assignment_receipts" ADD CONSTRAINT "field_assignment_receipts_task_id_fkey" FOREIGN KEY (task_id) REFERENCES cleanup_tasks(id);
ALTER TABLE "public"."report_resolution_events" ADD CONSTRAINT "report_resolution_events_crew_id_fkey" FOREIGN KEY (crew_id) REFERENCES profiles(id);
ALTER TABLE "public"."report_resolution_events" ADD CONSTRAINT "report_resolution_events_report_id_fkey" FOREIGN KEY (report_id) REFERENCES reports(id);
ALTER TABLE "public"."report_resolution_events" ADD CONSTRAINT "report_resolution_events_task_id_fkey" FOREIGN KEY (task_id) REFERENCES cleanup_tasks(id);
ALTER TABLE "public"."notifications" ADD CONSTRAINT "notifications_report_id_fkey" FOREIGN KEY (report_id) REFERENCES reports(id) ON DELETE CASCADE;
ALTER TABLE "public"."notifications" ADD CONSTRAINT "notifications_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
ALTER TABLE "public"."optimization_templates" ADD CONSTRAINT "optimization_templates_created_by_fkey" FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE CASCADE;
ALTER TABLE "public"."task_report_outcomes" ADD CONSTRAINT "task_report_outcomes_crew_id_fkey" FOREIGN KEY (crew_id) REFERENCES profiles(id);
ALTER TABLE "public"."task_report_outcomes" ADD CONSTRAINT "task_report_outcomes_receipt_id_fkey" FOREIGN KEY (receipt_id) REFERENCES field_assignment_receipts(id);
ALTER TABLE "public"."task_report_outcomes" ADD CONSTRAINT "task_report_outcomes_report_id_fkey" FOREIGN KEY (report_id) REFERENCES reports(id);
ALTER TABLE "public"."task_report_outcomes" ADD CONSTRAINT "task_report_outcomes_resolution_event_id_fkey" FOREIGN KEY (resolution_event_id) REFERENCES report_resolution_events(id);
ALTER TABLE "public"."task_report_outcomes" ADD CONSTRAINT "task_report_outcomes_task_id_fkey" FOREIGN KEY (task_id) REFERENCES cleanup_tasks(id);
ALTER TABLE "public"."optimization_settings" ADD CONSTRAINT "optimization_settings_updated_by_fkey" FOREIGN KEY (updated_by) REFERENCES profiles(id);
ALTER TABLE "public"."support_tickets" ADD CONSTRAINT "support_tickets_citizen_id_fkey" FOREIGN KEY (citizen_id) REFERENCES profiles(id) ON DELETE CASCADE;
ALTER TABLE "public"."support_tickets" ADD CONSTRAINT "support_tickets_handler_id_fkey" FOREIGN KEY (handler_id) REFERENCES profiles(id) ON DELETE SET NULL;
ALTER TABLE "public"."support_tickets" ADD CONSTRAINT "support_tickets_report_id_fkey" FOREIGN KEY (report_id) REFERENCES reports(id) ON DELETE SET NULL;
ALTER TABLE "public"."route_waypoints" ADD CONSTRAINT "route_waypoints_cleanup_task_id_fkey" FOREIGN KEY (cleanup_task_id) REFERENCES cleanup_tasks(id);
ALTER TABLE "public"."route_waypoints" ADD CONSTRAINT "route_waypoints_crew_route_id_fkey" FOREIGN KEY (crew_route_id) REFERENCES crew_routes(id) ON DELETE CASCADE;
ALTER TABLE "public"."route_waypoints" ADD CONSTRAINT "route_waypoints_report_id_fkey" FOREIGN KEY (report_id) REFERENCES reports(id);
ALTER TABLE "public"."optimization_runs" ADD CONSTRAINT "optimization_runs_approved_by_fkey" FOREIGN KEY (approved_by) REFERENCES profiles(id);
ALTER TABLE "public"."optimization_runs" ADD CONSTRAINT "optimization_runs_triggered_by_fkey" FOREIGN KEY (triggered_by) REFERENCES profiles(id);
ALTER TABLE "public"."crew_routes" ADD CONSTRAINT "crew_routes_crew_id_fkey" FOREIGN KEY (crew_id) REFERENCES field_crews(id);
ALTER TABLE "public"."crew_routes" ADD CONSTRAINT "crew_routes_optimization_run_id_fkey" FOREIGN KEY (optimization_run_id) REFERENCES optimization_runs(id) ON DELETE CASCADE;
ALTER TABLE "public"."field_load_events" ADD CONSTRAINT "field_load_events_actor_id_fkey" FOREIGN KEY (actor_id) REFERENCES profiles(id);
ALTER TABLE "public"."field_load_events" ADD CONSTRAINT "field_load_events_field_crew_id_fkey" FOREIGN KEY (field_crew_id) REFERENCES field_crews(id);
ALTER TABLE "public"."field_load_events" ADD CONSTRAINT "field_load_events_task_id_fkey" FOREIGN KEY (task_id) REFERENCES cleanup_tasks(id);
ALTER TABLE "public"."field_task_failure_events" ADD CONSTRAINT "field_task_failure_events_actor_id_fkey" FOREIGN KEY (actor_id) REFERENCES profiles(id);
ALTER TABLE "public"."field_task_failure_events" ADD CONSTRAINT "field_task_failure_events_task_id_fkey" FOREIGN KEY (task_id) REFERENCES cleanup_tasks(id);
ALTER TABLE "public"."sync_conflicts" ADD CONSTRAINT "sync_conflicts_resolved_by_fkey" FOREIGN KEY (resolved_by) REFERENCES auth.users(id);
ALTER TABLE "public"."sync_conflicts" ADD CONSTRAINT "sync_conflicts_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id);
ALTER TABLE "public"."strikes" ADD CONSTRAINT "strikes_issued_by_fkey" FOREIGN KEY (issued_by) REFERENCES profiles(id);
ALTER TABLE "public"."strikes" ADD CONSTRAINT "strikes_user_id_fkey" FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE;
ALTER TABLE "privacy_private"."hidden_report_artifacts" ADD CONSTRAINT "hidden_report_artifacts_report_id_fkey" FOREIGN KEY (report_id) REFERENCES privacy_private.hidden_report_owners(report_id);
ALTER TABLE "public"."cleanup_proof_publications" ADD CONSTRAINT "cleanup_proof_publications_report_id_fkey" FOREIGN KEY (report_id) REFERENCES reports(id) ON DELETE CASCADE;
ALTER TABLE "public"."cleanup_proof_publications" ADD CONSTRAINT "cleanup_proof_publications_verified_by_fkey" FOREIGN KEY (verified_by) REFERENCES profiles(id);
ALTER TABLE "public"."hotspot_predictions" ADD CONSTRAINT "hotspot_predictions_zone_id_fkey" FOREIGN KEY (zone_id) REFERENCES spatial_zones(id) ON DELETE RESTRICT;
ALTER TABLE "public"."citizen_trust" ADD CONSTRAINT "citizen_trust_user_id_fkey" FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE;
ALTER TABLE "public"."citizen_trust_decisions" ADD CONSTRAINT "citizen_trust_decisions_actor_id_fkey" FOREIGN KEY (actor_id) REFERENCES profiles(id) ON DELETE SET NULL;
ALTER TABLE "public"."citizen_trust_decisions" ADD CONSTRAINT "citizen_trust_decisions_supersedes_id_fkey" FOREIGN KEY (supersedes_id) REFERENCES citizen_trust_decisions(id);
ALTER TABLE "public"."citizen_trust_decisions" ADD CONSTRAINT "citizen_trust_decisions_user_id_fkey" FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE SET NULL;
ALTER TABLE "workflow_private"."unprocessed_alert_deliveries" ADD CONSTRAINT "unprocessed_alert_deliveries_recipient_id_fkey" FOREIGN KEY (recipient_id) REFERENCES profiles(id) ON DELETE CASCADE;
ALTER TABLE "workflow_private"."unprocessed_alert_deliveries" ADD CONSTRAINT "unprocessed_alert_deliveries_report_id_fkey" FOREIGN KEY (report_id) REFERENCES reports(id) ON DELETE CASCADE;
ALTER TABLE "public"."report_urgency_decisions" ADD CONSTRAINT "report_urgency_decisions_actor_id_fkey" FOREIGN KEY (actor_id) REFERENCES profiles(id) ON DELETE SET NULL;
ALTER TABLE "public"."report_urgency_decisions" ADD CONSTRAINT "report_urgency_decisions_previous_operation_id_fkey" FOREIGN KEY (previous_operation_id) REFERENCES report_urgency_decisions(operation_id);
ALTER TABLE "public"."report_urgency_alerts" ADD CONSTRAINT "report_urgency_alerts_recipient_id_fkey" FOREIGN KEY (recipient_id) REFERENCES profiles(id) ON DELETE CASCADE;
CREATE INDEX idx_dispatch_plan_items_report_id ON public.dispatch_plan_items USING btree (report_id);
CREATE INDEX idx_dispatch_plan_items_cluster_id ON public.dispatch_plan_items USING btree (cluster_id);
CREATE INDEX crew_urgency_by_report ON public.crew_urgency_observations USING btree (report_id, recorded_at DESC);
CREATE INDEX idx_reports_user_feed ON public.reports USING btree (user_id, created_at DESC, id DESC);
CREATE INDEX operational_events_report ON public.operational_events USING btree (report_id, id DESC);
CREATE INDEX task_report_outcomes_review ON public.task_report_outcomes USING btree (disposition, submitted_at) WHERE (disposition = ANY (ARRAY['verification_required'::text, 'contested'::text]));
CREATE INDEX idx_dispatch_plan_items_anchor_cluster_id ON public.dispatch_plan_items USING btree (anchor_cluster_id);
CREATE UNIQUE INDEX one_active_cluster_block ON public.dispatch_access_blocks USING btree (cluster_id) WHERE ((cleared_at IS NULL) AND (cluster_id IS NOT NULL));
CREATE INDEX idx_field_load_events_actor_id ON public.field_load_events USING btree (actor_id);
CREATE INDEX support_tickets_citizen_idx ON public.support_tickets USING btree (citizen_id, created_at DESC, id DESC);
CREATE INDEX idx_cleanup_tasks_crew_route_id ON public.cleanup_tasks USING btree (crew_route_id);
CREATE INDEX dispatch_item_group_idx ON public.dispatch_plan_items USING btree (dispatch_plan_id, group_key);
CREATE INDEX idx_audit_logs_user_id ON public.system_logs USING btree (user_id);
CREATE INDEX idx_response_log_report_id ON public.audit_logs USING btree (report_id);
CREATE INDEX idx_fc_operation_log_user ON public.fc_operation_log USING btree (user_id, created_at DESC);
CREATE INDEX route_waypoints_report_idx ON public.route_waypoints USING btree (report_id) WHERE (report_id IS NOT NULL);
CREATE INDEX idx_field_task_failure_events_actor_id ON public.field_task_failure_events USING btree (actor_id);
CREATE INDEX idx_manual_review_queue_assigned_to ON public.manual_review_queue USING btree (assigned_to);
CREATE INDEX idx_cleanup_tasks_crew_status ON public.cleanup_tasks USING btree (assigned_field_crew_id, status);
CREATE INDEX idx_notifications_created_at ON public.notifications USING btree (created_at DESC);
CREATE INDEX idx_route_waypoints_route ON public.route_waypoints USING btree (crew_route_id, sequence_order);
CREATE INDEX idx_cleanup_tasks_fc_version ON public.cleanup_tasks USING btree (id, fc_version);
CREATE INDEX report_urgency_decisions_latest ON public.report_urgency_decisions USING btree (report_id, sequence DESC);
CREATE INDEX idx_sync_conflicts_resolved_by ON public.sync_conflicts USING btree (resolved_by);
CREATE INDEX support_tickets_queue_idx ON public.support_tickets USING btree (status, created_at, id);
CREATE INDEX idx_profiles_suspended_until ON public.profiles USING btree (suspended_until);
CREATE INDEX plan_generation_claim ON public.plan_generation_jobs USING btree (requested_at) WHERE (status = 'queued'::text);
CREATE INDEX idx_task_report_outcomes_crew_id ON public.task_report_outcomes USING btree (crew_id);
CREATE INDEX idx_hotspot_accuracy_prediction ON public.hotspot_accuracy USING btree (prediction_id);
CREATE INDEX idx_task_report_outcomes_resolution_id ON public.task_report_outcomes USING btree (resolution_event_id);
CREATE INDEX idx_audit_logs_created_at ON public.system_logs USING btree (created_at DESC);
CREATE INDEX idx_fc_conflict_audit_entity ON public.fc_conflict_audit USING btree (entity_id, entity_type, created_at DESC);
CREATE INDEX reports_lifecycle_open_idx ON public.reports USING btree (lifecycle_state, deadline_at) WHERE (lifecycle_state IS DISTINCT FROM 'closed'::text);
CREATE INDEX idx_task_report_outcomes_report_id ON public.task_report_outcomes USING btree (report_id);
CREATE INDEX operational_events_task ON public.operational_events USING btree (task_id, id DESC);
CREATE INDEX idx_report_resolution_events_crew_id ON public.report_resolution_events USING btree (crew_id);
CREATE INDEX report_resolution_events_latest ON public.report_resolution_events USING btree (report_id, resolved_at DESC);
CREATE INDEX operational_events_live_task ON public.operational_events USING btree (id DESC) WHERE (task_id IS NOT NULL);
CREATE INDEX idx_manual_review_queue_status ON public.manual_review_queue USING btree (status);
CREATE INDEX idx_optimization_settings_updated_by ON public.optimization_settings USING btree (updated_by);
CREATE INDEX idx_strikes_is_active ON public.strikes USING btree (is_active);
CREATE INDEX field_load_events_crew_time ON public.field_load_events USING btree (field_crew_id, observed_at DESC);
CREATE INDEX idx_strikes_severity ON public.strikes USING btree (severity);
CREATE INDEX idx_dispatch_plan_items_plan_id ON public.dispatch_plan_items USING btree (dispatch_plan_id);
CREATE UNIQUE INDEX citizen_trust_one_initial_review ON public.citizen_trust_decisions USING btree (report_id) WHERE (supersedes_id IS NULL);
CREATE INDEX reports_active_task_claim ON public.reports USING btree (cleanup_task_id) WHERE (cleanup_task_id IS NOT NULL);
CREATE INDEX idx_optimization_runs_triggered_by ON public.optimization_runs USING btree (triggered_by);
CREATE INDEX idx_reports_manual_review_id ON public.reports USING btree (manual_review_id);
CREATE INDEX idx_sweeper_audit_user ON public.sweeper_audit_log USING btree (user_id);
CREATE UNIQUE INDEX plan_generation_idempotency ON public.plan_generation_jobs USING btree (requested_by, idempotency_key) WHERE (idempotency_key IS NOT NULL);
CREATE UNIQUE INDEX dispatch_unique_cluster ON public.dispatch_plan_items USING btree (dispatch_plan_id, cluster_id) WHERE (cluster_id IS NOT NULL);
CREATE INDEX idx_hotspot_accuracy_horizon ON public.hotspot_accuracy USING btree (time_horizon);
CREATE INDEX plan_generation_expiry ON public.plan_generation_jobs USING btree (lease_until) WHERE (status = 'running'::text);
CREATE INDEX idx_dispatch_plans_optimization_run_id ON public.dispatch_plans USING btree (optimization_run_id);
CREATE INDEX idx_notifications_type ON public.notifications USING btree (type);
CREATE INDEX idx_dispatch_plans_generation_job_id ON public.dispatch_plans USING btree (generation_job_id);
CREATE INDEX clusters_center_geography_idx ON public.clusters USING gist (((center)::geography));
CREATE INDEX idx_dispatch_access_blocks_cleared_by ON public.dispatch_access_blocks USING btree (cleared_by);
CREATE INDEX idx_fc_conflict_audit_user ON public.fc_conflict_audit USING btree (user_id, created_at DESC);
CREATE INDEX idx_notifications_user_created ON public.notifications USING btree (user_id, created_at DESC);
CREATE INDEX idx_manual_review_queue_priority ON public.manual_review_queue USING btree (priority);
CREATE INDEX citizen_trust_decisions_owner ON public.citizen_trust_decisions USING btree (user_id, id);
CREATE INDEX reports_hazard_dispatch_review ON public.reports USING btree (hazard_class, lifecycle_state) WHERE (hazard_class = ANY (ARRAY['suspected_hazard'::text, 'hazmat_required'::text]));
CREATE INDEX idx_hotspot_predictions_date ON public.hotspot_predictions USING btree (prediction_date);
CREATE INDEX idx_reports_cluster_id ON public.reports USING btree (cluster_id);
CREATE UNIQUE INDEX task_source_group ON public.cleanup_tasks USING btree (source_plan_id, source_group_key) WHERE (source_plan_id IS NOT NULL);
CREATE INDEX idx_strikes_issued_by ON public.strikes USING btree (issued_by);
CREATE INDEX idx_email_verifications_token ON public.email_verifications USING btree (token);
CREATE INDEX idx_response_log_user_id ON public.audit_logs USING btree (user_id);
CREATE INDEX idx_notifications_read ON public.notifications USING btree (is_read);
CREATE INDEX idx_dispatch_access_blocks_blocked_by ON public.dispatch_access_blocks USING btree (blocked_by);
CREATE INDEX idx_task_report_outcomes_task_id ON public.task_report_outcomes USING btree (task_id);
CREATE INDEX idx_reports_flagged_severe ON public.reports USING btree (flagged_severe);
CREATE INDEX idx_route_waypoints_cleanup_task_id ON public.route_waypoints USING btree (cleanup_task_id);
CREATE INDEX field_task_failure_events_task_time ON public.field_task_failure_events USING btree (task_id, observed_at DESC);
CREATE UNIQUE INDEX task_completion_operation ON public.cleanup_tasks USING btree (completion_operation_id) WHERE (completion_operation_id IS NOT NULL);
CREATE INDEX idx_task_report_outcomes_receipt_id ON public.task_report_outcomes USING btree (receipt_id);
CREATE INDEX idx_dispatch_plans_created_by ON public.dispatch_plans USING btree (created_by);
CREATE UNIQUE INDEX dispatch_unique_report ON public.dispatch_plan_items USING btree (dispatch_plan_id, report_id) WHERE (report_id IS NOT NULL);
CREATE INDEX idx_hotspot_predictions_region_id ON public.hotspot_predictions USING btree (region_id);
CREATE INDEX tasks_active_field_crew ON public.cleanup_tasks USING btree (assigned_field_crew_id) WHERE (status <> ALL (ARRAY['completed'::cleanup_task_status, 'cancelled'::cleanup_task_status]));
CREATE INDEX idx_fc_conflict_audit_operation ON public.fc_conflict_audit USING btree (operation_id);
CREATE INDEX idx_field_assignment_receipts_crew_id ON public.field_assignment_receipts USING btree (crew_id);
CREATE INDEX field_assignment_receipts_report ON public.field_assignment_receipts USING btree (report_id, issued_at DESC);
CREATE INDEX idx_audit_logs_action_type ON public.system_logs USING btree (action_type);
CREATE INDEX idx_sweeper_audit_event ON public.sweeper_audit_log USING btree (event_type);
CREATE INDEX reports_location_idx ON public.reports USING gist (location);
CREATE INDEX idx_report_resolution_events_task_id ON public.report_resolution_events USING btree (task_id);
CREATE UNIQUE INDEX hotspot_predictions_zone_horizon_date ON public.hotspot_predictions USING btree (zone_id, horizon_days, prediction_date);
CREATE INDEX idx_field_load_events_task_id ON public.field_load_events USING btree (task_id);
CREATE INDEX idx_crew_routes_crew ON public.crew_routes USING btree (crew_id, created_at DESC);
CREATE INDEX building_structures_geom_gist ON public.building_structures USING gist (boundary);
CREATE INDEX idx_hotspot_accuracy_date ON public.hotspot_accuracy USING btree (evaluation_date);
CREATE INDEX idx_strikes_user_id ON public.strikes USING btree (user_id);
CREATE INDEX idx_manual_review_queue_strike_id ON public.manual_review_queue USING btree (strike_id);
CREATE INDEX idx_field_crews_cert_reviewed_by ON public.field_crews USING btree (certification_reviewed_by);
CREATE INDEX idx_dispatch_plan_items_planned_crew_id ON public.dispatch_plan_items USING btree (planned_crew_id);
CREATE INDEX idx_dispatch_plan_items_committed_task_id ON public.dispatch_plan_items USING btree (committed_task_id);
CREATE INDEX idx_cleanup_tasks_assigned_by ON public.cleanup_tasks USING btree (assigned_by);
CREATE INDEX idx_audit_logs_report_created ON public.audit_logs USING btree (report_id, created_at DESC);
CREATE INDEX idx_sweeper_audit_entity ON public.sweeper_audit_log USING btree (entity_type, entity_id);
CREATE INDEX idx_notifications_user ON public.notifications USING btree (user_id);
CREATE INDEX idx_hotspot_predictions_composite ON public.hotspot_predictions USING btree (time_horizon, prediction_date);
CREATE INDEX building_structures_barangay_idx ON public.building_structures USING btree (barangay);
CREATE INDEX idx_sync_conflicts_user_id ON public.sync_conflicts USING btree (user_id);
CREATE INDEX reports_clustering_fresh_approved_idx ON public.reports USING btree (created_at, id) WHERE ((status = 'unresolved'::report_status) AND (validation_status = 'approved'::report_validation_status) AND (lifecycle_state = 'fresh'::text) AND (cluster_id IS NULL) AND (cleanup_task_id IS NULL));
CREATE INDEX idx_reports_fc_version ON public.reports USING btree (id, fc_version);
CREATE INDEX idx_reports_user_id ON public.reports USING btree (user_id);
CREATE INDEX idx_strikes_expires_at ON public.strikes USING btree (expires_at);
CREATE INDEX idx_optimization_runs_approved_by ON public.optimization_runs USING btree (approved_by);
CREATE INDEX task_unpublished_expiry ON public.cleanup_tasks USING btree (routing_deadline_at) WHERE (route_status = 'needs_replan'::text);
CREATE UNIQUE INDEX one_active_report_block ON public.dispatch_access_blocks USING btree (report_id) WHERE ((cleared_at IS NULL) AND (report_id IS NOT NULL));
CREATE INDEX idx_field_crews_team_lead ON public.field_crews USING btree (team_lead_profile_id);
CREATE INDEX reports_urgency_queue ON public.reports USING btree (urgency_status, created_at, id) WHERE (citizen_priority = 'urgent'::text);
CREATE INDEX idx_strikes_manual_review ON public.strikes USING btree (requires_manual_review, manual_review_status);
CREATE INDEX idx_notifications_report ON public.notifications USING btree (report_id);
CREATE INDEX idx_hotspot_predictions_risk_score ON public.hotspot_predictions USING btree (risk_score DESC);
CREATE INDEX idx_crew_routes_run ON public.crew_routes USING btree (optimization_run_id);
CREATE INDEX idx_cleanup_tasks_completed_by ON public.cleanup_tasks USING btree (completed_by);
CREATE INDEX idx_clusters_created_at ON public.clusters USING btree (created_at DESC);
CREATE INDEX idx_cleanup_tasks_created_by ON public.cleanup_tasks USING btree (created_by);
CREATE INDEX idx_cleanup_tasks_lgu_user_id ON public.cleanup_tasks USING btree (lgu_user_id);
CREATE INDEX idx_opt_templates_created_by ON public.optimization_templates USING btree (created_by);
CREATE UNIQUE INDEX idx_hotspot_predictions_unique ON public.hotspot_predictions USING btree (region_id, prediction_date, time_horizon);
CREATE INDEX idx_hotspot_predictions_time_horizon ON public.hotspot_predictions USING btree (time_horizon);
CREATE INDEX idx_clusters_center ON public.clusters USING gist (center);
CREATE INDEX idx_cleanup_tasks_cluster_id ON public.cleanup_tasks USING btree (cluster_id);
CREATE INDEX idx_cleanup_tasks_report_ids ON public.cleanup_tasks USING gin (report_ids);
CREATE INDEX building_structures_street_idx ON public.building_structures USING btree (street_name);
CREATE INDEX idx_notifications_unread_feed ON public.notifications USING btree (user_id, created_at DESC, id DESC) WHERE (is_read = false);
CREATE INDEX citizen_trust_decisions_report_latest ON public.citizen_trust_decisions USING btree (report_id, id DESC);
CREATE INDEX idx_dispatch_access_blocks_task_id ON public.dispatch_access_blocks USING btree (task_id);
CREATE INDEX idx_email_verifications_user_id ON public.email_verifications USING btree (user_id);
CREATE INDEX idx_manual_review_queue_report_id ON public.manual_review_queue USING btree (report_id);
CREATE UNIQUE INDEX email_verifications_token_digest_unique ON public.email_verifications USING btree (token_digest) WHERE (token_digest IS NOT NULL);
CREATE INDEX spatial_zones_boundary_gist ON public.spatial_zones USING gist (boundary);
CREATE INDEX idx_clusters_status ON public.clusters USING btree (status);
CREATE INDEX idx_dispatch_plans_status_created ON public.dispatch_plans USING btree (status, created_at DESC);
CREATE INDEX reports_active_cluster_membership ON public.reports USING btree (cluster_id) WHERE (cluster_id IS NOT NULL);
ALTER TABLE "public"."field_crews" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "operational_private"."crew_presence" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."dispatch_plans" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."manual_review_queue" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."audit_logs" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."system_logs" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."cleanup_tasks" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."dispatch_plan_items" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."building_structures" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."crew_urgency_observations" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."plan_generation_jobs" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."crew_urgency_reviews" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."reports" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."pasig_barangay_roster" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."fc_operation_log" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."fc_conflict_audit" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."hotspot_accuracy" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."dispatch_group_commits" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."system_settings" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."email_verifications" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."dispatch_access_blocks" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."pasig_barangay_boundary_source" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."field_assignment_receipts" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."report_resolution_events" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."notifications" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."optimization_templates" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."task_report_outcomes" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."optimization_settings" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."defense_seed_staging" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."support_tickets" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."route_waypoints" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."optimization_runs" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."crew_routes" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."field_load_events" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."field_task_failure_events" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."sync_conflicts" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."work_time_configuration" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."sweeper_configuration" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."sweeper_audit_log" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "workflow_private"."report_barangay_reconciliation_log" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "workflow_private"."unprocessed_escalation_baseline" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."clusters" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."strikes" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "privacy_private"."hidden_report_owners" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "privacy_private"."hidden_report_artifacts" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."cleanup_proof_publications" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."spatial_zones" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."hotspot_predictions" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."operational_events" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."citizen_trust" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."citizen_trust_decisions" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "workflow_private"."unprocessed_alert_deliveries" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "workflow_private"."lifecycle_deployment" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "workflow_private"."historical_sla_reset" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."report_urgency_decisions" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."report_urgency_alerts" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Clusters are viewable by everyone" ON "public"."clusters" AS PERMISSIVE FOR SELECT TO PUBLIC USING (true);
CREATE POLICY "public_read 1oj01fe_0" ON "storage"."objects" AS PERMISSIVE FOR SELECT TO PUBLIC USING ((bucket_id = 'avatars'::text));
CREATE POLICY "Public can view avatars" ON "storage"."objects" AS PERMISSIVE FOR SELECT TO PUBLIC USING ((bucket_id = 'avatars'::text));
CREATE POLICY "Users can upload their own avatars" ON "storage"."objects" AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (((bucket_id = 'avatars'::text) AND ((auth.uid())::text = (storage.foldername(name))[1])));
CREATE POLICY "Officers and Admins can create cleanup tasks" ON "public"."cleanup_tasks" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK ((get_auth_user_role() = ANY (ARRAY['officer'::role, 'admin'::role])));
CREATE POLICY "Officers and Admins can delete manual review queue" ON "public"."manual_review_queue" AS PERMISSIVE FOR DELETE TO "authenticated" USING ((get_auth_user_role() = ANY (ARRAY['officer'::role, 'admin'::role])));
CREATE POLICY "Only service role can delete clusters" ON "public"."clusters" AS PERMISSIVE FOR DELETE TO "service_role" USING (true);
CREATE POLICY "Only service role can insert clusters" ON "public"."clusters" AS PERMISSIVE FOR INSERT TO "service_role" WITH CHECK (true);
CREATE POLICY "Users can update their own avatars" ON "storage"."objects" AS PERMISSIVE FOR UPDATE TO PUBLIC USING (((bucket_id = 'avatars'::text) AND ((auth.uid())::text = (storage.foldername(name))[1])));
CREATE POLICY "Users can delete their own avatars" ON "storage"."objects" AS PERMISSIVE FOR DELETE TO PUBLIC USING (((bucket_id = 'avatars'::text) AND ((auth.uid())::text = (storage.foldername(name))[1])));
CREATE POLICY "Officers and Admins can update reports" ON "public"."reports" AS PERMISSIVE FOR UPDATE TO "authenticated" USING ((get_auth_user_role() = ANY (ARRAY['officer'::role, 'admin'::role]))) WITH CHECK ((get_auth_user_role() = ANY (ARRAY['officer'::role, 'admin'::role])));
CREATE POLICY "Allow users to view own strikes" ON "public"."strikes" AS PERMISSIVE FOR SELECT TO "service_role" USING (true);
CREATE POLICY "Allow authenticated to read settings" ON "public"."system_settings" AS PERMISSIVE FOR SELECT TO "authenticated" USING (true);
CREATE POLICY "Allow service role to insert audit logs" ON "public"."system_logs" AS PERMISSIVE FOR INSERT TO "service_role" WITH CHECK (true);
CREATE POLICY "Allow admins to update settings" ON "public"."system_settings" AS PERMISSIVE FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM profiles
  WHERE ((profiles.id = ( SELECT auth.uid() AS uid)) AND (profiles.role = 'admin'::role)))));
CREATE POLICY "Allow admins to insert settings" ON "public"."system_settings" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM profiles
  WHERE ((profiles.id = ( SELECT auth.uid() AS uid)) AND (profiles.role = 'admin'::role)))));
CREATE POLICY "Service role can insert notifications" ON "public"."notifications" AS PERMISSIVE FOR INSERT TO "service_role" WITH CHECK (true);
CREATE POLICY "Users can view their notifications" ON "public"."notifications" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((user_id = ( SELECT auth.uid() AS uid)));
CREATE POLICY "Users can update their notifications" ON "public"."notifications" AS PERMISSIVE FOR UPDATE TO "authenticated" USING ((user_id = ( SELECT auth.uid() AS uid))) WITH CHECK ((user_id = ( SELECT auth.uid() AS uid)));
CREATE POLICY "Public profiles are viewable by authenticated users" ON "public"."profiles" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((id = ( SELECT auth.uid() AS uid)) OR ((( SELECT get_auth_user_role() AS get_auth_user_role))::text = ANY (ARRAY['officer'::text, 'admin'::text])) OR (EXISTS ( SELECT 1
   FROM field_crews c
  WHERE (((c.team_lead_profile_id = ( SELECT auth.uid() AS uid)) OR (( SELECT auth.uid() AS uid) = ANY (COALESCE(c.member_profile_ids, '{}'::uuid[])))) AND ((c.team_lead_profile_id = profiles.id) OR (profiles.id = ANY (COALESCE(c.member_profile_ids, '{}'::uuid[])))))))));
CREATE POLICY "Reports are viewable by authenticated users" ON "public"."reports" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((((( SELECT get_auth_user_role() AS get_auth_user_role))::text = ANY (ARRAY['officer'::text, 'admin'::text])) OR (user_id = ( SELECT auth.uid() AS uid)) OR (((( SELECT get_auth_user_role() AS get_auth_user_role))::text = 'field_crew'::text) AND (EXISTS ( SELECT 1
   FROM cleanup_tasks ct
  WHERE ((ct.id = reports.cleanup_task_id) AND (ct.route_status = 'ready'::text) AND ((ct.status)::text = ANY (ARRAY['created'::text, 'pending'::text, 'in_progress'::text, 'partially_completed'::text])) AND (( SELECT auth.uid() AS uid) = ANY (COALESCE(ct.assigned_crew_ids, '{}'::uuid[])))))))));
CREATE POLICY "Field Crew, Officers, and Admins can update cleanup tasks" ON "public"."cleanup_tasks" AS PERMISSIVE FOR UPDATE TO "authenticated" USING ((get_auth_user_role() = ANY (ARRAY['field_crew'::role, 'officer'::role, 'admin'::role]))) WITH CHECK ((get_auth_user_role() = ANY (ARRAY['field_crew'::role, 'officer'::role, 'admin'::role])));
CREATE POLICY "Officers and Admins can insert strikes" ON "public"."strikes" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK ((get_auth_user_role() = ANY (ARRAY['officer'::role, 'admin'::role])));
CREATE POLICY "Officers and Admins can update strikes" ON "public"."strikes" AS PERMISSIVE FOR UPDATE TO "authenticated" USING ((get_auth_user_role() = ANY (ARRAY['officer'::role, 'admin'::role])));
CREATE POLICY "Officers and Admins can delete strikes" ON "public"."strikes" AS PERMISSIVE FOR DELETE TO "authenticated" USING ((get_auth_user_role() = ANY (ARRAY['officer'::role, 'admin'::role])));
CREATE POLICY "Officers and Admins can view manual review queue" ON "public"."manual_review_queue" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((get_auth_user_role() = ANY (ARRAY['officer'::role, 'admin'::role])));
CREATE POLICY "Officers and Admins can insert manual review queue" ON "public"."manual_review_queue" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK ((get_auth_user_role() = ANY (ARRAY['officer'::role, 'admin'::role])));
CREATE POLICY "Officers and Admins can update manual review queue" ON "public"."manual_review_queue" AS PERMISSIVE FOR UPDATE TO "authenticated" USING ((get_auth_user_role() = ANY (ARRAY['officer'::role, 'admin'::role])));
CREATE POLICY "Field Crew, Officers, and Admins can view response log" ON "public"."audit_logs" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((get_auth_user_role() = ANY (ARRAY['field_crew'::role, 'officer'::role, 'admin'::role])));
CREATE POLICY "Field Crew, Officers, and Admins can insert response log" ON "public"."audit_logs" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK ((get_auth_user_role() = ANY (ARRAY['field_crew'::role, 'officer'::role, 'admin'::role])));
CREATE POLICY "workflow_desk_read" ON "public"."dispatch_plans" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((get_auth_user_role())::text = ANY (ARRAY['admin'::text, 'officer'::text])));
CREATE POLICY "workflow_desk_read" ON "public"."dispatch_plan_items" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((get_auth_user_role())::text = ANY (ARRAY['admin'::text, 'officer'::text])));
CREATE POLICY "workflow_desk_read" ON "public"."optimization_runs" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((get_auth_user_role())::text = ANY (ARRAY['admin'::text, 'officer'::text])));
CREATE POLICY "workflow_desk_read" ON "public"."optimization_settings" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((get_auth_user_role())::text = ANY (ARRAY['admin'::text, 'officer'::text])));
CREATE POLICY "workflow_desk_read" ON "public"."optimization_templates" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((get_auth_user_role())::text = ANY (ARRAY['admin'::text, 'officer'::text])));
CREATE POLICY "workflow_desk_read" ON "public"."work_time_configuration" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((get_auth_user_role())::text = ANY (ARRAY['admin'::text, 'officer'::text])));
CREATE POLICY "workflow_desk_read" ON "public"."sweeper_configuration" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((get_auth_user_role())::text = ANY (ARRAY['admin'::text, 'officer'::text])));
CREATE POLICY "workflow_desk_read" ON "public"."sweeper_audit_log" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((get_auth_user_role())::text = ANY (ARRAY['admin'::text, 'officer'::text])));
CREATE POLICY "workflow_desk_read" ON "public"."fc_operation_log" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((get_auth_user_role())::text = ANY (ARRAY['admin'::text, 'officer'::text])));
CREATE POLICY "workflow_desk_read" ON "public"."fc_conflict_audit" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((get_auth_user_role())::text = ANY (ARRAY['admin'::text, 'officer'::text])));
CREATE POLICY "workflow_route_read" ON "public"."crew_routes" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((((( SELECT get_auth_user_role() AS get_auth_user_role))::text = ANY (ARRAY['admin'::text, 'officer'::text])) OR (EXISTS ( SELECT 1
   FROM field_crews c
  WHERE ((c.id = crew_routes.crew_id) AND ((( SELECT auth.uid() AS uid) = c.team_lead_profile_id) OR (( SELECT auth.uid() AS uid) = ANY (COALESCE(c.member_profile_ids, '{}'::uuid[])))))))));
CREATE POLICY "workflow_waypoint_read" ON "public"."route_waypoints" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM crew_routes r
  WHERE (r.id = route_waypoints.crew_route_id))));
CREATE POLICY "email_verifications_service_role" ON "public"."email_verifications" AS PERMISSIVE FOR ALL TO "service_role" USING (true) WITH CHECK (true);
CREATE POLICY "hotspot_predictions_public_read" ON "public"."hotspot_predictions" AS PERMISSIVE FOR SELECT TO PUBLIC USING (true);
CREATE POLICY "hotspot_predictions_service_write" ON "public"."hotspot_predictions" AS PERMISSIVE FOR ALL TO "service_role" USING (true) WITH CHECK (true);
CREATE POLICY "hotspot_accuracy_auth_read" ON "public"."hotspot_accuracy" AS PERMISSIVE FOR SELECT TO "authenticated" USING (true);
CREATE POLICY "hotspot_accuracy_service_write" ON "public"."hotspot_accuracy" AS PERMISSIVE FOR ALL TO "service_role" USING (true) WITH CHECK (true);
CREATE POLICY "Public can view Cleanup Task Photos" ON "storage"."objects" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((bucket_id = 'Cleanup Task Photos'::text));
CREATE POLICY "Public can view Report Evidence" ON "storage"."objects" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((bucket_id = 'Report Evidence'::text));
CREATE POLICY "Public can view Report Cleanup" ON "storage"."objects" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((bucket_id = 'Report Cleanup'::text));
CREATE POLICY "Officers and Admins can view all strikes" ON "public"."strikes" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((user_id = ( SELECT auth.uid() AS uid)) OR (( SELECT get_auth_user_role() AS get_auth_user_role) = ANY (ARRAY['officer'::role, 'admin'::role]))));
CREATE POLICY "Only service role can update clusters" ON "public"."clusters" AS PERMISSIVE FOR UPDATE TO "service_role" USING (true) WITH CHECK (true);
CREATE POLICY "Allow admins to read audit logs" ON "public"."system_logs" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM profiles
  WHERE ((profiles.id = ( SELECT auth.uid() AS uid)) AND (profiles.role = 'admin'::role)))));
CREATE POLICY "Users can delete their notifications" ON "public"."notifications" AS PERMISSIVE FOR DELETE TO "authenticated" USING ((user_id = ( SELECT auth.uid() AS uid)));
CREATE POLICY "Users can update their own profile" ON "public"."profiles" AS PERMISSIVE FOR UPDATE TO "authenticated" USING ((id = ( SELECT auth.uid() AS uid))) WITH CHECK ((id = ( SELECT auth.uid() AS uid)));
CREATE POLICY "hidden_report_related_read" ON "public"."manual_review_queue" AS RESTRICTIVE FOR SELECT TO "anon","authenticated" USING ((((report_id IS NULL) OR privacy_private.identity_readable(report_id)) AND privacy_private.identity_readable(id)));
CREATE POLICY "Citizens can insert their own reports" ON "public"."reports" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK ((user_id = ( SELECT auth.uid() AS uid)));
CREATE POLICY "workflow_crew_read" ON "public"."field_crews" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((((( SELECT get_auth_user_role() AS get_auth_user_role))::text = ANY (ARRAY['admin'::text, 'officer'::text])) OR (( SELECT auth.uid() AS uid) = team_lead_profile_id) OR (( SELECT auth.uid() AS uid) = ANY (COALESCE(member_profile_ids, '{}'::uuid[])))));
CREATE POLICY "service_role_all" ON "public"."dispatch_access_blocks" AS PERMISSIVE FOR ALL TO "service_role" USING (true) WITH CHECK (true);
CREATE POLICY "workflow_desk_read" ON "public"."dispatch_access_blocks" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((( SELECT get_auth_user_role() AS get_auth_user_role))::text = ANY (ARRAY['admin'::text, 'officer'::text])));
CREATE POLICY "service_role_all" ON "public"."dispatch_group_commits" AS PERMISSIVE FOR ALL TO "service_role" USING (true) WITH CHECK (true);
CREATE POLICY "workflow_desk_read" ON "public"."dispatch_group_commits" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((( SELECT get_auth_user_role() AS get_auth_user_role))::text = ANY (ARRAY['admin'::text, 'officer'::text])));
CREATE POLICY "service_role_all" ON "public"."field_assignment_receipts" AS PERMISSIVE FOR ALL TO "service_role" USING (true) WITH CHECK (true);
CREATE POLICY "workflow_desk_read" ON "public"."field_assignment_receipts" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((( SELECT get_auth_user_role() AS get_auth_user_role))::text = ANY (ARRAY['admin'::text, 'officer'::text])));
CREATE POLICY "service_role_all" ON "public"."field_load_events" AS PERMISSIVE FOR ALL TO "service_role" USING (true) WITH CHECK (true);
CREATE POLICY "workflow_desk_read" ON "public"."field_load_events" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((( SELECT get_auth_user_role() AS get_auth_user_role))::text = ANY (ARRAY['admin'::text, 'officer'::text])));
CREATE POLICY "service_role_all" ON "public"."field_task_failure_events" AS PERMISSIVE FOR ALL TO "service_role" USING (true) WITH CHECK (true);
CREATE POLICY "hidden_report_related_read" ON "public"."notifications" AS RESTRICTIVE FOR SELECT TO "anon","authenticated" USING ((((report_id IS NULL) OR privacy_private.identity_readable(report_id)) AND privacy_private.identity_readable(id)));
CREATE POLICY "workflow_desk_read" ON "public"."field_task_failure_events" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((( SELECT get_auth_user_role() AS get_auth_user_role))::text = ANY (ARRAY['admin'::text, 'officer'::text])));
CREATE POLICY "service_role_all" ON "public"."plan_generation_jobs" AS PERMISSIVE FOR ALL TO "service_role" USING (true) WITH CHECK (true);
CREATE POLICY "workflow_desk_read" ON "public"."plan_generation_jobs" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((( SELECT get_auth_user_role() AS get_auth_user_role))::text = ANY (ARRAY['admin'::text, 'officer'::text])));
CREATE POLICY "service_role_all" ON "public"."report_resolution_events" AS PERMISSIVE FOR ALL TO "service_role" USING (true) WITH CHECK (true);
CREATE POLICY "workflow_desk_read" ON "public"."report_resolution_events" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((( SELECT get_auth_user_role() AS get_auth_user_role))::text = ANY (ARRAY['admin'::text, 'officer'::text])));
CREATE POLICY "service_role_all" ON "public"."task_report_outcomes" AS PERMISSIVE FOR ALL TO "service_role" USING (true) WITH CHECK (true);
CREATE POLICY "hidden_unstructured_read" ON "public"."strikes" AS RESTRICTIVE FOR SELECT TO "anon","authenticated" USING (false);
CREATE POLICY "hidden_unstructured_read" ON "public"."sweeper_audit_log" AS RESTRICTIVE FOR SELECT TO "anon","authenticated" USING (false);
CREATE POLICY "workflow_desk_read" ON "public"."task_report_outcomes" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((( SELECT get_auth_user_role() AS get_auth_user_role))::text = ANY (ARRAY['admin'::text, 'officer'::text])));
CREATE POLICY "service_role_all" ON "workflow_private"."historical_sla_reset" AS PERMISSIVE FOR ALL TO "service_role" USING (true) WITH CHECK (true);
CREATE POLICY "service_role_all" ON "workflow_private"."lifecycle_deployment" AS PERMISSIVE FOR ALL TO "service_role" USING (true) WITH CHECK (true);
CREATE POLICY "Authenticated users can upload Report Evidence" ON "storage"."objects" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK (((bucket_id = 'Report Evidence'::text) AND (((storage.foldername(name))[1] = (( SELECT auth.uid() AS uid))::text) OR ((( SELECT get_auth_user_role() AS get_auth_user_role))::text = ANY (ARRAY['officer'::text, 'admin'::text])))));
CREATE POLICY "sync_conflicts_service_role_all" ON "public"."sync_conflicts" AS PERMISSIVE FOR ALL TO "service_role" USING (true) WITH CHECK (true);
CREATE POLICY "public_map_reader_approved_consent" ON "public"."reports" AS PERMISSIVE FOR SELECT TO "ecopin_public_map_reader" USING (((validation_status = 'approved'::report_validation_status) AND (status <> 'rejected'::report_status) AND ((on_private_property IS FALSE) OR ((on_private_property IS TRUE) AND (property_owner_consent_status = 'obtained'::consent_status)))));
CREATE POLICY "Authenticated users can upload Cleanup Task Photos" ON "storage"."objects" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK (((bucket_id = 'Cleanup Task Photos'::text) AND storage_authority.can_upload_cleanup_object(bucket_id, name)));
CREATE POLICY "Authenticated users can upload Report Cleanup" ON "storage"."objects" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK (((bucket_id = 'Report Cleanup'::text) AND storage_authority.can_upload_cleanup_object(bucket_id, name)));
CREATE POLICY "workflow_task_read" ON "public"."cleanup_tasks" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((((( SELECT get_auth_user_role() AS get_auth_user_role))::text = ANY (ARRAY['admin'::text, 'officer'::text])) OR (((( SELECT get_auth_user_role() AS get_auth_user_role))::text = 'field_crew'::text) AND (( SELECT auth.uid() AS uid) = ANY (COALESCE(assigned_crew_ids, '{}'::uuid[]))))));
CREATE POLICY "hidden_report_raw_read" ON "public"."reports" AS RESTRICTIVE FOR SELECT TO "anon","authenticated" USING (privacy_private.identity_readable(id));
CREATE POLICY "operational_view_rows" ON "public"."reports" AS PERMISSIVE FOR SELECT TO "ecopin_operational_reader" USING (privacy_private.operational_readable(id));
CREATE POLICY "hidden_report_related_read" ON "public"."audit_logs" AS RESTRICTIVE FOR SELECT TO "anon","authenticated" USING ((((report_id IS NULL) OR privacy_private.identity_readable(report_id)) AND privacy_private.identity_readable(id)));
CREATE POLICY "hidden_unstructured_read" ON "public"."fc_conflict_audit" AS RESTRICTIVE FOR SELECT TO "anon","authenticated" USING (false);
CREATE POLICY "hidden_unstructured_read" ON "public"."fc_operation_log" AS RESTRICTIVE FOR SELECT TO "anon","authenticated" USING (false);
CREATE POLICY "operational_activity_rows" ON "public"."audit_logs" AS PERMISSIVE FOR SELECT TO "ecopin_operational_reader" USING (((( SELECT auth.role() AS role) = 'service_role'::text) OR ((report_id IS NOT NULL) AND privacy_private.operational_readable(report_id)) OR ((report_id IS NULL) AND ((( SELECT get_auth_user_role() AS get_auth_user_role))::text = ANY (ARRAY['officer'::text, 'admin'::text])))));
CREATE POLICY "internal_privacy_artifact_read" ON "privacy_private"."hidden_report_artifacts" AS PERMISSIVE FOR SELECT TO "ecopin_operational_reader" USING (true);
CREATE POLICY "internal_privacy_view_read" ON "privacy_private"."hidden_report_owners" AS PERMISSIVE FOR SELECT TO "ecopin_operational_reader" USING (true);
CREATE TRIGGER on_report_status_change AFTER UPDATE ON reports FOR EACH ROW EXECUTE FUNCTION handle_report_status_change();
ALTER TABLE "public"."reports" ENABLE TRIGGER "on_report_status_change";
CREATE TRIGGER update_clusters_updated_at BEFORE UPDATE ON clusters FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
ALTER TABLE "public"."clusters" ENABLE TRIGGER "update_clusters_updated_at";
CREATE TRIGGER update_system_settings_updated_at BEFORE UPDATE ON system_settings FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
ALTER TABLE "public"."system_settings" ENABLE TRIGGER "update_system_settings_updated_at";
CREATE TRIGGER update_manual_review_queue_updated_at BEFORE UPDATE ON manual_review_queue FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
ALTER TABLE "public"."manual_review_queue" ENABLE TRIGGER "update_manual_review_queue_updated_at";
CREATE TRIGGER zz_audit_report_lifecycle AFTER UPDATE ON reports FOR EACH ROW EXECUTE FUNCTION workflow_private.audit_report_lifecycle();
ALTER TABLE "public"."reports" ENABLE TRIGGER "zz_audit_report_lifecycle";
CREATE TRIGGER zz_validate_lifecycle_config AFTER INSERT OR DELETE OR UPDATE ON sweeper_configuration FOR EACH STATEMENT EXECUTE FUNCTION workflow_private.validate_lifecycle_config();
ALTER TABLE "public"."sweeper_configuration" ENABLE TRIGGER "zz_validate_lifecycle_config";
CREATE TRIGGER workflow_report_claim_guard BEFORE INSERT OR UPDATE ON reports FOR EACH ROW EXECUTE FUNCTION workflow_private.guard_report_claim();
ALTER TABLE "public"."reports" ENABLE TRIGGER "workflow_report_claim_guard";
CREATE TRIGGER workflow_cluster_block_guard BEFORE UPDATE OF status ON clusters FOR EACH ROW EXECUTE FUNCTION workflow_private.guard_cluster_block();
ALTER TABLE "public"."clusters" ENABLE TRIGGER "workflow_cluster_block_guard";
CREATE TRIGGER workflow_task_release AFTER UPDATE OF status ON cleanup_tasks FOR EACH ROW EXECUTE FUNCTION workflow_private.release_finished_task();
ALTER TABLE "public"."cleanup_tasks" ENABLE TRIGGER "workflow_task_release";
CREATE TRIGGER zy_workflow_report_version BEFORE UPDATE ON reports FOR EACH ROW EXECUTE FUNCTION workflow_private.bump_report_version();
ALTER TABLE "public"."reports" ENABLE TRIGGER "zy_workflow_report_version";
CREATE TRIGGER zy_workflow_task_version BEFORE UPDATE ON cleanup_tasks FOR EACH ROW EXECUTE FUNCTION workflow_private.bump_report_version();
ALTER TABLE "public"."cleanup_tasks" ENABLE TRIGGER "zy_workflow_task_version";
CREATE TRIGGER require_completed_plan_job BEFORE INSERT ON cleanup_tasks FOR EACH ROW EXECUTE FUNCTION workflow_private.require_completed_plan_job();
ALTER TABLE "public"."cleanup_tasks" ENABLE TRIGGER "require_completed_plan_job";
CREATE TRIGGER zx_workflow_report_claim_generation BEFORE INSERT OR UPDATE ON reports FOR EACH ROW EXECUTE FUNCTION workflow_private.bump_report_claim_generation();
ALTER TABLE "public"."reports" ENABLE TRIGGER "zx_workflow_report_claim_generation";
CREATE TRIGGER zx_workflow_task_assignment_generation BEFORE INSERT OR UPDATE ON cleanup_tasks FOR EACH ROW EXECUTE FUNCTION workflow_private.bump_task_assignment_generation();
ALTER TABLE "public"."cleanup_tasks" ENABLE TRIGGER "zx_workflow_task_assignment_generation";
CREATE TRIGGER workflow_issue_task_report_receipts AFTER INSERT OR UPDATE ON cleanup_tasks FOR EACH ROW EXECUTE FUNCTION workflow_private.issue_task_report_receipts();
ALTER TABLE "public"."cleanup_tasks" ENABLE TRIGGER "workflow_issue_task_report_receipts";
CREATE TRIGGER workflow_issue_report_claim_receipts AFTER INSERT OR UPDATE ON reports FOR EACH ROW EXECUTE FUNCTION workflow_private.issue_report_claim_receipts();
ALTER TABLE "public"."reports" ENABLE TRIGGER "workflow_issue_report_claim_receipts";
CREATE TRIGGER trg_audit_logs_immutable BEFORE DELETE OR UPDATE ON audit_logs FOR EACH ROW EXECUTE FUNCTION prevent_audit_modification();
ALTER TABLE "public"."audit_logs" ENABLE TRIGGER "trg_audit_logs_immutable";
CREATE TRIGGER zz_apply_report_lifecycle BEFORE INSERT OR UPDATE ON reports FOR EACH ROW EXECUTE FUNCTION workflow_private.apply_report_lifecycle();
ALTER TABLE "public"."reports" ENABLE TRIGGER "zz_apply_report_lifecycle";
CREATE TRIGGER protect_report_identity BEFORE INSERT OR UPDATE ON reports FOR EACH ROW EXECUTE FUNCTION privacy_private.protect_report_identity();
ALTER TABLE "public"."reports" ENABLE TRIGGER "protect_report_identity";
CREATE TRIGGER capture_hidden_report_references BEFORE DELETE ON reports FOR EACH ROW EXECUTE FUNCTION privacy_private.capture_hidden_report_references();
ALTER TABLE "public"."reports" ENABLE TRIGGER "capture_hidden_report_references";
CREATE TRIGGER capture_hidden_queue_insert AFTER INSERT ON manual_review_queue FOR EACH ROW EXECUTE FUNCTION privacy_private.capture_hidden_queue_reference();
ALTER TABLE "public"."manual_review_queue" ENABLE TRIGGER "capture_hidden_queue_insert";
CREATE TRIGGER capture_hidden_queue_change BEFORE DELETE OR UPDATE ON manual_review_queue FOR EACH ROW EXECUTE FUNCTION privacy_private.capture_hidden_queue_reference();
ALTER TABLE "public"."manual_review_queue" ENABLE TRIGGER "capture_hidden_queue_change";
CREATE TRIGGER immutable_group_result BEFORE DELETE OR UPDATE ON dispatch_group_commits FOR EACH ROW EXECUTE FUNCTION workflow_private.immutable_group_result();
ALTER TABLE "public"."dispatch_group_commits" ENABLE TRIGGER "immutable_group_result";
CREATE TRIGGER trg_sweeper_audit_log_immutable BEFORE DELETE OR UPDATE ON sweeper_audit_log FOR EACH ROW EXECUTE FUNCTION prevent_audit_modification();
ALTER TABLE "public"."sweeper_audit_log" ENABLE TRIGGER "trg_sweeper_audit_log_immutable";
CREATE TRIGGER trg_system_logs_immutable BEFORE DELETE OR UPDATE ON system_logs FOR EACH ROW EXECUTE FUNCTION prevent_audit_modification();
ALTER TABLE "public"."system_logs" ENABLE TRIGGER "trg_system_logs_immutable";
CREATE TRIGGER set_report_deadline BEFORE INSERT OR UPDATE OF severity_score ON reports FOR EACH ROW EXECUTE FUNCTION calculate_report_deadline();
ALTER TABLE "public"."reports" ENABLE TRIGGER "set_report_deadline";
CREATE TRIGGER citizen_urgent_gate BEFORE INSERT OR UPDATE ON reports FOR EACH ROW EXECUTE FUNCTION gate_citizen_urgent_report();
ALTER TABLE "public"."reports" ENABLE TRIGGER "citizen_urgent_gate";
CREATE TRIGGER a_guard_report_urgency BEFORE INSERT OR UPDATE ON reports FOR EACH ROW EXECUTE FUNCTION workflow_private.guard_report_urgency();
ALTER TABLE "public"."reports" ENABLE TRIGGER "a_guard_report_urgency";
CREATE TRIGGER urgent_report_notification AFTER INSERT OR UPDATE OF urgency_status ON reports FOR EACH ROW EXECUTE FUNCTION workflow_private.notify_urgent_report();
ALTER TABLE "public"."reports" ENABLE TRIGGER "urgent_report_notification";
CREATE TRIGGER b_resolve_report_barangay BEFORE INSERT OR UPDATE OF location, barangay, barangay_resolution_status, barangay_candidates, barangay_resolution_checked_at ON reports FOR EACH ROW EXECUTE FUNCTION workflow_private.resolve_report_barangay_fields();
ALTER TABLE "public"."reports" ENABLE TRIGGER "b_resolve_report_barangay";
CREATE TRIGGER require_cleanup_resolution_proof BEFORE UPDATE OF status, lgu_resolved_at, cleanup_action_notes, before_photo_url, after_photo_url, before_photo_hash, after_photo_hash, before_photos, after_photos ON reports FOR EACH ROW EXECUTE FUNCTION workflow_private.guard_cleanup_resolution();
ALTER TABLE "public"."reports" ENABLE TRIGGER "require_cleanup_resolution_proof";
CREATE TRIGGER require_cleanup_receipt_proof BEFORE INSERT ON task_report_outcomes FOR EACH ROW EXECUTE FUNCTION workflow_private.guard_cleanup_receipt();
ALTER TABLE "public"."task_report_outcomes" ENABLE TRIGGER "require_cleanup_receipt_proof";
CREATE TRIGGER require_cleanup_task_proof BEFORE UPDATE OF status ON cleanup_tasks FOR EACH ROW EXECUTE FUNCTION workflow_private.guard_cleanup_task_completion();
ALTER TABLE "public"."cleanup_tasks" ENABLE TRIGGER "require_cleanup_task_proof";
CREATE TRIGGER immutable_operational_event BEFORE DELETE OR UPDATE OR TRUNCATE ON operational_events FOR EACH STATEMENT EXECUTE FUNCTION operational_private.immutable_event();
ALTER TABLE "public"."operational_events" ENABLE TRIGGER "immutable_operational_event";
CREATE TRIGGER operational_actor_context BEFORE INSERT OR UPDATE ON reports FOR EACH ROW EXECUTE FUNCTION operational_private.row_context();
ALTER TABLE "public"."reports" ENABLE TRIGGER "operational_actor_context";
CREATE TRIGGER operational_actor_context BEFORE INSERT OR UPDATE ON cleanup_tasks FOR EACH ROW EXECUTE FUNCTION operational_private.row_context();
ALTER TABLE "public"."cleanup_tasks" ENABLE TRIGGER "operational_actor_context";
CREATE TRIGGER operational_task_events AFTER INSERT OR UPDATE ON cleanup_tasks FOR EACH ROW EXECUTE FUNCTION operational_private.capture_row();
ALTER TABLE "public"."cleanup_tasks" ENABLE TRIGGER "operational_task_events";
CREATE TRIGGER operational_report_events AFTER INSERT OR UPDATE ON reports FOR EACH ROW EXECUTE FUNCTION operational_private.capture_row();
ALTER TABLE "public"."reports" ENABLE TRIGGER "operational_report_events";
CREATE TRIGGER operational_receipt_arrival AFTER INSERT ON task_report_outcomes FOR EACH ROW EXECUTE FUNCTION operational_private.capture_receipt();
ALTER TABLE "public"."task_report_outcomes" ENABLE TRIGGER "operational_receipt_arrival";
CREATE TRIGGER operational_verification AFTER INSERT OR UPDATE ON cleanup_proof_publications FOR EACH ROW EXECUTE FUNCTION operational_private.capture_verification();
ALTER TABLE "public"."cleanup_proof_publications" ENABLE TRIGGER "operational_verification";
CREATE TRIGGER operational_task_transition AFTER INSERT OR UPDATE OF status ON cleanup_tasks FOR EACH ROW EXECUTE FUNCTION operational_private.capture_task_transition();
ALTER TABLE "public"."cleanup_tasks" ENABLE TRIGGER "operational_task_transition";
REVOKE ALL ON ALL TABLES IN SCHEMA "workflow_private" FROM PUBLIC,"anon","authenticated","ecopin_operational_reader","ecopin_public_map_reader","pg_database_owner","postgres","service_role";
REVOKE ALL ON ALL SEQUENCES IN SCHEMA "workflow_private" FROM PUBLIC,"anon","authenticated","ecopin_operational_reader","ecopin_public_map_reader","pg_database_owner","postgres","service_role";
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA "workflow_private" FROM PUBLIC,"anon","authenticated","ecopin_operational_reader","ecopin_public_map_reader","pg_database_owner","postgres","service_role";
REVOKE ALL ON SCHEMA "workflow_private" FROM PUBLIC,"anon","authenticated","ecopin_operational_reader","ecopin_public_map_reader","pg_database_owner","postgres","service_role";
REVOKE ALL ON ALL TABLES IN SCHEMA "storage_authority" FROM PUBLIC,"anon","authenticated","ecopin_operational_reader","ecopin_public_map_reader","pg_database_owner","postgres","service_role";
REVOKE ALL ON ALL SEQUENCES IN SCHEMA "storage_authority" FROM PUBLIC,"anon","authenticated","ecopin_operational_reader","ecopin_public_map_reader","pg_database_owner","postgres","service_role";
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA "storage_authority" FROM PUBLIC,"anon","authenticated","ecopin_operational_reader","ecopin_public_map_reader","pg_database_owner","postgres","service_role";
REVOKE ALL ON SCHEMA "storage_authority" FROM PUBLIC,"anon","authenticated","ecopin_operational_reader","ecopin_public_map_reader","pg_database_owner","postgres","service_role";
REVOKE ALL ON ALL TABLES IN SCHEMA "verification_private" FROM PUBLIC,"anon","authenticated","ecopin_operational_reader","ecopin_public_map_reader","pg_database_owner","postgres","service_role";
REVOKE ALL ON ALL SEQUENCES IN SCHEMA "verification_private" FROM PUBLIC,"anon","authenticated","ecopin_operational_reader","ecopin_public_map_reader","pg_database_owner","postgres","service_role";
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA "verification_private" FROM PUBLIC,"anon","authenticated","ecopin_operational_reader","ecopin_public_map_reader","pg_database_owner","postgres","service_role";
REVOKE ALL ON SCHEMA "verification_private" FROM PUBLIC,"anon","authenticated","ecopin_operational_reader","ecopin_public_map_reader","pg_database_owner","postgres","service_role";
REVOKE ALL ON ALL TABLES IN SCHEMA "public" FROM PUBLIC,"anon","authenticated","ecopin_operational_reader","ecopin_public_map_reader","pg_database_owner","postgres","service_role";
REVOKE ALL ON ALL SEQUENCES IN SCHEMA "public" FROM PUBLIC,"anon","authenticated","ecopin_operational_reader","ecopin_public_map_reader","pg_database_owner","postgres","service_role";
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA "public" FROM PUBLIC,"anon","authenticated","ecopin_operational_reader","ecopin_public_map_reader","pg_database_owner","postgres","service_role";
REVOKE ALL ON SCHEMA "public" FROM PUBLIC,"anon","authenticated","ecopin_operational_reader","ecopin_public_map_reader","pg_database_owner","postgres","service_role";
REVOKE ALL ON ALL TABLES IN SCHEMA "privacy_private" FROM PUBLIC,"anon","authenticated","ecopin_operational_reader","ecopin_public_map_reader","pg_database_owner","postgres","service_role";
REVOKE ALL ON ALL SEQUENCES IN SCHEMA "privacy_private" FROM PUBLIC,"anon","authenticated","ecopin_operational_reader","ecopin_public_map_reader","pg_database_owner","postgres","service_role";
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA "privacy_private" FROM PUBLIC,"anon","authenticated","ecopin_operational_reader","ecopin_public_map_reader","pg_database_owner","postgres","service_role";
REVOKE ALL ON SCHEMA "privacy_private" FROM PUBLIC,"anon","authenticated","ecopin_operational_reader","ecopin_public_map_reader","pg_database_owner","postgres","service_role";
REVOKE ALL ON ALL TABLES IN SCHEMA "operational_private" FROM PUBLIC,"anon","authenticated","ecopin_operational_reader","ecopin_public_map_reader","pg_database_owner","postgres","service_role";
REVOKE ALL ON ALL SEQUENCES IN SCHEMA "operational_private" FROM PUBLIC,"anon","authenticated","ecopin_operational_reader","ecopin_public_map_reader","pg_database_owner","postgres","service_role";
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA "operational_private" FROM PUBLIC,"anon","authenticated","ecopin_operational_reader","ecopin_public_map_reader","pg_database_owner","postgres","service_role";
REVOKE ALL ON SCHEMA "operational_private" FROM PUBLIC,"anon","authenticated","ecopin_operational_reader","ecopin_public_map_reader","pg_database_owner","postgres","service_role";
GRANT INSERT ON TABLE "public"."field_crews" TO "postgres";
GRANT SELECT ON TABLE "public"."field_crews" TO "postgres";
GRANT UPDATE ON TABLE "public"."field_crews" TO "postgres";
GRANT DELETE ON TABLE "public"."field_crews" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."field_crews" TO "postgres";
GRANT REFERENCES ON TABLE "public"."field_crews" TO "postgres";
GRANT TRIGGER ON TABLE "public"."field_crews" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."field_crews" TO "postgres";
GRANT SELECT ON TABLE "public"."field_crews" TO "anon";
GRANT MAINTAIN ON TABLE "public"."field_crews" TO "anon";
GRANT SELECT ON TABLE "public"."field_crews" TO "authenticated";
GRANT MAINTAIN ON TABLE "public"."field_crews" TO "authenticated";
GRANT INSERT ON TABLE "public"."field_crews" TO "service_role";
GRANT SELECT ON TABLE "public"."field_crews" TO "service_role";
GRANT UPDATE ON TABLE "public"."field_crews" TO "service_role";
GRANT DELETE ON TABLE "public"."field_crews" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."field_crews" TO "service_role";
GRANT REFERENCES ON TABLE "public"."field_crews" TO "service_role";
GRANT TRIGGER ON TABLE "public"."field_crews" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."field_crews" TO "service_role";
GRANT INSERT ON TABLE "operational_private"."crew_presence" TO "postgres";
GRANT SELECT ON TABLE "operational_private"."crew_presence" TO "postgres";
GRANT UPDATE ON TABLE "operational_private"."crew_presence" TO "postgres";
GRANT DELETE ON TABLE "operational_private"."crew_presence" TO "postgres";
GRANT TRUNCATE ON TABLE "operational_private"."crew_presence" TO "postgres";
GRANT REFERENCES ON TABLE "operational_private"."crew_presence" TO "postgres";
GRANT TRIGGER ON TABLE "operational_private"."crew_presence" TO "postgres";
GRANT MAINTAIN ON TABLE "operational_private"."crew_presence" TO "postgres";
GRANT INSERT ON TABLE "operational_private"."crew_presence" TO "service_role";
GRANT SELECT ON TABLE "operational_private"."crew_presence" TO "service_role";
GRANT UPDATE ON TABLE "operational_private"."crew_presence" TO "service_role";
GRANT INSERT ON TABLE "public"."dispatch_plans" TO "postgres";
GRANT SELECT ON TABLE "public"."dispatch_plans" TO "postgres";
GRANT UPDATE ON TABLE "public"."dispatch_plans" TO "postgres";
GRANT DELETE ON TABLE "public"."dispatch_plans" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."dispatch_plans" TO "postgres";
GRANT REFERENCES ON TABLE "public"."dispatch_plans" TO "postgres";
GRANT TRIGGER ON TABLE "public"."dispatch_plans" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."dispatch_plans" TO "postgres";
GRANT SELECT ON TABLE "public"."dispatch_plans" TO "anon";
GRANT MAINTAIN ON TABLE "public"."dispatch_plans" TO "anon";
GRANT SELECT ON TABLE "public"."dispatch_plans" TO "authenticated";
GRANT MAINTAIN ON TABLE "public"."dispatch_plans" TO "authenticated";
GRANT INSERT ON TABLE "public"."dispatch_plans" TO "service_role";
GRANT SELECT ON TABLE "public"."dispatch_plans" TO "service_role";
GRANT UPDATE ON TABLE "public"."dispatch_plans" TO "service_role";
GRANT DELETE ON TABLE "public"."dispatch_plans" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."dispatch_plans" TO "service_role";
GRANT REFERENCES ON TABLE "public"."dispatch_plans" TO "service_role";
GRANT TRIGGER ON TABLE "public"."dispatch_plans" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."dispatch_plans" TO "service_role";
GRANT INSERT ON TABLE "public"."manual_review_queue" TO "postgres";
GRANT SELECT ON TABLE "public"."manual_review_queue" TO "postgres";
GRANT UPDATE ON TABLE "public"."manual_review_queue" TO "postgres";
GRANT DELETE ON TABLE "public"."manual_review_queue" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."manual_review_queue" TO "postgres";
GRANT REFERENCES ON TABLE "public"."manual_review_queue" TO "postgres";
GRANT TRIGGER ON TABLE "public"."manual_review_queue" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."manual_review_queue" TO "postgres";
GRANT INSERT ON TABLE "public"."manual_review_queue" TO "anon";
GRANT SELECT ON TABLE "public"."manual_review_queue" TO "anon";
GRANT UPDATE ON TABLE "public"."manual_review_queue" TO "anon";
GRANT DELETE ON TABLE "public"."manual_review_queue" TO "anon";
GRANT TRUNCATE ON TABLE "public"."manual_review_queue" TO "anon";
GRANT REFERENCES ON TABLE "public"."manual_review_queue" TO "anon";
GRANT TRIGGER ON TABLE "public"."manual_review_queue" TO "anon";
GRANT MAINTAIN ON TABLE "public"."manual_review_queue" TO "anon";
GRANT INSERT ON TABLE "public"."manual_review_queue" TO "authenticated";
GRANT SELECT ON TABLE "public"."manual_review_queue" TO "authenticated";
GRANT UPDATE ON TABLE "public"."manual_review_queue" TO "authenticated";
GRANT DELETE ON TABLE "public"."manual_review_queue" TO "authenticated";
GRANT TRUNCATE ON TABLE "public"."manual_review_queue" TO "authenticated";
GRANT REFERENCES ON TABLE "public"."manual_review_queue" TO "authenticated";
GRANT TRIGGER ON TABLE "public"."manual_review_queue" TO "authenticated";
GRANT MAINTAIN ON TABLE "public"."manual_review_queue" TO "authenticated";
GRANT INSERT ON TABLE "public"."manual_review_queue" TO "service_role";
GRANT SELECT ON TABLE "public"."manual_review_queue" TO "service_role";
GRANT UPDATE ON TABLE "public"."manual_review_queue" TO "service_role";
GRANT DELETE ON TABLE "public"."manual_review_queue" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."manual_review_queue" TO "service_role";
GRANT REFERENCES ON TABLE "public"."manual_review_queue" TO "service_role";
GRANT TRIGGER ON TABLE "public"."manual_review_queue" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."manual_review_queue" TO "service_role";
GRANT INSERT ON TABLE "public"."audit_logs" TO "postgres";
GRANT SELECT ON TABLE "public"."audit_logs" TO "postgres";
GRANT UPDATE ON TABLE "public"."audit_logs" TO "postgres";
GRANT DELETE ON TABLE "public"."audit_logs" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."audit_logs" TO "postgres";
GRANT REFERENCES ON TABLE "public"."audit_logs" TO "postgres";
GRANT TRIGGER ON TABLE "public"."audit_logs" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."audit_logs" TO "postgres";
GRANT INSERT ON TABLE "public"."audit_logs" TO "anon";
GRANT SELECT ON TABLE "public"."audit_logs" TO "anon";
GRANT REFERENCES ON TABLE "public"."audit_logs" TO "anon";
GRANT TRIGGER ON TABLE "public"."audit_logs" TO "anon";
GRANT MAINTAIN ON TABLE "public"."audit_logs" TO "anon";
GRANT INSERT ON TABLE "public"."audit_logs" TO "authenticated";
GRANT SELECT ON TABLE "public"."audit_logs" TO "authenticated";
GRANT REFERENCES ON TABLE "public"."audit_logs" TO "authenticated";
GRANT TRIGGER ON TABLE "public"."audit_logs" TO "authenticated";
GRANT MAINTAIN ON TABLE "public"."audit_logs" TO "authenticated";
GRANT INSERT ON TABLE "public"."audit_logs" TO "service_role";
GRANT SELECT ON TABLE "public"."audit_logs" TO "service_role";
GRANT UPDATE ON TABLE "public"."audit_logs" TO "service_role";
GRANT DELETE ON TABLE "public"."audit_logs" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."audit_logs" TO "service_role";
GRANT REFERENCES ON TABLE "public"."audit_logs" TO "service_role";
GRANT TRIGGER ON TABLE "public"."audit_logs" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."audit_logs" TO "service_role";
GRANT SELECT ON TABLE "public"."audit_logs" TO "ecopin_operational_reader";
GRANT INSERT ON TABLE "public"."system_logs" TO "postgres";
GRANT SELECT ON TABLE "public"."system_logs" TO "postgres";
GRANT UPDATE ON TABLE "public"."system_logs" TO "postgres";
GRANT DELETE ON TABLE "public"."system_logs" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."system_logs" TO "postgres";
GRANT REFERENCES ON TABLE "public"."system_logs" TO "postgres";
GRANT TRIGGER ON TABLE "public"."system_logs" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."system_logs" TO "postgres";
GRANT INSERT ON TABLE "public"."system_logs" TO "anon";
GRANT SELECT ON TABLE "public"."system_logs" TO "anon";
GRANT REFERENCES ON TABLE "public"."system_logs" TO "anon";
GRANT TRIGGER ON TABLE "public"."system_logs" TO "anon";
GRANT MAINTAIN ON TABLE "public"."system_logs" TO "anon";
GRANT INSERT ON TABLE "public"."system_logs" TO "authenticated";
GRANT SELECT ON TABLE "public"."system_logs" TO "authenticated";
GRANT REFERENCES ON TABLE "public"."system_logs" TO "authenticated";
GRANT TRIGGER ON TABLE "public"."system_logs" TO "authenticated";
GRANT MAINTAIN ON TABLE "public"."system_logs" TO "authenticated";
GRANT INSERT ON TABLE "public"."system_logs" TO "service_role";
GRANT SELECT ON TABLE "public"."system_logs" TO "service_role";
GRANT UPDATE ON TABLE "public"."system_logs" TO "service_role";
GRANT DELETE ON TABLE "public"."system_logs" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."system_logs" TO "service_role";
GRANT REFERENCES ON TABLE "public"."system_logs" TO "service_role";
GRANT TRIGGER ON TABLE "public"."system_logs" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."system_logs" TO "service_role";
GRANT INSERT ON TABLE "public"."cleanup_tasks" TO "postgres";
GRANT SELECT ON TABLE "public"."cleanup_tasks" TO "postgres";
GRANT UPDATE ON TABLE "public"."cleanup_tasks" TO "postgres";
GRANT DELETE ON TABLE "public"."cleanup_tasks" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."cleanup_tasks" TO "postgres";
GRANT REFERENCES ON TABLE "public"."cleanup_tasks" TO "postgres";
GRANT TRIGGER ON TABLE "public"."cleanup_tasks" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."cleanup_tasks" TO "postgres";
GRANT SELECT ON TABLE "public"."cleanup_tasks" TO "anon";
GRANT MAINTAIN ON TABLE "public"."cleanup_tasks" TO "anon";
GRANT SELECT ON TABLE "public"."cleanup_tasks" TO "authenticated";
GRANT MAINTAIN ON TABLE "public"."cleanup_tasks" TO "authenticated";
GRANT INSERT ON TABLE "public"."cleanup_tasks" TO "service_role";
GRANT SELECT ON TABLE "public"."cleanup_tasks" TO "service_role";
GRANT UPDATE ON TABLE "public"."cleanup_tasks" TO "service_role";
GRANT DELETE ON TABLE "public"."cleanup_tasks" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."cleanup_tasks" TO "service_role";
GRANT REFERENCES ON TABLE "public"."cleanup_tasks" TO "service_role";
GRANT TRIGGER ON TABLE "public"."cleanup_tasks" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."cleanup_tasks" TO "service_role";
GRANT INSERT ON TABLE "public"."dispatch_plan_items" TO "postgres";
GRANT SELECT ON TABLE "public"."dispatch_plan_items" TO "postgres";
GRANT UPDATE ON TABLE "public"."dispatch_plan_items" TO "postgres";
GRANT DELETE ON TABLE "public"."dispatch_plan_items" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."dispatch_plan_items" TO "postgres";
GRANT REFERENCES ON TABLE "public"."dispatch_plan_items" TO "postgres";
GRANT TRIGGER ON TABLE "public"."dispatch_plan_items" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."dispatch_plan_items" TO "postgres";
GRANT SELECT ON TABLE "public"."dispatch_plan_items" TO "anon";
GRANT MAINTAIN ON TABLE "public"."dispatch_plan_items" TO "anon";
GRANT SELECT ON TABLE "public"."dispatch_plan_items" TO "authenticated";
GRANT MAINTAIN ON TABLE "public"."dispatch_plan_items" TO "authenticated";
GRANT INSERT ON TABLE "public"."dispatch_plan_items" TO "service_role";
GRANT SELECT ON TABLE "public"."dispatch_plan_items" TO "service_role";
GRANT UPDATE ON TABLE "public"."dispatch_plan_items" TO "service_role";
GRANT DELETE ON TABLE "public"."dispatch_plan_items" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."dispatch_plan_items" TO "service_role";
GRANT REFERENCES ON TABLE "public"."dispatch_plan_items" TO "service_role";
GRANT TRIGGER ON TABLE "public"."dispatch_plan_items" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."dispatch_plan_items" TO "service_role";
GRANT INSERT ON TABLE "public"."building_structures" TO "postgres";
GRANT SELECT ON TABLE "public"."building_structures" TO "postgres";
GRANT UPDATE ON TABLE "public"."building_structures" TO "postgres";
GRANT DELETE ON TABLE "public"."building_structures" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."building_structures" TO "postgres";
GRANT REFERENCES ON TABLE "public"."building_structures" TO "postgres";
GRANT TRIGGER ON TABLE "public"."building_structures" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."building_structures" TO "postgres";
GRANT INSERT ON TABLE "public"."building_structures" TO "authenticated";
GRANT SELECT ON TABLE "public"."building_structures" TO "authenticated";
GRANT UPDATE ON TABLE "public"."building_structures" TO "authenticated";
GRANT DELETE ON TABLE "public"."building_structures" TO "authenticated";
GRANT TRUNCATE ON TABLE "public"."building_structures" TO "authenticated";
GRANT REFERENCES ON TABLE "public"."building_structures" TO "authenticated";
GRANT TRIGGER ON TABLE "public"."building_structures" TO "authenticated";
GRANT MAINTAIN ON TABLE "public"."building_structures" TO "authenticated";
GRANT INSERT ON TABLE "public"."building_structures" TO "service_role";
GRANT SELECT ON TABLE "public"."building_structures" TO "service_role";
GRANT UPDATE ON TABLE "public"."building_structures" TO "service_role";
GRANT DELETE ON TABLE "public"."building_structures" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."building_structures" TO "service_role";
GRANT REFERENCES ON TABLE "public"."building_structures" TO "service_role";
GRANT TRIGGER ON TABLE "public"."building_structures" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."building_structures" TO "service_role";
GRANT SELECT ON TABLE "public"."building_structures" TO "ecopin_public_map_reader";
GRANT INSERT ON TABLE "public"."crew_urgency_observations" TO "postgres";
GRANT SELECT ON TABLE "public"."crew_urgency_observations" TO "postgres";
GRANT UPDATE ON TABLE "public"."crew_urgency_observations" TO "postgres";
GRANT DELETE ON TABLE "public"."crew_urgency_observations" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."crew_urgency_observations" TO "postgres";
GRANT REFERENCES ON TABLE "public"."crew_urgency_observations" TO "postgres";
GRANT TRIGGER ON TABLE "public"."crew_urgency_observations" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."crew_urgency_observations" TO "postgres";
GRANT INSERT ON TABLE "public"."crew_urgency_observations" TO "service_role";
GRANT SELECT ON TABLE "public"."crew_urgency_observations" TO "service_role";
GRANT INSERT ON TABLE "public"."plan_generation_jobs" TO "postgres";
GRANT SELECT ON TABLE "public"."plan_generation_jobs" TO "postgres";
GRANT UPDATE ON TABLE "public"."plan_generation_jobs" TO "postgres";
GRANT DELETE ON TABLE "public"."plan_generation_jobs" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."plan_generation_jobs" TO "postgres";
GRANT REFERENCES ON TABLE "public"."plan_generation_jobs" TO "postgres";
GRANT TRIGGER ON TABLE "public"."plan_generation_jobs" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."plan_generation_jobs" TO "postgres";
GRANT INSERT ON TABLE "public"."plan_generation_jobs" TO "service_role";
GRANT SELECT ON TABLE "public"."plan_generation_jobs" TO "service_role";
GRANT UPDATE ON TABLE "public"."plan_generation_jobs" TO "service_role";
GRANT DELETE ON TABLE "public"."plan_generation_jobs" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."plan_generation_jobs" TO "service_role";
GRANT REFERENCES ON TABLE "public"."plan_generation_jobs" TO "service_role";
GRANT TRIGGER ON TABLE "public"."plan_generation_jobs" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."plan_generation_jobs" TO "service_role";
GRANT INSERT ON TABLE "public"."public_reports" TO "ecopin_public_map_reader";
GRANT SELECT ON TABLE "public"."public_reports" TO "ecopin_public_map_reader";
GRANT UPDATE ON TABLE "public"."public_reports" TO "ecopin_public_map_reader";
GRANT DELETE ON TABLE "public"."public_reports" TO "ecopin_public_map_reader";
GRANT TRUNCATE ON TABLE "public"."public_reports" TO "ecopin_public_map_reader";
GRANT REFERENCES ON TABLE "public"."public_reports" TO "ecopin_public_map_reader";
GRANT TRIGGER ON TABLE "public"."public_reports" TO "ecopin_public_map_reader";
GRANT MAINTAIN ON TABLE "public"."public_reports" TO "ecopin_public_map_reader";
GRANT SELECT ON TABLE "public"."public_reports" TO "anon";
GRANT SELECT ON TABLE "public"."public_reports" TO "authenticated";
GRANT SELECT ON TABLE "public"."public_reports" TO "service_role";
GRANT INSERT ON TABLE "public"."crew_urgency_reviews" TO "postgres";
GRANT SELECT ON TABLE "public"."crew_urgency_reviews" TO "postgres";
GRANT UPDATE ON TABLE "public"."crew_urgency_reviews" TO "postgres";
GRANT DELETE ON TABLE "public"."crew_urgency_reviews" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."crew_urgency_reviews" TO "postgres";
GRANT REFERENCES ON TABLE "public"."crew_urgency_reviews" TO "postgres";
GRANT TRIGGER ON TABLE "public"."crew_urgency_reviews" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."crew_urgency_reviews" TO "postgres";
GRANT INSERT ON TABLE "public"."crew_urgency_reviews" TO "service_role";
GRANT SELECT ON TABLE "public"."crew_urgency_reviews" TO "service_role";
GRANT INSERT ON TABLE "public"."reports" TO "postgres";
GRANT SELECT ON TABLE "public"."reports" TO "postgres";
GRANT UPDATE ON TABLE "public"."reports" TO "postgres";
GRANT DELETE ON TABLE "public"."reports" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."reports" TO "postgres";
GRANT REFERENCES ON TABLE "public"."reports" TO "postgres";
GRANT TRIGGER ON TABLE "public"."reports" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."reports" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."reports" TO "authenticated";
GRANT INSERT ON TABLE "public"."reports" TO "service_role";
GRANT SELECT ON TABLE "public"."reports" TO "service_role";
GRANT UPDATE ON TABLE "public"."reports" TO "service_role";
GRANT DELETE ON TABLE "public"."reports" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."reports" TO "service_role";
GRANT REFERENCES ON TABLE "public"."reports" TO "service_role";
GRANT TRIGGER ON TABLE "public"."reports" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."reports" TO "service_role";
GRANT SELECT ON TABLE "public"."reports" TO "ecopin_operational_reader";
GRANT SELECT ON SEQUENCE "public"."fc_version_seq" TO "postgres";
GRANT UPDATE ON SEQUENCE "public"."fc_version_seq" TO "postgres";
GRANT USAGE ON SEQUENCE "public"."fc_version_seq" TO "postgres";
GRANT SELECT ON SEQUENCE "public"."fc_version_seq" TO "anon";
GRANT UPDATE ON SEQUENCE "public"."fc_version_seq" TO "anon";
GRANT USAGE ON SEQUENCE "public"."fc_version_seq" TO "anon";
GRANT SELECT ON SEQUENCE "public"."fc_version_seq" TO "authenticated";
GRANT UPDATE ON SEQUENCE "public"."fc_version_seq" TO "authenticated";
GRANT USAGE ON SEQUENCE "public"."fc_version_seq" TO "authenticated";
GRANT SELECT ON SEQUENCE "public"."fc_version_seq" TO "service_role";
GRANT UPDATE ON SEQUENCE "public"."fc_version_seq" TO "service_role";
GRANT USAGE ON SEQUENCE "public"."fc_version_seq" TO "service_role";
GRANT INSERT ON TABLE "public"."pasig_barangay_roster" TO "postgres";
GRANT SELECT ON TABLE "public"."pasig_barangay_roster" TO "postgres";
GRANT UPDATE ON TABLE "public"."pasig_barangay_roster" TO "postgres";
GRANT DELETE ON TABLE "public"."pasig_barangay_roster" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."pasig_barangay_roster" TO "postgres";
GRANT REFERENCES ON TABLE "public"."pasig_barangay_roster" TO "postgres";
GRANT TRIGGER ON TABLE "public"."pasig_barangay_roster" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."pasig_barangay_roster" TO "postgres";
GRANT SELECT ON TABLE "public"."pasig_barangay_roster" TO "service_role";
GRANT INSERT ON TABLE "public"."fc_operation_log" TO "postgres";
GRANT SELECT ON TABLE "public"."fc_operation_log" TO "postgres";
GRANT UPDATE ON TABLE "public"."fc_operation_log" TO "postgres";
GRANT DELETE ON TABLE "public"."fc_operation_log" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."fc_operation_log" TO "postgres";
GRANT REFERENCES ON TABLE "public"."fc_operation_log" TO "postgres";
GRANT TRIGGER ON TABLE "public"."fc_operation_log" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."fc_operation_log" TO "postgres";
GRANT INSERT ON TABLE "public"."fc_operation_log" TO "service_role";
GRANT SELECT ON TABLE "public"."fc_operation_log" TO "service_role";
GRANT UPDATE ON TABLE "public"."fc_operation_log" TO "service_role";
GRANT DELETE ON TABLE "public"."fc_operation_log" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."fc_operation_log" TO "service_role";
GRANT REFERENCES ON TABLE "public"."fc_operation_log" TO "service_role";
GRANT TRIGGER ON TABLE "public"."fc_operation_log" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."fc_operation_log" TO "service_role";
GRANT INSERT ON TABLE "public"."response_log" TO "postgres";
GRANT SELECT ON TABLE "public"."response_log" TO "postgres";
GRANT UPDATE ON TABLE "public"."response_log" TO "postgres";
GRANT DELETE ON TABLE "public"."response_log" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."response_log" TO "postgres";
GRANT REFERENCES ON TABLE "public"."response_log" TO "postgres";
GRANT TRIGGER ON TABLE "public"."response_log" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."response_log" TO "postgres";
GRANT INSERT ON TABLE "public"."response_log" TO "anon";
GRANT SELECT ON TABLE "public"."response_log" TO "anon";
GRANT UPDATE ON TABLE "public"."response_log" TO "anon";
GRANT DELETE ON TABLE "public"."response_log" TO "anon";
GRANT TRUNCATE ON TABLE "public"."response_log" TO "anon";
GRANT REFERENCES ON TABLE "public"."response_log" TO "anon";
GRANT TRIGGER ON TABLE "public"."response_log" TO "anon";
GRANT MAINTAIN ON TABLE "public"."response_log" TO "anon";
GRANT INSERT ON TABLE "public"."response_log" TO "authenticated";
GRANT SELECT ON TABLE "public"."response_log" TO "authenticated";
GRANT UPDATE ON TABLE "public"."response_log" TO "authenticated";
GRANT DELETE ON TABLE "public"."response_log" TO "authenticated";
GRANT TRUNCATE ON TABLE "public"."response_log" TO "authenticated";
GRANT REFERENCES ON TABLE "public"."response_log" TO "authenticated";
GRANT TRIGGER ON TABLE "public"."response_log" TO "authenticated";
GRANT MAINTAIN ON TABLE "public"."response_log" TO "authenticated";
GRANT INSERT ON TABLE "public"."response_log" TO "service_role";
GRANT SELECT ON TABLE "public"."response_log" TO "service_role";
GRANT UPDATE ON TABLE "public"."response_log" TO "service_role";
GRANT DELETE ON TABLE "public"."response_log" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."response_log" TO "service_role";
GRANT REFERENCES ON TABLE "public"."response_log" TO "service_role";
GRANT TRIGGER ON TABLE "public"."response_log" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."response_log" TO "service_role";
GRANT INSERT ON TABLE "public"."fc_conflict_audit" TO "postgres";
GRANT SELECT ON TABLE "public"."fc_conflict_audit" TO "postgres";
GRANT UPDATE ON TABLE "public"."fc_conflict_audit" TO "postgres";
GRANT DELETE ON TABLE "public"."fc_conflict_audit" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."fc_conflict_audit" TO "postgres";
GRANT REFERENCES ON TABLE "public"."fc_conflict_audit" TO "postgres";
GRANT TRIGGER ON TABLE "public"."fc_conflict_audit" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."fc_conflict_audit" TO "postgres";
GRANT INSERT ON TABLE "public"."fc_conflict_audit" TO "service_role";
GRANT SELECT ON TABLE "public"."fc_conflict_audit" TO "service_role";
GRANT UPDATE ON TABLE "public"."fc_conflict_audit" TO "service_role";
GRANT DELETE ON TABLE "public"."fc_conflict_audit" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."fc_conflict_audit" TO "service_role";
GRANT REFERENCES ON TABLE "public"."fc_conflict_audit" TO "service_role";
GRANT TRIGGER ON TABLE "public"."fc_conflict_audit" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."fc_conflict_audit" TO "service_role";
GRANT INSERT ON TABLE "public"."profiles" TO "postgres";
GRANT SELECT ON TABLE "public"."profiles" TO "postgres";
GRANT UPDATE ON TABLE "public"."profiles" TO "postgres";
GRANT DELETE ON TABLE "public"."profiles" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."profiles" TO "postgres";
GRANT REFERENCES ON TABLE "public"."profiles" TO "postgres";
GRANT TRIGGER ON TABLE "public"."profiles" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."profiles" TO "postgres";
GRANT SELECT ON TABLE "public"."profiles" TO "anon";
GRANT MAINTAIN ON TABLE "public"."profiles" TO "anon";
GRANT SELECT ON TABLE "public"."profiles" TO "authenticated";
GRANT MAINTAIN ON TABLE "public"."profiles" TO "authenticated";
GRANT INSERT ON TABLE "public"."profiles" TO "service_role";
GRANT SELECT ON TABLE "public"."profiles" TO "service_role";
GRANT UPDATE ON TABLE "public"."profiles" TO "service_role";
GRANT DELETE ON TABLE "public"."profiles" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."profiles" TO "service_role";
GRANT REFERENCES ON TABLE "public"."profiles" TO "service_role";
GRANT TRIGGER ON TABLE "public"."profiles" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."profiles" TO "service_role";
GRANT INSERT ON TABLE "public"."hotspot_accuracy" TO "postgres";
GRANT SELECT ON TABLE "public"."hotspot_accuracy" TO "postgres";
GRANT UPDATE ON TABLE "public"."hotspot_accuracy" TO "postgres";
GRANT DELETE ON TABLE "public"."hotspot_accuracy" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."hotspot_accuracy" TO "postgres";
GRANT REFERENCES ON TABLE "public"."hotspot_accuracy" TO "postgres";
GRANT TRIGGER ON TABLE "public"."hotspot_accuracy" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."hotspot_accuracy" TO "postgres";
GRANT INSERT ON TABLE "public"."hotspot_accuracy" TO "anon";
GRANT SELECT ON TABLE "public"."hotspot_accuracy" TO "anon";
GRANT UPDATE ON TABLE "public"."hotspot_accuracy" TO "anon";
GRANT DELETE ON TABLE "public"."hotspot_accuracy" TO "anon";
GRANT TRUNCATE ON TABLE "public"."hotspot_accuracy" TO "anon";
GRANT REFERENCES ON TABLE "public"."hotspot_accuracy" TO "anon";
GRANT TRIGGER ON TABLE "public"."hotspot_accuracy" TO "anon";
GRANT MAINTAIN ON TABLE "public"."hotspot_accuracy" TO "anon";
GRANT INSERT ON TABLE "public"."hotspot_accuracy" TO "authenticated";
GRANT SELECT ON TABLE "public"."hotspot_accuracy" TO "authenticated";
GRANT UPDATE ON TABLE "public"."hotspot_accuracy" TO "authenticated";
GRANT DELETE ON TABLE "public"."hotspot_accuracy" TO "authenticated";
GRANT TRUNCATE ON TABLE "public"."hotspot_accuracy" TO "authenticated";
GRANT REFERENCES ON TABLE "public"."hotspot_accuracy" TO "authenticated";
GRANT TRIGGER ON TABLE "public"."hotspot_accuracy" TO "authenticated";
GRANT MAINTAIN ON TABLE "public"."hotspot_accuracy" TO "authenticated";
GRANT INSERT ON TABLE "public"."hotspot_accuracy" TO "service_role";
GRANT SELECT ON TABLE "public"."hotspot_accuracy" TO "service_role";
GRANT UPDATE ON TABLE "public"."hotspot_accuracy" TO "service_role";
GRANT DELETE ON TABLE "public"."hotspot_accuracy" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."hotspot_accuracy" TO "service_role";
GRANT REFERENCES ON TABLE "public"."hotspot_accuracy" TO "service_role";
GRANT TRIGGER ON TABLE "public"."hotspot_accuracy" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."hotspot_accuracy" TO "service_role";
GRANT INSERT ON TABLE "public"."dispatch_group_commits" TO "postgres";
GRANT SELECT ON TABLE "public"."dispatch_group_commits" TO "postgres";
GRANT UPDATE ON TABLE "public"."dispatch_group_commits" TO "postgres";
GRANT DELETE ON TABLE "public"."dispatch_group_commits" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."dispatch_group_commits" TO "postgres";
GRANT REFERENCES ON TABLE "public"."dispatch_group_commits" TO "postgres";
GRANT TRIGGER ON TABLE "public"."dispatch_group_commits" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."dispatch_group_commits" TO "postgres";
GRANT INSERT ON TABLE "public"."dispatch_group_commits" TO "service_role";
GRANT SELECT ON TABLE "public"."dispatch_group_commits" TO "service_role";
GRANT UPDATE ON TABLE "public"."dispatch_group_commits" TO "service_role";
GRANT DELETE ON TABLE "public"."dispatch_group_commits" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."dispatch_group_commits" TO "service_role";
GRANT REFERENCES ON TABLE "public"."dispatch_group_commits" TO "service_role";
GRANT TRIGGER ON TABLE "public"."dispatch_group_commits" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."dispatch_group_commits" TO "service_role";
GRANT INSERT ON TABLE "public"."system_settings" TO "postgres";
GRANT SELECT ON TABLE "public"."system_settings" TO "postgres";
GRANT UPDATE ON TABLE "public"."system_settings" TO "postgres";
GRANT DELETE ON TABLE "public"."system_settings" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."system_settings" TO "postgres";
GRANT REFERENCES ON TABLE "public"."system_settings" TO "postgres";
GRANT TRIGGER ON TABLE "public"."system_settings" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."system_settings" TO "postgres";
GRANT INSERT ON TABLE "public"."system_settings" TO "anon";
GRANT SELECT ON TABLE "public"."system_settings" TO "anon";
GRANT UPDATE ON TABLE "public"."system_settings" TO "anon";
GRANT DELETE ON TABLE "public"."system_settings" TO "anon";
GRANT TRUNCATE ON TABLE "public"."system_settings" TO "anon";
GRANT REFERENCES ON TABLE "public"."system_settings" TO "anon";
GRANT TRIGGER ON TABLE "public"."system_settings" TO "anon";
GRANT MAINTAIN ON TABLE "public"."system_settings" TO "anon";
GRANT INSERT ON TABLE "public"."system_settings" TO "authenticated";
GRANT SELECT ON TABLE "public"."system_settings" TO "authenticated";
GRANT UPDATE ON TABLE "public"."system_settings" TO "authenticated";
GRANT DELETE ON TABLE "public"."system_settings" TO "authenticated";
GRANT TRUNCATE ON TABLE "public"."system_settings" TO "authenticated";
GRANT REFERENCES ON TABLE "public"."system_settings" TO "authenticated";
GRANT TRIGGER ON TABLE "public"."system_settings" TO "authenticated";
GRANT MAINTAIN ON TABLE "public"."system_settings" TO "authenticated";
GRANT INSERT ON TABLE "public"."system_settings" TO "service_role";
GRANT SELECT ON TABLE "public"."system_settings" TO "service_role";
GRANT UPDATE ON TABLE "public"."system_settings" TO "service_role";
GRANT DELETE ON TABLE "public"."system_settings" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."system_settings" TO "service_role";
GRANT REFERENCES ON TABLE "public"."system_settings" TO "service_role";
GRANT TRIGGER ON TABLE "public"."system_settings" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."system_settings" TO "service_role";
GRANT INSERT ON TABLE "public"."email_verifications" TO "postgres";
GRANT SELECT ON TABLE "public"."email_verifications" TO "postgres";
GRANT UPDATE ON TABLE "public"."email_verifications" TO "postgres";
GRANT DELETE ON TABLE "public"."email_verifications" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."email_verifications" TO "postgres";
GRANT REFERENCES ON TABLE "public"."email_verifications" TO "postgres";
GRANT TRIGGER ON TABLE "public"."email_verifications" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."email_verifications" TO "postgres";
GRANT INSERT ON TABLE "public"."email_verifications" TO "service_role";
GRANT SELECT ON TABLE "public"."email_verifications" TO "service_role";
GRANT UPDATE ON TABLE "public"."email_verifications" TO "service_role";
GRANT DELETE ON TABLE "public"."email_verifications" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."email_verifications" TO "service_role";
GRANT REFERENCES ON TABLE "public"."email_verifications" TO "service_role";
GRANT TRIGGER ON TABLE "public"."email_verifications" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."email_verifications" TO "service_role";
GRANT INSERT ON TABLE "public"."dispatch_access_blocks" TO "postgres";
GRANT SELECT ON TABLE "public"."dispatch_access_blocks" TO "postgres";
GRANT UPDATE ON TABLE "public"."dispatch_access_blocks" TO "postgres";
GRANT DELETE ON TABLE "public"."dispatch_access_blocks" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."dispatch_access_blocks" TO "postgres";
GRANT REFERENCES ON TABLE "public"."dispatch_access_blocks" TO "postgres";
GRANT TRIGGER ON TABLE "public"."dispatch_access_blocks" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."dispatch_access_blocks" TO "postgres";
GRANT INSERT ON TABLE "public"."dispatch_access_blocks" TO "service_role";
GRANT SELECT ON TABLE "public"."dispatch_access_blocks" TO "service_role";
GRANT UPDATE ON TABLE "public"."dispatch_access_blocks" TO "service_role";
GRANT DELETE ON TABLE "public"."dispatch_access_blocks" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."dispatch_access_blocks" TO "service_role";
GRANT REFERENCES ON TABLE "public"."dispatch_access_blocks" TO "service_role";
GRANT TRIGGER ON TABLE "public"."dispatch_access_blocks" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."dispatch_access_blocks" TO "service_role";
GRANT INSERT ON TABLE "public"."pasig_barangay_boundary_source" TO "postgres";
GRANT SELECT ON TABLE "public"."pasig_barangay_boundary_source" TO "postgres";
GRANT UPDATE ON TABLE "public"."pasig_barangay_boundary_source" TO "postgres";
GRANT DELETE ON TABLE "public"."pasig_barangay_boundary_source" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."pasig_barangay_boundary_source" TO "postgres";
GRANT REFERENCES ON TABLE "public"."pasig_barangay_boundary_source" TO "postgres";
GRANT TRIGGER ON TABLE "public"."pasig_barangay_boundary_source" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."pasig_barangay_boundary_source" TO "postgres";
GRANT INSERT ON TABLE "public"."pasig_barangay_boundary_source" TO "service_role";
GRANT SELECT ON TABLE "public"."pasig_barangay_boundary_source" TO "service_role";
GRANT UPDATE ON TABLE "public"."pasig_barangay_boundary_source" TO "service_role";
GRANT INSERT ON TABLE "public"."field_assignment_receipts" TO "postgres";
GRANT SELECT ON TABLE "public"."field_assignment_receipts" TO "postgres";
GRANT UPDATE ON TABLE "public"."field_assignment_receipts" TO "postgres";
GRANT DELETE ON TABLE "public"."field_assignment_receipts" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."field_assignment_receipts" TO "postgres";
GRANT REFERENCES ON TABLE "public"."field_assignment_receipts" TO "postgres";
GRANT TRIGGER ON TABLE "public"."field_assignment_receipts" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."field_assignment_receipts" TO "postgres";
GRANT INSERT ON TABLE "public"."field_assignment_receipts" TO "service_role";
GRANT SELECT ON TABLE "public"."field_assignment_receipts" TO "service_role";
GRANT UPDATE ON TABLE "public"."field_assignment_receipts" TO "service_role";
GRANT DELETE ON TABLE "public"."field_assignment_receipts" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."field_assignment_receipts" TO "service_role";
GRANT REFERENCES ON TABLE "public"."field_assignment_receipts" TO "service_role";
GRANT TRIGGER ON TABLE "public"."field_assignment_receipts" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."field_assignment_receipts" TO "service_role";
GRANT INSERT ON TABLE "public"."report_resolution_events" TO "postgres";
GRANT SELECT ON TABLE "public"."report_resolution_events" TO "postgres";
GRANT UPDATE ON TABLE "public"."report_resolution_events" TO "postgres";
GRANT DELETE ON TABLE "public"."report_resolution_events" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."report_resolution_events" TO "postgres";
GRANT REFERENCES ON TABLE "public"."report_resolution_events" TO "postgres";
GRANT TRIGGER ON TABLE "public"."report_resolution_events" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."report_resolution_events" TO "postgres";
GRANT INSERT ON TABLE "public"."report_resolution_events" TO "service_role";
GRANT SELECT ON TABLE "public"."report_resolution_events" TO "service_role";
GRANT UPDATE ON TABLE "public"."report_resolution_events" TO "service_role";
GRANT DELETE ON TABLE "public"."report_resolution_events" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."report_resolution_events" TO "service_role";
GRANT REFERENCES ON TABLE "public"."report_resolution_events" TO "service_role";
GRANT TRIGGER ON TABLE "public"."report_resolution_events" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."report_resolution_events" TO "service_role";
GRANT INSERT ON TABLE "public"."notifications" TO "postgres";
GRANT SELECT ON TABLE "public"."notifications" TO "postgres";
GRANT UPDATE ON TABLE "public"."notifications" TO "postgres";
GRANT DELETE ON TABLE "public"."notifications" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."notifications" TO "postgres";
GRANT REFERENCES ON TABLE "public"."notifications" TO "postgres";
GRANT TRIGGER ON TABLE "public"."notifications" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."notifications" TO "postgres";
GRANT INSERT ON TABLE "public"."notifications" TO "anon";
GRANT SELECT ON TABLE "public"."notifications" TO "anon";
GRANT UPDATE ON TABLE "public"."notifications" TO "anon";
GRANT DELETE ON TABLE "public"."notifications" TO "anon";
GRANT TRUNCATE ON TABLE "public"."notifications" TO "anon";
GRANT REFERENCES ON TABLE "public"."notifications" TO "anon";
GRANT TRIGGER ON TABLE "public"."notifications" TO "anon";
GRANT MAINTAIN ON TABLE "public"."notifications" TO "anon";
GRANT INSERT ON TABLE "public"."notifications" TO "authenticated";
GRANT SELECT ON TABLE "public"."notifications" TO "authenticated";
GRANT DELETE ON TABLE "public"."notifications" TO "authenticated";
GRANT TRUNCATE ON TABLE "public"."notifications" TO "authenticated";
GRANT REFERENCES ON TABLE "public"."notifications" TO "authenticated";
GRANT TRIGGER ON TABLE "public"."notifications" TO "authenticated";
GRANT MAINTAIN ON TABLE "public"."notifications" TO "authenticated";
GRANT INSERT ON TABLE "public"."notifications" TO "service_role";
GRANT SELECT ON TABLE "public"."notifications" TO "service_role";
GRANT UPDATE ON TABLE "public"."notifications" TO "service_role";
GRANT DELETE ON TABLE "public"."notifications" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."notifications" TO "service_role";
GRANT REFERENCES ON TABLE "public"."notifications" TO "service_role";
GRANT TRIGGER ON TABLE "public"."notifications" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."notifications" TO "service_role";
GRANT INSERT ON TABLE "public"."optimization_templates" TO "postgres";
GRANT SELECT ON TABLE "public"."optimization_templates" TO "postgres";
GRANT UPDATE ON TABLE "public"."optimization_templates" TO "postgres";
GRANT DELETE ON TABLE "public"."optimization_templates" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."optimization_templates" TO "postgres";
GRANT REFERENCES ON TABLE "public"."optimization_templates" TO "postgres";
GRANT TRIGGER ON TABLE "public"."optimization_templates" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."optimization_templates" TO "postgres";
GRANT SELECT ON TABLE "public"."optimization_templates" TO "anon";
GRANT MAINTAIN ON TABLE "public"."optimization_templates" TO "anon";
GRANT SELECT ON TABLE "public"."optimization_templates" TO "authenticated";
GRANT MAINTAIN ON TABLE "public"."optimization_templates" TO "authenticated";
GRANT INSERT ON TABLE "public"."optimization_templates" TO "service_role";
GRANT SELECT ON TABLE "public"."optimization_templates" TO "service_role";
GRANT UPDATE ON TABLE "public"."optimization_templates" TO "service_role";
GRANT DELETE ON TABLE "public"."optimization_templates" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."optimization_templates" TO "service_role";
GRANT REFERENCES ON TABLE "public"."optimization_templates" TO "service_role";
GRANT TRIGGER ON TABLE "public"."optimization_templates" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."optimization_templates" TO "service_role";
GRANT INSERT ON TABLE "public"."task_report_outcomes" TO "postgres";
GRANT SELECT ON TABLE "public"."task_report_outcomes" TO "postgres";
GRANT UPDATE ON TABLE "public"."task_report_outcomes" TO "postgres";
GRANT DELETE ON TABLE "public"."task_report_outcomes" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."task_report_outcomes" TO "postgres";
GRANT REFERENCES ON TABLE "public"."task_report_outcomes" TO "postgres";
GRANT TRIGGER ON TABLE "public"."task_report_outcomes" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."task_report_outcomes" TO "postgres";
GRANT INSERT ON TABLE "public"."task_report_outcomes" TO "service_role";
GRANT SELECT ON TABLE "public"."task_report_outcomes" TO "service_role";
GRANT UPDATE ON TABLE "public"."task_report_outcomes" TO "service_role";
GRANT DELETE ON TABLE "public"."task_report_outcomes" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."task_report_outcomes" TO "service_role";
GRANT REFERENCES ON TABLE "public"."task_report_outcomes" TO "service_role";
GRANT TRIGGER ON TABLE "public"."task_report_outcomes" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."task_report_outcomes" TO "service_role";
GRANT INSERT ON TABLE "public"."optimization_settings" TO "postgres";
GRANT SELECT ON TABLE "public"."optimization_settings" TO "postgres";
GRANT UPDATE ON TABLE "public"."optimization_settings" TO "postgres";
GRANT DELETE ON TABLE "public"."optimization_settings" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."optimization_settings" TO "postgres";
GRANT REFERENCES ON TABLE "public"."optimization_settings" TO "postgres";
GRANT TRIGGER ON TABLE "public"."optimization_settings" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."optimization_settings" TO "postgres";
GRANT SELECT ON TABLE "public"."optimization_settings" TO "anon";
GRANT MAINTAIN ON TABLE "public"."optimization_settings" TO "anon";
GRANT SELECT ON TABLE "public"."optimization_settings" TO "authenticated";
GRANT MAINTAIN ON TABLE "public"."optimization_settings" TO "authenticated";
GRANT INSERT ON TABLE "public"."optimization_settings" TO "service_role";
GRANT SELECT ON TABLE "public"."optimization_settings" TO "service_role";
GRANT UPDATE ON TABLE "public"."optimization_settings" TO "service_role";
GRANT DELETE ON TABLE "public"."optimization_settings" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."optimization_settings" TO "service_role";
GRANT REFERENCES ON TABLE "public"."optimization_settings" TO "service_role";
GRANT TRIGGER ON TABLE "public"."optimization_settings" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."optimization_settings" TO "service_role";
GRANT INSERT ON TABLE "public"."defense_seed_staging" TO "postgres";
GRANT SELECT ON TABLE "public"."defense_seed_staging" TO "postgres";
GRANT UPDATE ON TABLE "public"."defense_seed_staging" TO "postgres";
GRANT DELETE ON TABLE "public"."defense_seed_staging" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."defense_seed_staging" TO "postgres";
GRANT REFERENCES ON TABLE "public"."defense_seed_staging" TO "postgres";
GRANT TRIGGER ON TABLE "public"."defense_seed_staging" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."defense_seed_staging" TO "postgres";
GRANT INSERT ON TABLE "public"."defense_seed_staging" TO "service_role";
GRANT SELECT ON TABLE "public"."defense_seed_staging" TO "service_role";
GRANT UPDATE ON TABLE "public"."defense_seed_staging" TO "service_role";
GRANT DELETE ON TABLE "public"."defense_seed_staging" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."defense_seed_staging" TO "service_role";
GRANT REFERENCES ON TABLE "public"."defense_seed_staging" TO "service_role";
GRANT TRIGGER ON TABLE "public"."defense_seed_staging" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."defense_seed_staging" TO "service_role";
GRANT INSERT ON TABLE "public"."support_tickets" TO "postgres";
GRANT SELECT ON TABLE "public"."support_tickets" TO "postgres";
GRANT UPDATE ON TABLE "public"."support_tickets" TO "postgres";
GRANT DELETE ON TABLE "public"."support_tickets" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."support_tickets" TO "postgres";
GRANT REFERENCES ON TABLE "public"."support_tickets" TO "postgres";
GRANT TRIGGER ON TABLE "public"."support_tickets" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."support_tickets" TO "postgres";
GRANT INSERT ON TABLE "public"."support_tickets" TO "service_role";
GRANT SELECT ON TABLE "public"."support_tickets" TO "service_role";
GRANT UPDATE ON TABLE "public"."support_tickets" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."support_ticket_number_seq" TO "postgres";
GRANT UPDATE ON SEQUENCE "public"."support_ticket_number_seq" TO "postgres";
GRANT USAGE ON SEQUENCE "public"."support_ticket_number_seq" TO "postgres";
GRANT SELECT ON SEQUENCE "public"."support_ticket_number_seq" TO "service_role";
GRANT UPDATE ON SEQUENCE "public"."support_ticket_number_seq" TO "service_role";
GRANT USAGE ON SEQUENCE "public"."support_ticket_number_seq" TO "service_role";
GRANT INSERT ON TABLE "public"."route_waypoints" TO "postgres";
GRANT SELECT ON TABLE "public"."route_waypoints" TO "postgres";
GRANT UPDATE ON TABLE "public"."route_waypoints" TO "postgres";
GRANT DELETE ON TABLE "public"."route_waypoints" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."route_waypoints" TO "postgres";
GRANT REFERENCES ON TABLE "public"."route_waypoints" TO "postgres";
GRANT TRIGGER ON TABLE "public"."route_waypoints" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."route_waypoints" TO "postgres";
GRANT SELECT ON TABLE "public"."route_waypoints" TO "anon";
GRANT MAINTAIN ON TABLE "public"."route_waypoints" TO "anon";
GRANT SELECT ON TABLE "public"."route_waypoints" TO "authenticated";
GRANT MAINTAIN ON TABLE "public"."route_waypoints" TO "authenticated";
GRANT INSERT ON TABLE "public"."route_waypoints" TO "service_role";
GRANT SELECT ON TABLE "public"."route_waypoints" TO "service_role";
GRANT UPDATE ON TABLE "public"."route_waypoints" TO "service_role";
GRANT DELETE ON TABLE "public"."route_waypoints" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."route_waypoints" TO "service_role";
GRANT REFERENCES ON TABLE "public"."route_waypoints" TO "service_role";
GRANT TRIGGER ON TABLE "public"."route_waypoints" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."route_waypoints" TO "service_role";
GRANT INSERT ON TABLE "public"."optimization_runs" TO "postgres";
GRANT SELECT ON TABLE "public"."optimization_runs" TO "postgres";
GRANT UPDATE ON TABLE "public"."optimization_runs" TO "postgres";
GRANT DELETE ON TABLE "public"."optimization_runs" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."optimization_runs" TO "postgres";
GRANT REFERENCES ON TABLE "public"."optimization_runs" TO "postgres";
GRANT TRIGGER ON TABLE "public"."optimization_runs" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."optimization_runs" TO "postgres";
GRANT SELECT ON TABLE "public"."optimization_runs" TO "anon";
GRANT MAINTAIN ON TABLE "public"."optimization_runs" TO "anon";
GRANT SELECT ON TABLE "public"."optimization_runs" TO "authenticated";
GRANT MAINTAIN ON TABLE "public"."optimization_runs" TO "authenticated";
GRANT INSERT ON TABLE "public"."optimization_runs" TO "service_role";
GRANT SELECT ON TABLE "public"."optimization_runs" TO "service_role";
GRANT UPDATE ON TABLE "public"."optimization_runs" TO "service_role";
GRANT DELETE ON TABLE "public"."optimization_runs" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."optimization_runs" TO "service_role";
GRANT REFERENCES ON TABLE "public"."optimization_runs" TO "service_role";
GRANT TRIGGER ON TABLE "public"."optimization_runs" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."optimization_runs" TO "service_role";
GRANT INSERT ON TABLE "public"."crew_routes" TO "postgres";
GRANT SELECT ON TABLE "public"."crew_routes" TO "postgres";
GRANT UPDATE ON TABLE "public"."crew_routes" TO "postgres";
GRANT DELETE ON TABLE "public"."crew_routes" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."crew_routes" TO "postgres";
GRANT REFERENCES ON TABLE "public"."crew_routes" TO "postgres";
GRANT TRIGGER ON TABLE "public"."crew_routes" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."crew_routes" TO "postgres";
GRANT SELECT ON TABLE "public"."crew_routes" TO "anon";
GRANT MAINTAIN ON TABLE "public"."crew_routes" TO "anon";
GRANT SELECT ON TABLE "public"."crew_routes" TO "authenticated";
GRANT MAINTAIN ON TABLE "public"."crew_routes" TO "authenticated";
GRANT INSERT ON TABLE "public"."crew_routes" TO "service_role";
GRANT SELECT ON TABLE "public"."crew_routes" TO "service_role";
GRANT UPDATE ON TABLE "public"."crew_routes" TO "service_role";
GRANT DELETE ON TABLE "public"."crew_routes" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."crew_routes" TO "service_role";
GRANT REFERENCES ON TABLE "public"."crew_routes" TO "service_role";
GRANT TRIGGER ON TABLE "public"."crew_routes" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."crew_routes" TO "service_role";
GRANT INSERT ON TABLE "public"."field_load_events" TO "postgres";
GRANT SELECT ON TABLE "public"."field_load_events" TO "postgres";
GRANT UPDATE ON TABLE "public"."field_load_events" TO "postgres";
GRANT DELETE ON TABLE "public"."field_load_events" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."field_load_events" TO "postgres";
GRANT REFERENCES ON TABLE "public"."field_load_events" TO "postgres";
GRANT TRIGGER ON TABLE "public"."field_load_events" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."field_load_events" TO "postgres";
GRANT INSERT ON TABLE "public"."field_load_events" TO "service_role";
GRANT SELECT ON TABLE "public"."field_load_events" TO "service_role";
GRANT UPDATE ON TABLE "public"."field_load_events" TO "service_role";
GRANT DELETE ON TABLE "public"."field_load_events" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."field_load_events" TO "service_role";
GRANT REFERENCES ON TABLE "public"."field_load_events" TO "service_role";
GRANT TRIGGER ON TABLE "public"."field_load_events" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."field_load_events" TO "service_role";
GRANT INSERT ON TABLE "public"."field_task_failure_events" TO "postgres";
GRANT SELECT ON TABLE "public"."field_task_failure_events" TO "postgres";
GRANT UPDATE ON TABLE "public"."field_task_failure_events" TO "postgres";
GRANT DELETE ON TABLE "public"."field_task_failure_events" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."field_task_failure_events" TO "postgres";
GRANT REFERENCES ON TABLE "public"."field_task_failure_events" TO "postgres";
GRANT TRIGGER ON TABLE "public"."field_task_failure_events" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."field_task_failure_events" TO "postgres";
GRANT INSERT ON TABLE "public"."field_task_failure_events" TO "service_role";
GRANT SELECT ON TABLE "public"."field_task_failure_events" TO "service_role";
GRANT UPDATE ON TABLE "public"."field_task_failure_events" TO "service_role";
GRANT DELETE ON TABLE "public"."field_task_failure_events" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."field_task_failure_events" TO "service_role";
GRANT REFERENCES ON TABLE "public"."field_task_failure_events" TO "service_role";
GRANT TRIGGER ON TABLE "public"."field_task_failure_events" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."field_task_failure_events" TO "service_role";
GRANT INSERT ON TABLE "public"."sync_conflicts" TO "postgres";
GRANT SELECT ON TABLE "public"."sync_conflicts" TO "postgres";
GRANT UPDATE ON TABLE "public"."sync_conflicts" TO "postgres";
GRANT DELETE ON TABLE "public"."sync_conflicts" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."sync_conflicts" TO "postgres";
GRANT REFERENCES ON TABLE "public"."sync_conflicts" TO "postgres";
GRANT TRIGGER ON TABLE "public"."sync_conflicts" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."sync_conflicts" TO "postgres";
GRANT INSERT ON TABLE "public"."sync_conflicts" TO "service_role";
GRANT SELECT ON TABLE "public"."sync_conflicts" TO "service_role";
GRANT UPDATE ON TABLE "public"."sync_conflicts" TO "service_role";
GRANT DELETE ON TABLE "public"."sync_conflicts" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."sync_conflicts" TO "service_role";
GRANT REFERENCES ON TABLE "public"."sync_conflicts" TO "service_role";
GRANT TRIGGER ON TABLE "public"."sync_conflicts" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."sync_conflicts" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."sweeper_audit_log_id_seq" TO "postgres";
GRANT UPDATE ON SEQUENCE "public"."sweeper_audit_log_id_seq" TO "postgres";
GRANT USAGE ON SEQUENCE "public"."sweeper_audit_log_id_seq" TO "postgres";
GRANT SELECT ON SEQUENCE "public"."sweeper_audit_log_id_seq" TO "anon";
GRANT UPDATE ON SEQUENCE "public"."sweeper_audit_log_id_seq" TO "anon";
GRANT USAGE ON SEQUENCE "public"."sweeper_audit_log_id_seq" TO "anon";
GRANT SELECT ON SEQUENCE "public"."sweeper_audit_log_id_seq" TO "authenticated";
GRANT UPDATE ON SEQUENCE "public"."sweeper_audit_log_id_seq" TO "authenticated";
GRANT USAGE ON SEQUENCE "public"."sweeper_audit_log_id_seq" TO "authenticated";
GRANT SELECT ON SEQUENCE "public"."sweeper_audit_log_id_seq" TO "service_role";
GRANT UPDATE ON SEQUENCE "public"."sweeper_audit_log_id_seq" TO "service_role";
GRANT USAGE ON SEQUENCE "public"."sweeper_audit_log_id_seq" TO "service_role";
GRANT INSERT ON TABLE "public"."work_time_configuration" TO "postgres";
GRANT SELECT ON TABLE "public"."work_time_configuration" TO "postgres";
GRANT UPDATE ON TABLE "public"."work_time_configuration" TO "postgres";
GRANT DELETE ON TABLE "public"."work_time_configuration" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."work_time_configuration" TO "postgres";
GRANT REFERENCES ON TABLE "public"."work_time_configuration" TO "postgres";
GRANT TRIGGER ON TABLE "public"."work_time_configuration" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."work_time_configuration" TO "postgres";
GRANT SELECT ON TABLE "public"."work_time_configuration" TO "anon";
GRANT MAINTAIN ON TABLE "public"."work_time_configuration" TO "anon";
GRANT SELECT ON TABLE "public"."work_time_configuration" TO "authenticated";
GRANT MAINTAIN ON TABLE "public"."work_time_configuration" TO "authenticated";
GRANT INSERT ON TABLE "public"."work_time_configuration" TO "service_role";
GRANT SELECT ON TABLE "public"."work_time_configuration" TO "service_role";
GRANT UPDATE ON TABLE "public"."work_time_configuration" TO "service_role";
GRANT DELETE ON TABLE "public"."work_time_configuration" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."work_time_configuration" TO "service_role";
GRANT REFERENCES ON TABLE "public"."work_time_configuration" TO "service_role";
GRANT TRIGGER ON TABLE "public"."work_time_configuration" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."work_time_configuration" TO "service_role";
GRANT INSERT ON TABLE "public"."sweeper_configuration" TO "postgres";
GRANT SELECT ON TABLE "public"."sweeper_configuration" TO "postgres";
GRANT UPDATE ON TABLE "public"."sweeper_configuration" TO "postgres";
GRANT DELETE ON TABLE "public"."sweeper_configuration" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."sweeper_configuration" TO "postgres";
GRANT REFERENCES ON TABLE "public"."sweeper_configuration" TO "postgres";
GRANT TRIGGER ON TABLE "public"."sweeper_configuration" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."sweeper_configuration" TO "postgres";
GRANT SELECT ON TABLE "public"."sweeper_configuration" TO "anon";
GRANT MAINTAIN ON TABLE "public"."sweeper_configuration" TO "anon";
GRANT SELECT ON TABLE "public"."sweeper_configuration" TO "authenticated";
GRANT MAINTAIN ON TABLE "public"."sweeper_configuration" TO "authenticated";
GRANT INSERT ON TABLE "public"."sweeper_configuration" TO "service_role";
GRANT SELECT ON TABLE "public"."sweeper_configuration" TO "service_role";
GRANT UPDATE ON TABLE "public"."sweeper_configuration" TO "service_role";
GRANT DELETE ON TABLE "public"."sweeper_configuration" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."sweeper_configuration" TO "service_role";
GRANT REFERENCES ON TABLE "public"."sweeper_configuration" TO "service_role";
GRANT TRIGGER ON TABLE "public"."sweeper_configuration" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."sweeper_configuration" TO "service_role";
GRANT INSERT ON TABLE "public"."sweeper_audit_log" TO "postgres";
GRANT SELECT ON TABLE "public"."sweeper_audit_log" TO "postgres";
GRANT UPDATE ON TABLE "public"."sweeper_audit_log" TO "postgres";
GRANT DELETE ON TABLE "public"."sweeper_audit_log" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."sweeper_audit_log" TO "postgres";
GRANT REFERENCES ON TABLE "public"."sweeper_audit_log" TO "postgres";
GRANT TRIGGER ON TABLE "public"."sweeper_audit_log" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."sweeper_audit_log" TO "postgres";
GRANT INSERT ON TABLE "public"."sweeper_audit_log" TO "service_role";
GRANT SELECT ON TABLE "public"."sweeper_audit_log" TO "service_role";
GRANT UPDATE ON TABLE "public"."sweeper_audit_log" TO "service_role";
GRANT DELETE ON TABLE "public"."sweeper_audit_log" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."sweeper_audit_log" TO "service_role";
GRANT REFERENCES ON TABLE "public"."sweeper_audit_log" TO "service_role";
GRANT TRIGGER ON TABLE "public"."sweeper_audit_log" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."sweeper_audit_log" TO "service_role";
GRANT INSERT ON TABLE "workflow_private"."report_barangay_reconciliation_log" TO "postgres";
GRANT SELECT ON TABLE "workflow_private"."report_barangay_reconciliation_log" TO "postgres";
GRANT UPDATE ON TABLE "workflow_private"."report_barangay_reconciliation_log" TO "postgres";
GRANT DELETE ON TABLE "workflow_private"."report_barangay_reconciliation_log" TO "postgres";
GRANT TRUNCATE ON TABLE "workflow_private"."report_barangay_reconciliation_log" TO "postgres";
GRANT REFERENCES ON TABLE "workflow_private"."report_barangay_reconciliation_log" TO "postgres";
GRANT TRIGGER ON TABLE "workflow_private"."report_barangay_reconciliation_log" TO "postgres";
GRANT MAINTAIN ON TABLE "workflow_private"."report_barangay_reconciliation_log" TO "postgres";
GRANT SELECT ON TABLE "workflow_private"."report_barangay_reconciliation_log" TO "service_role";
GRANT INSERT ON TABLE "workflow_private"."unprocessed_escalation_baseline" TO "postgres";
GRANT SELECT ON TABLE "workflow_private"."unprocessed_escalation_baseline" TO "postgres";
GRANT UPDATE ON TABLE "workflow_private"."unprocessed_escalation_baseline" TO "postgres";
GRANT DELETE ON TABLE "workflow_private"."unprocessed_escalation_baseline" TO "postgres";
GRANT TRUNCATE ON TABLE "workflow_private"."unprocessed_escalation_baseline" TO "postgres";
GRANT REFERENCES ON TABLE "workflow_private"."unprocessed_escalation_baseline" TO "postgres";
GRANT TRIGGER ON TABLE "workflow_private"."unprocessed_escalation_baseline" TO "postgres";
GRANT MAINTAIN ON TABLE "workflow_private"."unprocessed_escalation_baseline" TO "postgres";
GRANT SELECT ON TABLE "workflow_private"."unprocessed_escalation_baseline" TO "service_role";
GRANT INSERT ON TABLE "public"."clusters" TO "postgres";
GRANT SELECT ON TABLE "public"."clusters" TO "postgres";
GRANT UPDATE ON TABLE "public"."clusters" TO "postgres";
GRANT DELETE ON TABLE "public"."clusters" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."clusters" TO "postgres";
GRANT REFERENCES ON TABLE "public"."clusters" TO "postgres";
GRANT TRIGGER ON TABLE "public"."clusters" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."clusters" TO "postgres";
GRANT SELECT ON TABLE "public"."clusters" TO "anon";
GRANT MAINTAIN ON TABLE "public"."clusters" TO "anon";
GRANT SELECT ON TABLE "public"."clusters" TO "authenticated";
GRANT MAINTAIN ON TABLE "public"."clusters" TO "authenticated";
GRANT INSERT ON TABLE "public"."clusters" TO "service_role";
GRANT SELECT ON TABLE "public"."clusters" TO "service_role";
GRANT UPDATE ON TABLE "public"."clusters" TO "service_role";
GRANT DELETE ON TABLE "public"."clusters" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."clusters" TO "service_role";
GRANT REFERENCES ON TABLE "public"."clusters" TO "service_role";
GRANT TRIGGER ON TABLE "public"."clusters" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."clusters" TO "service_role";
GRANT INSERT ON TABLE "public"."strikes" TO "postgres";
GRANT SELECT ON TABLE "public"."strikes" TO "postgres";
GRANT UPDATE ON TABLE "public"."strikes" TO "postgres";
GRANT DELETE ON TABLE "public"."strikes" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."strikes" TO "postgres";
GRANT REFERENCES ON TABLE "public"."strikes" TO "postgres";
GRANT TRIGGER ON TABLE "public"."strikes" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."strikes" TO "postgres";
GRANT INSERT ON TABLE "public"."strikes" TO "service_role";
GRANT SELECT ON TABLE "public"."strikes" TO "service_role";
GRANT UPDATE ON TABLE "public"."strikes" TO "service_role";
GRANT DELETE ON TABLE "public"."strikes" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."strikes" TO "service_role";
GRANT REFERENCES ON TABLE "public"."strikes" TO "service_role";
GRANT TRIGGER ON TABLE "public"."strikes" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."strikes" TO "service_role";
GRANT INSERT ON TABLE "privacy_private"."hidden_report_owners" TO "postgres";
GRANT SELECT ON TABLE "privacy_private"."hidden_report_owners" TO "postgres";
GRANT UPDATE ON TABLE "privacy_private"."hidden_report_owners" TO "postgres";
GRANT DELETE ON TABLE "privacy_private"."hidden_report_owners" TO "postgres";
GRANT TRUNCATE ON TABLE "privacy_private"."hidden_report_owners" TO "postgres";
GRANT REFERENCES ON TABLE "privacy_private"."hidden_report_owners" TO "postgres";
GRANT TRIGGER ON TABLE "privacy_private"."hidden_report_owners" TO "postgres";
GRANT MAINTAIN ON TABLE "privacy_private"."hidden_report_owners" TO "postgres";
GRANT SELECT ON TABLE "privacy_private"."hidden_report_owners" TO "service_role";
GRANT SELECT ON TABLE "privacy_private"."hidden_report_owners" TO "ecopin_operational_reader";
GRANT INSERT ON TABLE "privacy_private"."hidden_report_artifacts" TO "postgres";
GRANT SELECT ON TABLE "privacy_private"."hidden_report_artifacts" TO "postgres";
GRANT UPDATE ON TABLE "privacy_private"."hidden_report_artifacts" TO "postgres";
GRANT DELETE ON TABLE "privacy_private"."hidden_report_artifacts" TO "postgres";
GRANT TRUNCATE ON TABLE "privacy_private"."hidden_report_artifacts" TO "postgres";
GRANT REFERENCES ON TABLE "privacy_private"."hidden_report_artifacts" TO "postgres";
GRANT TRIGGER ON TABLE "privacy_private"."hidden_report_artifacts" TO "postgres";
GRANT MAINTAIN ON TABLE "privacy_private"."hidden_report_artifacts" TO "postgres";
GRANT SELECT ON TABLE "privacy_private"."hidden_report_artifacts" TO "service_role";
GRANT SELECT ON TABLE "privacy_private"."hidden_report_artifacts" TO "ecopin_operational_reader";
GRANT INSERT ON TABLE "public"."reports_view" TO "ecopin_operational_reader";
GRANT SELECT ON TABLE "public"."reports_view" TO "ecopin_operational_reader";
GRANT UPDATE ON TABLE "public"."reports_view" TO "ecopin_operational_reader";
GRANT DELETE ON TABLE "public"."reports_view" TO "ecopin_operational_reader";
GRANT TRUNCATE ON TABLE "public"."reports_view" TO "ecopin_operational_reader";
GRANT REFERENCES ON TABLE "public"."reports_view" TO "ecopin_operational_reader";
GRANT TRIGGER ON TABLE "public"."reports_view" TO "ecopin_operational_reader";
GRANT MAINTAIN ON TABLE "public"."reports_view" TO "ecopin_operational_reader";
GRANT INSERT ON TABLE "public"."reports_view" TO "authenticated";
GRANT SELECT ON TABLE "public"."reports_view" TO "authenticated";
GRANT UPDATE ON TABLE "public"."reports_view" TO "authenticated";
GRANT DELETE ON TABLE "public"."reports_view" TO "authenticated";
GRANT TRUNCATE ON TABLE "public"."reports_view" TO "authenticated";
GRANT REFERENCES ON TABLE "public"."reports_view" TO "authenticated";
GRANT TRIGGER ON TABLE "public"."reports_view" TO "authenticated";
GRANT MAINTAIN ON TABLE "public"."reports_view" TO "authenticated";
GRANT INSERT ON TABLE "public"."reports_view" TO "service_role";
GRANT SELECT ON TABLE "public"."reports_view" TO "service_role";
GRANT UPDATE ON TABLE "public"."reports_view" TO "service_role";
GRANT DELETE ON TABLE "public"."reports_view" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."reports_view" TO "service_role";
GRANT REFERENCES ON TABLE "public"."reports_view" TO "service_role";
GRANT TRIGGER ON TABLE "public"."reports_view" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."reports_view" TO "service_role";
GRANT INSERT ON TABLE "public"."report_activity_view" TO "ecopin_operational_reader";
GRANT SELECT ON TABLE "public"."report_activity_view" TO "ecopin_operational_reader";
GRANT UPDATE ON TABLE "public"."report_activity_view" TO "ecopin_operational_reader";
GRANT DELETE ON TABLE "public"."report_activity_view" TO "ecopin_operational_reader";
GRANT TRUNCATE ON TABLE "public"."report_activity_view" TO "ecopin_operational_reader";
GRANT REFERENCES ON TABLE "public"."report_activity_view" TO "ecopin_operational_reader";
GRANT TRIGGER ON TABLE "public"."report_activity_view" TO "ecopin_operational_reader";
GRANT MAINTAIN ON TABLE "public"."report_activity_view" TO "ecopin_operational_reader";
GRANT INSERT ON TABLE "public"."report_activity_view" TO "authenticated";
GRANT SELECT ON TABLE "public"."report_activity_view" TO "authenticated";
GRANT UPDATE ON TABLE "public"."report_activity_view" TO "authenticated";
GRANT DELETE ON TABLE "public"."report_activity_view" TO "authenticated";
GRANT TRUNCATE ON TABLE "public"."report_activity_view" TO "authenticated";
GRANT REFERENCES ON TABLE "public"."report_activity_view" TO "authenticated";
GRANT TRIGGER ON TABLE "public"."report_activity_view" TO "authenticated";
GRANT MAINTAIN ON TABLE "public"."report_activity_view" TO "authenticated";
GRANT INSERT ON TABLE "public"."report_activity_view" TO "service_role";
GRANT SELECT ON TABLE "public"."report_activity_view" TO "service_role";
GRANT UPDATE ON TABLE "public"."report_activity_view" TO "service_role";
GRANT DELETE ON TABLE "public"."report_activity_view" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."report_activity_view" TO "service_role";
GRANT REFERENCES ON TABLE "public"."report_activity_view" TO "service_role";
GRANT TRIGGER ON TABLE "public"."report_activity_view" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."report_activity_view" TO "service_role";
GRANT INSERT ON TABLE "public"."staff_visible_strikes" TO "postgres";
GRANT SELECT ON TABLE "public"."staff_visible_strikes" TO "postgres";
GRANT UPDATE ON TABLE "public"."staff_visible_strikes" TO "postgres";
GRANT DELETE ON TABLE "public"."staff_visible_strikes" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."staff_visible_strikes" TO "postgres";
GRANT REFERENCES ON TABLE "public"."staff_visible_strikes" TO "postgres";
GRANT TRIGGER ON TABLE "public"."staff_visible_strikes" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."staff_visible_strikes" TO "postgres";
GRANT INSERT ON TABLE "public"."staff_visible_strikes" TO "service_role";
GRANT SELECT ON TABLE "public"."staff_visible_strikes" TO "service_role";
GRANT UPDATE ON TABLE "public"."staff_visible_strikes" TO "service_role";
GRANT DELETE ON TABLE "public"."staff_visible_strikes" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."staff_visible_strikes" TO "service_role";
GRANT REFERENCES ON TABLE "public"."staff_visible_strikes" TO "service_role";
GRANT TRIGGER ON TABLE "public"."staff_visible_strikes" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."staff_visible_strikes" TO "service_role";
GRANT INSERT ON TABLE "public"."cleanup_proof_publications" TO "postgres";
GRANT SELECT ON TABLE "public"."cleanup_proof_publications" TO "postgres";
GRANT UPDATE ON TABLE "public"."cleanup_proof_publications" TO "postgres";
GRANT DELETE ON TABLE "public"."cleanup_proof_publications" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."cleanup_proof_publications" TO "postgres";
GRANT REFERENCES ON TABLE "public"."cleanup_proof_publications" TO "postgres";
GRANT TRIGGER ON TABLE "public"."cleanup_proof_publications" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."cleanup_proof_publications" TO "postgres";
GRANT INSERT ON TABLE "public"."cleanup_proof_publications" TO "service_role";
GRANT SELECT ON TABLE "public"."cleanup_proof_publications" TO "service_role";
GRANT UPDATE ON TABLE "public"."cleanup_proof_publications" TO "service_role";
GRANT DELETE ON TABLE "public"."cleanup_proof_publications" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."cleanup_proof_publications" TO "service_role";
GRANT REFERENCES ON TABLE "public"."cleanup_proof_publications" TO "service_role";
GRANT TRIGGER ON TABLE "public"."cleanup_proof_publications" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."cleanup_proof_publications" TO "service_role";
GRANT INSERT ON TABLE "public"."zone_weekly_report_history" TO "postgres";
GRANT SELECT ON TABLE "public"."zone_weekly_report_history" TO "postgres";
GRANT UPDATE ON TABLE "public"."zone_weekly_report_history" TO "postgres";
GRANT DELETE ON TABLE "public"."zone_weekly_report_history" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."zone_weekly_report_history" TO "postgres";
GRANT REFERENCES ON TABLE "public"."zone_weekly_report_history" TO "postgres";
GRANT TRIGGER ON TABLE "public"."zone_weekly_report_history" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."zone_weekly_report_history" TO "postgres";
GRANT INSERT ON TABLE "public"."zone_weekly_report_history" TO "service_role";
GRANT SELECT ON TABLE "public"."zone_weekly_report_history" TO "service_role";
GRANT UPDATE ON TABLE "public"."zone_weekly_report_history" TO "service_role";
GRANT DELETE ON TABLE "public"."zone_weekly_report_history" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."zone_weekly_report_history" TO "service_role";
GRANT REFERENCES ON TABLE "public"."zone_weekly_report_history" TO "service_role";
GRANT TRIGGER ON TABLE "public"."zone_weekly_report_history" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."zone_weekly_report_history" TO "service_role";
GRANT INSERT ON TABLE "public"."spatial_zones" TO "postgres";
GRANT SELECT ON TABLE "public"."spatial_zones" TO "postgres";
GRANT UPDATE ON TABLE "public"."spatial_zones" TO "postgres";
GRANT DELETE ON TABLE "public"."spatial_zones" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."spatial_zones" TO "postgres";
GRANT REFERENCES ON TABLE "public"."spatial_zones" TO "postgres";
GRANT TRIGGER ON TABLE "public"."spatial_zones" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."spatial_zones" TO "postgres";
GRANT INSERT ON TABLE "public"."spatial_zones" TO "service_role";
GRANT SELECT ON TABLE "public"."spatial_zones" TO "service_role";
GRANT UPDATE ON TABLE "public"."spatial_zones" TO "service_role";
GRANT DELETE ON TABLE "public"."spatial_zones" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."spatial_zones" TO "service_role";
GRANT REFERENCES ON TABLE "public"."spatial_zones" TO "service_role";
GRANT TRIGGER ON TABLE "public"."spatial_zones" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."spatial_zones" TO "service_role";
GRANT INSERT ON TABLE "public"."hotspot_predictions" TO "postgres";
GRANT SELECT ON TABLE "public"."hotspot_predictions" TO "postgres";
GRANT UPDATE ON TABLE "public"."hotspot_predictions" TO "postgres";
GRANT DELETE ON TABLE "public"."hotspot_predictions" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."hotspot_predictions" TO "postgres";
GRANT REFERENCES ON TABLE "public"."hotspot_predictions" TO "postgres";
GRANT TRIGGER ON TABLE "public"."hotspot_predictions" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."hotspot_predictions" TO "postgres";
GRANT INSERT ON TABLE "public"."hotspot_predictions" TO "service_role";
GRANT SELECT ON TABLE "public"."hotspot_predictions" TO "service_role";
GRANT UPDATE ON TABLE "public"."hotspot_predictions" TO "service_role";
GRANT DELETE ON TABLE "public"."hotspot_predictions" TO "service_role";
GRANT TRUNCATE ON TABLE "public"."hotspot_predictions" TO "service_role";
GRANT REFERENCES ON TABLE "public"."hotspot_predictions" TO "service_role";
GRANT TRIGGER ON TABLE "public"."hotspot_predictions" TO "service_role";
GRANT MAINTAIN ON TABLE "public"."hotspot_predictions" TO "service_role";
GRANT INSERT ON TABLE "public"."operational_events" TO "postgres";
GRANT SELECT ON TABLE "public"."operational_events" TO "postgres";
GRANT UPDATE ON TABLE "public"."operational_events" TO "postgres";
GRANT DELETE ON TABLE "public"."operational_events" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."operational_events" TO "postgres";
GRANT REFERENCES ON TABLE "public"."operational_events" TO "postgres";
GRANT TRIGGER ON TABLE "public"."operational_events" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."operational_events" TO "postgres";
GRANT INSERT ON TABLE "public"."operational_events" TO "service_role";
GRANT SELECT ON TABLE "public"."operational_events" TO "service_role";
GRANT INSERT ON TABLE "public"."citizen_trust" TO "postgres";
GRANT SELECT ON TABLE "public"."citizen_trust" TO "postgres";
GRANT UPDATE ON TABLE "public"."citizen_trust" TO "postgres";
GRANT DELETE ON TABLE "public"."citizen_trust" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."citizen_trust" TO "postgres";
GRANT REFERENCES ON TABLE "public"."citizen_trust" TO "postgres";
GRANT TRIGGER ON TABLE "public"."citizen_trust" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."citizen_trust" TO "postgres";
GRANT INSERT ON TABLE "public"."citizen_trust" TO "service_role";
GRANT SELECT ON TABLE "public"."citizen_trust" TO "service_role";
GRANT UPDATE ON TABLE "public"."citizen_trust" TO "service_role";
GRANT INSERT ON TABLE "public"."citizen_trust_decisions" TO "postgres";
GRANT SELECT ON TABLE "public"."citizen_trust_decisions" TO "postgres";
GRANT UPDATE ON TABLE "public"."citizen_trust_decisions" TO "postgres";
GRANT DELETE ON TABLE "public"."citizen_trust_decisions" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."citizen_trust_decisions" TO "postgres";
GRANT REFERENCES ON TABLE "public"."citizen_trust_decisions" TO "postgres";
GRANT TRIGGER ON TABLE "public"."citizen_trust_decisions" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."citizen_trust_decisions" TO "postgres";
GRANT INSERT ON TABLE "public"."citizen_trust_decisions" TO "service_role";
GRANT SELECT ON TABLE "public"."citizen_trust_decisions" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."citizen_trust_decisions_id_seq" TO "postgres";
GRANT UPDATE ON SEQUENCE "public"."citizen_trust_decisions_id_seq" TO "postgres";
GRANT USAGE ON SEQUENCE "public"."citizen_trust_decisions_id_seq" TO "postgres";
GRANT SELECT ON SEQUENCE "public"."citizen_trust_decisions_id_seq" TO "anon";
GRANT UPDATE ON SEQUENCE "public"."citizen_trust_decisions_id_seq" TO "anon";
GRANT USAGE ON SEQUENCE "public"."citizen_trust_decisions_id_seq" TO "anon";
GRANT SELECT ON SEQUENCE "public"."citizen_trust_decisions_id_seq" TO "authenticated";
GRANT UPDATE ON SEQUENCE "public"."citizen_trust_decisions_id_seq" TO "authenticated";
GRANT USAGE ON SEQUENCE "public"."citizen_trust_decisions_id_seq" TO "authenticated";
GRANT SELECT ON SEQUENCE "public"."citizen_trust_decisions_id_seq" TO "service_role";
GRANT UPDATE ON SEQUENCE "public"."citizen_trust_decisions_id_seq" TO "service_role";
GRANT USAGE ON SEQUENCE "public"."citizen_trust_decisions_id_seq" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."operational_events_id_seq" TO "postgres";
GRANT UPDATE ON SEQUENCE "public"."operational_events_id_seq" TO "postgres";
GRANT USAGE ON SEQUENCE "public"."operational_events_id_seq" TO "postgres";
GRANT SELECT ON SEQUENCE "public"."operational_events_id_seq" TO "anon";
GRANT UPDATE ON SEQUENCE "public"."operational_events_id_seq" TO "anon";
GRANT USAGE ON SEQUENCE "public"."operational_events_id_seq" TO "anon";
GRANT SELECT ON SEQUENCE "public"."operational_events_id_seq" TO "authenticated";
GRANT UPDATE ON SEQUENCE "public"."operational_events_id_seq" TO "authenticated";
GRANT USAGE ON SEQUENCE "public"."operational_events_id_seq" TO "authenticated";
GRANT SELECT ON SEQUENCE "public"."operational_events_id_seq" TO "service_role";
GRANT UPDATE ON SEQUENCE "public"."operational_events_id_seq" TO "service_role";
GRANT USAGE ON SEQUENCE "public"."operational_events_id_seq" TO "service_role";
GRANT INSERT ON TABLE "workflow_private"."unprocessed_alert_deliveries" TO "postgres";
GRANT SELECT ON TABLE "workflow_private"."unprocessed_alert_deliveries" TO "postgres";
GRANT UPDATE ON TABLE "workflow_private"."unprocessed_alert_deliveries" TO "postgres";
GRANT DELETE ON TABLE "workflow_private"."unprocessed_alert_deliveries" TO "postgres";
GRANT TRUNCATE ON TABLE "workflow_private"."unprocessed_alert_deliveries" TO "postgres";
GRANT REFERENCES ON TABLE "workflow_private"."unprocessed_alert_deliveries" TO "postgres";
GRANT TRIGGER ON TABLE "workflow_private"."unprocessed_alert_deliveries" TO "postgres";
GRANT MAINTAIN ON TABLE "workflow_private"."unprocessed_alert_deliveries" TO "postgres";
GRANT INSERT ON TABLE "workflow_private"."unprocessed_alert_deliveries" TO "service_role";
GRANT SELECT ON TABLE "workflow_private"."unprocessed_alert_deliveries" TO "service_role";
GRANT INSERT ON TABLE "workflow_private"."lifecycle_deployment" TO "postgres";
GRANT SELECT ON TABLE "workflow_private"."lifecycle_deployment" TO "postgres";
GRANT UPDATE ON TABLE "workflow_private"."lifecycle_deployment" TO "postgres";
GRANT DELETE ON TABLE "workflow_private"."lifecycle_deployment" TO "postgres";
GRANT TRUNCATE ON TABLE "workflow_private"."lifecycle_deployment" TO "postgres";
GRANT REFERENCES ON TABLE "workflow_private"."lifecycle_deployment" TO "postgres";
GRANT TRIGGER ON TABLE "workflow_private"."lifecycle_deployment" TO "postgres";
GRANT MAINTAIN ON TABLE "workflow_private"."lifecycle_deployment" TO "postgres";
GRANT INSERT ON TABLE "workflow_private"."lifecycle_deployment" TO "service_role";
GRANT SELECT ON TABLE "workflow_private"."lifecycle_deployment" TO "service_role";
GRANT UPDATE ON TABLE "workflow_private"."lifecycle_deployment" TO "service_role";
GRANT DELETE ON TABLE "workflow_private"."lifecycle_deployment" TO "service_role";
GRANT TRUNCATE ON TABLE "workflow_private"."lifecycle_deployment" TO "service_role";
GRANT REFERENCES ON TABLE "workflow_private"."lifecycle_deployment" TO "service_role";
GRANT TRIGGER ON TABLE "workflow_private"."lifecycle_deployment" TO "service_role";
GRANT MAINTAIN ON TABLE "workflow_private"."lifecycle_deployment" TO "service_role";
GRANT INSERT ON TABLE "workflow_private"."historical_sla_reset" TO "postgres";
GRANT SELECT ON TABLE "workflow_private"."historical_sla_reset" TO "postgres";
GRANT UPDATE ON TABLE "workflow_private"."historical_sla_reset" TO "postgres";
GRANT DELETE ON TABLE "workflow_private"."historical_sla_reset" TO "postgres";
GRANT TRUNCATE ON TABLE "workflow_private"."historical_sla_reset" TO "postgres";
GRANT REFERENCES ON TABLE "workflow_private"."historical_sla_reset" TO "postgres";
GRANT TRIGGER ON TABLE "workflow_private"."historical_sla_reset" TO "postgres";
GRANT MAINTAIN ON TABLE "workflow_private"."historical_sla_reset" TO "postgres";
GRANT INSERT ON TABLE "workflow_private"."historical_sla_reset" TO "service_role";
GRANT SELECT ON TABLE "workflow_private"."historical_sla_reset" TO "service_role";
GRANT UPDATE ON TABLE "workflow_private"."historical_sla_reset" TO "service_role";
GRANT DELETE ON TABLE "workflow_private"."historical_sla_reset" TO "service_role";
GRANT TRUNCATE ON TABLE "workflow_private"."historical_sla_reset" TO "service_role";
GRANT REFERENCES ON TABLE "workflow_private"."historical_sla_reset" TO "service_role";
GRANT TRIGGER ON TABLE "workflow_private"."historical_sla_reset" TO "service_role";
GRANT MAINTAIN ON TABLE "workflow_private"."historical_sla_reset" TO "service_role";
GRANT INSERT ON TABLE "workflow_private"."unprocessed_report_alerts" TO "postgres";
GRANT SELECT ON TABLE "workflow_private"."unprocessed_report_alerts" TO "postgres";
GRANT UPDATE ON TABLE "workflow_private"."unprocessed_report_alerts" TO "postgres";
GRANT DELETE ON TABLE "workflow_private"."unprocessed_report_alerts" TO "postgres";
GRANT TRUNCATE ON TABLE "workflow_private"."unprocessed_report_alerts" TO "postgres";
GRANT REFERENCES ON TABLE "workflow_private"."unprocessed_report_alerts" TO "postgres";
GRANT TRIGGER ON TABLE "workflow_private"."unprocessed_report_alerts" TO "postgres";
GRANT MAINTAIN ON TABLE "workflow_private"."unprocessed_report_alerts" TO "postgres";
GRANT SELECT ON TABLE "workflow_private"."unprocessed_report_alerts" TO "service_role";
GRANT INSERT ON TABLE "public"."report_urgency_decisions" TO "postgres";
GRANT SELECT ON TABLE "public"."report_urgency_decisions" TO "postgres";
GRANT UPDATE ON TABLE "public"."report_urgency_decisions" TO "postgres";
GRANT DELETE ON TABLE "public"."report_urgency_decisions" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."report_urgency_decisions" TO "postgres";
GRANT REFERENCES ON TABLE "public"."report_urgency_decisions" TO "postgres";
GRANT TRIGGER ON TABLE "public"."report_urgency_decisions" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."report_urgency_decisions" TO "postgres";
GRANT INSERT ON TABLE "public"."report_urgency_decisions" TO "service_role";
GRANT SELECT ON TABLE "public"."report_urgency_decisions" TO "service_role";
GRANT INSERT ON TABLE "public"."report_urgency_alerts" TO "postgres";
GRANT SELECT ON TABLE "public"."report_urgency_alerts" TO "postgres";
GRANT UPDATE ON TABLE "public"."report_urgency_alerts" TO "postgres";
GRANT DELETE ON TABLE "public"."report_urgency_alerts" TO "postgres";
GRANT TRUNCATE ON TABLE "public"."report_urgency_alerts" TO "postgres";
GRANT REFERENCES ON TABLE "public"."report_urgency_alerts" TO "postgres";
GRANT TRIGGER ON TABLE "public"."report_urgency_alerts" TO "postgres";
GRANT MAINTAIN ON TABLE "public"."report_urgency_alerts" TO "postgres";
GRANT INSERT ON TABLE "public"."report_urgency_alerts" TO "service_role";
GRANT SELECT ON TABLE "public"."report_urgency_alerts" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."report_urgency_decisions_sequence_seq" TO "postgres";
GRANT UPDATE ON SEQUENCE "public"."report_urgency_decisions_sequence_seq" TO "postgres";
GRANT USAGE ON SEQUENCE "public"."report_urgency_decisions_sequence_seq" TO "postgres";
GRANT SELECT ON SEQUENCE "public"."report_urgency_decisions_sequence_seq" TO "anon";
GRANT UPDATE ON SEQUENCE "public"."report_urgency_decisions_sequence_seq" TO "anon";
GRANT USAGE ON SEQUENCE "public"."report_urgency_decisions_sequence_seq" TO "anon";
GRANT SELECT ON SEQUENCE "public"."report_urgency_decisions_sequence_seq" TO "authenticated";
GRANT UPDATE ON SEQUENCE "public"."report_urgency_decisions_sequence_seq" TO "authenticated";
GRANT USAGE ON SEQUENCE "public"."report_urgency_decisions_sequence_seq" TO "authenticated";
GRANT SELECT ON SEQUENCE "public"."report_urgency_decisions_sequence_seq" TO "service_role";
GRANT UPDATE ON SEQUENCE "public"."report_urgency_decisions_sequence_seq" TO "service_role";
GRANT USAGE ON SEQUENCE "public"."report_urgency_decisions_sequence_seq" TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."publish_mixed_dispatch_routes"(plan_id uuid, actor uuid, token uuid, routes jsonb, depot jsonb) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."publish_mixed_dispatch_routes"(plan_id uuid, actor uuid, token uuid, routes jsonb, depot jsonb) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."upsert_cluster_for_reports_old"(p_report_ids uuid[], p_issue_type text, p_severity text, p_radius_meters double precision) TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."guard_cluster_block"() TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."guard_cluster_block"() TO "service_role";
GRANT EXECUTE ON FUNCTION "workflow_private"."bump_report_claim_generation"() TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."bump_report_claim_generation"() TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."authorize_citizen_trust_review"(actor uuid, report_id uuid) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."authorize_citizen_trust_review"(actor uuid, report_id uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."apply_fc_operation"(actor uuid, operation_id text, operation_type text, entity_id uuid, entity_type text, payload jsonb, base_version bigint) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."apply_fc_operation"(actor uuid, operation_id text, operation_type text, entity_id uuid, entity_type text, payload jsonb, base_version bigint) TO "service_role";
GRANT EXECUTE ON FUNCTION "workflow_private"."can_execute_task"(actor uuid, task cleanup_tasks) TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."can_execute_task"(actor uuid, task cleanup_tasks) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."get_barangay_operational_analytics"(actor uuid, start_month date, end_month date) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."get_barangay_operational_analytics"(actor uuid, start_month date, end_month date) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."read_authorized_report_detail"(actor uuid, report_id uuid) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."read_authorized_report_detail"(actor uuid, report_id uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."read_hotspot_pattern_history"(p_max_reports integer) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."read_hotspot_pattern_history"(p_max_reports integer) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."clear_dispatch_block"(block_id uuid, actor uuid, notes text) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."clear_dispatch_block"(block_id uuid, actor uuid, notes text) TO "service_role";
GRANT EXECUTE ON FUNCTION "operational_private"."emit"(kind text, task uuid, report uuid, actor uuid, generation bigint, stamp timestamp with time zone, basis text, dedupe text, metadata jsonb) TO "postgres";
GRANT EXECUTE ON FUNCTION "operational_private"."emit"(kind text, task uuid, report uuid, actor uuid, generation bigint, stamp timestamp with time zone, basis text, dedupe text, metadata jsonb) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."begin_plan_routing"(plan_id uuid, actor uuid) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."begin_plan_routing"(plan_id uuid, actor uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."check_overdue_reports"() TO PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."check_overdue_reports"() TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."check_overdue_reports"() TO "anon";
GRANT EXECUTE ON FUNCTION "public"."check_overdue_reports"() TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."check_overdue_reports"() TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."finish_plan_routing"(plan_id uuid, actor uuid, token uuid, failure text) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."finish_plan_routing"(plan_id uuid, actor uuid, token uuid, failure text) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."task_coordinates"(task_ids uuid[]) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."task_coordinates"(task_ids uuid[]) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."publish_dispatch_routes"(plan_id uuid, actor uuid, token uuid, routes jsonb, depot jsonb) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."publish_dispatch_routes"(plan_id uuid, actor uuid, token uuid, routes jsonb, depot jsonb) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."set_report_photo"(report_id uuid, actor uuid, slot text, url text, photo_hash text, expected_version bigint) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."set_report_photo"(report_id uuid, actor uuid, slot text, url text, photo_hash text, expected_version bigint) TO "service_role";
GRANT EXECUTE ON FUNCTION "workflow_private"."issue_task_report_receipts"() TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."issue_task_report_receipts"() TO "service_role";
GRANT EXECUTE ON FUNCTION "operational_private"."row_context"() TO "postgres";
GRANT EXECUTE ON FUNCTION "operational_private"."row_context"() TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."support_ticket_json"(t support_tickets, staff boolean) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."support_ticket_json"(t support_tickets, staff boolean) TO "service_role";
GRANT EXECUTE ON FUNCTION "operational_private"."capture_receipt"() TO "postgres";
GRANT EXECUTE ON FUNCTION "operational_private"."capture_receipt"() TO "service_role";
GRANT EXECUTE ON FUNCTION "operational_private"."set_context"(actor uuid, payload jsonb) TO "postgres";
GRANT EXECUTE ON FUNCTION "operational_private"."set_context"(actor uuid, payload jsonb) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."complete_email_verification"(p_verification_id uuid, p_user_id uuid) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."complete_email_verification"(p_verification_id uuid, p_user_id uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION "workflow_private"."lifecycle_config"() TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."lifecycle_config"() TO "service_role";
GRANT EXECUTE ON FUNCTION "workflow_private"."derive_report_lifecycle"(report_status text, cluster uuid, task uuid, clock_start timestamp with time zone, deadline timestamp with time zone, maturation_hours numeric, at_time timestamp with time zone) TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."derive_report_lifecycle"(report_status text, cluster uuid, task uuid, clock_start timestamp with time zone, deadline timestamp with time zone, maturation_hours numeric, at_time timestamp with time zone) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."read_incident_case_record"(actor uuid, incident_id uuid) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."read_incident_case_record"(actor uuid, incident_id uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."calculate_report_deadline"() TO PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."calculate_report_deadline"() TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."calculate_report_deadline"() TO "anon";
GRANT EXECUTE ON FUNCTION "public"."calculate_report_deadline"() TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."calculate_report_deadline"() TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."count_recent_nearby_reports"(p_lon double precision, p_lat double precision, p_radius_meters double precision, p_days integer) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."count_recent_nearby_reports"(p_lon double precision, p_lat double precision, p_radius_meters double precision, p_days integer) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."nextval"(seq_name text) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."nextval"(seq_name text) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."reconcile_report_outcome"(actor uuid, operation_id text, payload jsonb) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."reconcile_report_outcome"(actor uuid, operation_id text, payload jsonb) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."create_manual_cleanup_task"(actor uuid, selected_report_ids uuid[], task_title text, task_description text, crew_member_ids uuid[], task_priority text) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."create_manual_cleanup_task"(actor uuid, selected_report_ids uuid[], task_title text, task_description text, crew_member_ids uuid[], task_priority text) TO "service_role";
GRANT EXECUTE ON FUNCTION "workflow_private"."audit_report_lifecycle"() TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."audit_report_lifecycle"() TO "service_role";
GRANT EXECUTE ON FUNCTION "workflow_private"."issue_report_claim_receipts"() TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."issue_report_claim_receipts"() TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."handle_new_user"() TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."handle_new_user"() TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."handle_report_status_change"() TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."handle_report_status_change"() TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."commit_dispatch_plan"(plan_id uuid, actor uuid) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."commit_dispatch_plan"(plan_id uuid, actor uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."save_dispatch_plan"(actor uuid, plan_mode text, settings jsonb, items jsonb, available_crews integer, capacity_minutes integer) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."save_dispatch_plan"(actor uuid, plan_mode text, settings jsonb, items jsonb, available_crews integer, capacity_minutes integer) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."update_updated_at_column"() TO PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."update_updated_at_column"() TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."update_updated_at_column"() TO "anon";
GRANT EXECUTE ON FUNCTION "public"."update_updated_at_column"() TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."update_updated_at_column"() TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."upsert_cluster_for_reports"(p_report_ids uuid[], p_issue_type text, p_severity text, p_radius_meters numeric) TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."validate_lifecycle_config"() TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."validate_lifecycle_config"() TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."get_auth_user_role"() TO PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."get_auth_user_role"() TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."get_auth_user_role"() TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."get_auth_user_role"() TO "service_role";
GRANT EXECUTE ON FUNCTION "workflow_private"."severity_tier"(score integer) TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."severity_tier"(score integer) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."set_cluster_queue_status"(cluster_id uuid, actor uuid, next_status text) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."set_cluster_queue_status"(cluster_id uuid, actor uuid, next_status text) TO "service_role";
GRANT EXECUTE ON FUNCTION "privacy_private"."protect_report_identity"() TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."apply_fc_operation"(actor uuid, operation_id text, operation_type text, entity_id uuid, entity_type text, payload jsonb, base_version bigint) TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."apply_fc_operation"(actor uuid, operation_id text, operation_type text, entity_id uuid, entity_type text, payload jsonb, base_version bigint) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."submit_task_outcome"(task_id uuid, actor uuid, outcome text, notes text, classification text, expected_version bigint, operation_id text) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."submit_task_outcome"(task_id uuid, actor uuid, outcome text, notes text, classification text, expected_version bigint, operation_id text) TO "service_role";
GRANT EXECUTE ON FUNCTION "workflow_private"."guard_report_claim"() TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."guard_report_claim"() TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."change_field_crew_member"(crew_id uuid, actor uuid, member_id uuid, action text) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."change_field_crew_member"(crew_id uuid, actor uuid, member_id uuid, action text) TO "service_role";
GRANT EXECUTE ON FUNCTION "workflow_private"."immutable_group_result"() TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."immutable_group_result"() TO "service_role";
GRANT EXECUTE ON FUNCTION "workflow_private"."require_desk_actor"(actor uuid) TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."require_desk_actor"(actor uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION "workflow_private"."bump_report_version"() TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."bump_report_version"() TO "service_role";
GRANT EXECUTE ON FUNCTION "workflow_private"."release_finished_task"() TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."release_finished_task"() TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."set_task_photo"(task_id uuid, actor uuid, slot text, url text, photo_hash text, expected_version bigint) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."set_task_photo"(task_id uuid, actor uuid, slot text, url text, photo_hash text, expected_version bigint) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."prevent_audit_modification"() TO PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."prevent_audit_modification"() TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."prevent_audit_modification"() TO "anon";
GRANT EXECUTE ON FUNCTION "public"."prevent_audit_modification"() TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."prevent_audit_modification"() TO "service_role";
GRANT EXECUTE ON FUNCTION "privacy_private"."capture_hidden_report_references"() TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."enqueue_plan_generation"(actor uuid, plan_mode text, settings jsonb, request_key text) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."enqueue_plan_generation"(actor uuid, plan_mode text, settings jsonb, request_key text) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."claim_plan_generation"(worker_id uuid) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."claim_plan_generation"(worker_id uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."commit_mixed_dispatch_plan"(plan_id uuid, actor uuid) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."commit_mixed_dispatch_plan"(plan_id uuid, actor uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."finish_plan_generation"(job_id uuid, worker_id uuid, result_plan_id uuid, failure_code text, diagnostics jsonb) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."finish_plan_generation"(job_id uuid, worker_id uuid, result_plan_id uuid, failure_code text, diagnostics jsonb) TO "service_role";
GRANT EXECUTE ON FUNCTION "workflow_private"."require_completed_plan_job"() TO PUBLIC;
GRANT EXECUTE ON FUNCTION "workflow_private"."require_completed_plan_job"() TO "postgres";
GRANT EXECUTE ON FUNCTION "storage_authority"."can_upload_cleanup_object"(bucket text, object_path text) TO "postgres";
GRANT EXECUTE ON FUNCTION "storage_authority"."can_upload_cleanup_object"(bucket text, object_path text) TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."issue_email_verification"(p_user_id uuid, p_token_digest text, p_ttl_hours integer) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."issue_email_verification"(p_user_id uuid, p_token_digest text, p_ttl_hours integer) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."save_mixed_dispatch_draft"(actor uuid, job_id uuid, worker_id uuid, settings jsonb, items jsonb, proposal jsonb, capacity jsonb, rejected jsonb, diagnostics jsonb) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."save_mixed_dispatch_draft"(actor uuid, job_id uuid, worker_id uuid, settings jsonb, items jsonb, proposal jsonb, capacity jsonb, rejected jsonb, diagnostics jsonb) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."record_field_load"(actor uuid, operation_id text, payload jsonb) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."record_field_load"(actor uuid, operation_id text, payload jsonb) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."submit_field_failure"(actor uuid, operation_id text, payload jsonb) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."submit_field_failure"(actor uuid, operation_id text, payload jsonb) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."activate_report_lifecycle"(high_maturation_hours numeric, normal_maturation_hours numeric) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."activate_report_lifecycle"(high_maturation_hours numeric, normal_maturation_hours numeric) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."set_report_before_photo"(report_id uuid, actor uuid, photo_key text, url text, photo_hash text, expected_version bigint) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."set_report_before_photo"(report_id uuid, actor uuid, photo_key text, url text, photo_hash text, expected_version bigint) TO "service_role";
GRANT EXECUTE ON FUNCTION "privacy_private"."identity_readable"(target uuid) TO "postgres";
GRANT EXECUTE ON FUNCTION "privacy_private"."identity_readable"(target uuid) TO "anon";
GRANT EXECUTE ON FUNCTION "privacy_private"."identity_readable"(target uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION "privacy_private"."operational_readable"(target uuid) TO "postgres";
GRANT EXECUTE ON FUNCTION "privacy_private"."operational_readable"(target uuid) TO "authenticated";
GRANT EXECUTE ON FUNCTION "privacy_private"."operational_readable"(target uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION "privacy_private"."operational_readable"(target uuid) TO "ecopin_operational_reader";
GRANT EXECUTE ON FUNCTION "workflow_private"."find_email_verification_user"(p_email text) TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."find_email_verification_user"(p_email text) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."find_email_verification_user"(p_email text) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."find_email_verification_user"(p_email text) TO "service_role";
GRANT EXECUTE ON FUNCTION "privacy_private"."capture_hidden_queue_reference"() TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."get_barangay_executive_analytics"(actor uuid, report_month date) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."get_barangay_executive_analytics"(actor uuid, report_month date) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."read_report_identity_context"(report_ids uuid[]) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."read_report_identity_context"(report_ids uuid[]) TO "service_role";
GRANT EXECUTE ON FUNCTION "workflow_private"."cleanup_proof_photo_urls"(r reports, slot text) TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."cleanup_proof_photo_urls"(r reports, slot text) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."get_structure_address"(lat double precision, lng double precision, buffer_meters double precision) TO PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."get_structure_address"(lat double precision, lng double precision, buffer_meters double precision) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."get_structure_address"(lat double precision, lng double precision, buffer_meters double precision) TO "anon";
GRANT EXECUTE ON FUNCTION "public"."get_structure_address"(lat double precision, lng double precision, buffer_meters double precision) TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."get_structure_address"(lat double precision, lng double precision, buffer_meters double precision) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."get_structure_address"(lat double precision, lng double precision, buffer_meters double precision) TO "ecopin_public_map_reader";
GRANT EXECUTE ON FUNCTION "public"."redeem_email_verification_atomic"(p_verification_id uuid, p_user_id uuid, p_expected_email text) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."redeem_email_verification_atomic"(p_verification_id uuid, p_user_id uuid, p_expected_email text) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."get_report_barangay"(lat double precision, lng double precision) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."get_report_barangay"(lat double precision, lng double precision) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."set_report_after_photo"(report_id uuid, actor uuid, photo_key text, url text, photo_hash text, expected_version bigint) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."set_report_after_photo"(report_id uuid, actor uuid, photo_key text, url text, photo_hash text, expected_version bigint) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."cleanup_expired_email_verifications"(p_batch_limit integer) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."cleanup_expired_email_verifications"(p_batch_limit integer) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."citizen_trust_snapshot"(target uuid) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."citizen_trust_snapshot"(target uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."get_field_crew_operations_summary"(actor uuid, start_day date, end_day date) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."get_field_crew_operations_summary"(actor uuid, start_day date, end_day date) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."publish_cleanup_proof_photos"(report_id uuid, actor uuid, expected_version bigint, expected_fingerprint text, before_paths jsonb, after_paths jsonb, public_notes text, expected_publication_id uuid, redactions jsonb) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."publish_cleanup_proof_photos"(report_id uuid, actor uuid, expected_version bigint, expected_fingerprint text, before_paths jsonb, after_paths jsonb, public_notes text, expected_publication_id uuid, redactions jsonb) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."publish_cleanup_proof"(report_id uuid, actor uuid, expected_version bigint, expected_fingerprint text, before_path text, after_path text, public_notes text, expected_publication_id uuid, redactions jsonb) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."publish_cleanup_proof"(report_id uuid, actor uuid, expected_version bigint, expected_fingerprint text, before_path text, after_path text, public_notes text, expected_publication_id uuid, redactions jsonb) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."read_cleanup_proof"(report_id uuid) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."read_cleanup_proof"(report_id uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION "workflow_private"."purge_completed_cron_job_runs"(p_batch_limit integer) TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."run_retention_maintenance"(p_batch_limit integer) TO "postgres";
GRANT EXECUTE ON FUNCTION "operational_private"."capture_task_transition"() TO "postgres";
GRANT EXECUTE ON FUNCTION "operational_private"."capture_task_transition"() TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."read_authorized_report_evidence_ids"(actor uuid, report_ids uuid[]) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."read_authorized_report_evidence_ids"(actor uuid, report_ids uuid[]) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."mixed_planning_snapshot"() TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."mixed_planning_snapshot"() TO "service_role";
GRANT EXECUTE ON FUNCTION "workflow_private"."bump_task_assignment_generation"() TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."bump_task_assignment_generation"() TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."dbscan_reports"(p_eps double precision, p_minpoints integer) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."dbscan_reports"(p_eps double precision, p_minpoints integer) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."upsert_cluster_for_reports_v2"(p_report_ids uuid[], p_issue_type text, p_severity text, p_radius_meters double precision) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."upsert_cluster_for_reports_v2"(p_report_ids uuid[], p_issue_type text, p_severity text, p_radius_meters double precision) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."cluster_reports_incremental"(p_eps double precision, p_minpoints integer) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."cluster_reports_incremental"(p_eps double precision, p_minpoints integer) TO "service_role";
GRANT EXECUTE ON FUNCTION "workflow_private"."urgency_report_context"(r reports) TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."urgency_report_context"(r reports) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."expire_unpublished_dispatch_claims"() TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."expire_unpublished_dispatch_claims"() TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."read_authorized_cleanup_tasks"(actor uuid, p_task_id uuid, p_cluster_id uuid, p_assigned_only boolean, p_limit integer, p_offset integer) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."read_authorized_cleanup_tasks"(actor uuid, p_task_id uuid, p_cluster_id uuid, p_assigned_only boolean, p_limit integer, p_offset integer) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."claim_plan_generation"(worker_id uuid, worker_env text) TO PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."claim_plan_generation"(worker_id uuid, worker_env text) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."claim_plan_generation"(worker_id uuid, worker_env text) TO "anon";
GRANT EXECUTE ON FUNCTION "public"."claim_plan_generation"(worker_id uuid, worker_env text) TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."claim_plan_generation"(worker_id uuid, worker_env text) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."issue_email_verification"(p_user_id uuid, p_token_digest text, p_ttl_hours integer, p_email text) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."issue_email_verification"(p_user_id uuid, p_token_digest text, p_ttl_hours integer, p_email text) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."complete_email_verification"(p_verification_id uuid, p_user_id uuid, p_expected_email text) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."complete_email_verification"(p_verification_id uuid, p_user_id uuid, p_expected_email text) TO "service_role";
GRANT EXECUTE ON FUNCTION "verification_private"."redeem_email"(p_verification_id uuid, p_user_id uuid, p_expected_email text) TO "postgres";
GRANT EXECUTE ON FUNCTION "verification_private"."redeem_email"(p_verification_id uuid, p_user_id uuid, p_expected_email text) TO "service_role";
GRANT EXECUTE ON FUNCTION "workflow_private"."urgency_maturation_bypass"(r reports) TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."urgency_maturation_bypass"(r reports) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."ensure_citizen_trust"(target uuid) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."ensure_citizen_trust"(target uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."rebuild_citizen_trust"(target uuid) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."rebuild_citizen_trust"(target uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."read_citizen_trust_review"(actor uuid, report_id uuid) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."read_citizen_trust_review"(actor uuid, report_id uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."record_citizen_trust_review"(actor uuid, report_id uuid, outcome text, reason text, operation_id uuid, expected_decision_id bigint) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."record_citizen_trust_review"(actor uuid, report_id uuid, outcome text, reason text, operation_id uuid, expected_decision_id bigint) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."gate_citizen_urgent_report"() TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."gate_citizen_urgent_report"() TO "service_role";
GRANT EXECUTE ON FUNCTION "workflow_private"."mixed_planning_snapshot"() TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."mixed_planning_snapshot"() TO "service_role";
GRANT EXECUTE ON FUNCTION "workflow_private"."apply_report_lifecycle"() TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."apply_report_lifecycle"() TO "service_role";
GRANT EXECUTE ON FUNCTION "workflow_private"."guard_report_urgency"() TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."guard_report_urgency"() TO "service_role";
GRANT EXECUTE ON FUNCTION "workflow_private"."notify_urgent_report"() TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."notify_urgent_report"() TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."advance_report_lifecycle"() TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."advance_report_lifecycle"() TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."record_report_urgency_decision"(actor uuid, report_id uuid, outcome text, reason text, operation_id uuid, expected_decision_id uuid) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."record_report_urgency_decision"(actor uuid, report_id uuid, outcome text, reason text, operation_id uuid, expected_decision_id uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."read_report_urgency_queue"(actor uuid, queue_status text, page_limit integer) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."read_report_urgency_queue"(actor uuid, queue_status text, page_limit integer) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."read_crew_urgency_observations"(actor uuid, report_id uuid) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."read_crew_urgency_observations"(actor uuid, report_id uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."review_crew_urgency_observation"(actor uuid, report_id uuid, observation_id text, reason text, operation_id uuid) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."review_crew_urgency_observation"(actor uuid, report_id uuid, observation_id text, reason text, operation_id uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION "workflow_private"."resolve_report_barangay_fields"() TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."get_report_lifecycle_summary"() TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."get_report_lifecycle_summary"() TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."resolve_report_barangay"(lat double precision, lng double precision) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."resolve_report_barangay"(lat double precision, lng double precision) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."import_pasig_barangay_boundaries"(rows jsonb, source_url text, source_sha256 text) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."import_pasig_barangay_boundaries"(rows jsonb, source_url text, source_sha256 text) TO "service_role";
GRANT EXECUTE ON FUNCTION "workflow_private"."assert_cleanup_photo_pair"(r jsonb) TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."assert_cleanup_photo_pair"(r jsonb) TO "service_role";
GRANT EXECUTE ON FUNCTION "workflow_private"."guard_cleanup_resolution"() TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."guard_cleanup_resolution"() TO "service_role";
GRANT EXECUTE ON FUNCTION "workflow_private"."guard_cleanup_receipt"() TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."guard_cleanup_receipt"() TO "service_role";
GRANT EXECUTE ON FUNCTION "workflow_private"."guard_cleanup_task_completion"() TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."guard_cleanup_task_completion"() TO "service_role";
GRANT EXECUTE ON FUNCTION "workflow_private"."cleanup_proof_fingerprint"(r reports) TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."cleanup_proof_fingerprint"(r reports) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."read_operational_events"(actor uuid, p_task_id uuid, p_report_id uuid, p_before_id bigint, p_limit integer) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."read_operational_events"(actor uuid, p_task_id uuid, p_report_id uuid, p_before_id bigint, p_limit integer) TO "service_role";
GRANT EXECUTE ON FUNCTION "operational_private"."immutable_event"() TO "postgres";
GRANT EXECUTE ON FUNCTION "operational_private"."immutable_event"() TO "service_role";
GRANT EXECUTE ON FUNCTION "operational_private"."arrival"(receipt jsonb, task uuid, report uuid, actor uuid, generation bigint, disposition text) TO "postgres";
GRANT EXECUTE ON FUNCTION "operational_private"."arrival"(receipt jsonb, task uuid, report uuid, actor uuid, generation bigint, disposition text) TO "service_role";
GRANT EXECUTE ON FUNCTION "operational_private"."capture_row"() TO "postgres";
GRANT EXECUTE ON FUNCTION "operational_private"."capture_row"() TO "service_role";
GRANT EXECUTE ON FUNCTION "operational_private"."capture_verification"() TO "postgres";
GRANT EXECUTE ON FUNCTION "operational_private"."capture_verification"() TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."read_unprocessed_report_alerts"(actor uuid, cursor_created timestamp with time zone, cursor_id uuid, page_limit integer) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."read_unprocessed_report_alerts"(actor uuid, cursor_created timestamp with time zone, cursor_id uuid, page_limit integer) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."escalate_unprocessed_reports"() TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."escalate_unprocessed_reports"() TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."touch_crew_presence"(actor uuid) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."touch_crew_presence"(actor uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."read_live_operations"(actor uuid, before_id bigint, page_limit integer) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."read_live_operations"(actor uuid, before_id bigint, page_limit integer) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."create_support_ticket"(actor uuid, ticket_category text, ticket_description text, ticket_report_id uuid) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."create_support_ticket"(actor uuid, ticket_category text, ticket_description text, ticket_report_id uuid) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."read_my_support_tickets"(actor uuid, cursor_created timestamp with time zone, cursor_id uuid, page_limit integer) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."read_my_support_tickets"(actor uuid, cursor_created timestamp with time zone, cursor_id uuid, page_limit integer) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."read_my_support_ticket"(actor uuid, ticket_ref text) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."read_my_support_ticket"(actor uuid, ticket_ref text) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."read_support_ticket_queue"(actor uuid, status_filter text, cursor_created timestamp with time zone, cursor_id uuid, page_limit integer) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."read_support_ticket_queue"(actor uuid, status_filter text, cursor_created timestamp with time zone, cursor_id uuid, page_limit integer) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."respond_support_ticket"(actor uuid, ticket_id uuid, reply text, new_status text) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."respond_support_ticket"(actor uuid, ticket_id uuid, reply text, new_status text) TO "service_role";
GRANT EXECUTE ON FUNCTION "public"."read_cleanup_proof_source"(report_id uuid) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."read_cleanup_proof_source"(report_id uuid) TO "service_role";
GRANT USAGE ON SCHEMA "workflow_private" TO "postgres";
GRANT CREATE ON SCHEMA "workflow_private" TO "postgres";
GRANT USAGE ON SCHEMA "workflow_private" TO "service_role";
GRANT USAGE ON SCHEMA "storage_authority" TO "postgres";
GRANT CREATE ON SCHEMA "storage_authority" TO "postgres";
GRANT USAGE ON SCHEMA "storage_authority" TO "authenticated";
GRANT USAGE ON SCHEMA "verification_private" TO "postgres";
GRANT CREATE ON SCHEMA "verification_private" TO "postgres";
GRANT USAGE ON SCHEMA "verification_private" TO "service_role";
GRANT USAGE ON SCHEMA "public" TO "pg_database_owner";
GRANT CREATE ON SCHEMA "public" TO "pg_database_owner";
GRANT USAGE ON SCHEMA "public" TO PUBLIC;
GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";
GRANT USAGE ON SCHEMA "public" TO "ecopin_public_map_reader";
GRANT USAGE ON SCHEMA "public" TO "ecopin_operational_reader";
GRANT USAGE ON SCHEMA "privacy_private" TO "postgres";
GRANT CREATE ON SCHEMA "privacy_private" TO "postgres";
GRANT USAGE ON SCHEMA "privacy_private" TO "service_role";
GRANT USAGE ON SCHEMA "privacy_private" TO "anon";
GRANT USAGE ON SCHEMA "privacy_private" TO "authenticated";
GRANT USAGE ON SCHEMA "privacy_private" TO "ecopin_operational_reader";
GRANT USAGE ON SCHEMA "operational_private" TO "postgres";
GRANT CREATE ON SCHEMA "operational_private" TO "postgres";
GRANT USAGE ON SCHEMA "operational_private" TO "service_role";
GRANT SELECT ("id") ON TABLE "public"."reports" TO "ecopin_public_map_reader";
GRANT SELECT ("id") ON TABLE "public"."reports" TO "authenticated";
GRANT INSERT ("user_id") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("user_id") ON TABLE "public"."reports" TO "authenticated";
GRANT INSERT ("title") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("title") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("title") ON TABLE "public"."reports" TO "ecopin_public_map_reader";
GRANT INSERT ("description") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("description") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("description") ON TABLE "public"."reports" TO "ecopin_public_map_reader";
GRANT INSERT ("issue_type") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("issue_type") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("issue_type") ON TABLE "public"."reports" TO "ecopin_public_map_reader";
GRANT INSERT ("location") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("location") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("location") ON TABLE "public"."reports" TO "ecopin_public_map_reader";
GRANT SELECT ("validation_status") ON TABLE "public"."reports" TO "ecopin_public_map_reader";
GRANT SELECT ("validation_status") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("status") ON TABLE "public"."reports" TO "ecopin_public_map_reader";
GRANT SELECT ("status") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("cluster_id") ON TABLE "public"."reports" TO "ecopin_public_map_reader";
GRANT SELECT ("cluster_id") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("created_at") ON TABLE "public"."reports" TO "ecopin_public_map_reader";
GRANT SELECT ("created_at") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("updated_at") ON TABLE "public"."reports" TO "ecopin_public_map_reader";
GRANT SELECT ("updated_at") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("notes") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("before_photo_url") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("after_photo_url") ON TABLE "public"."reports" TO "authenticated";
GRANT INSERT ("on_private_property") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("on_private_property") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("on_private_property") ON TABLE "public"."reports" TO "ecopin_public_map_reader";
GRANT INSERT ("property_owner_consent_status") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("property_owner_consent_status") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("property_owner_consent_status") ON TABLE "public"."reports" TO "ecopin_public_map_reader";
GRANT SELECT ("stage") ON TABLE "public"."reports" TO "ecopin_public_map_reader";
GRANT SELECT ("stage") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("satisfaction_rating") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("lgu_resolved_at") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("citizen_closed_at") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("is_overdue") ON TABLE "public"."reports" TO "ecopin_public_map_reader";
GRANT SELECT ("is_overdue") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("ai_score") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("flagged_severe") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("severe_violation_category") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("manual_review_id") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("severity_score") ON TABLE "public"."reports" TO "ecopin_public_map_reader";
GRANT SELECT ("severity_score") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("urgency_score") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("ra9003_category") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("ml_predicted_class") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("ml_confidence") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("ml_probabilities") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("cleanup_task_id") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("scale_level") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("obstruction_level") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("severity_level") ON TABLE "public"."reports" TO "ecopin_public_map_reader";
GRANT SELECT ("severity_level") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("severity_factors") ON TABLE "public"."reports" TO "authenticated";
GRANT INSERT ("idempotency_key") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("idempotency_key") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("deadline_at") ON TABLE "public"."reports" TO "ecopin_public_map_reader";
GRANT SELECT ("deadline_at") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("fc_version") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("before_photo_hash") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("after_photo_hash") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("sla_started_at") ON TABLE "public"."reports" TO "ecopin_public_map_reader";
GRANT SELECT ("sla_started_at") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("lifecycle_state") ON TABLE "public"."reports" TO "ecopin_public_map_reader";
GRANT SELECT ("lifecycle_state") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("matured_at") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("breached_at") ON TABLE "public"."reports" TO "ecopin_public_map_reader";
GRANT SELECT ("breached_at") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("report_claim_generation") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("hazard_class") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("hazard_model_version") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("hazard_confidence") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("hazard_decision_source") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("hazard_classified_at") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("photo_lat") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("photo_lng") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("photo_accuracy") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("photo_captured_at") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("photo_source") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("is_mocked") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("location_verification_status") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("photo_distance_meters") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("before_photos") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("after_photos") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("street_address") ON TABLE "public"."reports" TO "ecopin_public_map_reader";
GRANT SELECT ("street_address") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("barangay") ON TABLE "public"."reports" TO "ecopin_public_map_reader";
GRANT SELECT ("barangay") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("city") ON TABLE "public"."reports" TO "ecopin_public_map_reader";
GRANT SELECT ("city") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("hide_identity") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("citizen_priority") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("priority_reason") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("priority_explanation") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("submitted_citizen_priority") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("urgency_status") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("urgency_decision_id") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("urgency_decided_at") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("urgency_reason") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("barangay_resolution_status") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("barangay_candidates") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("barangay_resolution_checked_at") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("location_district") ON TABLE "public"."reports" TO "authenticated";
GRANT SELECT ("citizen_landmark") ON TABLE "public"."reports" TO "authenticated";
GRANT UPDATE ("full_name") ON TABLE "public"."profiles" TO "authenticated";
GRANT UPDATE ("avatar_url") ON TABLE "public"."profiles" TO "authenticated";
GRANT UPDATE ("data_consent") ON TABLE "public"."profiles" TO "authenticated";
GRANT UPDATE ("is_read") ON TABLE "public"."notifications" TO "authenticated";
CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();
NOTIFY pgrst,'reload schema';
COMMIT;
