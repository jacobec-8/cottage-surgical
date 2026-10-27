-- 082 — New-request notices reach the store once its location is known (regression from 074).
-- Storefront checkout inserts the order with no store and assigns it a moment
-- later in the same transaction. Since 074 scoped recipients by store, the
-- insert-time notice went to admins only; the store's staff and owner never
-- heard about storefront requests. Notify when the request has a store:
-- at insert if it already has one, otherwise when the store is assigned.

CREATE OR REPLACE FUNCTION public.notify_new_request()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_customer TEXT;
  v_title    TEXT;
  v_message  TEXT;
  v_ref      TEXT;
  v_actor    UUID := auth.uid();
  rec_user   UUID;
BEGIN
  IF NEW.status <> 'requested' THEN RETURN NEW; END IF;
  -- Wait until the request has a store; recipients are that store's staff and owner.
  IF NEW.location_id IS NULL THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD.status = 'requested' AND OLD.location_id IS NOT NULL THEN RETURN NEW; END IF;

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
      SELECT r FROM public.staff_recipients_for_location(NEW.location_id) r
       WHERE (v_actor IS NULL OR r <> v_actor)
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
$function$;

DROP TRIGGER IF EXISTS trg_notify_new_request ON public.rental_orders;
CREATE TRIGGER trg_notify_new_request AFTER INSERT OR UPDATE OF status, location_id ON public.rental_orders
  FOR EACH ROW EXECUTE FUNCTION public.notify_new_request();

-- Backfill the store staff and owners who missed notices for requests still
-- awaiting review (same text as the trigger; one row per recipient).
INSERT INTO public.notifications (user_id, type, title, message, priority, action_url, reference_id)
SELECT r.uid, 'rental',
       CASE WHEN o.payment_status = 'paid' THEN 'Paid ' ELSE 'New ' END || o.order_type
         || CASE WHEN o.payment_status = 'paid' THEN ' — Order #' ELSE ' request — Order #' END || o.order_no,
       'From ' || COALESCE(c.full_name, 'customer')
         || COALESCE(' · ' || NULLIF(concat_ws(', ', o.address_city, o.address_state), ''), ''),
       'high', '/requests', 'order_' || o.id || '_requested'
  FROM public.rental_orders o
  LEFT JOIN public.customers c ON c.id = o.customer_id
  CROSS JOIN LATERAL public.staff_recipients_for_location(o.location_id) AS r(uid)
 WHERE o.status = 'requested' AND o.location_id IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM public.notifications n
                    WHERE n.user_id = r.uid AND n.reference_id = 'order_' || o.id || '_requested');
