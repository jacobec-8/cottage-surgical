-- ═══════════════════════════════════════════════════════════════════════════
-- 028 — Notify the driver when they're assigned a delivery/pickup
-- ───────────────────────────────────────────────────────────────────────────
-- The moment a driver is assigned to a stop (New Order with a driver, or the
-- Delivery board), they get a detailed notification — WHAT (items), WHERE (full
-- address), WHEN (date + time window), and the customer. Stored in the
-- notifications table (an email sender can read from here later).
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.notify_driver_on_assignment()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_user UUID; v_no BIGINT; v_cust TEXT; v_items TEXT; v_when TEXT; v_where TEXT;
BEGIN
  IF NEW.driver_id IS NULL THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND NEW.driver_id IS NOT DISTINCT FROM OLD.driver_id THEN RETURN NEW; END IF;

  -- A notification must never block the delivery from being created/assigned.
  BEGIN
    SELECT user_id INTO v_user FROM public.drivers WHERE id = NEW.driver_id;
    IF v_user IS NULL THEN RETURN NEW; END IF;  -- driver has no linked login

    SELECT o.order_no, c.full_name INTO v_no, v_cust
      FROM public.rental_orders o LEFT JOIN public.customers c ON c.id = o.customer_id
     WHERE o.id = NEW.order_id;

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
  EXCEPTION WHEN others THEN
    RETURN NEW;  -- swallow: delivery assignment succeeds regardless
  END;

  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_notify_driver_on_assignment ON public.deliveries;
CREATE TRIGGER trg_notify_driver_on_assignment
  AFTER INSERT OR UPDATE OF driver_id ON public.deliveries
  FOR EACH ROW EXECUTE FUNCTION public.notify_driver_on_assignment();

-- RLS: each user reads/updates their own notifications; staff may read all.
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS notifications_own ON public.notifications;
CREATE POLICY notifications_own ON public.notifications
  FOR ALL USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());
DROP POLICY IF EXISTS notifications_staff_read ON public.notifications;
CREATE POLICY notifications_staff_read ON public.notifications
  FOR SELECT USING (public.is_staff_or_admin());
GRANT SELECT, UPDATE ON public.notifications TO authenticated;
