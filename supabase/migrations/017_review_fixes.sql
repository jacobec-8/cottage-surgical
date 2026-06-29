-- ═══════════════════════════════════════════════════════════════════════════
-- 017 — Adversarial-review fixes (high severity)
-- ───────────────────────────────────────────────────────────────────────────
-- A+B+D: harden submit_rental_request (the anon storefront RPC):
--   * NEVER merge a storefront submission into an existing customer by
--     unverified email/phone — always create a fresh "lead" customer. (Kills the
--     patient-record-poisoning / order-hijack vector.)
--   * Validate everything BEFORE any insert (clean abort, no orphan rows):
--     order_type, item count, name, quantity (1..50), and that each item exists,
--     is active, and is valid+priced for the order type (rentable+rental price /
--     purchasable+sale price). Bad input returns a clean {ok:false,reason} —
--     never a raw Postgres error to the public.
--   * Whitelist coverage_type; safe-parse dob (no cast errors reach anon).
--
-- E: get_busy_driver_ids gets an internal authorization guard, so even though it
--    is EXECUTE-granted broadly it no longer leaks driver IDs/schedules to a
--    logged-in customer.
--
-- Idempotent: CREATE OR REPLACE.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.submit_rental_request(
  p_order_type TEXT,
  p_items      JSONB,
  p_customer   JSONB,
  p_address    JSONB,
  p_notes      TEXT DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cust UUID; v_order UUID; v_no BIGINT;
  v_item JSONB; v_rec JSONB;
  v_rate NUMERIC := 0; v_item_rate NUMERIC; v_qty INT; v_iid UUID;
  v_cov TEXT; v_dob DATE;
  v_validated JSONB := '[]'::jsonb;
BEGIN
  IF p_order_type NOT IN ('rental', 'purchase') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_order_type');
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_items');
  END IF;
  IF jsonb_array_length(p_items) > 50 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'too_many_items');
  END IF;
  IF COALESCE(p_customer->>'full_name', '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_name');
  END IF;

  -- Sanitize self-reported fields (no raw CHECK/cast errors reach the caller).
  v_cov := CASE WHEN p_customer->>'coverage_type'
                  IN ('medicare', 'medicaid', 'private_pay', 'commercial_insurance')
                THEN p_customer->>'coverage_type' ELSE NULL END;
  v_dob := CASE WHEN p_customer->>'dob' ~ '^\d{4}-\d{2}-\d{2}$'
                THEN (p_customer->>'dob')::date ELSE NULL END;

  -- ── PASS 1: validate every item BEFORE writing anything ──────────────────
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    BEGIN v_qty := COALESCE(NULLIF(v_item->>'quantity', '')::int, 1);
    EXCEPTION WHEN others THEN v_qty := NULL; END;
    IF v_qty IS NULL OR v_qty < 1 OR v_qty > 50 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_quantity');
    END IF;

    BEGIN v_iid := (v_item->>'item_id')::uuid;
    EXCEPTION WHEN others THEN v_iid := NULL; END;
    IF v_iid IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item');
    END IF;

    -- Item must exist, be active, and be valid+priced for this order type.
    SELECT CASE WHEN p_order_type = 'rental' THEN monthly_rental_price ELSE sale_price END
      INTO v_item_rate
      FROM public.equipment_items
     WHERE id = v_iid AND is_active
       AND ((p_order_type = 'rental'   AND is_rentable    AND monthly_rental_price IS NOT NULL)
         OR (p_order_type = 'purchase' AND is_purchasable AND sale_price          IS NOT NULL));
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item');
    END IF;

    v_validated := v_validated || jsonb_build_array(
      jsonb_build_object('iid', v_iid, 'qty', v_qty, 'rate', v_item_rate));
    IF p_order_type = 'rental' THEN v_rate := v_rate + v_item_rate * v_qty; END IF;
  END LOOP;

  -- ── PASS 2: all valid → create a NEW lead customer + the order + lines ───
  INSERT INTO public.customers (full_name, phone, email, date_of_birth, coverage_type,
      address_line1, address_city, address_state, address_zip, notes)
  VALUES (p_customer->>'full_name', NULLIF(p_customer->>'phone',''), NULLIF(p_customer->>'email',''),
      v_dob, v_cov,
      p_address->>'line1', p_address->>'city', COALESCE(NULLIF(p_address->>'state',''),'NY'), p_address->>'zip',
      'Storefront request — unverified lead')
  RETURNING id INTO v_cust;

  INSERT INTO public.rental_orders (customer_id, order_type, status, source,
      address_line1, address_city, address_state, address_zip, special_notes, monthly_rate)
  VALUES (v_cust, p_order_type, 'requested', 'storefront',
      p_address->>'line1', p_address->>'city', COALESCE(NULLIF(p_address->>'state',''),'NY'), p_address->>'zip',
      p_notes, CASE WHEN p_order_type = 'rental' THEN v_rate ELSE NULL END)
  RETURNING id, order_no INTO v_order, v_no;

  FOR v_rec IN SELECT * FROM jsonb_array_elements(v_validated) LOOP
    INSERT INTO public.rental_line_items (order_id, equipment_item_id, line_type, quantity,
        monthly_rate, sale_price, is_active)
    VALUES (v_order, (v_rec->>'iid')::uuid, p_order_type, (v_rec->>'qty')::int,
        CASE WHEN p_order_type = 'rental'   THEN (v_rec->>'rate')::numeric END,
        CASE WHEN p_order_type = 'purchase' THEN (v_rec->>'rate')::numeric END,
        FALSE);
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'order_id', v_order, 'order_no', v_no);
END;
$$;

-- ── E: guard get_busy_driver_ids so customers can't enumerate driver schedules ─
CREATE OR REPLACE FUNCTION public.get_busy_driver_ids(p_date DATE, p_start TIME, p_end TIME)
RETURNS SETOF UUID
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN QUERY
    SELECT DISTINCT driver_id FROM public.deliveries
     WHERE driver_id IS NOT NULL
       AND scheduled_date = p_date
       AND status NOT IN ('cancelled', 'completed')
       AND window_start IS NOT NULL AND window_end IS NOT NULL
       AND window_start < p_end AND window_end > p_start;
END;
$$;
