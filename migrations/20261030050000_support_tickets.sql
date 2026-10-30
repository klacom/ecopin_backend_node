-- PDT-29: citizen support tickets. Citizens see only their own tickets; desk staff (officer/admin) handle them.
-- Same access model as live operations: no table grants, SECURITY INVOKER RPCs that take the session actor, service_role only.
BEGIN;
SET LOCAL lock_timeout='5s';

CREATE SEQUENCE public.support_ticket_number_seq AS bigint START 1000;

CREATE TABLE public.support_tickets (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 reference text NOT NULL UNIQUE DEFAULT 'TCK-'||lpad(nextval('public.support_ticket_number_seq')::text,6,'0'),
 citizen_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
 report_id uuid REFERENCES public.reports(id) ON DELETE SET NULL,
 category text NOT NULL CHECK(category IN ('status_inquiry','location_mismatch','re_inspection','hazard_escalation','account_help','other')),
 description text NOT NULL CHECK(char_length(btrim(description)) BETWEEN 10 AND 2000),
 status text NOT NULL DEFAULT 'open' CHECK(status IN ('open','in_progress','resolved','closed')),
 handler_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
 response text CHECK(response IS NULL OR char_length(btrim(response)) BETWEEN 1 AND 2000),
 responded_at timestamptz,
 resolved_at timestamptz,
 created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
 updated_at timestamptz NOT NULL DEFAULT statement_timestamp()
);
CREATE INDEX support_tickets_citizen_idx ON public.support_tickets(citizen_id,created_at DESC,id DESC);
CREATE INDEX support_tickets_queue_idx ON public.support_tickets(status,created_at,id);

ALTER TABLE public.support_tickets ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.support_tickets FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON SEQUENCE public.support_ticket_number_seq FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT,UPDATE ON public.support_tickets TO service_role;
GRANT USAGE ON SEQUENCE public.support_ticket_number_seq TO service_role;

-- Shared shape returned to clients. Staff also get handler_id; the citizen's id is never returned because replies go through the ticket.
CREATE FUNCTION public.support_ticket_json(t public.support_tickets,staff boolean DEFAULT false)
RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$
 SELECT jsonb_build_object('id',t.id,'reference',t.reference,'report_id',t.report_id,'category',t.category,
  'description',t.description,'status',t.status,'response',t.response,'responded_at',t.responded_at,
  'resolved_at',t.resolved_at,'created_at',t.created_at,'updated_at',t.updated_at)
  ||CASE WHEN staff THEN jsonb_build_object('handler_id',t.handler_id) ELSE '{}'::jsonb END
$$;

CREATE FUNCTION public.create_support_ticket(actor uuid,ticket_category text,ticket_description text,ticket_report_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE t public.support_tickets;
BEGIN
 IF actor IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=actor AND p.role::text='citizen'
  AND (p.suspended_until IS NULL OR p.suspended_until<=statement_timestamp())) THEN
  RAISE EXCEPTION 'Active citizen access required' USING ERRCODE='42501';
 END IF;
 IF ticket_report_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.reports r WHERE r.id=ticket_report_id AND r.user_id=actor) THEN
  RAISE EXCEPTION 'Report not found' USING ERRCODE='P0002';
 END IF;
 -- Serialise per citizen so the open-ticket cap cannot be bypassed by concurrent submissions.
 PERFORM pg_advisory_xact_lock(hashtextextended('support_ticket:'||actor::text,0));
 IF (SELECT count(*) FROM public.support_tickets s WHERE s.citizen_id=actor AND s.status IN ('open','in_progress'))>=5 THEN
  RAISE EXCEPTION 'Too many open tickets' USING ERRCODE='53400';
 END IF;
 INSERT INTO public.support_tickets(citizen_id,report_id,category,description)
 VALUES(actor,ticket_report_id,ticket_category,btrim(ticket_description)) RETURNING * INTO t;
 RETURN public.support_ticket_json(t);
END; $$;

CREATE FUNCTION public.read_my_support_tickets(actor uuid,cursor_created timestamptz DEFAULT NULL,cursor_id uuid DEFAULT NULL,page_limit integer DEFAULT 20)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path='' AS $$
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
END; $$;

-- Owner-only lookup; a ticket that exists but belongs to someone else is indistinguishable from a missing one.
CREATE FUNCTION public.read_my_support_ticket(actor uuid,ticket_ref text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path='' AS $$
DECLARE t public.support_tickets;
BEGIN
 IF actor IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=actor AND p.role::text='citizen') THEN
  RAISE EXCEPTION 'Citizen access required' USING ERRCODE='42501';
 END IF;
 SELECT * INTO t FROM public.support_tickets s WHERE s.citizen_id=actor AND s.reference=upper(btrim(ticket_ref));
 IF NOT FOUND THEN RAISE EXCEPTION 'Ticket not found' USING ERRCODE='P0002'; END IF;
 RETURN public.support_ticket_json(t);
END; $$;

CREATE FUNCTION public.read_support_ticket_queue(actor uuid,status_filter text DEFAULT NULL,cursor_created timestamptz DEFAULT NULL,cursor_id uuid DEFAULT NULL,page_limit integer DEFAULT 20)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path='' AS $$
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
END; $$;

CREATE FUNCTION public.respond_support_ticket(actor uuid,ticket_id uuid,reply text,new_status text)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
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
END; $$;

REVOKE ALL ON FUNCTION public.support_ticket_json(public.support_tickets,boolean),
 public.create_support_ticket(uuid,text,text,uuid),public.read_my_support_tickets(uuid,timestamptz,uuid,integer),
 public.read_my_support_ticket(uuid,text),public.read_support_ticket_queue(uuid,text,timestamptz,uuid,integer),
 public.respond_support_ticket(uuid,uuid,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.support_ticket_json(public.support_tickets,boolean),
 public.create_support_ticket(uuid,text,text,uuid),public.read_my_support_tickets(uuid,timestamptz,uuid,integer),
 public.read_my_support_ticket(uuid,text),public.read_support_ticket_queue(uuid,text,timestamptz,uuid,integer),
 public.respond_support_ticket(uuid,uuid,text,text) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
