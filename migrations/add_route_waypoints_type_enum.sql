-- 1. Create ENUM
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'route_waypoint_type') THEN
        CREATE TYPE route_waypoint_type AS ENUM (
            'depot_start', 'task', 'depot_end'
        );
    END IF;
END
$$;

-- 2. Drop the old CHECK constraint before altering the column
ALTER TABLE route_waypoints DROP CONSTRAINT IF EXISTS route_waypoints_waypoint_type_check;

-- 3. Drop default so we can alter the column
ALTER TABLE route_waypoints ALTER COLUMN waypoint_type DROP DEFAULT;

-- 4. Alter the route_waypoints table
ALTER TABLE route_waypoints ALTER COLUMN waypoint_type TYPE route_waypoint_type USING waypoint_type::route_waypoint_type;

-- 5. Re-add default
ALTER TABLE route_waypoints ALTER COLUMN waypoint_type SET DEFAULT 'task'::route_waypoint_type;
