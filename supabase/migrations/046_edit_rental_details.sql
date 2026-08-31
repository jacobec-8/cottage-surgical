-- Staff/admin can edit the operational details of an existing rental without
-- touching its serialized equipment allocations or lifecycle status.

CREATE OR REPLACE FUNCTION public.update_rental_details(
  p_order_id UUID,
  p_full_name TEXT,
  p_phone TEXT,
  p_email TEXT,
  p_address_line1 TEXT,
  p_address_city TEXT,
  p_address_state TEXT,
  p_address_zip TEXT,
  p_start_date DATE,
  p_end_date DATE,
  p_monthly_rate NUMERIC,
  p_deposit_amount NUMERIC,
  p_special_notes TEXT
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_customer UUID; v_type TEXT; v_status TEXT;
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF COALESCE(btrim(p_full_name), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_name');
  END IF;
  IF p_monthly_rate IS NOT NULL AND p_monthly_rate < 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_rate');
  END IF;
  IF p_deposit_amount IS NOT NULL AND p_deposit_amount < 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_deposit');
  END IF;
  IF p_start_date IS NOT NULL AND p_end_date IS NOT NULL AND p_end_date < p_start_date THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_dates');
  END IF;

  SELECT customer_id, order_type, status INTO v_customer, v_type, v_status
    FROM public.rental_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;
  IF v_type <> 'rental' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_rental');
  END IF;
  IF v_status IN ('closed', 'cancelled') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'closed');
  END IF;

  UPDATE public.customers
     SET full_name = btrim(p_full_name),
         phone = NULLIF(btrim(p_phone), ''),
         email = NULLIF(lower(btrim(p_email)), ''),
         address_line1 = NULLIF(btrim(p_address_line1), ''),
         address_city = NULLIF(btrim(p_address_city), ''),
         address_state = COALESCE(NULLIF(upper(btrim(p_address_state)), ''), 'NY'),
         address_zip = NULLIF(btrim(p_address_zip), '')
   WHERE id = v_customer;

  UPDATE public.rental_orders
     SET address_line1 = NULLIF(btrim(p_address_line1), ''),
         address_city = NULLIF(btrim(p_address_city), ''),
         address_state = COALESCE(NULLIF(upper(btrim(p_address_state)), ''), 'NY'),
         address_zip = NULLIF(btrim(p_address_zip), ''),
         start_date = p_start_date,
         end_date = p_end_date,
         monthly_rate = p_monthly_rate,
         deposit_amount = p_deposit_amount,
         special_notes = NULLIF(btrim(p_special_notes), '')
   WHERE id = p_order_id;

  -- Keep billing at the edited order rate. This updates the record only; it
  -- never charges Stripe or records a payment.
  UPDATE public.recurring_charges
     SET amount = COALESCE(p_monthly_rate, 0)
   WHERE order_id = p_order_id AND status <> 'ended';

  -- A future stop should follow an edited service address. Never rewrite a
  -- completed/cancelled stop or a driver already en route.
  UPDATE public.deliveries
     SET address_line1 = NULLIF(btrim(p_address_line1), ''),
         address_city = NULLIF(btrim(p_address_city), ''),
         address_state = COALESCE(NULLIF(upper(btrim(p_address_state)), ''), 'NY'),
         address_zip = NULLIF(btrim(p_address_zip), '')
   WHERE order_id = p_order_id AND status IN ('pending', 'scheduled');

  RETURN jsonb_build_object('ok', true);
END;
$$;

REVOKE ALL ON FUNCTION public.update_rental_details(
  UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT,
  DATE, DATE, NUMERIC, NUMERIC, TEXT
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_rental_details(
  UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT,
  DATE, DATE, NUMERIC, NUMERIC, TEXT
) TO authenticated, service_role;
