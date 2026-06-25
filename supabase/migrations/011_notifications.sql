-- ═══════════════════════════════════════════════════════════════════════════
-- 011 — Notifications inbox + delivery status-change fan-out
-- ───────────────────────────────────────────────────────────────────────────
-- Generic per-user notification inbox (one row per recipient), populated by a
-- DB trigger on delivery status changes and delivered live via realtime. Lifted
-- from WFW: partial unread index for a fast badge, reference_id for idempotent
-- dedup, SECURITY DEFINER trigger so inserts bypass RLS regardless of actor.
--
-- Fan-out is conservative for this internal app: the order's creator + the
-- driver assigned to the leg. Extend recipients as needed.
--
-- Idempotent: CREATE TABLE/INDEX IF NOT EXISTS, CREATE OR REPLACE FUNCTION,
-- DROP-then-CREATE policies/triggers, guarded realtime publication add.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.notifications (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  type         TEXT NOT NULL DEFAULT 'update'
                 CHECK (type IN ('delivery', 'rental', 'reminder', 'update', 'alert')),
  title        TEXT NOT NULL,
  message      TEXT,
  priority     TEXT NOT NULL DEFAULT 'medium' CHECK (priority IN ('high', 'medium', 'low')),
  action_url   TEXT,
  reference_id TEXT,             -- dedup key, e.g. 'delivery_<id>_completed'
  read         BOOLEAN NOT NULL DEFAULT FALSE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Fast unread-badge query.
CREATE INDEX IF NOT EXISTS idx_notifications_user_unread
  ON public.notifications (user_id, read) WHERE read = FALSE;
-- Dedup lookups.
CREATE INDEX IF NOT EXISTS idx_notifications_dedup
  ON public.notifications (user_id, reference_id);

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

-- A user reads (and marks read) only their own notifications.
DROP POLICY IF EXISTS "notifications_select_own" ON public.notifications;
CREATE POLICY "notifications_select_own" ON public.notifications
  FOR SELECT USING (user_id = auth.uid());

DROP POLICY IF EXISTS "notifications_update_own" ON public.notifications;
CREATE POLICY "notifications_update_own" ON public.notifications
  FOR UPDATE USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

-- Inserts come from the SECURITY DEFINER trigger / service role (no client INSERT).

-- ── Status-change fan-out ──────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.notify_delivery_status_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_title    TEXT;
  v_message  TEXT;
  v_priority TEXT := 'medium';
  v_type     TEXT := 'delivery';
  v_ref      TEXT;
  v_leg      TEXT := COALESCE(NEW.leg_type, 'delivery');
  v_customer TEXT;
  v_creator  UUID;
  v_driver_user UUID;
  rec_user   UUID;
BEGIN
  IF OLD.status = NEW.status THEN
    RETURN NEW;
  END IF;

  -- Build a human label per transition; skip transitions we don't announce.
  CASE NEW.status
    WHEN 'en_route'  THEN v_title := CASE WHEN v_leg = 'pickup' THEN 'Out for pickup' ELSE 'Out for delivery' END;
                          v_priority := 'high';
    WHEN 'completed' THEN v_title := CASE WHEN v_leg = 'pickup' THEN 'Pickup completed' ELSE 'Delivery completed' END;
    WHEN 'cancelled' THEN v_title := CASE WHEN v_leg = 'pickup' THEN 'Pickup cancelled' ELSE 'Delivery cancelled' END;
                          v_priority := 'high'; v_type := 'alert';
    ELSE RETURN NEW;  -- pending/scheduled: no notification
  END CASE;

  v_ref := 'delivery_' || NEW.id || '_' || NEW.status;

  SELECT c.full_name, o.created_by
    INTO v_customer, v_creator
    FROM public.rental_orders o
    JOIN public.customers c ON c.id = o.customer_id
   WHERE o.id = NEW.order_id;

  v_message := v_leg || ' for ' || COALESCE(v_customer, 'customer');

  SELECT d.user_id INTO v_driver_user FROM public.drivers d WHERE d.id = NEW.driver_id;

  -- Recipients: order creator + assigned driver's user (deduped, non-null).
  FOR rec_user IN
    SELECT DISTINCT u FROM unnest(ARRAY[v_creator, v_driver_user]) AS u WHERE u IS NOT NULL
  LOOP
    INSERT INTO public.notifications (user_id, type, title, message, priority, reference_id)
    SELECT rec_user, v_type, v_title, v_message, v_priority, v_ref
    WHERE NOT EXISTS (
      SELECT 1 FROM public.notifications n
      WHERE n.user_id = rec_user AND n.reference_id = v_ref
    );
  END LOOP;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS notify_delivery_status_change ON public.deliveries;
CREATE TRIGGER notify_delivery_status_change
  AFTER UPDATE OF status ON public.deliveries
  FOR EACH ROW EXECUTE FUNCTION public.notify_delivery_status_change();

-- ── Realtime ───────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime')
     AND NOT EXISTS (
       SELECT 1 FROM pg_publication_tables
       WHERE pubname = 'supabase_realtime' AND schemaname = 'public'
         AND tablename = 'notifications'
     ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.notifications;
  END IF;
END $$;
