-- Local schema-only reconstruction from EcoPin catalog, 11 October 2026.
-- Auth and Storage below are limited test shims; this does not replace a full Supabase recovery drill.
\set ON_ERROR_STOP on
SET check_function_bodies=off; CREATE SCHEMA extensions; CREATE EXTENSION postgis WITH SCHEMA extensions; CREATE EXTENSION pgcrypto WITH SCHEMA extensions; CREATE EXTENSION "uuid-ossp" WITH SCHEMA extensions;
SET search_path=public,extensions;
DO $$ BEGIN IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon; END IF; IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF; IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role BYPASSRLS; END IF; END $$;
CREATE SCHEMA auth; CREATE SCHEMA storage; CREATE SCHEMA workflow_private;
CREATE TABLE auth.users(id uuid PRIMARY KEY,raw_user_meta_data jsonb,raw_app_meta_data jsonb,email text);
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT COALESCE(NULLIF(current_setting('request.jwt.claim.sub',true),''),NULLIF(current_setting('request.jwt.claims',true),'')::jsonb->>'sub')::uuid $$;
CREATE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $$ SELECT NULLIF(current_setting('request.jwt.claims',true),'')::jsonb->>'role' $$;
CREATE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$ SELECT NULLIF(current_setting('request.jwt.claims',true),'')::jsonb $$;
CREATE TABLE storage.buckets(id text PRIMARY KEY,name text,public boolean); CREATE TABLE storage.objects(id uuid DEFAULT gen_random_uuid() PRIMARY KEY,bucket_id text REFERENCES storage.buckets(id),name text,owner uuid,owner_id text,metadata jsonb,created_at timestamptz DEFAULT now(),updated_at timestamptz DEFAULT now(),UNIQUE(bucket_id,name));
CREATE FUNCTION storage.foldername(name text) RETURNS text[] LANGUAGE sql IMMUTABLE AS $$ SELECT string_to_array(regexp_replace(name,'/[^/]*$',''),'/') $$;
CREATE FUNCTION storage.filename(name text) RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT reverse(split_part(reverse(name),'/',1)) $$;
CREATE SEQUENCE public.sweeper_audit_log_id_seq;
CREATE TYPE "public"."cluster_severity" AS ENUM ('low','medium','high');
CREATE TYPE "public"."audit_log_action_type" AS ENUM ('user_created','login','logout','password_change','password_reset','profile_update','account_deletion');
CREATE TYPE "public"."response_log_action_type" AS ENUM ('citizen_close','manual_note','lifecycle_stage_update','status_update','assigned','unassigned');
CREATE TYPE "public"."sync_entity_type" AS ENUM ('report','task','cluster','dispatch_plan');
CREATE TYPE "public"."sync_operation_type" AS ENUM ('fc.report.update_status','fc.report.update_lifecycle_stage','fc.report.update_validation','fc.report.update_details','fc.note.add','fc.task.mark_complete','fc.photo.upload_before','fc.photo.upload_after','fc.photo.delete','task_update','report_create','report_update','fc.report.reconcile','fc.load.record','fc.task.failure');
CREATE TYPE "public"."dispatch_plan_status" AS ENUM ('draft','approved','discarded');
CREATE TYPE "public"."crew_availability_status" AS ENUM ('available','on_route','off_shift','disabled');
CREATE TYPE "public"."role" AS ENUM ('citizen','lgu','admin','officer','field_crew');
CREATE TYPE "public"."notification_type" AS ENUM ('general','pending_validation','approved','rejected','flagged','resolved','in_progress','closed','lifecycle_update','account_warning','account_suspended');
CREATE TYPE "public"."cleanup_task_status" AS ENUM ('created','pending','in_progress','partially_completed','completed','cancelled','failed');
CREATE TYPE "public"."cleanup_task_type" AS ENUM ('Cleanup','Investigation','Verification','Emergency Response','Reinspection','Monitoring','Escalation','Deferred','Sweeper','Mixed');
CREATE TYPE "public"."route_waypoint_type" AS ENUM ('depot_start','task','depot_end','bundled_report');
CREATE TYPE "public"."vehicle_type_enum" AS ENUM ('compactor','pickup','tricycle','motorcycle','hazmat_unit');
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
CREATE TYPE "public"."lifecycle_stage" AS ENUM ('submitted','assigned','in_progress','resolved','closed');
CREATE TABLE "public"."field_crews" ("id" uuid DEFAULT gen_random_uuid() NOT NULL,
"name" text NOT NULL,
"team_lead_profile_id" uuid,
"member_profile_ids" uuid[] DEFAULT '{}'::uuid[],
"depot_location" geography(Point,4326),
"shift_start" time without time zone DEFAULT '08:00:00'::time without time zone NOT NULL,
"shift_end" time without time zone DEFAULT '17:00:00'::time without time zone NOT NULL,
"max_tasks_per_shift" integer DEFAULT 10,
"availability_status" crew_availability_status DEFAULT 'available'::crew_availability_status,
"created_at" timestamp with time zone DEFAULT now(),
"updated_at" timestamp with time zone DEFAULT now(),
"supports_standard" boolean DEFAULT true NOT NULL,
"supports_sweeper" boolean DEFAULT false NOT NULL,
"speed_factor" numeric DEFAULT 1 NOT NULL,
"service_time_factor" numeric DEFAULT 1 NOT NULL,
"vehicle_type" vehicle_type_enum DEFAULT 'compactor'::vehicle_type_enum NOT NULL,
"hazmat_certified" boolean DEFAULT false NOT NULL,
"certifications" text[] DEFAULT '{}'::text[] NOT NULL,
"max_volume_m3" numeric(8,3),
"max_weight_kg" numeric(10,2),
"starting_volume_m3" numeric(8,3),
"starting_weight_kg" numeric(10,2),
"load_measured_at" timestamp with time zone,
"certification_reviewed_by" uuid);
CREATE TABLE "public"."dispatch_plans" ("id" uuid DEFAULT uuid_generate_v4() NOT NULL,
"planned_date" date DEFAULT CURRENT_DATE NOT NULL,
"total_crews_available" integer DEFAULT 0 NOT NULL,
"total_capacity_minutes" integer DEFAULT 0 NOT NULL,
"status" dispatch_plan_status DEFAULT 'draft'::dispatch_plan_status,
"created_at" timestamp with time zone DEFAULT now(),
"created_by" uuid,
"mode" text DEFAULT 'standard'::text NOT NULL,
"settings_snapshot" jsonb DEFAULT '{}'::jsonb NOT NULL,
"optimization_run_id" uuid,
"routing_attempts" integer DEFAULT 0 NOT NULL,
"routing_token" uuid,
"routing_lease_until" timestamp with time zone,
"capacity_breakdown" jsonb DEFAULT '{}'::jsonb NOT NULL,
"route_proposal" jsonb,
"rejected_bundles" jsonb DEFAULT '[]'::jsonb NOT NULL,
"solver_diagnostics" jsonb DEFAULT '{}'::jsonb NOT NULL,
"planning_as_of" timestamp with time zone,
"generation_job_id" uuid);
CREATE TABLE "public"."system_logs" ("id" uuid DEFAULT gen_random_uuid() NOT NULL,
"user_id" uuid,
"action_type" audit_log_action_type NOT NULL,
"action_details" text,
"ip_address" character varying(45),
"user_agent" text,
"created_at" timestamp with time zone DEFAULT timezone('utc'::text, now()));
CREATE TABLE "public"."audit_logs" ("id" uuid DEFAULT gen_random_uuid() NOT NULL,
"report_id" uuid,
"user_id" uuid,
"action_type" response_log_action_type NOT NULL,
"action_details" text NOT NULL,
"created_at" timestamp with time zone DEFAULT now());
CREATE TABLE "public"."cleanup_tasks" ("id" uuid DEFAULT gen_random_uuid() NOT NULL,
"cluster_id" uuid,
"lgu_user_id" uuid,
"title" text,
"status" cleanup_task_status DEFAULT 'created'::cleanup_task_status,
"before_photo_url" text,
"after_photo_url" text,
"notes" text,
"created_at" timestamp with time zone DEFAULT now(),
"completed_at" timestamp with time zone,
"created_by" uuid,
"description" text,
"is_custom" boolean DEFAULT false,
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
"task_type" cleanup_task_type DEFAULT 'Cleanup'::cleanup_task_type,
"cluster_ids" uuid[] DEFAULT '{}'::uuid[],
"required_resources" text,
"expected_action" text,
"scheduled_date" date,
"completion_result" text,
"completion_notes" text,
"report_sequence" uuid[] DEFAULT '{}'::uuid[],
"fc_version" bigint DEFAULT 0 NOT NULL,
"before_photo_hash" text,
"after_photo_hash" text,
"location" geography(Point,4326),
"street_address" text,
"source_plan_id" uuid,
"source_group_key" text,
"assigned_field_crew_id" uuid,
"estimated_work_minutes" integer DEFAULT 0 NOT NULL,
"dispatch_kind" text DEFAULT 'standard'::text NOT NULL,
"route_status" text DEFAULT 'ready'::text NOT NULL,
"routing_deadline_at" timestamp with time zone,
"routing_escalated_at" timestamp with time zone,
"failure_class" text,
"failure_reason" text,
"completed_by" uuid,
"completion_operation_id" text,
"satellite_report_ids" uuid[] DEFAULT '{}'::uuid[] NOT NULL,
"bundle_detour_min" numeric(6,2),
"estimated_volume_m3" numeric(8,3),
"estimated_weight_kg" numeric(10,2),
"load_estimate_confidence" text,
"route_revision" bigint DEFAULT 0 NOT NULL,
"assignment_generation" bigint DEFAULT 0 NOT NULL);
CREATE TABLE "public"."manual_review_queue" ("id" uuid DEFAULT gen_random_uuid() NOT NULL,
"report_id" uuid,
"strike_id" uuid,
"review_type" manual_review_type NOT NULL,
"priority" character varying(20) DEFAULT 'normal'::character varying,
"status" manual_review_status DEFAULT 'pending'::manual_review_status,
"assigned_to" uuid,
"assigned_at" timestamp with time zone,
"reviewed_at" timestamp with time zone,
"review_notes" text,
"created_at" timestamp with time zone DEFAULT timezone('utc'::text, now()),
"updated_at" timestamp with time zone DEFAULT timezone('utc'::text, now()));
CREATE TABLE "public"."dispatch_plan_items" ("id" uuid DEFAULT uuid_generate_v4() NOT NULL,
"dispatch_plan_id" uuid NOT NULL,
"cluster_id" uuid,
"is_selected" boolean DEFAULT false NOT NULL,
"reason" text,
"estimated_duration_minutes" integer,
"created_at" timestamp with time zone DEFAULT now(),
"report_id" uuid,
"report_ids" uuid[] DEFAULT '{}'::uuid[] NOT NULL,
"item_type" text DEFAULT 'cluster'::text NOT NULL,
"group_key" text DEFAULT (gen_random_uuid())::text NOT NULL,
"planned_crew_id" uuid,
"estimated_work_minutes" integer DEFAULT 0 NOT NULL,
"priority_score" numeric,
"crew_snapshot" jsonb DEFAULT '{}'::jsonb NOT NULL,
"anchor_cluster_id" uuid,
"cluster_ids" uuid[] DEFAULT '{}'::uuid[] NOT NULL,
"bundle_order" smallint,
"detour_minutes" numeric(6,2),
"estimated_volume_m3" numeric(8,3),
"estimated_weight_kg" numeric(10,2),
"load_snapshot" jsonb,
"commit_disposition" text DEFAULT 'pending'::text NOT NULL,
"commit_reason" text,
"committed_task_id" uuid);
CREATE TABLE "public"."plan_generation_jobs" ("id" uuid DEFAULT gen_random_uuid() NOT NULL,
"requested_by" uuid NOT NULL,
"mode" text NOT NULL,
"status" text DEFAULT 'queued'::text NOT NULL,
"idempotency_key" text,
"requested_at" timestamp with time zone DEFAULT now() NOT NULL,
"started_at" timestamp with time zone,
"finished_at" timestamp with time zone,
"lease_until" timestamp with time zone,
"worker_token" uuid,
"settings_snapshot" jsonb NOT NULL,
"plan_id" uuid,
"error_code" text,
"solver_diagnostics" jsonb DEFAULT '{}'::jsonb NOT NULL);
CREATE TABLE "public"."reports" ("id" uuid DEFAULT gen_random_uuid() NOT NULL,
"user_id" uuid,
"title" text NOT NULL,
"description" text,
"issue_type" report_issue_type,
"location" geography(Point,4326) NOT NULL,
"validation_status" report_validation_status DEFAULT 'pending'::report_validation_status,
"status" report_status DEFAULT 'unresolved'::report_status,
"cluster_id" uuid,
"created_at" timestamp with time zone DEFAULT now(),
"updated_at" timestamp with time zone DEFAULT now(),
"notes" text,
"before_photo_url" text,
"after_photo_url" text,
"on_private_property" boolean DEFAULT false,
"property_owner_consent_status" consent_status DEFAULT 'not_required'::consent_status,
"stage" lifecycle_stage DEFAULT 'submitted'::lifecycle_stage,
"satisfaction_rating" integer,
"lgu_resolved_at" timestamp with time zone,
"citizen_closed_at" timestamp with time zone,
"is_overdue" boolean DEFAULT false,
"ai_score" numeric,
"flagged_severe" boolean DEFAULT false,
"severe_violation_category" severe_violation_category,
"manual_review_id" uuid,
"severity_score" smallint,
"urgency_score" smallint,
"ra9003_category" text,
"ml_predicted_class" text,
"ml_confidence" real,
"ml_probabilities" jsonb,
"cleanup_task_id" uuid,
"scale_level" character varying(20) DEFAULT 'medium'::character varying,
"obstruction_level" character varying(20) DEFAULT 'none'::character varying,
"severity_level" report_severity_level,
"severity_factors" jsonb,
"idempotency_key" text,
"deadline_at" timestamp with time zone,
"fc_version" bigint DEFAULT 0 NOT NULL,
"before_photo_hash" text,
"after_photo_hash" text,
"sla_started_at" timestamp with time zone,
"lifecycle_state" text,
"matured_at" timestamp with time zone,
"breached_at" timestamp with time zone,
"report_claim_generation" bigint DEFAULT 0 NOT NULL,
"hazard_class" text DEFAULT 'unknown'::text NOT NULL,
"hazard_model_version" text,
"hazard_confidence" numeric(4,3),
"hazard_decision_source" text,
"hazard_classified_at" timestamp with time zone);
CREATE TABLE "public"."fc_operation_log" ("operation_id" text NOT NULL,
"user_id" uuid,
"operation_type" sync_operation_type NOT NULL,
"entity_id" text NOT NULL,
"entity_type" sync_entity_type NOT NULL,
"status" text DEFAULT 'success'::text NOT NULL,
"result" jsonb,
"created_at" timestamp with time zone DEFAULT now() NOT NULL,
"expires_at" timestamp with time zone DEFAULT (now() + '30 days'::interval) NOT NULL);
CREATE TABLE "public"."fc_conflict_audit" ("id" uuid DEFAULT gen_random_uuid() NOT NULL,
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
"created_at" timestamp with time zone DEFAULT now() NOT NULL);
CREATE TABLE "public"."profiles" ("id" uuid NOT NULL,
"full_name" text,
"created_at" timestamp with time zone DEFAULT now(),
"role" role DEFAULT 'citizen'::role,
"avatar_url" text,
"data_consent" boolean,
"suspended_until" timestamp with time zone,
"strike_count" integer DEFAULT 0,
"last_strike_at" timestamp with time zone,
"is_email_verified" boolean DEFAULT false,
"require_password_change" boolean DEFAULT false);
CREATE TABLE "public"."hotspot_accuracy" ("id" uuid DEFAULT gen_random_uuid() NOT NULL,
"prediction_id" uuid,
"actual_reports" integer NOT NULL,
"predicted_reports" integer NOT NULL,
"accuracy_score" numeric(5,4),
"time_horizon" character varying(20) NOT NULL,
"evaluation_date" date NOT NULL,
"created_at" timestamp with time zone DEFAULT now());
CREATE TABLE "public"."dispatch_group_commits" ("dispatch_plan_id" uuid NOT NULL,
"group_key" text NOT NULL,
"result" jsonb NOT NULL,
"committed_at" timestamp with time zone DEFAULT now() NOT NULL);
CREATE TABLE "public"."system_settings" ("id" uuid DEFAULT gen_random_uuid() NOT NULL,
"password_min_length" integer DEFAULT 8,
"password_require_uppercase" boolean DEFAULT true,
"password_require_lowercase" boolean DEFAULT true,
"password_require_numbers" boolean DEFAULT true,
"password_require_special_chars" boolean DEFAULT true,
"session_timeout_minutes" integer DEFAULT 60,
"created_at" timestamp with time zone DEFAULT timezone('utc'::text, now()),
"updated_at" timestamp with time zone DEFAULT timezone('utc'::text, now()),
"strike_1_action" character varying(50) DEFAULT 'warning'::character varying,
"strike_2_action" character varying(50) DEFAULT 'suspend_24h'::character varying,
"strike_3_action" character varying(50) DEFAULT 'suspend_7d'::character varying,
"strike_4_action" character varying(50) DEFAULT 'permanent_ban'::character varying,
"strike_2_duration_hours" integer DEFAULT 24,
"strike_3_duration_hours" integer DEFAULT 168,
"severe_violation_action" character varying(50) DEFAULT 'suspend_7d'::character varying,
"severe_violation_duration_hours" integer DEFAULT 168,
"severe_violation_auto_reject" boolean DEFAULT true,
"severe_violation_immediate_strike" boolean DEFAULT true);
CREATE TABLE "public"."email_verifications" ("id" uuid DEFAULT gen_random_uuid() NOT NULL,
"user_id" uuid NOT NULL,
"token" uuid DEFAULT gen_random_uuid() NOT NULL,
"expires_at" timestamp with time zone NOT NULL,
"used_at" timestamp with time zone,
"created_at" timestamp with time zone DEFAULT now());
CREATE TABLE "public"."dispatch_access_blocks" ("id" uuid DEFAULT gen_random_uuid() NOT NULL,
"cluster_id" uuid,
"report_id" uuid,
"task_id" uuid,
"reason" text NOT NULL,
"failure_class" text NOT NULL,
"blocked_by" uuid,
"blocked_at" timestamp with time zone DEFAULT now() NOT NULL,
"cleared_by" uuid,
"cleared_at" timestamp with time zone,
"clearance_notes" text);
CREATE TABLE "public"."strikes" ("id" uuid DEFAULT gen_random_uuid() NOT NULL,
"user_id" uuid,
"reason" text NOT NULL,
"violation_type" character varying(50) NOT NULL,
"issued_by" uuid,
"issued_at" timestamp with time zone DEFAULT timezone('utc'::text, now()),
"expires_at" timestamp with time zone,
"is_active" boolean DEFAULT true,
"notes" text,
"severity" violation_severity DEFAULT 'normal'::violation_severity,
"severe_category" severe_violation_category,
"requires_manual_review" boolean DEFAULT false,
"manual_review_status" character varying(50));
CREATE TABLE "public"."field_assignment_receipts" ("id" uuid DEFAULT gen_random_uuid() NOT NULL,
"task_id" uuid NOT NULL,
"report_id" uuid NOT NULL,
"crew_id" uuid NOT NULL,
"assignment_generation" bigint NOT NULL,
"report_claim_generation" bigint NOT NULL,
"issued_at" timestamp with time zone DEFAULT now() NOT NULL);
CREATE TABLE "public"."report_resolution_events" ("id" uuid DEFAULT gen_random_uuid() NOT NULL,
"report_id" uuid NOT NULL,
"task_id" uuid NOT NULL,
"crew_id" uuid NOT NULL,
"operation_id" text NOT NULL,
"resolved_at" timestamp with time zone DEFAULT now() NOT NULL,
"report_fc_version" bigint NOT NULL,
"resolution_kind" text DEFAULT 'cleaned'::text NOT NULL);
CREATE TABLE "public"."notifications" ("id" uuid DEFAULT gen_random_uuid() NOT NULL,
"user_id" uuid NOT NULL,
"report_id" uuid,
"type" notification_type DEFAULT 'general'::notification_type NOT NULL,
"title" text NOT NULL,
"body" text NOT NULL,
"is_read" boolean DEFAULT false NOT NULL,
"created_at" timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL);
CREATE TABLE "public"."task_report_outcomes" ("id" uuid DEFAULT gen_random_uuid() NOT NULL,
"operation_id" text NOT NULL,
"task_id" uuid NOT NULL,
"report_id" uuid NOT NULL,
"crew_id" uuid NOT NULL,
"receipt_id" uuid NOT NULL,
"outcome" text NOT NULL,
"disposition" text NOT NULL,
"observed_at" timestamp with time zone NOT NULL,
"submitted_at" timestamp with time zone DEFAULT now() NOT NULL,
"evidence_refs" jsonb DEFAULT '[]'::jsonb NOT NULL,
"notes" text DEFAULT ''::text NOT NULL,
"resolution_event_id" uuid);
CREATE TABLE "public"."optimization_templates" ("id" uuid DEFAULT uuid_generate_v4() NOT NULL,
"name" text NOT NULL,
"description" text,
"created_by" uuid,
"is_default" boolean DEFAULT false,
"settings" jsonb DEFAULT '{}'::jsonb NOT NULL,
"created_at" timestamp with time zone DEFAULT now(),
"updated_at" timestamp with time zone DEFAULT now());
CREATE TABLE "public"."optimization_settings" ("id" uuid DEFAULT gen_random_uuid() NOT NULL,
"key" text NOT NULL,
"value" jsonb NOT NULL,
"description" text,
"updated_by" uuid,
"updated_at" timestamp with time zone DEFAULT now());
CREATE TABLE "public"."sync_conflicts" ("id" uuid DEFAULT gen_random_uuid() NOT NULL,
"user_id" uuid,
"operation_type" sync_operation_type NOT NULL,
"operation_payload" jsonb NOT NULL,
"conflict_reason" text NOT NULL,
"server_state" jsonb,
"created_at" timestamp with time zone DEFAULT now(),
"resolved_at" timestamp with time zone,
"resolved_by" uuid,
"resolution_notes" text);
CREATE TABLE "public"."route_waypoints" ("id" uuid DEFAULT gen_random_uuid() NOT NULL,
"crew_route_id" uuid NOT NULL,
"sequence_order" integer NOT NULL,
"latitude" numeric NOT NULL,
"longitude" numeric NOT NULL,
"cleanup_task_id" uuid,
"waypoint_type" route_waypoint_type DEFAULT 'task'::route_waypoint_type,
"distance_from_previous_meters" numeric,
"estimated_time_from_previous_min" numeric,
"created_at" timestamp with time zone DEFAULT now(),
"polyline" jsonb,
"report_id" uuid);
CREATE TABLE "public"."optimization_runs" ("id" uuid DEFAULT gen_random_uuid() NOT NULL,
"triggered_by" uuid,
"status" text DEFAULT 'draft'::text,
"criteria" jsonb NOT NULL,
"weather_condition" text DEFAULT 'normal'::text,
"traffic_condition" text DEFAULT 'low'::text,
"num_tasks_optimized" integer DEFAULT 0,
"num_crews" integer DEFAULT 2,
"total_estimated_distance_meters" numeric,
"total_estimated_duration_min" numeric,
"error_message" text,
"approved_by" uuid,
"approved_at" timestamp with time zone,
"created_at" timestamp with time zone DEFAULT now());
CREATE TABLE "public"."crew_routes" ("id" uuid DEFAULT gen_random_uuid() NOT NULL,
"optimization_run_id" uuid NOT NULL,
"crew_id" uuid NOT NULL,
"start_depot" geography(Point,4326) NOT NULL,
"end_depot" geography(Point,4326) NOT NULL,
"total_distance_meters" numeric,
"total_duration_min" numeric,
"task_count" integer DEFAULT 0,
"weather_snapshot" jsonb,
"traffic_snapshot" jsonb,
"created_at" timestamp with time zone DEFAULT now());
CREATE TABLE "public"."field_load_events" ("id" uuid DEFAULT gen_random_uuid() NOT NULL,
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
"submitted_at" timestamp with time zone DEFAULT now() NOT NULL,
"notes" text DEFAULT ''::text NOT NULL);
CREATE TABLE "public"."field_task_failure_events" ("id" uuid DEFAULT gen_random_uuid() NOT NULL,
"operation_id" text NOT NULL,
"task_id" uuid NOT NULL,
"actor_id" uuid NOT NULL,
"assignment_generation" bigint NOT NULL,
"reason_code" text NOT NULL,
"failure_class" text NOT NULL,
"evidence_refs" jsonb NOT NULL,
"notes" text NOT NULL,
"observed_at" timestamp with time zone NOT NULL,
"submitted_at" timestamp with time zone DEFAULT now() NOT NULL);
CREATE TABLE "public"."hotspot_predictions" ("id" uuid DEFAULT gen_random_uuid() NOT NULL,
"region_id" character varying(255) NOT NULL,
"time_horizon" character varying(50) NOT NULL,
"prediction_date" date NOT NULL,
"risk_score" numeric(5,4) NOT NULL,
"report_count" integer NOT NULL,
"gi_statistic" numeric(10,6),
"p_value" numeric(10,8),
"is_significant" boolean DEFAULT false,
"risk_level" character varying(20) NOT NULL,
"region_center_lat" numeric(10,8) NOT NULL,
"region_center_lng" numeric(11,8) NOT NULL,
"region_radius_meters" numeric(10,2),
"region_polygon" text,
"created_at" timestamp with time zone DEFAULT now(),
"updated_at" timestamp with time zone DEFAULT now(),
"geojson_polygon" jsonb,
"top_issue_type" report_issue_type,
"issue_breakdown" jsonb,
"rank" integer);
CREATE TABLE "public"."work_time_configuration" ("report_type" character varying(100) NOT NULL,
"work_time_minutes" integer NOT NULL,
"updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
"estimated_volume_m3" numeric(8,3),
"estimated_weight_kg" numeric(10,2),
"estimate_source" text,
"estimate_reviewed_at" timestamp with time zone);
CREATE TABLE "public"."sweeper_configuration" ("parameter_name" character varying(100) NOT NULL,
"parameter_value" jsonb NOT NULL,
"updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
"updated_by" character varying(255));
CREATE TABLE "public"."sweeper_audit_log" ("id" integer DEFAULT nextval('sweeper_audit_log_id_seq'::regclass) NOT NULL,
"event_type" character varying(100) NOT NULL,
"entity_type" character varying(100) NOT NULL,
"entity_id" character varying(255) NOT NULL,
"user_id" character varying(255),
"event_data" jsonb,
"created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE "public"."clusters" ("id" uuid DEFAULT gen_random_uuid() NOT NULL,
"center" geometry(Point,4326) NOT NULL,
"radius_meters" numeric DEFAULT 50,
"report_count" integer NOT NULL,
"issue_type" report_issue_type,
"severity" cluster_severity,
"status" cluster_status DEFAULT 'unresolved'::cluster_status,
"created_at" timestamp with time zone DEFAULT now(),
"updated_at" timestamp with time zone DEFAULT now(),
"priority_score" numeric,
"priority" text,
"estimated_effort_minutes" integer DEFAULT 60,
"recommended_task_type" text DEFAULT 'Cleanup'::text,
"label" text);
CREATE TABLE "workflow_private"."lifecycle_deployment" ("singleton" boolean DEFAULT true NOT NULL,
"activated_at" timestamp with time zone NOT NULL);
CREATE TABLE "workflow_private"."historical_sla_reset" ("report_id" uuid NOT NULL,
"original_created_at" timestamp with time zone,
"original_deadline_at" timestamp with time zone,
"original_is_outlier" boolean,
"reset_at" timestamp with time zone NOT NULL);
ALTER TABLE "public"."field_task_failure_events" ADD CONSTRAINT "field_task_failure_events_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."audit_logs" ADD CONSTRAINT "response_log_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."profiles" ADD CONSTRAINT "profiles_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."reports" ADD CONSTRAINT "reports_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."field_task_failure_events" ADD CONSTRAINT "field_task_failure_events_operation_id_key" UNIQUE (operation_id);
ALTER TABLE "public"."optimization_runs" ADD CONSTRAINT "optimization_runs_status_check" CHECK ((status = ANY (ARRAY['draft'::text, 'proposed'::text, 'approved'::text, 'discarded'::text, 'failed'::text])));
ALTER TABLE "public"."optimization_runs" ADD CONSTRAINT "optimization_runs_weather_condition_check" CHECK ((weather_condition = ANY (ARRAY['normal'::text, 'heavy_rain'::text, 'storm'::text])));
ALTER TABLE "public"."optimization_runs" ADD CONSTRAINT "optimization_runs_traffic_condition_check" CHECK ((traffic_condition = ANY (ARRAY['low'::text, 'moderate'::text, 'heavy'::text])));
ALTER TABLE "public"."optimization_runs" ADD CONSTRAINT "optimization_runs_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."crew_routes" ADD CONSTRAINT "crew_routes_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."cleanup_tasks" ADD CONSTRAINT "cleanup_tasks_priority_check" CHECK ((priority = ANY (ARRAY['urgent'::text, 'high'::text, 'medium'::text, 'low'::text])));
ALTER TABLE "public"."clusters" ADD CONSTRAINT "clusters_priority_check" CHECK ((priority = ANY (ARRAY['urgent'::text, 'high'::text, 'medium'::text, 'low'::text])));
ALTER TABLE "public"."route_waypoints" ADD CONSTRAINT "route_waypoints_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."dispatch_plans" ADD CONSTRAINT "dispatch_plans_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."dispatch_plan_items" ADD CONSTRAINT "dispatch_plan_items_pkey" PRIMARY KEY (id);
ALTER TABLE "workflow_private"."lifecycle_deployment" ADD CONSTRAINT "lifecycle_deployment_singleton_check" CHECK (singleton);
ALTER TABLE "workflow_private"."lifecycle_deployment" ADD CONSTRAINT "lifecycle_deployment_pkey" PRIMARY KEY (singleton);
ALTER TABLE "workflow_private"."historical_sla_reset" ADD CONSTRAINT "historical_sla_reset_pkey" PRIMARY KEY (report_id);
ALTER TABLE "public"."dispatch_plan_items" ADD CONSTRAINT "dispatch_plan_items_estimated_work_minutes_check" CHECK ((estimated_work_minutes >= 0));
ALTER TABLE "public"."dispatch_access_blocks" ADD CONSTRAINT "dispatch_access_blocks_failure_class_check" CHECK ((failure_class = ANY (ARRAY['site'::text, 'safety'::text, 'unclassified'::text])));
ALTER TABLE "public"."system_settings" ADD CONSTRAINT "system_settings_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."strikes" ADD CONSTRAINT "strikes_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."reports" ADD CONSTRAINT "reports_urgency_score_check" CHECK ((urgency_score = ANY (ARRAY[1, 2, 3])));
ALTER TABLE "public"."clusters" ADD CONSTRAINT "clusters_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."cleanup_tasks" ADD CONSTRAINT "cleanup_tasks_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."dispatch_access_blocks" ADD CONSTRAINT "dispatch_access_blocks_reason_check" CHECK ((length(btrim(reason)) > 0));
ALTER TABLE "public"."system_logs" ADD CONSTRAINT "audit_logs_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."manual_review_queue" ADD CONSTRAINT "manual_review_queue_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."reports" ADD CONSTRAINT "reports_ra9003_category_check" CHECK ((ra9003_category = ANY (ARRAY['solid'::text, 'bulky'::text, 'special'::text, 'na'::text])));
ALTER TABLE "public"."email_verifications" ADD CONSTRAINT "email_verifications_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."reports" ADD CONSTRAINT "reports_satisfaction_rating_check" CHECK (((satisfaction_rating >= 1) AND (satisfaction_rating <= 5)));
ALTER TABLE "public"."hotspot_accuracy" ADD CONSTRAINT "hotspot_accuracy_accuracy_score_check" CHECK (((accuracy_score >= (0)::numeric) AND (accuracy_score <= (1)::numeric)));
ALTER TABLE "public"."hotspot_accuracy" ADD CONSTRAINT "hotspot_accuracy_time_horizon_check" CHECK (((time_horizon)::text = ANY ((ARRAY['daily'::character varying, 'weekly'::character varying, 'monthly'::character varying])::text[])));
ALTER TABLE "public"."hotspot_accuracy" ADD CONSTRAINT "hotspot_accuracy_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."field_crews" ADD CONSTRAINT "field_crews_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."sync_conflicts" ADD CONSTRAINT "sync_conflicts_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."reports" ADD CONSTRAINT "reports_idempotency_key_key" UNIQUE (idempotency_key);
ALTER TABLE "public"."fc_operation_log" ADD CONSTRAINT "fc_operation_log_pkey" PRIMARY KEY (operation_id);
ALTER TABLE "public"."optimization_templates" ADD CONSTRAINT "optimization_templates_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."task_report_outcomes" ADD CONSTRAINT "task_report_outcomes_outcome_check" CHECK ((outcome = ANY (ARRAY['cleaned'::text, 'already_resolved'::text, 'unable'::text, 'skipped'::text])));
ALTER TABLE "public"."hotspot_predictions" ADD CONSTRAINT "hotspot_predictions_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."notifications" ADD CONSTRAINT "notifications_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."reports" ADD CONSTRAINT "reports_severity_score_check" CHECK (((severity_score >= 0) AND (severity_score <= 100)));
ALTER TABLE "public"."optimization_settings" ADD CONSTRAINT "optimization_settings_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."optimization_settings" ADD CONSTRAINT "optimization_settings_key_key" UNIQUE (key);
ALTER TABLE "public"."fc_conflict_audit" ADD CONSTRAINT "fc_conflict_audit_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."sweeper_configuration" ADD CONSTRAINT "sweeper_configuration_pkey" PRIMARY KEY (parameter_name);
ALTER TABLE "public"."work_time_configuration" ADD CONSTRAINT "work_time_configuration_pkey" PRIMARY KEY (report_type);
ALTER TABLE "public"."sweeper_audit_log" ADD CONSTRAINT "sweeper_audit_log_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."field_load_events" ADD CONSTRAINT "field_load_events_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."field_load_events" ADD CONSTRAINT "field_load_events_operation_id_key" UNIQUE (operation_id);
ALTER TABLE "public"."field_task_failure_events" ADD CONSTRAINT "field_task_failure_events_assignment_generation_check" CHECK ((assignment_generation > 0));
ALTER TABLE "public"."field_task_failure_events" ADD CONSTRAINT "field_task_failure_events_reason_code_check" CHECK ((reason_code = ANY (ARRAY['site_inaccessible'::text, 'safety_hazard'::text, 'vehicle_failure'::text, 'crew_unavailable'::text])));
ALTER TABLE "public"."field_task_failure_events" ADD CONSTRAINT "field_task_failure_events_failure_class_check" CHECK ((failure_class = ANY (ARRAY['site'::text, 'safety'::text, 'transient'::text])));
ALTER TABLE "public"."reports" ADD CONSTRAINT "reports_lifecycle_state_check" CHECK ((lifecycle_state = ANY (ARRAY['fresh'::text, 'clustered'::text, 'maturing'::text, 'sla_breached'::text, 'dispatched'::text, 'closed'::text])));
ALTER TABLE "public"."field_crews" ADD CONSTRAINT "field_crews_speed_factor_check" CHECK (((speed_factor > (0)::numeric) AND (speed_factor <= (3)::numeric)));
ALTER TABLE "public"."field_crews" ADD CONSTRAINT "field_crews_service_time_factor_check" CHECK (((service_time_factor > (0)::numeric) AND (service_time_factor <= (3)::numeric)));
ALTER TABLE "public"."dispatch_plans" ADD CONSTRAINT "dispatch_plans_routing_attempts_check" CHECK (((routing_attempts >= 0) AND (routing_attempts <= 3)));
ALTER TABLE "public"."cleanup_tasks" ADD CONSTRAINT "cleanup_tasks_estimated_work_minutes_check" CHECK ((estimated_work_minutes >= 0));
ALTER TABLE "public"."cleanup_tasks" ADD CONSTRAINT "cleanup_tasks_route_status_check" CHECK ((route_status = ANY (ARRAY['needs_replan'::text, 'ready'::text, 'expired'::text])));
ALTER TABLE "public"."cleanup_tasks" ADD CONSTRAINT "cleanup_tasks_failure_class_check" CHECK ((failure_class = ANY (ARRAY['transient'::text, 'site'::text, 'safety'::text, 'unclassified'::text])));
ALTER TABLE "public"."dispatch_group_commits" ADD CONSTRAINT "dispatch_group_commits_pkey" PRIMARY KEY (dispatch_plan_id, group_key);
ALTER TABLE "public"."dispatch_access_blocks" ADD CONSTRAINT "dispatch_access_blocks_check" CHECK (((((cluster_id IS NOT NULL))::integer + ((report_id IS NOT NULL))::integer) = 1));
ALTER TABLE "public"."dispatch_access_blocks" ADD CONSTRAINT "dispatch_access_blocks_check1" CHECK ((((cleared_at IS NULL) AND (cleared_by IS NULL)) OR ((cleared_at IS NOT NULL) AND (cleared_by IS NOT NULL))));
ALTER TABLE "public"."dispatch_access_blocks" ADD CONSTRAINT "dispatch_access_blocks_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."field_crews" ADD CONSTRAINT "field_crews_max_volume_m3_check" CHECK ((max_volume_m3 > (0)::numeric));
ALTER TABLE "public"."field_crews" ADD CONSTRAINT "field_crews_max_weight_kg_check" CHECK ((max_weight_kg > (0)::numeric));
ALTER TABLE "public"."field_crews" ADD CONSTRAINT "field_crews_starting_volume_m3_check" CHECK ((starting_volume_m3 >= (0)::numeric));
ALTER TABLE "public"."field_crews" ADD CONSTRAINT "field_crews_starting_weight_kg_check" CHECK ((starting_weight_kg >= (0)::numeric));
ALTER TABLE "public"."field_task_failure_events" ADD CONSTRAINT "field_task_failure_events_evidence_refs_check" CHECK ((jsonb_typeof(evidence_refs) = 'array'::text));
ALTER TABLE "public"."field_crews" ADD CONSTRAINT "field_crews_volume_not_overfilled" CHECK (((starting_volume_m3 IS NULL) OR (max_volume_m3 IS NULL) OR (starting_volume_m3 <= max_volume_m3)));
ALTER TABLE "public"."field_crews" ADD CONSTRAINT "field_crews_weight_not_overfilled" CHECK (((starting_weight_kg IS NULL) OR (max_weight_kg IS NULL) OR (starting_weight_kg <= max_weight_kg)));
ALTER TABLE "public"."field_crews" ADD CONSTRAINT "field_crews_load_has_measurement" CHECK ((((starting_volume_m3 IS NULL) AND (starting_weight_kg IS NULL)) OR (load_measured_at IS NOT NULL)));
ALTER TABLE "public"."work_time_configuration" ADD CONSTRAINT "work_time_configuration_estimated_volume_m3_check" CHECK ((estimated_volume_m3 >= (0)::numeric));
ALTER TABLE "public"."work_time_configuration" ADD CONSTRAINT "work_time_configuration_estimated_weight_kg_check" CHECK ((estimated_weight_kg >= (0)::numeric));
ALTER TABLE "public"."dispatch_plans" ADD CONSTRAINT "dispatch_plans_mode_check" CHECK ((mode = ANY (ARRAY['standard'::text, 'sweeper'::text, 'mixed'::text])));
ALTER TABLE "public"."dispatch_plan_items" ADD CONSTRAINT "dispatch_plan_items_detour_minutes_check" CHECK ((detour_minutes >= (0)::numeric));
ALTER TABLE "public"."dispatch_plan_items" ADD CONSTRAINT "dispatch_plan_items_commit_disposition_check" CHECK ((commit_disposition = ANY (ARRAY['pending'::text, 'included'::text, 'omitted'::text])));
ALTER TABLE "public"."dispatch_plan_items" ADD CONSTRAINT "dispatch_plan_items_item_type_check" CHECK ((item_type = ANY (ARRAY['cluster'::text, 'report'::text, 'bundled_report'::text])));
ALTER TABLE "public"."dispatch_plan_items" ADD CONSTRAINT "dispatch_item_target" CHECK ((((item_type = 'cluster'::text) AND (cluster_id IS NOT NULL) AND (report_id IS NULL) AND (anchor_cluster_id IS NULL)) OR ((item_type = 'report'::text) AND (report_id IS NOT NULL) AND (cluster_id IS NULL) AND (anchor_cluster_id IS NULL)) OR ((item_type = 'bundled_report'::text) AND (report_id IS NOT NULL) AND (cluster_id IS NULL) AND (anchor_cluster_id IS NOT NULL))));
ALTER TABLE "public"."cleanup_tasks" ADD CONSTRAINT "cleanup_tasks_bundle_detour_min_check" CHECK ((bundle_detour_min >= (0)::numeric));
ALTER TABLE "public"."cleanup_tasks" ADD CONSTRAINT "cleanup_tasks_dispatch_kind_check" CHECK ((dispatch_kind = ANY (ARRAY['standard'::text, 'sweeper'::text, 'mixed'::text])));
ALTER TABLE "public"."plan_generation_jobs" ADD CONSTRAINT "plan_generation_jobs_mode_check" CHECK ((mode = ANY (ARRAY['standard'::text, 'sweeper'::text, 'mixed'::text])));
ALTER TABLE "public"."plan_generation_jobs" ADD CONSTRAINT "plan_generation_jobs_status_check" CHECK ((status = ANY (ARRAY['queued'::text, 'running'::text, 'completed'::text, 'failed'::text])));
ALTER TABLE "public"."plan_generation_jobs" ADD CONSTRAINT "plan_generation_jobs_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."plan_generation_jobs" ADD CONSTRAINT "plan_generation_jobs_plan_id_key" UNIQUE (plan_id);
ALTER TABLE "public"."field_task_failure_events" ADD CONSTRAINT "field_task_failure_events_notes_check" CHECK ((length(btrim(notes)) > 0));
ALTER TABLE "public"."reports" ADD CONSTRAINT "reports_hazard_class_check" CHECK ((hazard_class = ANY (ARRAY['unknown'::text, 'standard'::text, 'suspected_hazard'::text, 'hazmat_required'::text])));
ALTER TABLE "public"."reports" ADD CONSTRAINT "reports_hazard_confidence_check" CHECK (((hazard_confidence IS NULL) OR ((hazard_confidence >= (0)::numeric) AND (hazard_confidence <= (1)::numeric))));
ALTER TABLE "public"."reports" ADD CONSTRAINT "reports_hazard_metadata_check" CHECK (((hazard_class = 'unknown'::text) OR ((hazard_model_version IS NOT NULL) AND (hazard_confidence IS NOT NULL) AND (hazard_decision_source IS NOT NULL) AND (hazard_classified_at IS NOT NULL))));
ALTER TABLE "public"."field_assignment_receipts" ADD CONSTRAINT "field_assignment_receipts_assignment_generation_check" CHECK ((assignment_generation > 0));
ALTER TABLE "public"."field_assignment_receipts" ADD CONSTRAINT "field_assignment_receipts_report_claim_generation_check" CHECK ((report_claim_generation > 0));
ALTER TABLE "public"."field_assignment_receipts" ADD CONSTRAINT "field_assignment_receipts_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."field_assignment_receipts" ADD CONSTRAINT "field_assignment_receipts_task_id_report_id_crew_id_assignm_key" UNIQUE (task_id, report_id, crew_id, assignment_generation, report_claim_generation);
ALTER TABLE "public"."report_resolution_events" ADD CONSTRAINT "report_resolution_events_resolution_kind_check" CHECK ((resolution_kind = 'cleaned'::text));
ALTER TABLE "public"."report_resolution_events" ADD CONSTRAINT "report_resolution_events_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."report_resolution_events" ADD CONSTRAINT "report_resolution_events_operation_id_key" UNIQUE (operation_id);
ALTER TABLE "public"."task_report_outcomes" ADD CONSTRAINT "task_report_outcomes_disposition_check" CHECK ((disposition = ANY (ARRAY['applied'::text, 'acknowledged_already_resolved'::text, 'verification_required'::text, 'contested'::text])));
ALTER TABLE "public"."task_report_outcomes" ADD CONSTRAINT "task_report_outcomes_evidence_refs_check" CHECK ((jsonb_typeof(evidence_refs) = 'array'::text));
ALTER TABLE "public"."task_report_outcomes" ADD CONSTRAINT "task_report_outcomes_pkey" PRIMARY KEY (id);
ALTER TABLE "public"."task_report_outcomes" ADD CONSTRAINT "task_report_outcomes_operation_id_key" UNIQUE (operation_id);
ALTER TABLE "public"."field_load_events" ADD CONSTRAINT "field_load_events_assignment_generation_check" CHECK ((assignment_generation > 0));
ALTER TABLE "public"."field_load_events" ADD CONSTRAINT "field_load_events_event_type_check" CHECK ((event_type = ANY (ARRAY['load_observation'::text, 'disposal'::text])));
ALTER TABLE "public"."field_load_events" ADD CONSTRAINT "field_load_events_fill_percent_check" CHECK (((fill_percent >= (0)::numeric) AND (fill_percent <= (100)::numeric)));
ALTER TABLE "public"."field_load_events" ADD CONSTRAINT "field_load_events_actual_volume_m3_check" CHECK ((actual_volume_m3 >= (0)::numeric));
ALTER TABLE "public"."field_load_events" ADD CONSTRAINT "field_load_events_actual_weight_kg_check" CHECK ((actual_weight_kg >= (0)::numeric));
ALTER TABLE "public"."audit_logs" ADD CONSTRAINT "response_log_report_id_fkey" FOREIGN KEY (report_id) REFERENCES reports(id) ON DELETE CASCADE;
ALTER TABLE "public"."audit_logs" ADD CONSTRAINT "response_log_user_id_fkey" FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE SET NULL;
ALTER TABLE "public"."profiles" ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY (id) REFERENCES auth.users(id);
ALTER TABLE "public"."reports" ADD CONSTRAINT "reports_user_id_fkey" FOREIGN KEY (user_id) REFERENCES profiles(id);
ALTER TABLE "public"."field_task_failure_events" ADD CONSTRAINT "field_task_failure_events_task_id_fkey" FOREIGN KEY (task_id) REFERENCES cleanup_tasks(id);
ALTER TABLE "public"."field_task_failure_events" ADD CONSTRAINT "field_task_failure_events_actor_id_fkey" FOREIGN KEY (actor_id) REFERENCES profiles(id);
ALTER TABLE "public"."cleanup_tasks" ADD CONSTRAINT "cleanup_tasks_assigned_by_fkey" FOREIGN KEY (assigned_by) REFERENCES profiles(id);
ALTER TABLE "public"."reports" ADD CONSTRAINT "reports_cleanup_task_id_fkey" FOREIGN KEY (cleanup_task_id) REFERENCES cleanup_tasks(id);
ALTER TABLE "public"."optimization_runs" ADD CONSTRAINT "optimization_runs_triggered_by_fkey" FOREIGN KEY (triggered_by) REFERENCES profiles(id);
ALTER TABLE "public"."optimization_runs" ADD CONSTRAINT "optimization_runs_approved_by_fkey" FOREIGN KEY (approved_by) REFERENCES profiles(id);
ALTER TABLE "public"."crew_routes" ADD CONSTRAINT "crew_routes_optimization_run_id_fkey" FOREIGN KEY (optimization_run_id) REFERENCES optimization_runs(id) ON DELETE CASCADE;
ALTER TABLE "public"."crew_routes" ADD CONSTRAINT "crew_routes_crew_id_fkey" FOREIGN KEY (crew_id) REFERENCES field_crews(id);
ALTER TABLE "public"."route_waypoints" ADD CONSTRAINT "route_waypoints_crew_route_id_fkey" FOREIGN KEY (crew_route_id) REFERENCES crew_routes(id) ON DELETE CASCADE;
ALTER TABLE "public"."route_waypoints" ADD CONSTRAINT "route_waypoints_cleanup_task_id_fkey" FOREIGN KEY (cleanup_task_id) REFERENCES cleanup_tasks(id);
ALTER TABLE "public"."cleanup_tasks" ADD CONSTRAINT "cleanup_tasks_crew_route_id_fkey" FOREIGN KEY (crew_route_id) REFERENCES crew_routes(id) ON DELETE SET NULL;
ALTER TABLE "public"."dispatch_plans" ADD CONSTRAINT "dispatch_plans_created_by_fkey" FOREIGN KEY (created_by) REFERENCES auth.users(id);
ALTER TABLE "public"."dispatch_plan_items" ADD CONSTRAINT "dispatch_plan_items_dispatch_plan_id_fkey" FOREIGN KEY (dispatch_plan_id) REFERENCES dispatch_plans(id) ON DELETE CASCADE;
ALTER TABLE "public"."dispatch_plan_items" ADD CONSTRAINT "dispatch_plan_items_cluster_id_fkey" FOREIGN KEY (cluster_id) REFERENCES clusters(id) ON DELETE CASCADE;
ALTER TABLE "public"."cleanup_tasks" ADD CONSTRAINT "cleanup_tasks_cluster_id_fkey" FOREIGN KEY (cluster_id) REFERENCES clusters(id);
ALTER TABLE "public"."cleanup_tasks" ADD CONSTRAINT "cleanup_tasks_lgu_user_id_fkey" FOREIGN KEY (lgu_user_id) REFERENCES profiles(id);
ALTER TABLE "public"."strikes" ADD CONSTRAINT "strikes_user_id_fkey" FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE CASCADE;
ALTER TABLE "public"."strikes" ADD CONSTRAINT "strikes_issued_by_fkey" FOREIGN KEY (issued_by) REFERENCES profiles(id);
ALTER TABLE "public"."cleanup_tasks" ADD CONSTRAINT "cleanup_tasks_created_by_fkey" FOREIGN KEY (created_by) REFERENCES auth.users(id);
ALTER TABLE "public"."cleanup_tasks" ADD CONSTRAINT "cleanup_tasks_completed_by_fkey" FOREIGN KEY (completed_by) REFERENCES profiles(id);
ALTER TABLE "public"."system_logs" ADD CONSTRAINT "audit_logs_user_id_fkey" FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE SET NULL;
ALTER TABLE "public"."manual_review_queue" ADD CONSTRAINT "manual_review_queue_report_id_fkey" FOREIGN KEY (report_id) REFERENCES reports(id) ON DELETE CASCADE;
ALTER TABLE "public"."manual_review_queue" ADD CONSTRAINT "manual_review_queue_strike_id_fkey" FOREIGN KEY (strike_id) REFERENCES strikes(id) ON DELETE SET NULL;
ALTER TABLE "public"."manual_review_queue" ADD CONSTRAINT "manual_review_queue_assigned_to_fkey" FOREIGN KEY (assigned_to) REFERENCES profiles(id) ON DELETE SET NULL;
ALTER TABLE "public"."reports" ADD CONSTRAINT "reports_manual_review_id_fkey" FOREIGN KEY (manual_review_id) REFERENCES manual_review_queue(id) ON DELETE SET NULL;
ALTER TABLE "public"."email_verifications" ADD CONSTRAINT "email_verifications_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
ALTER TABLE "public"."field_crews" ADD CONSTRAINT "field_crews_team_lead_profile_id_fkey" FOREIGN KEY (team_lead_profile_id) REFERENCES profiles(id);
ALTER TABLE "public"."sync_conflicts" ADD CONSTRAINT "sync_conflicts_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id);
ALTER TABLE "public"."sync_conflicts" ADD CONSTRAINT "sync_conflicts_resolved_by_fkey" FOREIGN KEY (resolved_by) REFERENCES auth.users(id);
ALTER TABLE "public"."fc_operation_log" ADD CONSTRAINT "fc_operation_log_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
ALTER TABLE "public"."optimization_templates" ADD CONSTRAINT "optimization_templates_created_by_fkey" FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE CASCADE;
ALTER TABLE "public"."report_resolution_events" ADD CONSTRAINT "report_resolution_events_crew_id_fkey" FOREIGN KEY (crew_id) REFERENCES profiles(id);
ALTER TABLE "public"."notifications" ADD CONSTRAINT "notifications_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
ALTER TABLE "public"."notifications" ADD CONSTRAINT "notifications_report_id_fkey" FOREIGN KEY (report_id) REFERENCES reports(id) ON DELETE CASCADE;
ALTER TABLE "public"."optimization_settings" ADD CONSTRAINT "optimization_settings_updated_by_fkey" FOREIGN KEY (updated_by) REFERENCES profiles(id);
ALTER TABLE "public"."fc_conflict_audit" ADD CONSTRAINT "fc_conflict_audit_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;
ALTER TABLE "public"."field_load_events" ADD CONSTRAINT "field_load_events_task_id_fkey" FOREIGN KEY (task_id) REFERENCES cleanup_tasks(id);
ALTER TABLE "public"."field_load_events" ADD CONSTRAINT "field_load_events_field_crew_id_fkey" FOREIGN KEY (field_crew_id) REFERENCES field_crews(id);
ALTER TABLE "public"."field_load_events" ADD CONSTRAINT "field_load_events_actor_id_fkey" FOREIGN KEY (actor_id) REFERENCES profiles(id);
ALTER TABLE "public"."dispatch_plans" ADD CONSTRAINT "dispatch_plans_optimization_run_id_fkey" FOREIGN KEY (optimization_run_id) REFERENCES optimization_runs(id);
ALTER TABLE "public"."dispatch_plan_items" ADD CONSTRAINT "dispatch_plan_items_report_id_fkey" FOREIGN KEY (report_id) REFERENCES reports(id);
ALTER TABLE "public"."dispatch_plan_items" ADD CONSTRAINT "dispatch_plan_items_planned_crew_id_fkey" FOREIGN KEY (planned_crew_id) REFERENCES field_crews(id);
ALTER TABLE "public"."cleanup_tasks" ADD CONSTRAINT "cleanup_tasks_source_plan_id_fkey" FOREIGN KEY (source_plan_id) REFERENCES dispatch_plans(id);
ALTER TABLE "public"."cleanup_tasks" ADD CONSTRAINT "cleanup_tasks_assigned_field_crew_id_fkey" FOREIGN KEY (assigned_field_crew_id) REFERENCES field_crews(id);
ALTER TABLE "public"."dispatch_group_commits" ADD CONSTRAINT "dispatch_group_commits_dispatch_plan_id_fkey" FOREIGN KEY (dispatch_plan_id) REFERENCES dispatch_plans(id);
ALTER TABLE "public"."dispatch_access_blocks" ADD CONSTRAINT "dispatch_access_blocks_cluster_id_fkey" FOREIGN KEY (cluster_id) REFERENCES clusters(id);
ALTER TABLE "public"."dispatch_access_blocks" ADD CONSTRAINT "dispatch_access_blocks_report_id_fkey" FOREIGN KEY (report_id) REFERENCES reports(id);
ALTER TABLE "public"."dispatch_access_blocks" ADD CONSTRAINT "dispatch_access_blocks_task_id_fkey" FOREIGN KEY (task_id) REFERENCES cleanup_tasks(id);
ALTER TABLE "public"."dispatch_access_blocks" ADD CONSTRAINT "dispatch_access_blocks_blocked_by_fkey" FOREIGN KEY (blocked_by) REFERENCES profiles(id);
ALTER TABLE "public"."dispatch_access_blocks" ADD CONSTRAINT "dispatch_access_blocks_cleared_by_fkey" FOREIGN KEY (cleared_by) REFERENCES profiles(id);
ALTER TABLE "public"."reports" ADD CONSTRAINT "reports_cluster_id_fkey" FOREIGN KEY (cluster_id) REFERENCES clusters(id) ON UPDATE CASCADE ON DELETE SET NULL;
ALTER TABLE "public"."field_crews" ADD CONSTRAINT "field_crews_certification_reviewed_by_fkey" FOREIGN KEY (certification_reviewed_by) REFERENCES profiles(id);
ALTER TABLE "public"."dispatch_plan_items" ADD CONSTRAINT "dispatch_plan_items_anchor_cluster_id_fkey" FOREIGN KEY (anchor_cluster_id) REFERENCES clusters(id);
ALTER TABLE "public"."dispatch_plan_items" ADD CONSTRAINT "dispatch_plan_items_committed_task_id_fkey" FOREIGN KEY (committed_task_id) REFERENCES cleanup_tasks(id);
ALTER TABLE "public"."route_waypoints" ADD CONSTRAINT "route_waypoints_report_id_fkey" FOREIGN KEY (report_id) REFERENCES reports(id);
ALTER TABLE "public"."plan_generation_jobs" ADD CONSTRAINT "plan_generation_jobs_requested_by_fkey" FOREIGN KEY (requested_by) REFERENCES profiles(id);
ALTER TABLE "public"."plan_generation_jobs" ADD CONSTRAINT "plan_generation_jobs_plan_id_fkey" FOREIGN KEY (plan_id) REFERENCES dispatch_plans(id);
ALTER TABLE "public"."dispatch_plans" ADD CONSTRAINT "dispatch_plans_generation_job_id_fkey" FOREIGN KEY (generation_job_id) REFERENCES plan_generation_jobs(id);
ALTER TABLE "public"."field_assignment_receipts" ADD CONSTRAINT "field_assignment_receipts_task_id_fkey" FOREIGN KEY (task_id) REFERENCES cleanup_tasks(id);
ALTER TABLE "public"."field_assignment_receipts" ADD CONSTRAINT "field_assignment_receipts_report_id_fkey" FOREIGN KEY (report_id) REFERENCES reports(id);
ALTER TABLE "public"."field_assignment_receipts" ADD CONSTRAINT "field_assignment_receipts_crew_id_fkey" FOREIGN KEY (crew_id) REFERENCES profiles(id);
ALTER TABLE "public"."report_resolution_events" ADD CONSTRAINT "report_resolution_events_report_id_fkey" FOREIGN KEY (report_id) REFERENCES reports(id);
ALTER TABLE "public"."report_resolution_events" ADD CONSTRAINT "report_resolution_events_task_id_fkey" FOREIGN KEY (task_id) REFERENCES cleanup_tasks(id);
ALTER TABLE "public"."task_report_outcomes" ADD CONSTRAINT "task_report_outcomes_task_id_fkey" FOREIGN KEY (task_id) REFERENCES cleanup_tasks(id);
ALTER TABLE "public"."task_report_outcomes" ADD CONSTRAINT "task_report_outcomes_report_id_fkey" FOREIGN KEY (report_id) REFERENCES reports(id);
ALTER TABLE "public"."task_report_outcomes" ADD CONSTRAINT "task_report_outcomes_crew_id_fkey" FOREIGN KEY (crew_id) REFERENCES profiles(id);
ALTER TABLE "public"."task_report_outcomes" ADD CONSTRAINT "task_report_outcomes_receipt_id_fkey" FOREIGN KEY (receipt_id) REFERENCES field_assignment_receipts(id);
ALTER TABLE "public"."task_report_outcomes" ADD CONSTRAINT "task_report_outcomes_resolution_event_id_fkey" FOREIGN KEY (resolution_event_id) REFERENCES report_resolution_events(id);
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
end; $function$
;
CREATE OR REPLACE FUNCTION public.upsert_cluster_for_reports_old(p_report_ids uuid[], p_issue_type text, p_severity text, p_radius_meters double precision)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  RAISE EXCEPTION 'Function public.upsert_cluster_for_reports_old is deprecated. Use upsert_cluster_for_reports_v2 instead.';
END;
$function$
;
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
end; $function$
;
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
$function$
;
CREATE OR REPLACE FUNCTION workflow_private.bump_task_assignment_generation()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if tg_op = 'INSERT' then
    if new.assigned_field_crew_id is not null
       or cardinality(coalesce(new.assigned_crew_ids, '{}'::uuid[])) > 0 then
      new.assignment_generation := greatest(new.assignment_generation, 1);
    end if;
  elsif new.assigned_field_crew_id is distinct from old.assigned_field_crew_id
     or new.assigned_crew_ids is distinct from old.assigned_crew_ids
     or new.crew_route_id is distinct from old.crew_route_id
     or new.route_revision is distinct from old.route_revision then
    new.assignment_generation := old.assignment_generation + 1;
  else
    new.assignment_generation := old.assignment_generation;
  end if;
  return new;
end;
$function$
;
CREATE OR REPLACE FUNCTION workflow_private.can_execute_task(actor uuid, task cleanup_tasks)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select exists(select 1 from public.profiles p where p.id=actor and
    (p.role::text in ('admin','officer') or (p.role::text='field_crew' and
      task.route_status='ready' and actor=any(coalesce(task.assigned_crew_ids,'{}'::uuid[])))));
$function$
;
CREATE OR REPLACE FUNCTION public.dbscan_reports(p_eps double precision, p_minpoints integer)
 RETURNS TABLE(id uuid, issue_type text, location geometry, cluster_id integer)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if p_eps<=0 or p_eps>10000 or p_minpoints<2 or p_minpoints>100 then raise exception 'Invalid clustering parameters'; end if;
  return query select r.id,r.issue_type::text,r.location::extensions.geometry,
    extensions.st_clusterdbscan(extensions.st_transform(r.location::extensions.geometry,32651),eps:=p_eps,minpoints:=p_minpoints) over()
    from public.reports r where r.status::text='unresolved' and r.cluster_id is null and r.cleanup_task_id is null
      and r.lifecycle_state='fresh'
      and not exists(select 1 from public.dispatch_access_blocks b where b.report_id=r.id and b.cleared_at is null);
end; $function$
;
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
end; $function$
;
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
end; $function$
;
CREATE OR REPLACE FUNCTION public.check_overdue_reports()
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  -- Deprecated: Superseded by public.advance_report_lifecycle() running under pg_cron
  RAISE NOTICE 'Function public.check_overdue_reports is deprecated. Handled by advance_report_lifecycle.';
END;
$function$
;
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
end; $function$
;
CREATE OR REPLACE FUNCTION public.task_coordinates(task_ids uuid[])
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object('id',t.id,'lat',extensions.st_y(coalesce(t.location::extensions.geometry,c.center)),
    'lng',extensions.st_x(coalesce(t.location::extensions.geometry,c.center)))),'[]'::jsonb)
  from public.cleanup_tasks t left join public.clusters c on c.id=t.cluster_id where t.id=any(task_ids);
$function$
;
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
end; $function$
;
CREATE OR REPLACE FUNCTION public.set_report_photo(report_id uuid, actor uuid, slot text, url text, photo_hash text, expected_version bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare claim uuid; task public.cleanup_tasks; report public.reports; prior_url text;
begin
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
  if report.status::text in ('resolved','completed','closed','rejected') then
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
end; $function$
;
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
$function$
;
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
$function$
;
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
$function$
;
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
begin
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
  return jsonb_build_object('status','created','task',to_jsonb(task));
end; $function$
;
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
begin
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
    where e.ref !~ '^https://[^[:space:]]+$') then
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
      update public.reports set status='resolved',lgu_resolved_at=now(),updated_at=now()
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
$function$
;
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
$function$
;
CREATE OR REPLACE FUNCTION public.nextval(seq_name text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  RETURN nextval(seq_name::regclass);
END;
$function$
;
CREATE OR REPLACE FUNCTION public.advance_report_lifecycle()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare cfg record; changed integer; breaches jsonb;
begin
  if not pg_catalog.pg_try_advisory_xact_lock(72631008) then
    return jsonb_build_object('skipped',true,'changedCount',0,'newlyBreached','[]'::jsonb);
  end if;
  if not exists(select 1 from workflow_private.lifecycle_deployment) then
    raise exception 'Report lifecycle has not been activated';
  end if;
  select * into cfg from workflow_private.lifecycle_config();
  with candidates as materialized (
    select r.id,r.breached_at as old_breached from public.reports r
    where r.lifecycle_state is distinct from 'closed' and (
      r.lifecycle_state is distinct from workflow_private.derive_report_lifecycle(
        r.status::text,r.cluster_id,r.cleanup_task_id,r.sla_started_at,r.deadline_at,
        case when workflow_private.severity_tier(r.severity_score)='high' then cfg.high_hours else cfg.normal_hours end,statement_timestamp())
      or (r.breached_at is null and statement_timestamp() >= r.deadline_at)
      or (r.matured_at is null and statement_timestamp() >= r.sla_started_at +
        (case when workflow_private.severity_tier(r.severity_score)='high' then cfg.high_hours else cfg.normal_hours end) * interval '1 hour'))
    for update skip locked
  ), updated as (
    update public.reports r set updated_at=statement_timestamp() from candidates c where r.id=c.id
    returning r.id,r.breached_at,c.old_breached,r.sla_started_at
  )
  select count(*)::integer,coalesce(jsonb_agg(jsonb_build_object('id',u.id,
    'breachDuration',extract(epoch from(statement_timestamp()-u.sla_started_at))/3600,
    'timestamp',u.breached_at)) filter(where u.old_breached is null and u.breached_at is not null),'[]'::jsonb)
    into changed,breaches from updated u;
  insert into public.sweeper_audit_log(event_type,entity_type,entity_id,user_id,event_data)
    values ('LIFECYCLE_RUN_COMPLETED','SYSTEM','report_lifecycle','system',
      jsonb_build_object('changedCount',changed,'newlyBreachedCount',jsonb_array_length(breaches)));
  return jsonb_build_object('skipped',false,'changedCount',changed,'newlyBreached',breaches);
end;
$function$
;
CREATE OR REPLACE FUNCTION workflow_private.issue_task_report_receipts()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if new.assignment_generation = 0 then return new; end if;
  if tg_op = 'UPDATE' then
    if new.assignment_generation is not distinct from old.assignment_generation then return new; end if;
  end if;
    insert into public.field_assignment_receipts
      (task_id,report_id,crew_id,assignment_generation,report_claim_generation)
    select new.id,r.id,crew.id,new.assignment_generation,r.report_claim_generation
      from public.reports r
      cross join lateral unnest(coalesce(new.assigned_crew_ids,'{}'::uuid[])) crew(id)
      where r.cleanup_task_id = new.id and r.report_claim_generation > 0
    on conflict do nothing;
  return new;
end;
$function$
;
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
$function$
;
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
$function$
;
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
$function$
;
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
$function$
;
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
begin
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
end; $function$
;
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
end; $function$
;
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
    NEW.updated_at = timezone('utc'::text, now());
    RETURN NEW;
END;
$function$
;
CREATE OR REPLACE FUNCTION public.upsert_cluster_for_reports(p_report_ids uuid[], p_issue_type text, p_severity text, p_radius_meters numeric)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  RAISE EXCEPTION 'Function public.upsert_cluster_for_reports is deprecated. Use upsert_cluster_for_reports_v2 instead.';
END;
$function$
;
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
$function$
;
CREATE OR REPLACE FUNCTION workflow_private.apply_report_lifecycle()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  deployed timestamptz;
  cfg record;
  maturation numeric;
  stamp timestamptz := statement_timestamp();
begin
  select activated_at into deployed from workflow_private.lifecycle_deployment where singleton;
  if deployed is null then
    new.sla_started_at := null;
    new.lifecycle_state := null;
    new.matured_at := null;
    new.breached_at := null;
    return new;
  end if;
  select * into cfg from workflow_private.lifecycle_config();
  maturation := case when workflow_private.severity_tier(new.severity_score)='high'
    then cfg.high_hours else cfg.normal_hours end;
  if tg_op='INSERT' then
    new.sla_started_at := stamp;
    new.deadline_at := stamp + cfg.sla_hours * interval '1 hour';
    new.matured_at := null;
    new.breached_at := null;
  else
    -- An unresolved predeployment report receives the deployment clock exactly once.
    new.sla_started_at := coalesce(old.sla_started_at,
      case when old.status::text='unresolved' then deployed else coalesce(old.created_at, deployed) end);
    new.deadline_at := case when old.sla_started_at is not null then old.deadline_at
      when old.status::text='unresolved' then deployed + cfg.sla_hours * interval '1 hour'
      else coalesce(old.deadline_at, new.sla_started_at + cfg.sla_hours * interval '1 hour') end;
    new.matured_at := old.matured_at;
    new.breached_at := old.breached_at;
  end if;
  -- Include closure updates so completion at/after the deadline cannot erase a breach.
  -- Existing closed reports have no reconstructed cleanup/SLA history.
  if tg_op='INSERT' or coalesce(old.status::text,'unresolved') not in ('resolved','completed','closed','rejected') then
    if stamp >= new.sla_started_at + maturation * interval '1 hour' then
      new.matured_at := coalesce(new.matured_at, new.sla_started_at + maturation * interval '1 hour');
    end if;
    if stamp >= new.deadline_at then
      new.breached_at := coalesce(new.breached_at, new.deadline_at);
    end if;
  end if;
  new.lifecycle_state := workflow_private.derive_report_lifecycle(
    new.status::text,new.cluster_id,new.cleanup_task_id,new.sla_started_at,new.deadline_at,maturation,stamp);
  return new;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.get_auth_user_role()
 RETURNS role
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT role FROM public.profiles WHERE id = (SELECT auth.uid());
$function$
;
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
$function$
;
CREATE OR REPLACE FUNCTION public.apply_fc_operation(actor uuid, operation_id text, operation_type text, entity_id uuid, entity_type text, payload jsonb, base_version bigint DEFAULT 0)
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
begin
  if operation_id is null or length(operation_id) not between 1 and 200 or jsonb_typeof(payload) is distinct from 'object'
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
    if prior.user_id <> actor or prior.entity_id <> entity_id::text or prior.operation_type::text <> operation_type then
      raise exception 'Operation ID belongs to another request' using errcode = '42501';
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
        when 'fc.report.update_status' then array['status']
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
            notes = patched.notes, 
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

  result := result || jsonb_build_object('operation_id', operation_id, 'payload', payload, 'payload_hash', md5(payload::text));

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
$function$
;
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
end; $function$
;
CREATE OR REPLACE FUNCTION public.submit_task_outcome(task_id uuid, actor uuid, outcome text, notes text, classification text DEFAULT NULL::text, expected_version bigint DEFAULT NULL::bigint, operation_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare task public.cleanup_tasks; cleaned boolean; terminal boolean; target_status public.cleanup_task_status;
begin
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
    update public.reports set status='resolved',lgu_resolved_at=now(),updated_at=now() where cleanup_task_id=task_id
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
end; $function$
;
CREATE OR REPLACE FUNCTION public.expire_unpublished_dispatch_claims()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare task public.cleanup_tasks; expired integer:=0; escalated integer:=0;
begin
  for task in select * from public.cleanup_tasks where route_status='needs_replan'
    and routing_deadline_at<=now()+interval '15 minutes' order by id for update skip locked loop
    if task.routing_deadline_at<=now() and task.assigned_at is null and coalesce(cardinality(task.assigned_crew_ids),0)=0 and task.status::text in ('created','pending') then
      update public.cleanup_tasks set route_status='expired',status='cancelled',failure_class='transient',
        failure_reason='Unpublished route planning expired',completion_result='routing_expired' where id=task.id;
      expired:=expired+1;
    elsif task.routing_escalated_at is null then
      update public.cleanup_tasks set routing_escalated_at=now() where id=task.id;
      insert into public.sweeper_audit_log(event_type,entity_type,entity_id,user_id,event_data)
        values('ROUTING_ESCALATION','TASK',task.id::text,'system',jsonb_build_object('routing_deadline_at',task.routing_deadline_at,'assigned_at',task.assigned_at));
      escalated:=escalated+1;
    end if;
  end loop;
  return jsonb_build_object('expiredCount',expired,'escalatedCount',escalated);
end; $function$
;
CREATE OR REPLACE FUNCTION public.upsert_cluster_for_reports_v2(p_report_ids uuid[], p_issue_type text, p_severity text, p_radius_meters double precision)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare locked_ids uuid[]; centroid extensions.geometry; cluster uuid;
begin
  if cardinality(p_report_ids)<2 or cardinality(p_report_ids)<>(select count(distinct x) from unnest(p_report_ids) x) then raise exception 'Distinct fresh reports required'; end if;
  select array_agg(id order by id) into locked_ids from (
    select r.id from public.reports r where id=any(p_report_ids) and r.status::text='unresolved'
      and cluster_id is null and cleanup_task_id is null and lifecycle_state='fresh'
      and not exists(select 1 from public.dispatch_access_blocks b where b.report_id=r.id and b.cleared_at is null)
    order by id for update skip locked
  ) r;
  if coalesce(cardinality(locked_ids),0)<>cardinality(p_report_ids) then raise exception 'Clustering snapshot is stale'; end if;
  select extensions.st_centroid(extensions.st_collect(location::extensions.geometry)) into centroid from public.reports where id=any(locked_ids);
  insert into public.clusters(center,issue_type,severity,status,radius_meters,report_count)
    values(centroid,p_issue_type::public.report_issue_type,p_severity::public.cluster_severity,'new',p_radius_meters,cardinality(locked_ids)) returning id into cluster;
  update public.reports set cluster_id=cluster,updated_at=now() where id=any(locked_ids);
  return cluster;
end; $function$
;
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
end; $function$
;
CREATE OR REPLACE FUNCTION public.change_field_crew_member(crew_id uuid, actor uuid, member_id uuid, action text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare crew public.field_crews;
begin
  perform workflow_private.require_desk_actor(actor);
  if action is null or action not in ('add','remove') or member_id is null then raise exception 'Invalid membership action'; end if;
  perform pg_advisory_xact_lock(72631010);
  select * into crew from public.field_crews where id=crew_id for update;
  if not found then raise exception 'Crew not found'; end if;
  if action='add' then
    if not exists(select 1 from public.profiles where id=member_id and role::text='field_crew') then raise exception 'Member must have field_crew role'; end if;
    if exists(select 1 from public.field_crews where id<>crew_id and (member_id=any(coalesce(member_profile_ids,'{}'::uuid[])) or team_lead_profile_id=member_id)) then raise exception 'Member already belongs to another crew'; end if;
    update public.field_crews set member_profile_ids=array(select distinct x from unnest(coalesce(crew.member_profile_ids,'{}'::uuid[])||array[member_id]) x),updated_at=now() where id=crew_id returning * into crew;
  else
    update public.field_crews set member_profile_ids=array_remove(member_profile_ids,member_id),
      team_lead_profile_id=case when team_lead_profile_id=member_id then null else team_lead_profile_id end,updated_at=now() where id=crew_id returning * into crew;
  end if;
  return to_jsonb(crew);
end; $function$
;
CREATE OR REPLACE FUNCTION public.set_task_photo(task_id uuid, actor uuid, slot text, url text, photo_hash text, expected_version bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare task public.cleanup_tasks;
begin
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
end; $function$
;
CREATE OR REPLACE FUNCTION workflow_private.immutable_group_result()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$ begin
  raise exception 'Dispatch group results are immutable';
end; $function$
;
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
end; $function$
;
CREATE OR REPLACE FUNCTION workflow_private.bump_report_version()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  -- Server lifecycle/assignment changes invalidate every cached mobile snapshot too.
  new.fc_version:=old.fc_version+1;
  return new;
end; $function$
;
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
end; $function$
;
CREATE OR REPLACE FUNCTION public.mixed_planning_snapshot()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
with anchors as (
  select c.id, c.priority_score, c.estimated_effort_minutes, c.recommended_task_type,
    c.created_at, extensions.st_y(c.center) as lat, extensions.st_x(c.center) as lng,
    (select case when count(*)=count(w.estimated_volume_m3) then sum(w.estimated_volume_m3) end from public.reports r left join public.work_time_configuration w on w.report_type=r.issue_type::text
      where r.cluster_id=c.id and r.cleanup_task_id is null and r.status::text not in ('resolved','completed','closed','rejected')) as estimated_volume_m3,
    (select case when count(*)=count(w.estimated_weight_kg) then sum(w.estimated_weight_kg) end from public.reports r left join public.work_time_configuration w on w.report_type=r.issue_type::text
      where r.cluster_id=c.id and r.cleanup_task_id is null and r.status::text not in ('resolved','completed','closed','rejected')) as estimated_weight_kg,
    array(select r.id from public.reports r where r.cluster_id=c.id
      and r.cleanup_task_id is null and r.status::text not in ('resolved','completed','closed','rejected')
      order by r.id) as report_ids
  from public.clusters c
  where c.status::text in ('new','unresolved','prioritized','queued','monitoring')
    and not exists(select 1 from public.dispatch_access_blocks b where b.cluster_id=c.id and b.cleared_at is null)
    and not exists(select 1 from public.reports r join public.dispatch_access_blocks b on b.report_id=r.id
      where r.cluster_id=c.id and b.cleared_at is null)
  order by c.priority_score desc nulls last,c.id limit 200
),
satellites as (
  select r.id, r.issue_type::text, r.lifecycle_state::text, r.severity_score, r.urgency_score,
    r.created_at, r.sla_started_at, r.deadline_at,
    extensions.st_y(r.location::extensions.geometry) as lat,
    extensions.st_x(r.location::extensions.geometry) as lng,
    w.work_time_minutes, w.estimated_volume_m3, w.estimated_weight_kg,
    exists(select 1 from public.dispatch_access_blocks b where b.report_id=r.id and b.cleared_at is null) as blocked
  from public.reports r left join public.work_time_configuration w on w.report_type=r.issue_type::text
  where r.status::text='unresolved' and r.cluster_id is null and r.cleanup_task_id is null
    and r.lifecycle_state in ('maturing','sla_breached') and r.location is not null
  order by r.deadline_at nulls last,r.id limit 200
)
select jsonb_build_object(
  'anchors',coalesce((select jsonb_agg(to_jsonb(a)) from anchors a where cardinality(a.report_ids)>0),'[]'::jsonb),
  'satellites',coalesce((select jsonb_agg(to_jsonb(s)) from satellites s),'[]'::jsonb)
);
$function$
;
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
end; $function$
;
CREATE OR REPLACE FUNCTION public.claim_plan_generation(worker_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare job public.plan_generation_jobs;
begin
  if worker_id is null then raise exception 'Worker token required'; end if;
  update public.plan_generation_jobs set status='failed',finished_at=now(),error_code='worker_lease_expired'
    where status='running' and lease_until<now();
  update public.plan_generation_jobs set status='running',started_at=now(),
    lease_until=now()+interval '3 minutes',worker_token=worker_id
    where id=(select id from public.plan_generation_jobs where status='queued'
      order by requested_at,id for update skip locked limit 1)
    returning * into job;
  if not found then return null; end if;
  return to_jsonb(job);
end; $function$
;
CREATE OR REPLACE FUNCTION public.commit_mixed_dispatch_plan(plan_id uuid, actor uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare plan public.dispatch_plans; anchor public.dispatch_plan_items; satellite public.dispatch_plan_items;
  crew public.field_crews; task public.cleanup_tasks; result jsonb; results jsonb:='[]'::jsonb;
  mandatory_ids uuid[]; satellite_ids uuid[]; locked_ids uuid[]; cluster_ids uuid[];
  omitted_ids uuid[]; member_count integer; claimed integer; reason text;
  group_minutes numeric; group_volume numeric; group_weight numeric; busy_minutes numeric; busy_count integer;
  busy_volume numeric; busy_weight numeric; budget numeric; shift_minutes numeric;
begin
  perform workflow_private.require_desk_actor(actor);
  select * into plan from public.dispatch_plans where id=plan_id for update;
  if not found then raise exception 'Plan not found'; end if;
  if plan.mode<>'mixed' then raise exception 'Mixed plan required'; end if;
  if plan.status::text='discarded' then raise exception 'Plan discarded'; end if;
  if not exists(select 1 from public.plan_generation_jobs j where j.id=plan.generation_job_id
      and j.status='completed' and j.plan_id=plan.id) then raise exception 'Planning job is incomplete'; end if;
  if jsonb_typeof(plan.route_proposal->'routes') is distinct from 'array' then raise exception 'Validated route proposal required'; end if;
  perform id from public.field_crews where id in
    (select planned_crew_id from public.dispatch_plan_items where dispatch_plan_id=plan_id and is_selected)
    order by id for update;
  for anchor in select distinct on (group_key) * from public.dispatch_plan_items
      where dispatch_plan_id=plan_id and is_selected and item_type in ('cluster','report')
      order by group_key,id loop
    select c.result into result from public.dispatch_group_commits c
      where c.dispatch_plan_id=plan_id and c.group_key=anchor.group_key;
    if found then results:=results||jsonb_build_array(result); continue; end if;
    reason:=null;
    begin
      select * into crew from public.field_crews where id=anchor.planned_crew_id for update;
      if not found or crew.availability_status::text<>'available'
        or (anchor.item_type='cluster' and not crew.supports_standard)
        or (anchor.item_type='report' and not crew.supports_sweeper) then raise exception 'crew_unavailable'; end if;
      if coalesce(cardinality(crew.member_profile_ids),0)=0 and crew.team_lead_profile_id is null then
        raise exception 'crew_has_no_members'; end if;
      if (anchor.crew_snapshot->>'speed_factor')::numeric is distinct from crew.speed_factor
        or (anchor.crew_snapshot->>'service_time_factor')::numeric is distinct from crew.service_time_factor then
        raise exception 'crew_timing_changed'; end if;
      if crew.max_volume_m3 is null or crew.max_weight_kg is null
        or crew.starting_volume_m3 is null or crew.starting_weight_kg is null then
        raise exception 'unknown_load'; end if;
      cluster_ids:=case when anchor.item_type='cluster' then
        coalesce(nullif(anchor.cluster_ids,'{}'::uuid[]),array[anchor.cluster_id]) else '{}'::uuid[] end;
      if anchor.item_type='cluster' then
        select count(*) into member_count from (
          select c.id from public.clusters c where c.id=any(cluster_ids)
            and c.status::text in ('new','unresolved','prioritized','queued','monitoring')
            and not exists(select 1 from public.dispatch_access_blocks b where b.cluster_id=c.id and b.cleared_at is null)
            order by c.id for update skip locked
        ) locked_clusters;
        if member_count<>cardinality(cluster_ids) then raise exception 'stale_anchor'; end if;
        if exists(select 1 from public.reports r where r.cluster_id=any(cluster_ids)
          and r.cleanup_task_id is null and r.status::text not in ('resolved','completed','closed','rejected')
          and not(r.id=any(anchor.report_ids))) then raise exception 'anchor_membership_changed'; end if;
      end if;
      select coalesce(array_agg(r.id order by r.id),'{}'::uuid[]) into mandatory_ids from (
        select id from public.reports r where id=any(anchor.report_ids) and cleanup_task_id is null
          and status::text not in ('resolved','completed','closed','rejected')
          and ((anchor.item_type='cluster' and cluster_id=any(cluster_ids))
             or (anchor.item_type='report' and cluster_id is null and lifecycle_state in ('maturing','sla_breached')))
          and not exists(select 1 from public.dispatch_access_blocks b where b.report_id=r.id and b.cleared_at is null)
          order by id for update skip locked
      ) r;
      if cardinality(mandatory_ids)<>cardinality(anchor.report_ids) then raise exception 'stale_anchor'; end if;
      satellite_ids:='{}'::uuid[]; omitted_ids:='{}'::uuid[];
      for satellite in select * from public.dispatch_plan_items
        where dispatch_plan_id=plan_id and group_key=anchor.group_key and item_type='bundled_report' and is_selected
        order by bundle_order,id loop
        if satellite.planned_crew_id is distinct from crew.id then raise exception 'crew_assignment_changed'; end if;
        select array_agg(r.id) into locked_ids from (
          select id from public.reports r where r.id=satellite.report_id and r.cleanup_task_id is null
            and r.cluster_id is null and r.lifecycle_state in ('maturing','sla_breached')
            and r.status::text='unresolved'
            and not exists(select 1 from public.dispatch_access_blocks b where b.report_id=r.id and b.cleared_at is null)
            for update skip locked
        ) r;
        if locked_ids is null then
          omitted_ids:=array_append(omitted_ids,satellite.report_id);
          update public.dispatch_plan_items set commit_disposition='omitted',commit_reason='satellite_unavailable'
            where id=satellite.id;
        else
          satellite_ids:=array_append(satellite_ids,satellite.report_id);
        end if;
      end loop;
      group_minutes:=anchor.estimated_duration_minutes+coalesce((select sum(i.estimated_duration_minutes)
        from public.dispatch_plan_items i where i.dispatch_plan_id=plan_id and i.group_key=anchor.group_key
          and i.report_id=any(satellite_ids)),0);
      group_volume:=anchor.estimated_volume_m3+coalesce((select sum(i.estimated_volume_m3)
        from public.dispatch_plan_items i where i.dispatch_plan_id=plan_id and i.group_key=anchor.group_key
          and i.report_id=any(satellite_ids)),0);
      group_weight:=anchor.estimated_weight_kg+coalesce((select sum(i.estimated_weight_kg)
        from public.dispatch_plan_items i where i.dispatch_plan_id=plan_id and i.group_key=anchor.group_key
          and i.report_id=any(satellite_ids)),0);
      if group_volume is null or group_weight is null then raise exception 'unknown_load'; end if;
      select coalesce(sum(coalesce(estimated_duration_min,60)),0),count(*),
        coalesce(sum(estimated_volume_m3),0),coalesce(sum(estimated_weight_kg),0)
        into busy_minutes,busy_count,busy_volume,busy_weight from public.cleanup_tasks
        where assigned_field_crew_id=crew.id and status::text not in ('completed','cancelled');
      if exists(select 1 from public.cleanup_tasks t where t.assigned_field_crew_id=crew.id
        and t.status::text not in ('completed','cancelled')
        and (t.estimated_volume_m3 is null or t.estimated_weight_kg is null)) then
        raise exception 'unknown_load'; end if;
      shift_minutes:=extract(epoch from(crew.shift_end-crew.shift_start))/60;
      if shift_minutes<0 then shift_minutes:=shift_minutes+1440; end if;
      budget:=greatest(0,(shift_minutes-coalesce((plan.settings_snapshot->>'break_duration_min')::numeric,60)
        +coalesce((plan.settings_snapshot->>'overtime_tolerance_min')::numeric,15))
        *coalesce((plan.settings_snapshot->>'capacity_utilization')::numeric,1));
      if busy_minutes+group_minutes>budget or busy_count>=least(coalesce(crew.max_tasks_per_shift,10),
        coalesce((plan.settings_snapshot->>'max_tasks_per_shift')::integer,15)) then
        raise exception 'crew_capacity_changed'; end if;
      if crew.starting_volume_m3+busy_volume+group_volume>crew.max_volume_m3 then raise exception 'capacity_volume'; end if;
      if crew.starting_weight_kg+busy_weight+group_weight>crew.max_weight_kg then raise exception 'capacity_weight'; end if;
      insert into public.cleanup_tasks(cluster_id,cluster_ids,report_ids,report_sequence,satellite_report_ids,
        title,status,task_type,estimated_duration_min,estimated_work_minutes,created_by,source_plan_id,
        source_group_key,assigned_field_crew_id,dispatch_kind,route_status,routing_deadline_at,
        scheduled_date,location,priority_score,estimated_volume_m3,estimated_weight_kg)
      values(anchor.cluster_id,cluster_ids,mandatory_ids||satellite_ids,mandatory_ids||satellite_ids,satellite_ids,
        case when anchor.item_type='cluster' then 'Mixed cluster cleanup' else 'Sweeper pickup' end,
        'pending',case when anchor.item_type='cluster' then 'Mixed'::public.cleanup_task_type else 'Sweeper'::public.cleanup_task_type end,
        ceil(group_minutes),anchor.estimated_work_minutes+coalesce((select sum(i.estimated_work_minutes)
          from public.dispatch_plan_items i where i.dispatch_plan_id=plan_id and i.group_key=anchor.group_key
            and i.report_id=any(satellite_ids)),0),actor,plan_id,anchor.group_key,crew.id,'mixed',
        'needs_replan',now()+interval '30 minutes',plan.planned_date,
        (select location from public.reports where id=mandatory_ids[1]),
        anchor.priority_score,group_volume,group_weight) returning * into task;
      update public.reports set cleanup_task_id=task.id,updated_at=now()
        where id=any(mandatory_ids||satellite_ids) and cleanup_task_id is null;
      get diagnostics claimed=row_count;
      if claimed<>cardinality(mandatory_ids)+cardinality(satellite_ids) then raise exception 'stale_group'; end if;
      update public.clusters set status='scheduled' where id=any(cluster_ids);
      update public.dispatch_plan_items set commit_disposition='included',committed_task_id=task.id
        where dispatch_plan_id=plan_id and group_key=anchor.group_key and is_selected
          and (item_type<>'bundled_report' or report_id=any(satellite_ids));
      result:=jsonb_build_object('status',case when cardinality(omitted_ids)>0 then 'partial_commit' else 'committed' end,
        'group_key',anchor.group_key,'task_id',task.id,'crew_id',crew.id,
        'report_ids',mandatory_ids||satellite_ids,'satellite_report_ids',satellite_ids,'omitted_satellite_ids',omitted_ids);
    exception when raise_exception then
      get stacked diagnostics reason=message_text;
      if reason not in ('crew_unavailable','crew_has_no_members','crew_timing_changed','unknown_load',
        'stale_anchor','anchor_membership_changed','crew_assignment_changed','crew_capacity_changed',
        'capacity_volume','capacity_weight','stale_group','dispatch_blocked') then raise; end if;
      result:=jsonb_build_object('status','skipped','group_key',anchor.group_key,'reason',reason);
    end;
    insert into public.dispatch_group_commits(dispatch_plan_id,group_key,result)
      values(plan_id,anchor.group_key,result);
    results:=results||jsonb_build_array(result);
  end loop;
  update public.dispatch_plans set status='approved' where id=plan_id;
  return jsonb_build_object('plan_id',plan_id,'results',results,'tasks',
    coalesce((select jsonb_agg(to_jsonb(t)) from public.cleanup_tasks t where t.source_plan_id=plan_id),'[]'::jsonb));
end; $function$
;
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
end; $function$
;
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
end; $function$
;
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
end; $function$
;
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
$function$
;
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
$function$
;
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
$function$
;
CREATE VIEW public."response_log" WITH (security_invoker=true) AS  SELECT id,
    report_id,
    user_id,
    action_type,
    action_details,
    created_at
   FROM audit_logs;
CREATE VIEW public."reports_view" WITH (security_invoker=true) AS  SELECT id,
    user_id,
    title,
    description,
    issue_type,
    location,
    validation_status,
    status,
    cluster_id,
    created_at,
    updated_at,
    notes,
    before_photo_url,
    after_photo_url,
    on_private_property,
    property_owner_consent_status,
    stage,
    satisfaction_rating,
    lgu_resolved_at,
    citizen_closed_at,
    is_overdue,
    ai_score,
    flagged_severe,
    severe_violation_category,
    manual_review_id,
    severity_score,
    urgency_score,
    ra9003_category,
    ml_predicted_class,
    ml_confidence,
    ml_probabilities,
    cleanup_task_id,
    scale_level,
    obstruction_level,
    severity_level,
    severity_factors,
    idempotency_key,
    deadline_at,
    fc_version,
    before_photo_hash,
    after_photo_hash,
    sla_started_at,
    lifecycle_state,
    matured_at,
    breached_at,
    report_claim_generation,
    hazard_class,
    hazard_model_version,
    hazard_confidence,
    hazard_decision_source,
    hazard_classified_at
   FROM reports;
CREATE INDEX idx_field_crews_cert_reviewed_by ON public.field_crews USING btree (certification_reviewed_by);
CREATE INDEX idx_field_crews_team_lead ON public.field_crews USING btree (team_lead_profile_id);
CREATE INDEX idx_dispatch_plans_created_by ON public.dispatch_plans USING btree (created_by);
CREATE INDEX idx_dispatch_plans_generation_job_id ON public.dispatch_plans USING btree (generation_job_id);
CREATE INDEX idx_dispatch_plans_optimization_run_id ON public.dispatch_plans USING btree (optimization_run_id);
CREATE INDEX idx_dispatch_plans_status_created ON public.dispatch_plans USING btree (status, created_at DESC);
CREATE INDEX idx_audit_logs_user_id ON public.system_logs USING btree (user_id);
CREATE INDEX idx_audit_logs_created_at ON public.system_logs USING btree (created_at DESC);
CREATE INDEX idx_audit_logs_action_type ON public.system_logs USING btree (action_type);
CREATE INDEX idx_response_log_report_id ON public.audit_logs USING btree (report_id);
CREATE INDEX idx_response_log_user_id ON public.audit_logs USING btree (user_id);
CREATE INDEX idx_audit_logs_report_created ON public.audit_logs USING btree (report_id, created_at DESC);
CREATE INDEX idx_cleanup_tasks_fc_version ON public.cleanup_tasks USING btree (id, fc_version);
CREATE INDEX idx_cleanup_tasks_report_ids ON public.cleanup_tasks USING gin (report_ids);
CREATE INDEX idx_cleanup_tasks_cluster_id ON public.cleanup_tasks USING btree (cluster_id);
CREATE UNIQUE INDEX task_source_group ON public.cleanup_tasks USING btree (source_plan_id, source_group_key) WHERE (source_plan_id IS NOT NULL);
CREATE INDEX task_unpublished_expiry ON public.cleanup_tasks USING btree (routing_deadline_at) WHERE (route_status = 'needs_replan'::text);
CREATE UNIQUE INDEX task_completion_operation ON public.cleanup_tasks USING btree (completion_operation_id) WHERE (completion_operation_id IS NOT NULL);
CREATE INDEX tasks_active_field_crew ON public.cleanup_tasks USING btree (assigned_field_crew_id) WHERE (status <> ALL (ARRAY['completed'::cleanup_task_status, 'cancelled'::cleanup_task_status]));
CREATE INDEX idx_cleanup_tasks_crew_route_id ON public.cleanup_tasks USING btree (crew_route_id);
CREATE INDEX idx_cleanup_tasks_lgu_user_id ON public.cleanup_tasks USING btree (lgu_user_id);
CREATE INDEX idx_cleanup_tasks_assigned_by ON public.cleanup_tasks USING btree (assigned_by);
CREATE INDEX idx_cleanup_tasks_completed_by ON public.cleanup_tasks USING btree (completed_by);
CREATE INDEX idx_cleanup_tasks_created_by ON public.cleanup_tasks USING btree (created_by);
CREATE INDEX idx_cleanup_tasks_crew_status ON public.cleanup_tasks USING btree (assigned_field_crew_id, status);
CREATE INDEX idx_manual_review_queue_priority ON public.manual_review_queue USING btree (priority);
CREATE INDEX idx_manual_review_queue_assigned_to ON public.manual_review_queue USING btree (assigned_to);
CREATE INDEX idx_manual_review_queue_report_id ON public.manual_review_queue USING btree (report_id);
CREATE INDEX idx_manual_review_queue_status ON public.manual_review_queue USING btree (status);
CREATE INDEX idx_manual_review_queue_strike_id ON public.manual_review_queue USING btree (strike_id);
CREATE INDEX idx_dispatch_plan_items_plan_id ON public.dispatch_plan_items USING btree (dispatch_plan_id);
CREATE UNIQUE INDEX dispatch_unique_cluster ON public.dispatch_plan_items USING btree (dispatch_plan_id, cluster_id) WHERE (cluster_id IS NOT NULL);
CREATE UNIQUE INDEX dispatch_unique_report ON public.dispatch_plan_items USING btree (dispatch_plan_id, report_id) WHERE (report_id IS NOT NULL);
CREATE INDEX dispatch_item_group_idx ON public.dispatch_plan_items USING btree (dispatch_plan_id, group_key);
CREATE INDEX idx_dispatch_plan_items_planned_crew_id ON public.dispatch_plan_items USING btree (planned_crew_id);
CREATE INDEX idx_dispatch_plan_items_committed_task_id ON public.dispatch_plan_items USING btree (committed_task_id);
CREATE INDEX idx_dispatch_plan_items_anchor_cluster_id ON public.dispatch_plan_items USING btree (anchor_cluster_id);
CREATE INDEX idx_dispatch_plan_items_cluster_id ON public.dispatch_plan_items USING btree (cluster_id);
CREATE INDEX idx_dispatch_plan_items_report_id ON public.dispatch_plan_items USING btree (report_id);
CREATE UNIQUE INDEX plan_generation_idempotency ON public.plan_generation_jobs USING btree (requested_by, idempotency_key) WHERE (idempotency_key IS NOT NULL);
CREATE INDEX plan_generation_claim ON public.plan_generation_jobs USING btree (requested_at) WHERE (status = 'queued'::text);
CREATE INDEX plan_generation_expiry ON public.plan_generation_jobs USING btree (lease_until) WHERE (status = 'running'::text);
CREATE INDEX reports_location_idx ON public.reports USING gist (location);
CREATE INDEX idx_reports_flagged_severe ON public.reports USING btree (flagged_severe);
CREATE INDEX idx_reports_fc_version ON public.reports USING btree (id, fc_version);
CREATE INDEX idx_reports_cluster_id ON public.reports USING btree (cluster_id);
CREATE INDEX reports_lifecycle_open_idx ON public.reports USING btree (lifecycle_state, deadline_at) WHERE (lifecycle_state IS DISTINCT FROM 'closed'::text);
CREATE INDEX idx_reports_user_feed ON public.reports USING btree (user_id, created_at DESC, id DESC);
CREATE INDEX reports_active_task_claim ON public.reports USING btree (cleanup_task_id) WHERE (cleanup_task_id IS NOT NULL);
CREATE INDEX reports_active_cluster_membership ON public.reports USING btree (cluster_id) WHERE (cluster_id IS NOT NULL);
CREATE INDEX reports_hazard_dispatch_review ON public.reports USING btree (hazard_class, lifecycle_state) WHERE (hazard_class = ANY (ARRAY['suspected_hazard'::text, 'hazmat_required'::text]));
CREATE INDEX idx_reports_user_id ON public.reports USING btree (user_id);
CREATE INDEX idx_reports_manual_review_id ON public.reports USING btree (manual_review_id);
CREATE INDEX idx_fc_operation_log_operation_id ON public.fc_operation_log USING btree (operation_id);
CREATE INDEX idx_fc_operation_log_user ON public.fc_operation_log USING btree (user_id, created_at DESC);
CREATE INDEX idx_fc_conflict_audit_user ON public.fc_conflict_audit USING btree (user_id, created_at DESC);
CREATE INDEX idx_fc_conflict_audit_operation ON public.fc_conflict_audit USING btree (operation_id);
CREATE INDEX idx_fc_conflict_audit_entity ON public.fc_conflict_audit USING btree (entity_id, entity_type, created_at DESC);
CREATE INDEX idx_profiles_suspended_until ON public.profiles USING btree (suspended_until);
CREATE INDEX idx_hotspot_accuracy_prediction ON public.hotspot_accuracy USING btree (prediction_id);
CREATE INDEX idx_hotspot_accuracy_horizon ON public.hotspot_accuracy USING btree (time_horizon);
CREATE INDEX idx_hotspot_accuracy_date ON public.hotspot_accuracy USING btree (evaluation_date);
CREATE INDEX idx_email_verifications_token ON public.email_verifications USING btree (token);
CREATE INDEX idx_email_verifications_user_id ON public.email_verifications USING btree (user_id);
CREATE UNIQUE INDEX one_active_cluster_block ON public.dispatch_access_blocks USING btree (cluster_id) WHERE ((cleared_at IS NULL) AND (cluster_id IS NOT NULL));
CREATE UNIQUE INDEX one_active_report_block ON public.dispatch_access_blocks USING btree (report_id) WHERE ((cleared_at IS NULL) AND (report_id IS NOT NULL));
CREATE INDEX idx_dispatch_access_blocks_blocked_by ON public.dispatch_access_blocks USING btree (blocked_by);
CREATE INDEX idx_dispatch_access_blocks_cleared_by ON public.dispatch_access_blocks USING btree (cleared_by);
CREATE INDEX idx_dispatch_access_blocks_task_id ON public.dispatch_access_blocks USING btree (task_id);
CREATE INDEX idx_strikes_severity ON public.strikes USING btree (severity);
CREATE INDEX idx_strikes_manual_review ON public.strikes USING btree (requires_manual_review, manual_review_status);
CREATE INDEX idx_strikes_user_id ON public.strikes USING btree (user_id);
CREATE INDEX idx_strikes_issued_by ON public.strikes USING btree (issued_by);
CREATE INDEX idx_strikes_is_active ON public.strikes USING btree (is_active);
CREATE INDEX idx_strikes_expires_at ON public.strikes USING btree (expires_at);
CREATE INDEX field_assignment_receipts_report ON public.field_assignment_receipts USING btree (report_id, issued_at DESC);
CREATE INDEX idx_field_assignment_receipts_crew_id ON public.field_assignment_receipts USING btree (crew_id);
CREATE INDEX report_resolution_events_latest ON public.report_resolution_events USING btree (report_id, resolved_at DESC);
CREATE INDEX idx_report_resolution_events_crew_id ON public.report_resolution_events USING btree (crew_id);
CREATE INDEX idx_report_resolution_events_task_id ON public.report_resolution_events USING btree (task_id);
CREATE INDEX idx_notifications_user ON public.notifications USING btree (user_id);
CREATE INDEX idx_notifications_report ON public.notifications USING btree (report_id);
CREATE INDEX idx_notifications_read ON public.notifications USING btree (is_read);
CREATE INDEX idx_notifications_created_at ON public.notifications USING btree (created_at DESC);
CREATE INDEX idx_notifications_type ON public.notifications USING btree (type);
CREATE INDEX idx_notifications_user_created ON public.notifications USING btree (user_id, created_at DESC);
CREATE INDEX idx_notifications_unread_feed ON public.notifications USING btree (user_id, created_at DESC, id DESC) WHERE (is_read = false);
CREATE INDEX task_report_outcomes_review ON public.task_report_outcomes USING btree (disposition, submitted_at) WHERE (disposition = ANY (ARRAY['verification_required'::text, 'contested'::text]));
CREATE INDEX idx_task_report_outcomes_task_id ON public.task_report_outcomes USING btree (task_id);
CREATE INDEX idx_task_report_outcomes_report_id ON public.task_report_outcomes USING btree (report_id);
CREATE INDEX idx_task_report_outcomes_crew_id ON public.task_report_outcomes USING btree (crew_id);
CREATE INDEX idx_task_report_outcomes_receipt_id ON public.task_report_outcomes USING btree (receipt_id);
CREATE INDEX idx_task_report_outcomes_resolution_id ON public.task_report_outcomes USING btree (resolution_event_id);
CREATE INDEX idx_opt_templates_created_by ON public.optimization_templates USING btree (created_by);
CREATE INDEX idx_optimization_settings_updated_by ON public.optimization_settings USING btree (updated_by);
CREATE INDEX idx_sync_conflicts_resolved_by ON public.sync_conflicts USING btree (resolved_by);
CREATE INDEX idx_sync_conflicts_user_id ON public.sync_conflicts USING btree (user_id);
CREATE INDEX idx_route_waypoints_route ON public.route_waypoints USING btree (crew_route_id, sequence_order);
CREATE INDEX route_waypoints_report_idx ON public.route_waypoints USING btree (report_id) WHERE (report_id IS NOT NULL);
CREATE INDEX idx_route_waypoints_cleanup_task_id ON public.route_waypoints USING btree (cleanup_task_id);
CREATE INDEX idx_optimization_runs_approved_by ON public.optimization_runs USING btree (approved_by);
CREATE INDEX idx_optimization_runs_triggered_by ON public.optimization_runs USING btree (triggered_by);
CREATE INDEX idx_crew_routes_run ON public.crew_routes USING btree (optimization_run_id);
CREATE INDEX idx_crew_routes_crew ON public.crew_routes USING btree (crew_id, created_at DESC);
CREATE INDEX field_load_events_crew_time ON public.field_load_events USING btree (field_crew_id, observed_at DESC);
CREATE INDEX idx_field_load_events_actor_id ON public.field_load_events USING btree (actor_id);
CREATE INDEX idx_field_load_events_task_id ON public.field_load_events USING btree (task_id);
CREATE INDEX field_task_failure_events_task_time ON public.field_task_failure_events USING btree (task_id, observed_at DESC);
CREATE INDEX idx_field_task_failure_events_actor_id ON public.field_task_failure_events USING btree (actor_id);
CREATE INDEX idx_hotspot_predictions_time_horizon ON public.hotspot_predictions USING btree (time_horizon);
CREATE INDEX idx_hotspot_predictions_date ON public.hotspot_predictions USING btree (prediction_date);
CREATE INDEX idx_hotspot_predictions_risk_score ON public.hotspot_predictions USING btree (risk_score DESC);
CREATE INDEX idx_hotspot_predictions_region_id ON public.hotspot_predictions USING btree (region_id);
CREATE INDEX idx_hotspot_predictions_composite ON public.hotspot_predictions USING btree (time_horizon, prediction_date);
CREATE UNIQUE INDEX idx_hotspot_predictions_unique ON public.hotspot_predictions USING btree (region_id, prediction_date, time_horizon);
CREATE INDEX idx_sweeper_audit_entity ON public.sweeper_audit_log USING btree (entity_type, entity_id);
CREATE INDEX idx_sweeper_audit_user ON public.sweeper_audit_log USING btree (user_id);
CREATE INDEX idx_sweeper_audit_event ON public.sweeper_audit_log USING btree (event_type);
CREATE INDEX idx_clusters_status ON public.clusters USING btree (status);
CREATE INDEX idx_clusters_center ON public.clusters USING gist (center);
CREATE INDEX idx_clusters_created_at ON public.clusters USING btree (created_at DESC);
CREATE TRIGGER on_report_status_change AFTER UPDATE ON public.reports FOR EACH ROW EXECUTE FUNCTION handle_report_status_change();
CREATE TRIGGER update_clusters_updated_at BEFORE UPDATE ON public.clusters FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_system_settings_updated_at BEFORE UPDATE ON public.system_settings FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_manual_review_queue_updated_at BEFORE UPDATE ON public.manual_review_queue FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER set_report_deadline BEFORE INSERT OR UPDATE OF severity_score ON public.reports FOR EACH ROW EXECUTE FUNCTION calculate_report_deadline();
CREATE TRIGGER zz_apply_report_lifecycle BEFORE INSERT OR UPDATE ON public.reports FOR EACH ROW EXECUTE FUNCTION workflow_private.apply_report_lifecycle();
CREATE TRIGGER zz_audit_report_lifecycle AFTER UPDATE ON public.reports FOR EACH ROW EXECUTE FUNCTION workflow_private.audit_report_lifecycle();
CREATE TRIGGER zz_validate_lifecycle_config AFTER INSERT OR DELETE OR UPDATE ON public.sweeper_configuration FOR EACH STATEMENT EXECUTE FUNCTION workflow_private.validate_lifecycle_config();
CREATE TRIGGER immutable_group_result BEFORE DELETE OR UPDATE ON public.dispatch_group_commits FOR EACH ROW EXECUTE FUNCTION workflow_private.immutable_group_result();
CREATE TRIGGER workflow_report_claim_guard BEFORE INSERT OR UPDATE ON public.reports FOR EACH ROW EXECUTE FUNCTION workflow_private.guard_report_claim();
CREATE TRIGGER workflow_cluster_block_guard BEFORE UPDATE OF status ON public.clusters FOR EACH ROW EXECUTE FUNCTION workflow_private.guard_cluster_block();
CREATE TRIGGER workflow_task_release AFTER UPDATE OF status ON public.cleanup_tasks FOR EACH ROW EXECUTE FUNCTION workflow_private.release_finished_task();
CREATE TRIGGER zy_workflow_report_version BEFORE UPDATE ON public.reports FOR EACH ROW EXECUTE FUNCTION workflow_private.bump_report_version();
CREATE TRIGGER zy_workflow_task_version BEFORE UPDATE ON public.cleanup_tasks FOR EACH ROW EXECUTE FUNCTION workflow_private.bump_report_version();
CREATE TRIGGER require_completed_plan_job BEFORE INSERT ON public.cleanup_tasks FOR EACH ROW EXECUTE FUNCTION workflow_private.require_completed_plan_job();
CREATE TRIGGER zx_workflow_report_claim_generation BEFORE INSERT OR UPDATE ON public.reports FOR EACH ROW EXECUTE FUNCTION workflow_private.bump_report_claim_generation();
CREATE TRIGGER zx_workflow_task_assignment_generation BEFORE INSERT OR UPDATE ON public.cleanup_tasks FOR EACH ROW EXECUTE FUNCTION workflow_private.bump_task_assignment_generation();
CREATE TRIGGER workflow_issue_task_report_receipts AFTER INSERT OR UPDATE ON public.cleanup_tasks FOR EACH ROW EXECUTE FUNCTION workflow_private.issue_task_report_receipts();
CREATE TRIGGER workflow_issue_report_claim_receipts AFTER INSERT OR UPDATE ON public.reports FOR EACH ROW EXECUTE FUNCTION workflow_private.issue_report_claim_receipts();
ALTER TABLE "public"."field_crews" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."dispatch_plans" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."system_logs" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."audit_logs" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."cleanup_tasks" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."manual_review_queue" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."dispatch_plan_items" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."plan_generation_jobs" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."reports" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."fc_operation_log" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."fc_conflict_audit" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."hotspot_accuracy" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."dispatch_group_commits" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."system_settings" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."email_verifications" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."dispatch_access_blocks" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."strikes" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."field_assignment_receipts" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."report_resolution_events" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."notifications" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."task_report_outcomes" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."optimization_templates" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."optimization_settings" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."route_waypoints" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."optimization_runs" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."crew_routes" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."field_load_events" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."field_task_failure_events" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."hotspot_predictions" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."work_time_configuration" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."sweeper_configuration" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."sweeper_audit_log" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."clusters" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "workflow_private"."lifecycle_deployment" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "workflow_private"."historical_sla_reset" ENABLE ROW LEVEL SECURITY;
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY; GRANT USAGE ON SCHEMA public,auth,storage TO anon,authenticated,service_role; GRANT USAGE ON SCHEMA workflow_private TO service_role; GRANT ALL ON ALL TABLES IN SCHEMA public,workflow_private,storage TO service_role; GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO service_role; GRANT ALL ON storage.objects TO authenticated; GRANT SELECT ON storage.objects TO anon;
GRANT select ON public."field_crews" TO "anon";
GRANT select ON public."field_crews" TO "authenticated";
GRANT select ON public."field_crews" TO "service_role";
GRANT insert ON public."field_crews" TO "service_role";
GRANT update ON public."field_crews" TO "service_role";
GRANT delete ON public."field_crews" TO "service_role";
GRANT select ON public."dispatch_plans" TO "anon";
GRANT select ON public."dispatch_plans" TO "authenticated";
GRANT select ON public."dispatch_plans" TO "service_role";
GRANT insert ON public."dispatch_plans" TO "service_role";
GRANT update ON public."dispatch_plans" TO "service_role";
GRANT delete ON public."dispatch_plans" TO "service_role";
GRANT select ON public."system_logs" TO "anon";
GRANT insert ON public."system_logs" TO "anon";
GRANT update ON public."system_logs" TO "anon";
GRANT delete ON public."system_logs" TO "anon";
GRANT select ON public."system_logs" TO "authenticated";
GRANT insert ON public."system_logs" TO "authenticated";
GRANT update ON public."system_logs" TO "authenticated";
GRANT delete ON public."system_logs" TO "authenticated";
GRANT select ON public."system_logs" TO "service_role";
GRANT insert ON public."system_logs" TO "service_role";
GRANT update ON public."system_logs" TO "service_role";
GRANT delete ON public."system_logs" TO "service_role";
GRANT select ON public."audit_logs" TO "anon";
GRANT insert ON public."audit_logs" TO "anon";
GRANT update ON public."audit_logs" TO "anon";
GRANT delete ON public."audit_logs" TO "anon";
GRANT select ON public."audit_logs" TO "authenticated";
GRANT insert ON public."audit_logs" TO "authenticated";
GRANT update ON public."audit_logs" TO "authenticated";
GRANT delete ON public."audit_logs" TO "authenticated";
GRANT select ON public."audit_logs" TO "service_role";
GRANT insert ON public."audit_logs" TO "service_role";
GRANT update ON public."audit_logs" TO "service_role";
GRANT delete ON public."audit_logs" TO "service_role";
GRANT select ON public."cleanup_tasks" TO "anon";
GRANT select ON public."cleanup_tasks" TO "authenticated";
GRANT select ON public."cleanup_tasks" TO "service_role";
GRANT insert ON public."cleanup_tasks" TO "service_role";
GRANT update ON public."cleanup_tasks" TO "service_role";
GRANT delete ON public."cleanup_tasks" TO "service_role";
GRANT select ON public."manual_review_queue" TO "anon";
GRANT insert ON public."manual_review_queue" TO "anon";
GRANT update ON public."manual_review_queue" TO "anon";
GRANT delete ON public."manual_review_queue" TO "anon";
GRANT select ON public."manual_review_queue" TO "authenticated";
GRANT insert ON public."manual_review_queue" TO "authenticated";
GRANT update ON public."manual_review_queue" TO "authenticated";
GRANT delete ON public."manual_review_queue" TO "authenticated";
GRANT select ON public."manual_review_queue" TO "service_role";
GRANT insert ON public."manual_review_queue" TO "service_role";
GRANT update ON public."manual_review_queue" TO "service_role";
GRANT delete ON public."manual_review_queue" TO "service_role";
GRANT select ON public."dispatch_plan_items" TO "anon";
GRANT select ON public."dispatch_plan_items" TO "authenticated";
GRANT select ON public."dispatch_plan_items" TO "service_role";
GRANT insert ON public."dispatch_plan_items" TO "service_role";
GRANT update ON public."dispatch_plan_items" TO "service_role";
GRANT delete ON public."dispatch_plan_items" TO "service_role";
GRANT select ON public."plan_generation_jobs" TO "service_role";
GRANT insert ON public."plan_generation_jobs" TO "service_role";
GRANT update ON public."plan_generation_jobs" TO "service_role";
GRANT delete ON public."plan_generation_jobs" TO "service_role";
GRANT select ON public."reports" TO "authenticated";
GRANT select ON public."reports" TO "service_role";
GRANT insert ON public."reports" TO "service_role";
GRANT update ON public."reports" TO "service_role";
GRANT delete ON public."reports" TO "service_role";
GRANT select ON public."response_log" TO "anon";
GRANT insert ON public."response_log" TO "anon";
GRANT update ON public."response_log" TO "anon";
GRANT delete ON public."response_log" TO "anon";
GRANT select ON public."response_log" TO "authenticated";
GRANT insert ON public."response_log" TO "authenticated";
GRANT update ON public."response_log" TO "authenticated";
GRANT delete ON public."response_log" TO "authenticated";
GRANT select ON public."response_log" TO "service_role";
GRANT insert ON public."response_log" TO "service_role";
GRANT update ON public."response_log" TO "service_role";
GRANT delete ON public."response_log" TO "service_role";
GRANT select ON public."fc_operation_log" TO "anon";
GRANT select ON public."fc_operation_log" TO "authenticated";
GRANT select ON public."fc_operation_log" TO "service_role";
GRANT insert ON public."fc_operation_log" TO "service_role";
GRANT update ON public."fc_operation_log" TO "service_role";
GRANT delete ON public."fc_operation_log" TO "service_role";
GRANT select ON public."fc_conflict_audit" TO "anon";
GRANT select ON public."fc_conflict_audit" TO "authenticated";
GRANT select ON public."fc_conflict_audit" TO "service_role";
GRANT insert ON public."fc_conflict_audit" TO "service_role";
GRANT update ON public."fc_conflict_audit" TO "service_role";
GRANT delete ON public."fc_conflict_audit" TO "service_role";
GRANT select ON public."profiles" TO "anon";
GRANT select ON public."profiles" TO "authenticated";
GRANT select ON public."profiles" TO "service_role";
GRANT insert ON public."profiles" TO "service_role";
GRANT update ON public."profiles" TO "service_role";
GRANT delete ON public."profiles" TO "service_role";
GRANT select ON public."hotspot_accuracy" TO "anon";
GRANT insert ON public."hotspot_accuracy" TO "anon";
GRANT update ON public."hotspot_accuracy" TO "anon";
GRANT delete ON public."hotspot_accuracy" TO "anon";
GRANT select ON public."hotspot_accuracy" TO "authenticated";
GRANT insert ON public."hotspot_accuracy" TO "authenticated";
GRANT update ON public."hotspot_accuracy" TO "authenticated";
GRANT delete ON public."hotspot_accuracy" TO "authenticated";
GRANT select ON public."hotspot_accuracy" TO "service_role";
GRANT insert ON public."hotspot_accuracy" TO "service_role";
GRANT update ON public."hotspot_accuracy" TO "service_role";
GRANT delete ON public."hotspot_accuracy" TO "service_role";
GRANT select ON public."dispatch_group_commits" TO "service_role";
GRANT insert ON public."dispatch_group_commits" TO "service_role";
GRANT update ON public."dispatch_group_commits" TO "service_role";
GRANT delete ON public."dispatch_group_commits" TO "service_role";
GRANT select ON public."system_settings" TO "anon";
GRANT insert ON public."system_settings" TO "anon";
GRANT update ON public."system_settings" TO "anon";
GRANT delete ON public."system_settings" TO "anon";
GRANT select ON public."system_settings" TO "authenticated";
GRANT insert ON public."system_settings" TO "authenticated";
GRANT update ON public."system_settings" TO "authenticated";
GRANT delete ON public."system_settings" TO "authenticated";
GRANT select ON public."system_settings" TO "service_role";
GRANT insert ON public."system_settings" TO "service_role";
GRANT update ON public."system_settings" TO "service_role";
GRANT delete ON public."system_settings" TO "service_role";
GRANT select ON public."email_verifications" TO "anon";
GRANT insert ON public."email_verifications" TO "anon";
GRANT update ON public."email_verifications" TO "anon";
GRANT delete ON public."email_verifications" TO "anon";
GRANT select ON public."email_verifications" TO "authenticated";
GRANT insert ON public."email_verifications" TO "authenticated";
GRANT update ON public."email_verifications" TO "authenticated";
GRANT delete ON public."email_verifications" TO "authenticated";
GRANT select ON public."email_verifications" TO "service_role";
GRANT insert ON public."email_verifications" TO "service_role";
GRANT update ON public."email_verifications" TO "service_role";
GRANT delete ON public."email_verifications" TO "service_role";
GRANT select ON public."dispatch_access_blocks" TO "service_role";
GRANT insert ON public."dispatch_access_blocks" TO "service_role";
GRANT update ON public."dispatch_access_blocks" TO "service_role";
GRANT delete ON public."dispatch_access_blocks" TO "service_role";
GRANT select ON public."strikes" TO "anon";
GRANT insert ON public."strikes" TO "anon";
GRANT update ON public."strikes" TO "anon";
GRANT delete ON public."strikes" TO "anon";
GRANT select ON public."strikes" TO "authenticated";
GRANT insert ON public."strikes" TO "authenticated";
GRANT update ON public."strikes" TO "authenticated";
GRANT delete ON public."strikes" TO "authenticated";
GRANT select ON public."strikes" TO "service_role";
GRANT insert ON public."strikes" TO "service_role";
GRANT update ON public."strikes" TO "service_role";
GRANT delete ON public."strikes" TO "service_role";
GRANT select ON public."field_assignment_receipts" TO "service_role";
GRANT insert ON public."field_assignment_receipts" TO "service_role";
GRANT update ON public."field_assignment_receipts" TO "service_role";
GRANT delete ON public."field_assignment_receipts" TO "service_role";
GRANT select ON public."report_resolution_events" TO "service_role";
GRANT insert ON public."report_resolution_events" TO "service_role";
GRANT update ON public."report_resolution_events" TO "service_role";
GRANT delete ON public."report_resolution_events" TO "service_role";
GRANT select ON public."notifications" TO "anon";
GRANT insert ON public."notifications" TO "anon";
GRANT update ON public."notifications" TO "anon";
GRANT delete ON public."notifications" TO "anon";
GRANT select ON public."notifications" TO "authenticated";
GRANT insert ON public."notifications" TO "authenticated";
GRANT delete ON public."notifications" TO "authenticated";
GRANT select ON public."notifications" TO "service_role";
GRANT insert ON public."notifications" TO "service_role";
GRANT update ON public."notifications" TO "service_role";
GRANT delete ON public."notifications" TO "service_role";
GRANT select ON public."task_report_outcomes" TO "service_role";
GRANT insert ON public."task_report_outcomes" TO "service_role";
GRANT update ON public."task_report_outcomes" TO "service_role";
GRANT delete ON public."task_report_outcomes" TO "service_role";
GRANT select ON public."optimization_templates" TO "anon";
GRANT select ON public."optimization_templates" TO "authenticated";
GRANT select ON public."optimization_templates" TO "service_role";
GRANT insert ON public."optimization_templates" TO "service_role";
GRANT update ON public."optimization_templates" TO "service_role";
GRANT delete ON public."optimization_templates" TO "service_role";
GRANT select ON public."optimization_settings" TO "anon";
GRANT select ON public."optimization_settings" TO "authenticated";
GRANT select ON public."optimization_settings" TO "service_role";
GRANT insert ON public."optimization_settings" TO "service_role";
GRANT update ON public."optimization_settings" TO "service_role";
GRANT delete ON public."optimization_settings" TO "service_role";
GRANT select ON public."sync_conflicts" TO "service_role";
GRANT insert ON public."sync_conflicts" TO "service_role";
GRANT update ON public."sync_conflicts" TO "service_role";
GRANT delete ON public."sync_conflicts" TO "service_role";
GRANT select ON public."route_waypoints" TO "anon";
GRANT select ON public."route_waypoints" TO "authenticated";
GRANT select ON public."route_waypoints" TO "service_role";
GRANT insert ON public."route_waypoints" TO "service_role";
GRANT update ON public."route_waypoints" TO "service_role";
GRANT delete ON public."route_waypoints" TO "service_role";
GRANT select ON public."optimization_runs" TO "anon";
GRANT select ON public."optimization_runs" TO "authenticated";
GRANT select ON public."optimization_runs" TO "service_role";
GRANT insert ON public."optimization_runs" TO "service_role";
GRANT update ON public."optimization_runs" TO "service_role";
GRANT delete ON public."optimization_runs" TO "service_role";
GRANT select ON public."crew_routes" TO "anon";
GRANT select ON public."crew_routes" TO "authenticated";
GRANT select ON public."crew_routes" TO "service_role";
GRANT insert ON public."crew_routes" TO "service_role";
GRANT update ON public."crew_routes" TO "service_role";
GRANT delete ON public."crew_routes" TO "service_role";
GRANT select ON public."field_load_events" TO "service_role";
GRANT insert ON public."field_load_events" TO "service_role";
GRANT update ON public."field_load_events" TO "service_role";
GRANT delete ON public."field_load_events" TO "service_role";
GRANT select ON public."field_task_failure_events" TO "service_role";
GRANT insert ON public."field_task_failure_events" TO "service_role";
GRANT update ON public."field_task_failure_events" TO "service_role";
GRANT delete ON public."field_task_failure_events" TO "service_role";
GRANT select ON public."hotspot_predictions" TO "anon";
GRANT insert ON public."hotspot_predictions" TO "anon";
GRANT update ON public."hotspot_predictions" TO "anon";
GRANT delete ON public."hotspot_predictions" TO "anon";
GRANT select ON public."hotspot_predictions" TO "authenticated";
GRANT insert ON public."hotspot_predictions" TO "authenticated";
GRANT update ON public."hotspot_predictions" TO "authenticated";
GRANT delete ON public."hotspot_predictions" TO "authenticated";
GRANT select ON public."hotspot_predictions" TO "service_role";
GRANT insert ON public."hotspot_predictions" TO "service_role";
GRANT update ON public."hotspot_predictions" TO "service_role";
GRANT delete ON public."hotspot_predictions" TO "service_role";
GRANT select ON public."work_time_configuration" TO "anon";
GRANT select ON public."work_time_configuration" TO "authenticated";
GRANT select ON public."work_time_configuration" TO "service_role";
GRANT insert ON public."work_time_configuration" TO "service_role";
GRANT update ON public."work_time_configuration" TO "service_role";
GRANT delete ON public."work_time_configuration" TO "service_role";
GRANT select ON public."sweeper_configuration" TO "anon";
GRANT select ON public."sweeper_configuration" TO "authenticated";
GRANT select ON public."sweeper_configuration" TO "service_role";
GRANT insert ON public."sweeper_configuration" TO "service_role";
GRANT update ON public."sweeper_configuration" TO "service_role";
GRANT delete ON public."sweeper_configuration" TO "service_role";
GRANT select ON public."sweeper_audit_log" TO "anon";
GRANT select ON public."sweeper_audit_log" TO "authenticated";
GRANT select ON public."sweeper_audit_log" TO "service_role";
GRANT insert ON public."sweeper_audit_log" TO "service_role";
GRANT update ON public."sweeper_audit_log" TO "service_role";
GRANT delete ON public."sweeper_audit_log" TO "service_role";
GRANT select ON public."clusters" TO "anon";
GRANT select ON public."clusters" TO "authenticated";
GRANT select ON public."clusters" TO "service_role";
GRANT insert ON public."clusters" TO "service_role";
GRANT update ON public."clusters" TO "service_role";
GRANT delete ON public."clusters" TO "service_role";
GRANT insert ON public."reports_view" TO "anon";
GRANT update ON public."reports_view" TO "anon";
GRANT delete ON public."reports_view" TO "anon";
GRANT select ON public."reports_view" TO "authenticated";
GRANT insert ON public."reports_view" TO "authenticated";
GRANT update ON public."reports_view" TO "authenticated";
GRANT delete ON public."reports_view" TO "authenticated";
GRANT select ON public."reports_view" TO "service_role";
GRANT insert ON public."reports_view" TO "service_role";
GRANT update ON public."reports_view" TO "service_role";
GRANT delete ON public."reports_view" TO "service_role";
GRANT SELECT ("id") ON public."notifications" TO "anon";
GRANT SELECT ("id") ON public."notifications" TO "authenticated";
GRANT SELECT ("user_id") ON public."notifications" TO "anon";
GRANT SELECT ("user_id") ON public."notifications" TO "authenticated";
GRANT SELECT ("report_id") ON public."notifications" TO "anon";
GRANT SELECT ("report_id") ON public."notifications" TO "authenticated";
GRANT SELECT ("type") ON public."notifications" TO "anon";
GRANT SELECT ("type") ON public."notifications" TO "authenticated";
GRANT SELECT ("title") ON public."notifications" TO "anon";
GRANT SELECT ("title") ON public."notifications" TO "authenticated";
GRANT SELECT ("body") ON public."notifications" TO "anon";
GRANT SELECT ("body") ON public."notifications" TO "authenticated";
GRANT SELECT ("is_read") ON public."notifications" TO "anon";
GRANT SELECT ("is_read") ON public."notifications" TO "authenticated";
GRANT UPDATE ("is_read") ON public."notifications" TO "authenticated";
GRANT SELECT ("created_at") ON public."notifications" TO "anon";
GRANT SELECT ("created_at") ON public."notifications" TO "authenticated";
GRANT SELECT ("id") ON public."profiles" TO "anon";
GRANT SELECT ("id") ON public."profiles" TO "authenticated";
GRANT SELECT ("full_name") ON public."profiles" TO "anon";
GRANT SELECT ("full_name") ON public."profiles" TO "authenticated";
GRANT UPDATE ("full_name") ON public."profiles" TO "authenticated";
GRANT SELECT ("created_at") ON public."profiles" TO "anon";
GRANT SELECT ("created_at") ON public."profiles" TO "authenticated";
GRANT SELECT ("role") ON public."profiles" TO "anon";
GRANT SELECT ("role") ON public."profiles" TO "authenticated";
GRANT SELECT ("avatar_url") ON public."profiles" TO "anon";
GRANT SELECT ("avatar_url") ON public."profiles" TO "authenticated";
GRANT UPDATE ("avatar_url") ON public."profiles" TO "authenticated";
GRANT SELECT ("data_consent") ON public."profiles" TO "anon";
GRANT SELECT ("data_consent") ON public."profiles" TO "authenticated";
GRANT UPDATE ("data_consent") ON public."profiles" TO "authenticated";
GRANT SELECT ("suspended_until") ON public."profiles" TO "anon";
GRANT SELECT ("suspended_until") ON public."profiles" TO "authenticated";
GRANT SELECT ("strike_count") ON public."profiles" TO "anon";
GRANT SELECT ("strike_count") ON public."profiles" TO "authenticated";
GRANT SELECT ("last_strike_at") ON public."profiles" TO "anon";
GRANT SELECT ("last_strike_at") ON public."profiles" TO "authenticated";
GRANT SELECT ("is_email_verified") ON public."profiles" TO "anon";
GRANT SELECT ("is_email_verified") ON public."profiles" TO "authenticated";
GRANT SELECT ("require_password_change") ON public."profiles" TO "anon";
GRANT SELECT ("require_password_change") ON public."profiles" TO "authenticated";
GRANT SELECT ("id") ON public."reports" TO "anon";
GRANT SELECT ("id") ON public."reports" TO "authenticated";
GRANT SELECT ("user_id") ON public."reports" TO "authenticated";
GRANT SELECT ("title") ON public."reports" TO "anon";
GRANT SELECT ("title") ON public."reports" TO "authenticated";
GRANT SELECT ("description") ON public."reports" TO "anon";
GRANT SELECT ("description") ON public."reports" TO "authenticated";
GRANT SELECT ("issue_type") ON public."reports" TO "anon";
GRANT SELECT ("issue_type") ON public."reports" TO "authenticated";
GRANT SELECT ("location") ON public."reports" TO "anon";
GRANT SELECT ("location") ON public."reports" TO "authenticated";
GRANT SELECT ("validation_status") ON public."reports" TO "authenticated";
GRANT SELECT ("status") ON public."reports" TO "anon";
GRANT SELECT ("status") ON public."reports" TO "authenticated";
GRANT SELECT ("cluster_id") ON public."reports" TO "anon";
GRANT SELECT ("cluster_id") ON public."reports" TO "authenticated";
GRANT SELECT ("created_at") ON public."reports" TO "anon";
GRANT SELECT ("created_at") ON public."reports" TO "authenticated";
GRANT SELECT ("updated_at") ON public."reports" TO "anon";
GRANT SELECT ("updated_at") ON public."reports" TO "authenticated";
GRANT SELECT ("notes") ON public."reports" TO "authenticated";
GRANT SELECT ("before_photo_url") ON public."reports" TO "anon";
GRANT SELECT ("before_photo_url") ON public."reports" TO "authenticated";
GRANT SELECT ("after_photo_url") ON public."reports" TO "anon";
GRANT SELECT ("after_photo_url") ON public."reports" TO "authenticated";
GRANT SELECT ("on_private_property") ON public."reports" TO "authenticated";
GRANT SELECT ("property_owner_consent_status") ON public."reports" TO "authenticated";
GRANT SELECT ("stage") ON public."reports" TO "anon";
GRANT SELECT ("stage") ON public."reports" TO "authenticated";
GRANT SELECT ("satisfaction_rating") ON public."reports" TO "anon";
GRANT SELECT ("satisfaction_rating") ON public."reports" TO "authenticated";
GRANT SELECT ("lgu_resolved_at") ON public."reports" TO "anon";
GRANT SELECT ("lgu_resolved_at") ON public."reports" TO "authenticated";
GRANT SELECT ("citizen_closed_at") ON public."reports" TO "anon";
GRANT SELECT ("citizen_closed_at") ON public."reports" TO "authenticated";
GRANT SELECT ("is_overdue") ON public."reports" TO "anon";
GRANT SELECT ("is_overdue") ON public."reports" TO "authenticated";
GRANT SELECT ("ai_score") ON public."reports" TO "authenticated";
GRANT SELECT ("flagged_severe") ON public."reports" TO "authenticated";
GRANT SELECT ("severe_violation_category") ON public."reports" TO "authenticated";
GRANT SELECT ("manual_review_id") ON public."reports" TO "authenticated";
GRANT SELECT ("severity_score") ON public."reports" TO "authenticated";
GRANT SELECT ("urgency_score") ON public."reports" TO "authenticated";
GRANT SELECT ("ra9003_category") ON public."reports" TO "authenticated";
GRANT SELECT ("ml_predicted_class") ON public."reports" TO "authenticated";
GRANT SELECT ("ml_confidence") ON public."reports" TO "authenticated";
GRANT SELECT ("ml_probabilities") ON public."reports" TO "authenticated";
GRANT SELECT ("cleanup_task_id") ON public."reports" TO "authenticated";
GRANT SELECT ("scale_level") ON public."reports" TO "authenticated";
GRANT SELECT ("obstruction_level") ON public."reports" TO "authenticated";
GRANT SELECT ("severity_level") ON public."reports" TO "authenticated";
GRANT SELECT ("severity_factors") ON public."reports" TO "authenticated";
GRANT SELECT ("idempotency_key") ON public."reports" TO "authenticated";
GRANT SELECT ("deadline_at") ON public."reports" TO "anon";
GRANT SELECT ("deadline_at") ON public."reports" TO "authenticated";
GRANT SELECT ("fc_version") ON public."reports" TO "authenticated";
GRANT SELECT ("before_photo_hash") ON public."reports" TO "authenticated";
GRANT SELECT ("after_photo_hash") ON public."reports" TO "authenticated";
GRANT SELECT ("sla_started_at") ON public."reports" TO "authenticated";
GRANT SELECT ("lifecycle_state") ON public."reports" TO "authenticated";
GRANT SELECT ("matured_at") ON public."reports" TO "authenticated";
GRANT SELECT ("breached_at") ON public."reports" TO "authenticated";
GRANT SELECT ("report_claim_generation") ON public."reports" TO "authenticated";
GRANT SELECT ("hazard_class") ON public."reports" TO "authenticated";
GRANT SELECT ("hazard_model_version") ON public."reports" TO "authenticated";
GRANT SELECT ("hazard_confidence") ON public."reports" TO "authenticated";
GRANT SELECT ("hazard_decision_source") ON public."reports" TO "authenticated";
GRANT SELECT ("hazard_classified_at") ON public."reports" TO "authenticated";
GRANT SELECT ("id") ON public."reports_view" TO "anon";
GRANT SELECT ("id") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("id") ON public."reports_view" TO "authenticated";
GRANT SELECT ("user_id") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("user_id") ON public."reports_view" TO "authenticated";
GRANT SELECT ("title") ON public."reports_view" TO "anon";
GRANT SELECT ("title") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("title") ON public."reports_view" TO "authenticated";
GRANT SELECT ("description") ON public."reports_view" TO "anon";
GRANT SELECT ("description") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("description") ON public."reports_view" TO "authenticated";
GRANT SELECT ("issue_type") ON public."reports_view" TO "anon";
GRANT SELECT ("issue_type") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("issue_type") ON public."reports_view" TO "authenticated";
GRANT SELECT ("location") ON public."reports_view" TO "anon";
GRANT SELECT ("location") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("location") ON public."reports_view" TO "authenticated";
GRANT SELECT ("validation_status") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("validation_status") ON public."reports_view" TO "authenticated";
GRANT SELECT ("status") ON public."reports_view" TO "anon";
GRANT SELECT ("status") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("status") ON public."reports_view" TO "authenticated";
GRANT SELECT ("cluster_id") ON public."reports_view" TO "anon";
GRANT SELECT ("cluster_id") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("cluster_id") ON public."reports_view" TO "authenticated";
GRANT SELECT ("created_at") ON public."reports_view" TO "anon";
GRANT SELECT ("created_at") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("created_at") ON public."reports_view" TO "authenticated";
GRANT SELECT ("updated_at") ON public."reports_view" TO "anon";
GRANT SELECT ("updated_at") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("updated_at") ON public."reports_view" TO "authenticated";
GRANT SELECT ("notes") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("notes") ON public."reports_view" TO "authenticated";
GRANT SELECT ("before_photo_url") ON public."reports_view" TO "anon";
GRANT SELECT ("before_photo_url") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("before_photo_url") ON public."reports_view" TO "authenticated";
GRANT SELECT ("after_photo_url") ON public."reports_view" TO "anon";
GRANT SELECT ("after_photo_url") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("after_photo_url") ON public."reports_view" TO "authenticated";
GRANT SELECT ("on_private_property") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("on_private_property") ON public."reports_view" TO "authenticated";
GRANT SELECT ("property_owner_consent_status") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("property_owner_consent_status") ON public."reports_view" TO "authenticated";
GRANT SELECT ("stage") ON public."reports_view" TO "anon";
GRANT SELECT ("stage") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("stage") ON public."reports_view" TO "authenticated";
GRANT SELECT ("satisfaction_rating") ON public."reports_view" TO "anon";
GRANT SELECT ("satisfaction_rating") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("satisfaction_rating") ON public."reports_view" TO "authenticated";
GRANT SELECT ("lgu_resolved_at") ON public."reports_view" TO "anon";
GRANT SELECT ("lgu_resolved_at") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("lgu_resolved_at") ON public."reports_view" TO "authenticated";
GRANT SELECT ("citizen_closed_at") ON public."reports_view" TO "anon";
GRANT SELECT ("citizen_closed_at") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("citizen_closed_at") ON public."reports_view" TO "authenticated";
GRANT SELECT ("is_overdue") ON public."reports_view" TO "anon";
GRANT SELECT ("is_overdue") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("is_overdue") ON public."reports_view" TO "authenticated";
GRANT SELECT ("ai_score") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("ai_score") ON public."reports_view" TO "authenticated";
GRANT SELECT ("flagged_severe") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("flagged_severe") ON public."reports_view" TO "authenticated";
GRANT SELECT ("severe_violation_category") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("severe_violation_category") ON public."reports_view" TO "authenticated";
GRANT SELECT ("manual_review_id") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("manual_review_id") ON public."reports_view" TO "authenticated";
GRANT SELECT ("severity_score") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("severity_score") ON public."reports_view" TO "authenticated";
GRANT SELECT ("urgency_score") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("urgency_score") ON public."reports_view" TO "authenticated";
GRANT SELECT ("ra9003_category") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("ra9003_category") ON public."reports_view" TO "authenticated";
GRANT SELECT ("ml_predicted_class") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("ml_predicted_class") ON public."reports_view" TO "authenticated";
GRANT SELECT ("ml_confidence") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("ml_confidence") ON public."reports_view" TO "authenticated";
GRANT SELECT ("ml_probabilities") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("ml_probabilities") ON public."reports_view" TO "authenticated";
GRANT SELECT ("cleanup_task_id") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("cleanup_task_id") ON public."reports_view" TO "authenticated";
GRANT SELECT ("scale_level") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("scale_level") ON public."reports_view" TO "authenticated";
GRANT SELECT ("obstruction_level") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("obstruction_level") ON public."reports_view" TO "authenticated";
GRANT SELECT ("severity_level") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("severity_level") ON public."reports_view" TO "authenticated";
GRANT SELECT ("severity_factors") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("severity_factors") ON public."reports_view" TO "authenticated";
GRANT SELECT ("idempotency_key") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("idempotency_key") ON public."reports_view" TO "authenticated";
GRANT SELECT ("deadline_at") ON public."reports_view" TO "anon";
GRANT SELECT ("deadline_at") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("deadline_at") ON public."reports_view" TO "authenticated";
GRANT SELECT ("fc_version") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("fc_version") ON public."reports_view" TO "authenticated";
GRANT SELECT ("before_photo_hash") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("before_photo_hash") ON public."reports_view" TO "authenticated";
GRANT SELECT ("after_photo_hash") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("after_photo_hash") ON public."reports_view" TO "authenticated";
GRANT SELECT ("sla_started_at") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("sla_started_at") ON public."reports_view" TO "authenticated";
GRANT SELECT ("lifecycle_state") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("lifecycle_state") ON public."reports_view" TO "authenticated";
GRANT SELECT ("matured_at") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("matured_at") ON public."reports_view" TO "authenticated";
GRANT SELECT ("breached_at") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("breached_at") ON public."reports_view" TO "authenticated";
GRANT SELECT ("report_claim_generation") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("report_claim_generation") ON public."reports_view" TO "authenticated";
GRANT SELECT ("hazard_class") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("hazard_class") ON public."reports_view" TO "authenticated";
GRANT SELECT ("hazard_model_version") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("hazard_model_version") ON public."reports_view" TO "authenticated";
GRANT SELECT ("hazard_confidence") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("hazard_confidence") ON public."reports_view" TO "authenticated";
GRANT SELECT ("hazard_decision_source") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("hazard_decision_source") ON public."reports_view" TO "authenticated";
GRANT SELECT ("hazard_classified_at") ON public."reports_view" TO "authenticated";
GRANT UPDATE ("hazard_classified_at") ON public."reports_view" TO "authenticated";
CREATE POLICY "Clusters are viewable by everyone" ON "public"."clusters" FOR SELECT TO "public" USING (true);
CREATE POLICY "public_read 1oj01fe_0" ON "storage"."objects" FOR SELECT TO "public" USING ((bucket_id = 'avatars'::text));
CREATE POLICY "Public can view avatars" ON "storage"."objects" FOR SELECT TO "public" USING ((bucket_id = 'avatars'::text));
CREATE POLICY "Users can upload their own avatars" ON "storage"."objects" FOR INSERT TO "public" WITH CHECK (((bucket_id = 'avatars'::text) AND ((auth.uid())::text = (storage.foldername(name))[1])));
CREATE POLICY "Officers and Admins can create cleanup tasks" ON "public"."cleanup_tasks" FOR INSERT TO "authenticated" WITH CHECK ((get_auth_user_role() = ANY (ARRAY['officer'::role, 'admin'::role])));
CREATE POLICY "Officers and Admins can delete manual review queue" ON "public"."manual_review_queue" FOR DELETE TO "authenticated" USING ((get_auth_user_role() = ANY (ARRAY['officer'::role, 'admin'::role])));
CREATE POLICY "Only service role can delete clusters" ON "public"."clusters" FOR DELETE TO "service_role" USING (true);
CREATE POLICY "Only service role can insert clusters" ON "public"."clusters" FOR INSERT TO "service_role" WITH CHECK (true);
CREATE POLICY "Users can update their own avatars" ON "storage"."objects" FOR UPDATE TO "public" USING (((bucket_id = 'avatars'::text) AND ((auth.uid())::text = (storage.foldername(name))[1])));
CREATE POLICY "Users can delete their own avatars" ON "storage"."objects" FOR DELETE TO "public" USING (((bucket_id = 'avatars'::text) AND ((auth.uid())::text = (storage.foldername(name))[1])));
CREATE POLICY "Officers and Admins can update reports" ON "public"."reports" FOR UPDATE TO "authenticated" USING ((get_auth_user_role() = ANY (ARRAY['officer'::role, 'admin'::role]))) WITH CHECK ((get_auth_user_role() = ANY (ARRAY['officer'::role, 'admin'::role])));
CREATE POLICY "Allow users to view own strikes" ON "public"."strikes" FOR SELECT TO "service_role" USING (true);
CREATE POLICY "Allow authenticated to read settings" ON "public"."system_settings" FOR SELECT TO "authenticated" USING (true);
CREATE POLICY "Allow service role to insert audit logs" ON "public"."system_logs" FOR INSERT TO "service_role" WITH CHECK (true);
CREATE POLICY "Allow admins to update settings" ON "public"."system_settings" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM profiles
  WHERE ((profiles.id = ( SELECT auth.uid() AS uid)) AND (profiles.role = 'admin'::role)))));
CREATE POLICY "Allow admins to insert settings" ON "public"."system_settings" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM profiles
  WHERE ((profiles.id = ( SELECT auth.uid() AS uid)) AND (profiles.role = 'admin'::role)))));
CREATE POLICY "Service role can insert notifications" ON "public"."notifications" FOR INSERT TO "service_role" WITH CHECK (true);
CREATE POLICY "Users can view their notifications" ON "public"."notifications" FOR SELECT TO "authenticated" USING ((user_id = ( SELECT auth.uid() AS uid)));
CREATE POLICY "Users can update their notifications" ON "public"."notifications" FOR UPDATE TO "authenticated" USING ((user_id = ( SELECT auth.uid() AS uid))) WITH CHECK ((user_id = ( SELECT auth.uid() AS uid)));
CREATE POLICY "Public profiles are viewable by authenticated users" ON "public"."profiles" FOR SELECT TO "authenticated" USING (((id = ( SELECT auth.uid() AS uid)) OR ((( SELECT get_auth_user_role() AS get_auth_user_role))::text = ANY (ARRAY['officer'::text, 'admin'::text])) OR (EXISTS ( SELECT 1
   FROM field_crews c
  WHERE (((c.team_lead_profile_id = ( SELECT auth.uid() AS uid)) OR (( SELECT auth.uid() AS uid) = ANY (COALESCE(c.member_profile_ids, '{}'::uuid[])))) AND ((c.team_lead_profile_id = profiles.id) OR (profiles.id = ANY (COALESCE(c.member_profile_ids, '{}'::uuid[])))))))));
CREATE POLICY "Reports are viewable by authenticated users" ON "public"."reports" FOR SELECT TO "authenticated" USING ((((( SELECT get_auth_user_role() AS get_auth_user_role))::text = ANY (ARRAY['officer'::text, 'admin'::text])) OR (user_id = ( SELECT auth.uid() AS uid)) OR ((validation_status = 'approved'::report_validation_status) AND (status <> 'rejected'::report_status)) OR ((cleanup_task_id IS NOT NULL) AND (EXISTS ( SELECT 1
   FROM cleanup_tasks ct
  WHERE ((ct.id = reports.cleanup_task_id) AND (( SELECT auth.uid() AS uid) = ANY (COALESCE(ct.assigned_crew_ids, '{}'::uuid[])))))))));
CREATE POLICY "Field Crew, Officers, and Admins can update cleanup tasks" ON "public"."cleanup_tasks" FOR UPDATE TO "authenticated" USING ((get_auth_user_role() = ANY (ARRAY['field_crew'::role, 'officer'::role, 'admin'::role]))) WITH CHECK ((get_auth_user_role() = ANY (ARRAY['field_crew'::role, 'officer'::role, 'admin'::role])));
CREATE POLICY "Officers and Admins can insert strikes" ON "public"."strikes" FOR INSERT TO "authenticated" WITH CHECK ((get_auth_user_role() = ANY (ARRAY['officer'::role, 'admin'::role])));
CREATE POLICY "Officers and Admins can update strikes" ON "public"."strikes" FOR UPDATE TO "authenticated" USING ((get_auth_user_role() = ANY (ARRAY['officer'::role, 'admin'::role])));
CREATE POLICY "Officers and Admins can delete strikes" ON "public"."strikes" FOR DELETE TO "authenticated" USING ((get_auth_user_role() = ANY (ARRAY['officer'::role, 'admin'::role])));
CREATE POLICY "Officers and Admins can view manual review queue" ON "public"."manual_review_queue" FOR SELECT TO "authenticated" USING ((get_auth_user_role() = ANY (ARRAY['officer'::role, 'admin'::role])));
CREATE POLICY "Officers and Admins can insert manual review queue" ON "public"."manual_review_queue" FOR INSERT TO "authenticated" WITH CHECK ((get_auth_user_role() = ANY (ARRAY['officer'::role, 'admin'::role])));
CREATE POLICY "Officers and Admins can update manual review queue" ON "public"."manual_review_queue" FOR UPDATE TO "authenticated" USING ((get_auth_user_role() = ANY (ARRAY['officer'::role, 'admin'::role])));
CREATE POLICY "Field Crew, Officers, and Admins can view response log" ON "public"."audit_logs" FOR SELECT TO "authenticated" USING ((get_auth_user_role() = ANY (ARRAY['field_crew'::role, 'officer'::role, 'admin'::role])));
CREATE POLICY "Field Crew, Officers, and Admins can insert response log" ON "public"."audit_logs" FOR INSERT TO "authenticated" WITH CHECK ((get_auth_user_role() = ANY (ARRAY['field_crew'::role, 'officer'::role, 'admin'::role])));
CREATE POLICY "workflow_desk_read" ON "public"."dispatch_plans" FOR SELECT TO "authenticated" USING (((get_auth_user_role())::text = ANY (ARRAY['admin'::text, 'officer'::text])));
CREATE POLICY "workflow_desk_read" ON "public"."dispatch_plan_items" FOR SELECT TO "authenticated" USING (((get_auth_user_role())::text = ANY (ARRAY['admin'::text, 'officer'::text])));
CREATE POLICY "workflow_desk_read" ON "public"."optimization_runs" FOR SELECT TO "authenticated" USING (((get_auth_user_role())::text = ANY (ARRAY['admin'::text, 'officer'::text])));
CREATE POLICY "workflow_desk_read" ON "public"."optimization_settings" FOR SELECT TO "authenticated" USING (((get_auth_user_role())::text = ANY (ARRAY['admin'::text, 'officer'::text])));
CREATE POLICY "workflow_desk_read" ON "public"."optimization_templates" FOR SELECT TO "authenticated" USING (((get_auth_user_role())::text = ANY (ARRAY['admin'::text, 'officer'::text])));
CREATE POLICY "workflow_desk_read" ON "public"."work_time_configuration" FOR SELECT TO "authenticated" USING (((get_auth_user_role())::text = ANY (ARRAY['admin'::text, 'officer'::text])));
CREATE POLICY "workflow_desk_read" ON "public"."sweeper_configuration" FOR SELECT TO "authenticated" USING (((get_auth_user_role())::text = ANY (ARRAY['admin'::text, 'officer'::text])));
CREATE POLICY "workflow_desk_read" ON "public"."sweeper_audit_log" FOR SELECT TO "authenticated" USING (((get_auth_user_role())::text = ANY (ARRAY['admin'::text, 'officer'::text])));
CREATE POLICY "workflow_desk_read" ON "public"."fc_operation_log" FOR SELECT TO "authenticated" USING (((get_auth_user_role())::text = ANY (ARRAY['admin'::text, 'officer'::text])));
CREATE POLICY "workflow_desk_read" ON "public"."fc_conflict_audit" FOR SELECT TO "authenticated" USING (((get_auth_user_role())::text = ANY (ARRAY['admin'::text, 'officer'::text])));
CREATE POLICY "workflow_route_read" ON "public"."crew_routes" FOR SELECT TO "authenticated" USING ((((( SELECT get_auth_user_role() AS get_auth_user_role))::text = ANY (ARRAY['admin'::text, 'officer'::text])) OR (EXISTS ( SELECT 1
   FROM field_crews c
  WHERE ((c.id = crew_routes.crew_id) AND ((( SELECT auth.uid() AS uid) = c.team_lead_profile_id) OR (( SELECT auth.uid() AS uid) = ANY (COALESCE(c.member_profile_ids, '{}'::uuid[])))))))));
CREATE POLICY "workflow_waypoint_read" ON "public"."route_waypoints" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM crew_routes r
  WHERE (r.id = route_waypoints.crew_route_id))));
CREATE POLICY "email_verifications_service_role" ON "public"."email_verifications" FOR ALL TO "service_role" USING (true) WITH CHECK (true);
CREATE POLICY "hotspot_predictions_public_read" ON "public"."hotspot_predictions" FOR SELECT TO "public" USING (true);
CREATE POLICY "hotspot_predictions_service_write" ON "public"."hotspot_predictions" FOR ALL TO "service_role" USING (true) WITH CHECK (true);
CREATE POLICY "hotspot_accuracy_auth_read" ON "public"."hotspot_accuracy" FOR SELECT TO "authenticated" USING (true);
CREATE POLICY "hotspot_accuracy_service_write" ON "public"."hotspot_accuracy" FOR ALL TO "service_role" USING (true) WITH CHECK (true);
CREATE POLICY "Public can view Report Evidence" ON "storage"."objects" FOR SELECT TO "public" USING ((bucket_id = 'Report Evidence'::text));
CREATE POLICY "Public can view Cleanup Task Photos" ON "storage"."objects" FOR SELECT TO "public" USING ((bucket_id = 'Cleanup Task Photos'::text));
CREATE POLICY "Public can view Report Cleanup" ON "storage"."objects" FOR SELECT TO "public" USING ((bucket_id = 'Report Cleanup'::text));
CREATE POLICY "Enable read access for all users" ON "public"."reports" FOR SELECT TO "anon" USING (((validation_status = 'approved'::report_validation_status) AND (status <> 'rejected'::report_status)));
CREATE POLICY "Officers and Admins can view all strikes" ON "public"."strikes" FOR SELECT TO "authenticated" USING (((user_id = ( SELECT auth.uid() AS uid)) OR (( SELECT get_auth_user_role() AS get_auth_user_role) = ANY (ARRAY['officer'::role, 'admin'::role]))));
CREATE POLICY "Only service role can update clusters" ON "public"."clusters" FOR UPDATE TO "service_role" USING (true) WITH CHECK (true);
CREATE POLICY "Allow admins to read audit logs" ON "public"."system_logs" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM profiles
  WHERE ((profiles.id = ( SELECT auth.uid() AS uid)) AND (profiles.role = 'admin'::role)))));
CREATE POLICY "Users can delete their notifications" ON "public"."notifications" FOR DELETE TO "authenticated" USING ((user_id = ( SELECT auth.uid() AS uid)));
CREATE POLICY "Users can update their own profile" ON "public"."profiles" FOR UPDATE TO "authenticated" USING ((id = ( SELECT auth.uid() AS uid))) WITH CHECK ((id = ( SELECT auth.uid() AS uid)));
CREATE POLICY "Citizens can insert their own reports" ON "public"."reports" FOR INSERT TO "authenticated" WITH CHECK ((user_id = ( SELECT auth.uid() AS uid)));
CREATE POLICY "workflow_task_read" ON "public"."cleanup_tasks" FOR SELECT TO "authenticated" USING ((((( SELECT get_auth_user_role() AS get_auth_user_role))::text = ANY (ARRAY['admin'::text, 'officer'::text])) OR (((( SELECT get_auth_user_role() AS get_auth_user_role))::text = 'field_crew'::text) AND (( SELECT auth.uid() AS uid) = ANY (COALESCE(assigned_crew_ids, '{}'::uuid[]))))));
CREATE POLICY "workflow_crew_read" ON "public"."field_crews" FOR SELECT TO "authenticated" USING ((((( SELECT get_auth_user_role() AS get_auth_user_role))::text = ANY (ARRAY['admin'::text, 'officer'::text])) OR (( SELECT auth.uid() AS uid) = team_lead_profile_id) OR (( SELECT auth.uid() AS uid) = ANY (COALESCE(member_profile_ids, '{}'::uuid[])))));
CREATE POLICY "service_role_all" ON "public"."dispatch_access_blocks" FOR ALL TO "service_role" USING (true) WITH CHECK (true);
CREATE POLICY "workflow_desk_read" ON "public"."dispatch_access_blocks" FOR SELECT TO "authenticated" USING (((( SELECT get_auth_user_role() AS get_auth_user_role))::text = ANY (ARRAY['admin'::text, 'officer'::text])));
CREATE POLICY "service_role_all" ON "public"."dispatch_group_commits" FOR ALL TO "service_role" USING (true) WITH CHECK (true);
CREATE POLICY "workflow_desk_read" ON "public"."dispatch_group_commits" FOR SELECT TO "authenticated" USING (((( SELECT get_auth_user_role() AS get_auth_user_role))::text = ANY (ARRAY['admin'::text, 'officer'::text])));
CREATE POLICY "service_role_all" ON "public"."field_assignment_receipts" FOR ALL TO "service_role" USING (true) WITH CHECK (true);
CREATE POLICY "workflow_desk_read" ON "public"."field_assignment_receipts" FOR SELECT TO "authenticated" USING (((( SELECT get_auth_user_role() AS get_auth_user_role))::text = ANY (ARRAY['admin'::text, 'officer'::text])));
CREATE POLICY "service_role_all" ON "public"."field_load_events" FOR ALL TO "service_role" USING (true) WITH CHECK (true);
CREATE POLICY "workflow_desk_read" ON "public"."field_load_events" FOR SELECT TO "authenticated" USING (((( SELECT get_auth_user_role() AS get_auth_user_role))::text = ANY (ARRAY['admin'::text, 'officer'::text])));
CREATE POLICY "service_role_all" ON "public"."field_task_failure_events" FOR ALL TO "service_role" USING (true) WITH CHECK (true);
CREATE POLICY "workflow_desk_read" ON "public"."field_task_failure_events" FOR SELECT TO "authenticated" USING (((( SELECT get_auth_user_role() AS get_auth_user_role))::text = ANY (ARRAY['admin'::text, 'officer'::text])));
CREATE POLICY "service_role_all" ON "public"."plan_generation_jobs" FOR ALL TO "service_role" USING (true) WITH CHECK (true);
CREATE POLICY "workflow_desk_read" ON "public"."plan_generation_jobs" FOR SELECT TO "authenticated" USING (((( SELECT get_auth_user_role() AS get_auth_user_role))::text = ANY (ARRAY['admin'::text, 'officer'::text])));
CREATE POLICY "service_role_all" ON "public"."report_resolution_events" FOR ALL TO "service_role" USING (true) WITH CHECK (true);
CREATE POLICY "workflow_desk_read" ON "public"."report_resolution_events" FOR SELECT TO "authenticated" USING (((( SELECT get_auth_user_role() AS get_auth_user_role))::text = ANY (ARRAY['admin'::text, 'officer'::text])));
CREATE POLICY "service_role_all" ON "public"."task_report_outcomes" FOR ALL TO "service_role" USING (true) WITH CHECK (true);
CREATE POLICY "workflow_desk_read" ON "public"."task_report_outcomes" FOR SELECT TO "authenticated" USING (((( SELECT get_auth_user_role() AS get_auth_user_role))::text = ANY (ARRAY['admin'::text, 'officer'::text])));
CREATE POLICY "service_role_all" ON "workflow_private"."historical_sla_reset" FOR ALL TO "service_role" USING (true) WITH CHECK (true);
CREATE POLICY "service_role_all" ON "workflow_private"."lifecycle_deployment" FOR ALL TO "service_role" USING (true) WITH CHECK (true);
CREATE POLICY "Authenticated users can upload Report Evidence" ON "storage"."objects" FOR INSERT TO "authenticated" WITH CHECK (((bucket_id = 'Report Evidence'::text) AND (((storage.foldername(name))[1] = (( SELECT auth.uid() AS uid))::text) OR ((( SELECT get_auth_user_role() AS get_auth_user_role))::text = ANY (ARRAY['officer'::text, 'admin'::text])))));
CREATE POLICY "Authenticated users can upload Cleanup Task Photos" ON "storage"."objects" FOR INSERT TO "authenticated" WITH CHECK (((bucket_id = 'Cleanup Task Photos'::text) AND ((( SELECT get_auth_user_role() AS get_auth_user_role))::text = ANY (ARRAY['field_crew'::text, 'officer'::text, 'admin'::text]))));
CREATE POLICY "Authenticated users can upload Report Cleanup" ON "storage"."objects" FOR INSERT TO "authenticated" WITH CHECK (((bucket_id = 'Report Cleanup'::text) AND ((( SELECT get_auth_user_role() AS get_auth_user_role))::text = ANY (ARRAY['field_crew'::text, 'officer'::text, 'admin'::text]))));
REVOKE ALL ON FUNCTION "public"."publish_mixed_dispatch_routes"(plan_id uuid, actor uuid, token uuid, routes jsonb, depot jsonb) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."publish_mixed_dispatch_routes"(plan_id uuid, actor uuid, token uuid, routes jsonb, depot jsonb) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."publish_mixed_dispatch_routes"(plan_id uuid, actor uuid, token uuid, routes jsonb, depot jsonb) TO "service_role";
REVOKE ALL ON FUNCTION "public"."upsert_cluster_for_reports_old"(p_report_ids uuid[], p_issue_type text, p_severity text, p_radius_meters double precision) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."upsert_cluster_for_reports_old"(p_report_ids uuid[], p_issue_type text, p_severity text, p_radius_meters double precision) TO "postgres";
REVOKE ALL ON FUNCTION "workflow_private"."guard_cluster_block"() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "workflow_private"."guard_cluster_block"() TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."guard_cluster_block"() TO "service_role";
REVOKE ALL ON FUNCTION "workflow_private"."bump_report_claim_generation"() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "workflow_private"."bump_report_claim_generation"() TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."bump_report_claim_generation"() TO "service_role";
REVOKE ALL ON FUNCTION "workflow_private"."bump_task_assignment_generation"() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "workflow_private"."bump_task_assignment_generation"() TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."bump_task_assignment_generation"() TO "service_role";
REVOKE ALL ON FUNCTION "workflow_private"."can_execute_task"(actor uuid, task cleanup_tasks) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "workflow_private"."can_execute_task"(actor uuid, task cleanup_tasks) TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."can_execute_task"(actor uuid, task cleanup_tasks) TO "service_role";
REVOKE ALL ON FUNCTION "public"."dbscan_reports"(p_eps double precision, p_minpoints integer) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."dbscan_reports"(p_eps double precision, p_minpoints integer) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."dbscan_reports"(p_eps double precision, p_minpoints integer) TO "service_role";
REVOKE ALL ON FUNCTION "public"."clear_dispatch_block"(block_id uuid, actor uuid, notes text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."clear_dispatch_block"(block_id uuid, actor uuid, notes text) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."clear_dispatch_block"(block_id uuid, actor uuid, notes text) TO "service_role";
REVOKE ALL ON FUNCTION "public"."begin_plan_routing"(plan_id uuid, actor uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."begin_plan_routing"(plan_id uuid, actor uuid) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."begin_plan_routing"(plan_id uuid, actor uuid) TO "service_role";
REVOKE ALL ON FUNCTION "public"."check_overdue_reports"() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."check_overdue_reports"() TO PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."check_overdue_reports"() TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."check_overdue_reports"() TO "anon";
GRANT EXECUTE ON FUNCTION "public"."check_overdue_reports"() TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."check_overdue_reports"() TO "service_role";
REVOKE ALL ON FUNCTION "public"."finish_plan_routing"(plan_id uuid, actor uuid, token uuid, failure text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."finish_plan_routing"(plan_id uuid, actor uuid, token uuid, failure text) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."finish_plan_routing"(plan_id uuid, actor uuid, token uuid, failure text) TO "service_role";
REVOKE ALL ON FUNCTION "public"."task_coordinates"(task_ids uuid[]) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."task_coordinates"(task_ids uuid[]) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."task_coordinates"(task_ids uuid[]) TO "service_role";
REVOKE ALL ON FUNCTION "public"."publish_dispatch_routes"(plan_id uuid, actor uuid, token uuid, routes jsonb, depot jsonb) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."publish_dispatch_routes"(plan_id uuid, actor uuid, token uuid, routes jsonb, depot jsonb) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."publish_dispatch_routes"(plan_id uuid, actor uuid, token uuid, routes jsonb, depot jsonb) TO "service_role";
REVOKE ALL ON FUNCTION "public"."set_report_photo"(report_id uuid, actor uuid, slot text, url text, photo_hash text, expected_version bigint) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."set_report_photo"(report_id uuid, actor uuid, slot text, url text, photo_hash text, expected_version bigint) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."set_report_photo"(report_id uuid, actor uuid, slot text, url text, photo_hash text, expected_version bigint) TO "service_role";
REVOKE ALL ON FUNCTION "workflow_private"."lifecycle_config"() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "workflow_private"."lifecycle_config"() TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."lifecycle_config"() TO "service_role";
REVOKE ALL ON FUNCTION "workflow_private"."derive_report_lifecycle"(report_status text, cluster uuid, task uuid, clock_start timestamp with time zone, deadline timestamp with time zone, maturation_hours numeric, at_time timestamp with time zone) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "workflow_private"."derive_report_lifecycle"(report_status text, cluster uuid, task uuid, clock_start timestamp with time zone, deadline timestamp with time zone, maturation_hours numeric, at_time timestamp with time zone) TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."derive_report_lifecycle"(report_status text, cluster uuid, task uuid, clock_start timestamp with time zone, deadline timestamp with time zone, maturation_hours numeric, at_time timestamp with time zone) TO "service_role";
REVOKE ALL ON FUNCTION "public"."calculate_report_deadline"() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."calculate_report_deadline"() TO PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."calculate_report_deadline"() TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."calculate_report_deadline"() TO "anon";
GRANT EXECUTE ON FUNCTION "public"."calculate_report_deadline"() TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."calculate_report_deadline"() TO "service_role";
REVOKE ALL ON FUNCTION "public"."create_manual_cleanup_task"(actor uuid, selected_report_ids uuid[], task_title text, task_description text, crew_member_ids uuid[], task_priority text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."create_manual_cleanup_task"(actor uuid, selected_report_ids uuid[], task_title text, task_description text, crew_member_ids uuid[], task_priority text) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."create_manual_cleanup_task"(actor uuid, selected_report_ids uuid[], task_title text, task_description text, crew_member_ids uuid[], task_priority text) TO "service_role";
REVOKE ALL ON FUNCTION "public"."reconcile_report_outcome"(actor uuid, operation_id text, payload jsonb) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."reconcile_report_outcome"(actor uuid, operation_id text, payload jsonb) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."reconcile_report_outcome"(actor uuid, operation_id text, payload jsonb) TO "service_role";
REVOKE ALL ON FUNCTION "public"."count_recent_nearby_reports"(p_lon double precision, p_lat double precision, p_radius_meters double precision, p_days integer) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."count_recent_nearby_reports"(p_lon double precision, p_lat double precision, p_radius_meters double precision, p_days integer) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."count_recent_nearby_reports"(p_lon double precision, p_lat double precision, p_radius_meters double precision, p_days integer) TO "service_role";
REVOKE ALL ON FUNCTION "public"."nextval"(seq_name text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."nextval"(seq_name text) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."nextval"(seq_name text) TO "service_role";
REVOKE ALL ON FUNCTION "public"."advance_report_lifecycle"() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."advance_report_lifecycle"() TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."advance_report_lifecycle"() TO "service_role";
REVOKE ALL ON FUNCTION "workflow_private"."issue_task_report_receipts"() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "workflow_private"."issue_task_report_receipts"() TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."issue_task_report_receipts"() TO "service_role";
REVOKE ALL ON FUNCTION "workflow_private"."audit_report_lifecycle"() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "workflow_private"."audit_report_lifecycle"() TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."audit_report_lifecycle"() TO "service_role";
REVOKE ALL ON FUNCTION "workflow_private"."issue_report_claim_receipts"() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "workflow_private"."issue_report_claim_receipts"() TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."issue_report_claim_receipts"() TO "service_role";
REVOKE ALL ON FUNCTION "public"."handle_new_user"() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."handle_new_user"() TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."handle_new_user"() TO "service_role";
REVOKE ALL ON FUNCTION "public"."handle_report_status_change"() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."handle_report_status_change"() TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."handle_report_status_change"() TO "service_role";
REVOKE ALL ON FUNCTION "public"."commit_dispatch_plan"(plan_id uuid, actor uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."commit_dispatch_plan"(plan_id uuid, actor uuid) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."commit_dispatch_plan"(plan_id uuid, actor uuid) TO "service_role";
REVOKE ALL ON FUNCTION "public"."save_dispatch_plan"(actor uuid, plan_mode text, settings jsonb, items jsonb, available_crews integer, capacity_minutes integer) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."save_dispatch_plan"(actor uuid, plan_mode text, settings jsonb, items jsonb, available_crews integer, capacity_minutes integer) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."save_dispatch_plan"(actor uuid, plan_mode text, settings jsonb, items jsonb, available_crews integer, capacity_minutes integer) TO "service_role";
REVOKE ALL ON FUNCTION "public"."update_updated_at_column"() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."update_updated_at_column"() TO PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."update_updated_at_column"() TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."update_updated_at_column"() TO "anon";
GRANT EXECUTE ON FUNCTION "public"."update_updated_at_column"() TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."update_updated_at_column"() TO "service_role";
REVOKE ALL ON FUNCTION "public"."upsert_cluster_for_reports"(p_report_ids uuid[], p_issue_type text, p_severity text, p_radius_meters numeric) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."upsert_cluster_for_reports"(p_report_ids uuid[], p_issue_type text, p_severity text, p_radius_meters numeric) TO "postgres";
REVOKE ALL ON FUNCTION "workflow_private"."validate_lifecycle_config"() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "workflow_private"."validate_lifecycle_config"() TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."validate_lifecycle_config"() TO "service_role";
REVOKE ALL ON FUNCTION "workflow_private"."apply_report_lifecycle"() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "workflow_private"."apply_report_lifecycle"() TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."apply_report_lifecycle"() TO "service_role";
REVOKE ALL ON FUNCTION "public"."get_auth_user_role"() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."get_auth_user_role"() TO PUBLIC;
GRANT EXECUTE ON FUNCTION "public"."get_auth_user_role"() TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."get_auth_user_role"() TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."get_auth_user_role"() TO "service_role";
REVOKE ALL ON FUNCTION "workflow_private"."severity_tier"(score integer) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "workflow_private"."severity_tier"(score integer) TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."severity_tier"(score integer) TO "service_role";
REVOKE ALL ON FUNCTION "public"."apply_fc_operation"(actor uuid, operation_id text, operation_type text, entity_id uuid, entity_type text, payload jsonb, base_version bigint) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."apply_fc_operation"(actor uuid, operation_id text, operation_type text, entity_id uuid, entity_type text, payload jsonb, base_version bigint) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."apply_fc_operation"(actor uuid, operation_id text, operation_type text, entity_id uuid, entity_type text, payload jsonb, base_version bigint) TO "service_role";
REVOKE ALL ON FUNCTION "public"."set_cluster_queue_status"(cluster_id uuid, actor uuid, next_status text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."set_cluster_queue_status"(cluster_id uuid, actor uuid, next_status text) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."set_cluster_queue_status"(cluster_id uuid, actor uuid, next_status text) TO "service_role";
REVOKE ALL ON FUNCTION "public"."submit_task_outcome"(task_id uuid, actor uuid, outcome text, notes text, classification text, expected_version bigint, operation_id text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."submit_task_outcome"(task_id uuid, actor uuid, outcome text, notes text, classification text, expected_version bigint, operation_id text) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."submit_task_outcome"(task_id uuid, actor uuid, outcome text, notes text, classification text, expected_version bigint, operation_id text) TO "service_role";
REVOKE ALL ON FUNCTION "public"."expire_unpublished_dispatch_claims"() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."expire_unpublished_dispatch_claims"() TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."expire_unpublished_dispatch_claims"() TO "service_role";
REVOKE ALL ON FUNCTION "public"."upsert_cluster_for_reports_v2"(p_report_ids uuid[], p_issue_type text, p_severity text, p_radius_meters double precision) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."upsert_cluster_for_reports_v2"(p_report_ids uuid[], p_issue_type text, p_severity text, p_radius_meters double precision) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."upsert_cluster_for_reports_v2"(p_report_ids uuid[], p_issue_type text, p_severity text, p_radius_meters double precision) TO "service_role";
REVOKE ALL ON FUNCTION "workflow_private"."guard_report_claim"() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "workflow_private"."guard_report_claim"() TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."guard_report_claim"() TO "service_role";
REVOKE ALL ON FUNCTION "public"."change_field_crew_member"(crew_id uuid, actor uuid, member_id uuid, action text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."change_field_crew_member"(crew_id uuid, actor uuid, member_id uuid, action text) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."change_field_crew_member"(crew_id uuid, actor uuid, member_id uuid, action text) TO "service_role";
REVOKE ALL ON FUNCTION "public"."set_task_photo"(task_id uuid, actor uuid, slot text, url text, photo_hash text, expected_version bigint) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."set_task_photo"(task_id uuid, actor uuid, slot text, url text, photo_hash text, expected_version bigint) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."set_task_photo"(task_id uuid, actor uuid, slot text, url text, photo_hash text, expected_version bigint) TO "service_role";
REVOKE ALL ON FUNCTION "workflow_private"."immutable_group_result"() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "workflow_private"."immutable_group_result"() TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."immutable_group_result"() TO "service_role";
REVOKE ALL ON FUNCTION "workflow_private"."require_desk_actor"(actor uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "workflow_private"."require_desk_actor"(actor uuid) TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."require_desk_actor"(actor uuid) TO "service_role";
REVOKE ALL ON FUNCTION "workflow_private"."bump_report_version"() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "workflow_private"."bump_report_version"() TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."bump_report_version"() TO "service_role";
REVOKE ALL ON FUNCTION "workflow_private"."release_finished_task"() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "workflow_private"."release_finished_task"() TO "postgres";
GRANT EXECUTE ON FUNCTION "workflow_private"."release_finished_task"() TO "service_role";
REVOKE ALL ON FUNCTION "public"."mixed_planning_snapshot"() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."mixed_planning_snapshot"() TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."mixed_planning_snapshot"() TO "service_role";
REVOKE ALL ON FUNCTION "public"."enqueue_plan_generation"(actor uuid, plan_mode text, settings jsonb, request_key text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."enqueue_plan_generation"(actor uuid, plan_mode text, settings jsonb, request_key text) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."enqueue_plan_generation"(actor uuid, plan_mode text, settings jsonb, request_key text) TO "service_role";
REVOKE ALL ON FUNCTION "public"."claim_plan_generation"(worker_id uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."claim_plan_generation"(worker_id uuid) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."claim_plan_generation"(worker_id uuid) TO "service_role";
REVOKE ALL ON FUNCTION "public"."commit_mixed_dispatch_plan"(plan_id uuid, actor uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."commit_mixed_dispatch_plan"(plan_id uuid, actor uuid) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."commit_mixed_dispatch_plan"(plan_id uuid, actor uuid) TO "service_role";
REVOKE ALL ON FUNCTION "public"."finish_plan_generation"(job_id uuid, worker_id uuid, result_plan_id uuid, failure_code text, diagnostics jsonb) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."finish_plan_generation"(job_id uuid, worker_id uuid, result_plan_id uuid, failure_code text, diagnostics jsonb) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."finish_plan_generation"(job_id uuid, worker_id uuid, result_plan_id uuid, failure_code text, diagnostics jsonb) TO "service_role";
REVOKE ALL ON FUNCTION "workflow_private"."require_completed_plan_job"() FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION "public"."save_mixed_dispatch_draft"(actor uuid, job_id uuid, worker_id uuid, settings jsonb, items jsonb, proposal jsonb, capacity jsonb, rejected jsonb, diagnostics jsonb) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."save_mixed_dispatch_draft"(actor uuid, job_id uuid, worker_id uuid, settings jsonb, items jsonb, proposal jsonb, capacity jsonb, rejected jsonb, diagnostics jsonb) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."save_mixed_dispatch_draft"(actor uuid, job_id uuid, worker_id uuid, settings jsonb, items jsonb, proposal jsonb, capacity jsonb, rejected jsonb, diagnostics jsonb) TO "service_role";
REVOKE ALL ON FUNCTION "public"."record_field_load"(actor uuid, operation_id text, payload jsonb) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."record_field_load"(actor uuid, operation_id text, payload jsonb) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."record_field_load"(actor uuid, operation_id text, payload jsonb) TO "service_role";
REVOKE ALL ON FUNCTION "public"."submit_field_failure"(actor uuid, operation_id text, payload jsonb) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."submit_field_failure"(actor uuid, operation_id text, payload jsonb) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."submit_field_failure"(actor uuid, operation_id text, payload jsonb) TO "service_role";
REVOKE ALL ON FUNCTION "public"."activate_report_lifecycle"(high_maturation_hours numeric, normal_maturation_hours numeric) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION "public"."activate_report_lifecycle"(high_maturation_hours numeric, normal_maturation_hours numeric) TO "postgres";
GRANT EXECUTE ON FUNCTION "public"."activate_report_lifecycle"(high_maturation_hours numeric, normal_maturation_hours numeric) TO "service_role";
