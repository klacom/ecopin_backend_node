-- Migration: Add Phase 3 Capacity Planning
-- Description: Creates tables to store auto-generated dispatch plans and selection reasons

CREATE TABLE IF NOT EXISTS dispatch_plans (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  planned_date DATE NOT NULL DEFAULT CURRENT_DATE,
  total_crews_available INT NOT NULL DEFAULT 0,
  total_capacity_minutes INT NOT NULL DEFAULT 0,
  status TEXT DEFAULT 'draft' CHECK (status IN ('draft', 'approved', 'discarded')),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  created_by UUID REFERENCES auth.users(id) -- if we want to track who generated it
);

CREATE TABLE IF NOT EXISTS dispatch_plan_items (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  dispatch_plan_id UUID NOT NULL REFERENCES dispatch_plans(id) ON DELETE CASCADE,
  cluster_id UUID NOT NULL REFERENCES clusters(id) ON DELETE CASCADE,
  is_selected BOOLEAN NOT NULL DEFAULT false,
  reason TEXT,
  estimated_duration_minutes INT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_dispatch_plan_items_plan_id ON dispatch_plan_items(dispatch_plan_id);
