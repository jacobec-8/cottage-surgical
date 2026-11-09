-- 141: Every order gets a receipt: the whole story from placement to done.
--
-- order_receipt(order) returns, in one read, the order, its pharmacy, the
-- customer, every item and unit, every status and payment change (order_events,
-- 114), every money record, deposits and monthly charges, and each stop with
-- its driver, missed attempts and proof photos. Staff, owners and admins of the
-- order's pharmacy may read it (Jacob, 2026-11-02: store staff see money on
-- their own pharmacy's receipts). money_records keeps its owner-only policy;
-- this function is the one path staff see money. Another pharmacy's order
-- reads as not found.
--
-- Stops now record who finished them (deliveries.completed_by): drivers
-- finishing with a photo, staff marking a counter pickup or overriding. A
-- counter pickup needs no photo for now. Additive: no live function changes;
-- the trigger runs last (zz_) so it sees completed_at set by any path.

ALTER TABLE public.deliveries ADD COLUMN IF NOT EXISTS completed_by uuid;

CREATE OR REPLACE FUNCTION public.stamp_delivery_completed_by()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  -- The signed-in person who finished it; nobody can rewrite it afterwards.
  IF NEW.completed_at IS NOT NULL AND OLD.completed_at IS NULL THEN
    NEW.completed_by := COALESCE(auth.uid(), NEW.completed_by);
  ELSE
    NEW.completed_by := OLD.completed_by;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS zz_stamp_completed_by ON public.deliveries;
CREATE TRIGGER zz_stamp_completed_by BEFORE UPDATE ON public.deliveries
  FOR EACH ROW EXECUTE FUNCTION public.stamp_delivery_completed_by();

-- A signed-in person's name for the receipt; NULL means online checkout or the system.
CREATE OR REPLACE FUNCTION public.receipt_person(p_user uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT CASE WHEN p_user IS NULL THEN NULL ELSE COALESCE(
    (SELECT COALESCE(NULLIF(p.full_name, ''), p.email) FROM public.profiles p WHERE p.id = p_user),
    'Signed-in user') END
$function$;

CREATE OR REPLACE FUNCTION public.order_receipt(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_order public.rental_orders%ROWTYPE;
BEGIN
  SELECT * INTO v_order FROM public.rental_orders WHERE id = p_order_id;
  IF NOT FOUND OR NOT (public.is_staff_or_admin() AND public.can_access_location(v_order.location_id)) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  RETURN jsonb_build_object('ok', true, 'receipt', jsonb_build_object(
    'order', jsonb_build_object(
      'id', v_order.id, 'order_no', v_order.order_no, 'order_type', v_order.order_type,
      'status', v_order.status, 'source', v_order.source, 'created_at', v_order.created_at,
      'placed_by', public.receipt_person(v_order.created_by),
      'amount_due', public.order_amount_due(v_order.id),
      'start_date', v_order.start_date, 'end_date', v_order.end_date,
      'monthly_rate', v_order.monthly_rate, 'deposit_amount', v_order.deposit_amount,
      'payment_status', v_order.payment_status, 'payment_preference', v_order.payment_preference,
      'fulfillment_method', v_order.fulfillment_method, 'special_notes', v_order.special_notes,
      'stripe_session_id', v_order.stripe_session_id, 'stripe_refund_id', v_order.stripe_refund_id,
      'square_order_id', v_order.square_order_id,
      'closed_reason', v_order.closed_reason, 'closed_at', v_order.closed_at,
      'closed_by', public.receipt_person(v_order.closed_by),
      'address_line1', v_order.address_line1, 'address_city', v_order.address_city,
      'address_state', v_order.address_state, 'address_zip', v_order.address_zip),
    'store', (SELECT jsonb_build_object(
        'name', l.name, 'address_line1', l.address_line1, 'address_line2', l.address_line2,
        'address_city', l.address_city, 'address_state', l.address_state,
        'address_zip', l.address_zip, 'phone', l.phone)
      FROM public.pickup_locations l WHERE l.id = v_order.location_id),
    'customer', (SELECT jsonb_build_object(
        'full_name', c.full_name, 'phone', c.phone, 'email', c.email,
        'address_line1', c.address_line1, 'address_city', c.address_city,
        'address_state', c.address_state, 'address_zip', c.address_zip)
      FROM public.customers c WHERE c.id = v_order.customer_id),
    'lines', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'name', i.name, 'line_type', li.line_type, 'quantity', li.quantity,
        'monthly_rate', li.monthly_rate, 'sale_price', li.sale_price, 'is_active', li.is_active,
        'asset_tag', u.asset_tag, 'serial_number', u.serial_number) ORDER BY li.created_at)
      FROM public.rental_line_items li
      LEFT JOIN public.equipment_items i ON i.id = li.equipment_item_id
      LEFT JOIN public.equipment_units u ON u.id = li.equipment_unit_id
      WHERE li.order_id = v_order.id), '[]'::jsonb),
    'events', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'changed_at', e.changed_at, 'from_status', e.from_status, 'to_status', e.to_status,
        'from_payment_status', e.from_payment_status, 'to_payment_status', e.to_payment_status,
        'by', public.receipt_person(e.changed_by)) ORDER BY e.changed_at)
      FROM public.order_events e WHERE e.order_id = v_order.id), '[]'::jsonb),
    'money', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'recorded_at', m.recorded_at, 'kind', m.kind, 'cash_amount', m.cash_amount,
        'revenue_amount', m.revenue_amount, 'method', m.method, 'reference', m.reference,
        'note', m.note, 'by', public.receipt_person(m.recorded_by)) ORDER BY m.recorded_at)
      FROM public.money_records m WHERE m.order_id = v_order.id), '[]'::jsonb),
    'deposits', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'amount', dp.amount, 'status', dp.status, 'held_at', dp.held_at) ORDER BY dp.held_at)
      FROM public.deposits dp WHERE dp.order_id = v_order.id), '[]'::jsonb),
    'charges', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'amount', rc.amount, 'status', rc.status, 'billing_start', rc.billing_start,
        'billing_end', rc.billing_end, 'next_due_date', rc.next_due_date,
        'last_billed_on', rc.last_billed_on) ORDER BY rc.created_at)
      FROM public.recurring_charges rc WHERE rc.order_id = v_order.id), '[]'::jsonb),
    'stops', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'id', d.id, 'leg_type', d.leg_type, 'requires_driver', d.requires_driver,
        'status', d.status, 'scheduled_date', d.scheduled_date, 'window_label', d.window_label,
        'window_start', d.window_start, 'window_end', d.window_end,
        'address_line1', d.address_line1, 'address_city', d.address_city,
        'address_state', d.address_state, 'address_zip', d.address_zip, 'notes', d.notes,
        'created_at', d.created_at, 'started_at', d.started_at, 'completed_at', d.completed_at,
        'completed_by', public.receipt_person(d.completed_by),
        'driver', NULLIF(concat_ws(' ', dr.first_name, dr.last_name), ''), 'driver_phone', dr.phone,
        'attempts', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'created_at', a.created_at, 'reason', a.reason, 'note', a.note,
            'by', public.receipt_person(a.reported_by)) ORDER BY a.created_at)
          FROM public.stop_attempts a WHERE a.delivery_id = d.id), '[]'::jsonb),
        'photos', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'storage_path', ph.storage_path, 'captured_at', ph.captured_at, 'notes', ph.notes,
            'by', public.receipt_person(ph.captured_by)) ORDER BY ph.captured_at)
          FROM public.delivery_photos ph WHERE ph.delivery_id = d.id), '[]'::jsonb))
        ORDER BY d.created_at, d.sequence)
      FROM public.deliveries d
      LEFT JOIN public.drivers dr ON dr.id = d.driver_id
      WHERE d.order_id = v_order.id), '[]'::jsonb)
  ));
END;
$function$;

REVOKE ALL ON FUNCTION public.stamp_delivery_completed_by() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.receipt_person(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.order_receipt(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.order_receipt(uuid) TO authenticated;
