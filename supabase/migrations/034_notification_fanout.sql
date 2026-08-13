-- ═══════════════════════════════════════════════════════════════════════════
-- 034 — Notification fan-out completion (C8, U3, U12)
-- ───────────────────────────────────────────────────────────────────────────
-- C8:  notify_delivery_status_change (011) only reached the order creator +
--      the assigned driver. Storefront orders have created_by NULL, so the
--      ONLY recipient was the acting driver — staff never saw 'Out for
--      delivery' / 'Delivery completed' / 'Delivery cancelled'. Now fans out
--      to every ACTIVE admin/staff profile too, minus the acting user (no
--      self-notifications).
-- U3:  nothing notified anyone when a storefront request arrived (INSERT with
--      status='requested' via submit_rental_request) or when a paid Stripe/
--      Square checkout was promoted to 'requested' (verify_stripe_payment /
--      verify_square_payment UPDATE). New AFTER trigger on rental_orders
--      notifies all active staff/admin, deduped via reference_id
--      'order_<id>_requested'.
-- U12: notify_driver_on_assignment (028) returned early when NEW.driver_id
--      was NULL and only ever resolved the NEW driver, so a driver whose stop
--      was reassigned away or unassigned was never told. Now the OLD driver
--      gets a high-priority alert.
--
-- Safety:
--   * Every body wraps its work in BEGIN/EXCEPTION WHEN others (the 028
--     pattern): a notification failure must never roll back a delivery status
--     change, and above all must never abort verify_stripe_payment's UPDATE
--     that promotes a PAID order — Stripe is live.
--   * No recursion: rental_orders carries only the set_updated_at BEFORE
--     UPDATE trigger (007) and notifications carries no triggers at all, so
--     an AFTER trigger on rental_orders inserting into notifications fires
--     nothing further.
--   * Volume: recipients per event = active admin/staff (currently 2 in
--     seed_accounts) + at most 1 driver − 1 actor ≈ 2-3 rows/event. Even at
--     10 staff × 100 events/day ≈ 1,000 rows/day on a partial-indexed table.
--   * notifications is already in supabase_realtime (011:117-127) — no
--     publication change needed here.
--
-- Idempotent: CREATE OR REPLACE FUNCTION, DROP TRIGGER IF EXISTS + CREATE.
-- NOTE: 011 and 028 re-create the OLD function bodies on every migration run;
-- this file runs after them and re-asserts the final versions.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── (C8) Delivery lifecycle: fan out to all active staff/admin ─────────────
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
  v_actor    UUID := auth.uid();
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

  -- A notification must never block the status change itself (028 pattern).
  BEGIN
    v_ref := 'delivery_' || NEW.id || '_' || NEW.status;

    SELECT c.full_name, o.created_by
      INTO v_customer, v_creator
      FROM public.rental_orders o
      JOIN public.customers c ON c.id = o.customer_id
     WHERE o.id = NEW.order_id;

    v_message := v_leg || ' for ' || COALESCE(v_customer, 'customer');

    SELECT d.user_id INTO v_driver_user FROM public.drivers d WHERE d.id = NEW.driver_id;

    -- Recipients: every active staff/admin + the order creator + the assigned
    -- driver's user — deduped, non-null, minus the acting user (a driver
    -- tapping Start should not notify themselves; a NULL actor = backend,
    -- everyone is notified).
    FOR rec_user IN
      SELECT DISTINCT u FROM (
        SELECT p.id AS u FROM public.profiles p
         WHERE p.role IN ('admin', 'staff') AND p.is_active
        UNION ALL SELECT v_creator
        UNION ALL SELECT v_driver_user
      ) r
      WHERE u IS NOT NULL AND (v_actor IS NULL OR u <> v_actor)
    LOOP
      INSERT INTO public.notifications (user_id, type, title, message, priority, action_url, reference_id)
      SELECT rec_user, v_type, v_title, v_message, v_priority, '/delivery', v_ref
      WHERE NOT EXISTS (
        SELECT 1 FROM public.notifications n
        WHERE n.user_id = rec_user AND n.reference_id = v_ref
      );
    END LOOP;
  EXCEPTION WHEN others THEN
    RETURN NEW;  -- swallow: the lifecycle transition must succeed regardless
  END;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS notify_delivery_status_change ON public.deliveries;
CREATE TRIGGER notify_delivery_status_change
  AFTER UPDATE OF status ON public.deliveries
  FOR EACH ROW EXECUTE FUNCTION public.notify_delivery_status_change();

-- ── (U3) New 'requested' order → notify all active staff/admin ─────────────
-- Fires on the storefront INSERT (submit_rental_request writes
-- status='requested') and on the payment promotion UPDATE
-- (verify_stripe_payment / verify_square_payment: pending_payment →
-- 'requested'). reference_id 'order_<id>_requested' dedups re-fires.
CREATE OR REPLACE FUNCTION public.notify_new_request()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_customer TEXT;
  v_title    TEXT;
  v_message  TEXT;
  v_ref      TEXT;
  v_actor    UUID := auth.uid();
  rec_user   UUID;
BEGIN
  IF NEW.status <> 'requested' THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD.status = 'requested' THEN RETURN NEW; END IF;

  -- Must never abort the order INSERT or — critically — the promotion of a
  -- PAID Stripe/Square order to 'requested' (Stripe is live; an exception
  -- here would drop a paid order back to pending_payment).
  BEGIN
    SELECT c.full_name INTO v_customer FROM public.customers c WHERE c.id = NEW.customer_id;

    v_ref := 'order_' || NEW.id || '_requested';
    v_title := CASE
      WHEN TG_OP = 'UPDATE' AND NEW.payment_status = 'paid'
        THEN 'Paid ' || NEW.order_type || ' — Order #' || NEW.order_no
      ELSE 'New ' || NEW.order_type || ' request — Order #' || NEW.order_no
    END;
    v_message := 'From ' || COALESCE(v_customer, 'customer')
      || COALESCE(' · ' || NULLIF(concat_ws(', ', NEW.address_city, NEW.address_state), ''), '');

    FOR rec_user IN
      SELECT p.id FROM public.profiles p
       WHERE p.role IN ('admin', 'staff') AND p.is_active
         AND (v_actor IS NULL OR p.id <> v_actor)
    LOOP
      INSERT INTO public.notifications (user_id, type, title, message, priority, action_url, reference_id)
      SELECT rec_user, 'rental', v_title, v_message, 'high', '/requests', v_ref
      WHERE NOT EXISTS (
        SELECT 1 FROM public.notifications n
        WHERE n.user_id = rec_user AND n.reference_id = v_ref
      );
    END LOOP;
  EXCEPTION WHEN others THEN
    RETURN NEW;  -- swallow: the order write must succeed regardless
  END;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_new_request ON public.rental_orders;
CREATE TRIGGER trg_notify_new_request
  AFTER INSERT OR UPDATE OF status ON public.rental_orders
  FOR EACH ROW EXECUTE FUNCTION public.notify_new_request();

-- ── (U12) Assignment changes: also notify the driver who LOST the stop ─────
CREATE OR REPLACE FUNCTION public.notify_driver_on_assignment()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_user UUID; v_old_user UUID; v_no BIGINT; v_cust TEXT; v_items TEXT; v_when TEXT; v_where TEXT;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.driver_id IS NOT DISTINCT FROM OLD.driver_id THEN RETURN NEW; END IF;
  IF TG_OP = 'INSERT' AND NEW.driver_id IS NULL THEN RETURN NEW; END IF;

  -- A notification must never block the delivery from being created/assigned.
  BEGIN
    SELECT o.order_no, c.full_name INTO v_no, v_cust
      FROM public.rental_orders o LEFT JOIN public.customers c ON c.id = o.customer_id
     WHERE o.id = NEW.order_id;

    -- (U12) The driver who lost the stop (reassigned away or unassigned).
    -- Skipped for completed/cancelled legs — nothing left to stand down from.
    IF TG_OP = 'UPDATE' AND OLD.driver_id IS NOT NULL
       AND NEW.status NOT IN ('completed', 'cancelled') THEN
      SELECT user_id INTO v_old_user FROM public.drivers WHERE id = OLD.driver_id;
      IF v_old_user IS NOT NULL THEN
        INSERT INTO public.notifications (user_id, type, title, message, priority, action_url, reference_id, read)
        VALUES (v_old_user, 'alert',
          'Stop removed — Order #' || v_no,
          'The ' || NEW.leg_type || ' for ' || COALESCE(v_cust, 'customer')
            || ' was taken off your route. Do not run this stop.',
          'high', '/delivery', 'delivery_' || NEW.id || '_unassigned_' || OLD.driver_id, false);
      END IF;
    END IF;

    -- (028, unchanged) The driver who gained the stop — WHAT/WHERE/WHEN/who.
    IF NEW.driver_id IS NOT NULL THEN
      SELECT user_id INTO v_user FROM public.drivers WHERE id = NEW.driver_id;
      IF v_user IS NOT NULL THEN  -- driver has a linked login
        SELECT string_agg(cnt || '× ' || name, ', ')
          INTO v_items
          FROM (SELECT ei.name, SUM(li.quantity) AS cnt
                  FROM public.rental_line_items li JOIN public.equipment_items ei ON ei.id = li.equipment_item_id
                 WHERE li.order_id = NEW.order_id GROUP BY ei.name) t;

        v_where := concat_ws(', ', NEW.address_line1, NEW.address_city, NEW.address_state, NEW.address_zip);

        v_when := trim(
          COALESCE(to_char(NEW.scheduled_date, 'Dy, Mon FMDD'), 'Date TBD')
          || CASE WHEN NEW.window_start IS NOT NULL
                  THEN ' · ' || to_char(NEW.window_start, 'FMHH12:MI AM')
                       || CASE WHEN NEW.window_end IS NOT NULL THEN '–' || to_char(NEW.window_end, 'FMHH12:MI AM') ELSE '' END
                  ELSE '' END);

        INSERT INTO public.notifications (user_id, type, title, message, priority, action_url, reference_id, read)
        VALUES (v_user, 'delivery',
          'New ' || NEW.leg_type || ' — Order #' || v_no,
          'What: '  || COALESCE(NULLIF(v_items, ''), '(items on order)') ||
          E'\nWhere: ' || COALESCE(NULLIF(v_where, ''), '(address on file)') ||
          E'\nWhen: '  || v_when ||
          E'\nCustomer: ' || COALESCE(v_cust, '—'),
          'high', '/delivery', NEW.id::text, false);
      END IF;
    END IF;
  EXCEPTION WHEN others THEN
    RETURN NEW;  -- swallow: delivery assignment succeeds regardless
  END;

  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_notify_driver_on_assignment ON public.deliveries;
CREATE TRIGGER trg_notify_driver_on_assignment
  AFTER INSERT OR UPDATE OF driver_id ON public.deliveries
  FOR EACH ROW EXECUTE FUNCTION public.notify_driver_on_assignment();
