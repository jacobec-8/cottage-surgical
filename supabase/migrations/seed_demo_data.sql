-- ═══════════════════════════════════════════════════════════════════════════
-- seed_demo_data.sql — Demo data matching the Figma designs (DEV ONLY)
-- ───────────────────────────────────────────────────────────────────────────
-- Populates customers, payment methods, the equipment catalog + serialized
-- units, drivers, the six rentals from the All-Rentals board, the delivery/
-- pickup tasks, and billing records, so the UI renders the same content as the
-- screenshots.
--
-- NOT numbered: run on demand (python3 scripts/run_migrations.py --only seed_demo_data.sql),
-- NOT as part of the normal migration sweep. Guarded: skips entirely if any
-- customers already exist, so it never clobbers real data.
--
-- Note: profiles (admin Sarah Johnson / staff Mike Chen) are created through
-- Supabase Auth, not here. Drivers are seeded as operational records with a
-- NULL user_id until a driver login is linked.
-- ═══════════════════════════════════════════════════════════════════════════

DO $$
DECLARE
  v_ord  UUID;
  v_ord6 UUID;
  v_u    UUID;
  v_drv  UUID;
BEGIN
  IF (SELECT count(*) FROM public.customers) > 0 THEN
    RAISE NOTICE 'seed_demo_data: customers already present — skipping.';
    RETURN;
  END IF;

  -- ── Customers ─────────────────────────────────────────────────────────────
  INSERT INTO public.customers (full_name, phone, coverage_type, address_line1, address_city, address_state, address_zip) VALUES
    ('Eleanor Martinez', '516-555-0101', 'medicare',             '123 Oak Street',  'Woodbury',  'NY', '11797'),
    ('Robert Thompson',  '516-555-0203', 'private_pay',          '456 Maple Ave',   'Syosset',   'NY', '11791'),
    ('Patricia Williams','516-555-0305', 'medicaid',             '789 Pine Road',   'Plainview', 'NY', '11803'),
    ('James Anderson',   '516-555-0406', 'commercial_insurance', '321 Birch Lane',  'Jericho',   'NY', '11753'),
    ('Linda Garcia',     '516-555-0508', 'medicare',             '654 Cedar Court', 'Hicksville','NY', '11801');

  -- ── Payment methods on file (display metadata only) ───────────────────────
  INSERT INTO public.payment_methods (customer_id, method_type, brand, last4, account_label, is_default)
  SELECT id, 'card', 'Visa', '4242', NULL, TRUE        FROM public.customers WHERE full_name = 'Eleanor Martinez'
  UNION ALL
  SELECT id, 'ach',  'Chase', NULL, 'Checking', TRUE   FROM public.customers WHERE full_name = 'Robert Thompson'
  UNION ALL
  SELECT id, 'card', 'Mastercard', '9871', NULL, TRUE  FROM public.customers WHERE full_name = 'Patricia Williams'
  UNION ALL
  SELECT id, 'card', 'Amex', '3344', NULL, TRUE        FROM public.customers WHERE full_name = 'James Anderson'
  UNION ALL
  SELECT id, 'ach',  'BofA', NULL, 'Savings', TRUE     FROM public.customers WHERE full_name = 'Linda Garcia';

  -- ── Equipment catalog ─────────────────────────────────────────────────────
  INSERT INTO public.equipment_items (name, description, category, sku, monthly_rental_price, sale_price, quantity_on_hand) VALUES
    ('Knee Scooter',                       'Dual pad steerable knee walker with basket',     'mobility',    'KS-001',   50,  295,  5),
    ('3 Position Seat Lift Chair',         'Power lift recliner with 3 position adjustment', 'seating',     'LC3-001',  250, 1299, 4),
    ('Hip Chair',                          'Post-surgical hip chair with elevated seat',     'seating',     'HC-001',   200, 899,  8),
    ('Trapeze Bar',                        'Overhead trapeze bar for bed mobility assistance','bedroom',    'TB-001',   125, 549,  6),
    ('Freestyle Portable Oxygen Concentrator','Portable oxygen concentrator for active patients','respiratory','POC-001',200, 2195, 6),
    ('5 Liter Stationary Oxygen Concentrator','5L compact stationary oxygen concentrator',   'respiratory', 'OC5L-001', 299, 749,  10),
    ('Suction Machine',                    'Assist suction aspirator for airway clearance',  'respiratory', 'SM-001',   200, 895,  5),
    -- Referenced by rentals but not on the inventory screenshot:
    ('Lightweight Wheelchair',             'Lightweight folding wheelchair',                 'mobility',    'LW-001',   299, 399,  7),
    ('Hoyer Hydraulic Patient Lift',       'Hydraulic patient transfer lift',                'mobility',    'HL-001',   125, 1599, 3),
    ('Reclining Wheelchair',               'High-back reclining wheelchair',                 'mobility',    'RW-001',   80,  699,  4),
    ('Companion Transport Wheelchair',     'Lightweight companion transport chair',          'mobility',    'CTW-001',  85,  249,  5);

  -- Base available units per item (asset tags SKU-1 .. SKU-N).
  INSERT INTO public.equipment_units (item_id, asset_tag, status)
  SELECT i.id, i.sku || '-' || g, 'available'
  FROM public.equipment_items i
  CROSS JOIN LATERAL generate_series(1, i.quantity_on_hand) g;

  -- ── Drivers (operational records; user login linked later) ────────────────
  INSERT INTO public.drivers (first_name, last_name, phone, status)
  VALUES ('Marco', 'Rodriguez', '516-555-0700', 'active')
  RETURNING id INTO v_drv;

  -- ── Helper inline: each rental gets dedicated 'out' units so the catalog's
  --    available counts still match the screenshots. ─────────────────────────

  -- Rental 1: Eleanor Martinez — Lightweight Wheelchair + Hip Chair — active
  INSERT INTO public.rental_orders (customer_id, order_type, status, address_line1, address_city, address_state, address_zip, start_date, monthly_rate, deposit_amount)
  SELECT id, 'rental', 'active', address_line1, address_city, address_state, address_zip, DATE '2026-05-15', 499, 150
  FROM public.customers WHERE full_name = 'Eleanor Martinez' RETURNING id INTO v_ord;
  INSERT INTO public.equipment_units (item_id, asset_tag, status)
    SELECT id, 'LW-001-R1', 'rented' FROM public.equipment_items WHERE sku = 'LW-001' RETURNING id INTO v_u;
  INSERT INTO public.rental_line_items (order_id, equipment_item_id, equipment_unit_id, line_type, monthly_rate, is_active)
    SELECT v_ord, id, v_u, 'rental', 299, TRUE FROM public.equipment_items WHERE sku = 'LW-001';
  INSERT INTO public.equipment_units (item_id, asset_tag, status)
    SELECT id, 'HC-001-R1', 'rented' FROM public.equipment_items WHERE sku = 'HC-001' RETURNING id INTO v_u;
  INSERT INTO public.rental_line_items (order_id, equipment_item_id, equipment_unit_id, line_type, monthly_rate, is_active)
    SELECT v_ord, id, v_u, 'rental', 200, TRUE FROM public.equipment_items WHERE sku = 'HC-001';
  INSERT INTO public.recurring_charges (order_id, customer_id, amount, status, billing_start, next_due_date)
    SELECT v_ord, customer_id, 499, 'current', DATE '2026-05-15', DATE '2026-07-15' FROM public.rental_orders WHERE id = v_ord;

  -- Rental 2: Robert Thompson — Oxygen (portable + stationary) — active
  INSERT INTO public.rental_orders (customer_id, order_type, status, address_line1, address_city, address_state, address_zip, start_date, monthly_rate, deposit_amount)
  SELECT id, 'rental', 'active', address_line1, address_city, address_state, address_zip, DATE '2026-06-01', 220, 150
  FROM public.customers WHERE full_name = 'Robert Thompson' RETURNING id INTO v_ord;
  INSERT INTO public.equipment_units (item_id, asset_tag, status)
    SELECT id, 'POC-001-R1', 'rented' FROM public.equipment_items WHERE sku = 'POC-001' RETURNING id INTO v_u;
  INSERT INTO public.rental_line_items (order_id, equipment_item_id, equipment_unit_id, line_type, monthly_rate, is_active)
    SELECT v_ord, id, v_u, 'rental', 200, TRUE FROM public.equipment_items WHERE sku = 'POC-001';
  INSERT INTO public.equipment_units (item_id, asset_tag, status)
    SELECT id, 'OC5L-001-R1', 'rented' FROM public.equipment_items WHERE sku = 'OC5L-001' RETURNING id INTO v_u;
  INSERT INTO public.rental_line_items (order_id, equipment_item_id, equipment_unit_id, line_type, monthly_rate, is_active)
    SELECT v_ord, id, v_u, 'rental', 299, TRUE FROM public.equipment_items WHERE sku = 'OC5L-001';
  INSERT INTO public.recurring_charges (order_id, customer_id, amount, status, billing_start, next_due_date)
    SELECT v_ord, customer_id, 499, 'current', DATE '2026-06-01', DATE '2026-07-01' FROM public.rental_orders WHERE id = v_ord;

  -- Rental 3: Patricia Williams — Trapeze Bar + Suction Machine — overdue
  INSERT INTO public.rental_orders (customer_id, order_type, status, address_line1, address_city, address_state, address_zip, start_date, monthly_rate, deposit_amount)
  SELECT id, 'rental', 'overdue', address_line1, address_city, address_state, address_zip, DATE '2026-04-20', 285, 150
  FROM public.customers WHERE full_name = 'Patricia Williams' RETURNING id INTO v_ord;
  INSERT INTO public.equipment_units (item_id, asset_tag, status)
    SELECT id, 'TB-001-R1', 'rented' FROM public.equipment_items WHERE sku = 'TB-001' RETURNING id INTO v_u;
  INSERT INTO public.rental_line_items (order_id, equipment_item_id, equipment_unit_id, line_type, monthly_rate, is_active)
    SELECT v_ord, id, v_u, 'rental', 125, TRUE FROM public.equipment_items WHERE sku = 'TB-001';
  INSERT INTO public.equipment_units (item_id, asset_tag, status)
    SELECT id, 'SM-001-R1', 'rented' FROM public.equipment_items WHERE sku = 'SM-001' RETURNING id INTO v_u;
  INSERT INTO public.rental_line_items (order_id, equipment_item_id, equipment_unit_id, line_type, monthly_rate, is_active)
    SELECT v_ord, id, v_u, 'rental', 200, TRUE FROM public.equipment_items WHERE sku = 'SM-001';
  INSERT INTO public.recurring_charges (order_id, customer_id, amount, status, billing_start, next_due_date)
    SELECT v_ord, customer_id, 325, 'overdue', DATE '2026-04-20', DATE '2026-06-20' FROM public.rental_orders WHERE id = v_ord;

  -- Rental 4: James Anderson — Hoyer Hydraulic Patient Lift — scheduled
  INSERT INTO public.rental_orders (customer_id, order_type, status, address_line1, address_city, address_state, address_zip, start_date, monthly_rate, deposit_amount)
  SELECT id, 'rental', 'scheduled', address_line1, address_city, address_state, address_zip, DATE '2026-06-08', 125, 150
  FROM public.customers WHERE full_name = 'James Anderson' RETURNING id INTO v_ord;
  INSERT INTO public.equipment_units (item_id, asset_tag, status)
    SELECT id, 'HL-001-R1', 'reserved' FROM public.equipment_items WHERE sku = 'HL-001' RETURNING id INTO v_u;
  INSERT INTO public.rental_line_items (order_id, equipment_item_id, equipment_unit_id, line_type, monthly_rate, is_active)
    SELECT v_ord, id, v_u, 'rental', 125, TRUE FROM public.equipment_items WHERE sku = 'HL-001';
  -- Delivery task for this scheduled rental (assigned to Marco).
  INSERT INTO public.deliveries (order_id, leg_type, driver_id, status, scheduled_date, window_start, window_end, address_line1, address_city, address_state, address_zip, sequence)
    SELECT v_ord, 'delivery', v_drv, 'scheduled', DATE '2026-06-08', TIME '13:00', TIME '15:00', address_line1, address_city, address_state, address_zip, 1
    FROM public.rental_orders WHERE id = v_ord;

  -- Rental 5: Linda Garcia — Reclining Wheelchair + Knee Scooter — delivered
  INSERT INTO public.rental_orders (customer_id, order_type, status, address_line1, address_city, address_state, address_zip, start_date, monthly_rate, deposit_amount)
  SELECT id, 'rental', 'delivered', address_line1, address_city, address_state, address_zip, DATE '2026-05-28', 130, 150
  FROM public.customers WHERE full_name = 'Linda Garcia' RETURNING id INTO v_ord;
  INSERT INTO public.equipment_units (item_id, asset_tag, status)
    SELECT id, 'RW-001-R1', 'rented' FROM public.equipment_items WHERE sku = 'RW-001' RETURNING id INTO v_u;
  INSERT INTO public.rental_line_items (order_id, equipment_item_id, equipment_unit_id, line_type, monthly_rate, is_active)
    SELECT v_ord, id, v_u, 'rental', 80, TRUE FROM public.equipment_items WHERE sku = 'RW-001';
  INSERT INTO public.equipment_units (item_id, asset_tag, status)
    SELECT id, 'KS-001-R1', 'rented' FROM public.equipment_items WHERE sku = 'KS-001' RETURNING id INTO v_u;
  INSERT INTO public.rental_line_items (order_id, equipment_item_id, equipment_unit_id, line_type, monthly_rate, is_active)
    SELECT v_ord, id, v_u, 'rental', 50, TRUE FROM public.equipment_items WHERE sku = 'KS-001';
  INSERT INTO public.recurring_charges (order_id, customer_id, amount, status, billing_start, next_due_date)
    SELECT v_ord, customer_id, 125, 'current', DATE '2026-05-28', DATE '2026-06-28' FROM public.rental_orders WHERE id = v_ord;

  -- Rental 6: Eleanor Martinez — Companion Transport WC + 3-Position Lift Chair — pickup scheduled
  INSERT INTO public.rental_orders (customer_id, order_type, status, address_line1, address_city, address_state, address_zip, start_date, monthly_rate, deposit_amount)
  SELECT id, 'rental', 'pickup_scheduled', address_line1, address_city, address_state, address_zip, DATE '2026-06-10', 335, 150
  FROM public.customers WHERE full_name = 'Eleanor Martinez' RETURNING id INTO v_ord6;
  INSERT INTO public.equipment_units (item_id, asset_tag, status)
    SELECT id, 'CTW-001-R1', 'rented' FROM public.equipment_items WHERE sku = 'CTW-001' RETURNING id INTO v_u;
  INSERT INTO public.rental_line_items (order_id, equipment_item_id, equipment_unit_id, line_type, monthly_rate, is_active)
    SELECT v_ord6, id, v_u, 'rental', 85, TRUE FROM public.equipment_items WHERE sku = 'CTW-001';
  INSERT INTO public.equipment_units (item_id, asset_tag, status)
    SELECT id, 'LC3-001-R1', 'rented' FROM public.equipment_items WHERE sku = 'LC3-001' RETURNING id INTO v_u;
  INSERT INTO public.rental_line_items (order_id, equipment_item_id, equipment_unit_id, line_type, monthly_rate, is_active)
    SELECT v_ord6, id, v_u, 'rental', 250, TRUE FROM public.equipment_items WHERE sku = 'LC3-001';
  -- Deposit pending refund (Billing → Refunds tab).
  INSERT INTO public.deposits (order_id, customer_id, amount, status)
    SELECT v_ord6, customer_id, 150, 'pending_refund' FROM public.rental_orders WHERE id = v_ord6;
  -- Pickup task (assigned to Marco) for this rental.
  INSERT INTO public.deliveries (order_id, leg_type, driver_id, status, scheduled_date, window_start, window_end, address_line1, address_city, address_state, address_zip, sequence)
    SELECT v_ord6, 'pickup', v_drv, 'scheduled', DATE '2026-06-10', TIME '10:00', TIME '12:00', address_line1, address_city, address_state, address_zip, 1
    FROM public.rental_orders WHERE id = v_ord6;

  -- Second delivery task on the board: Robert Thompson (his active rental), 6/8 3-5PM.
  INSERT INTO public.deliveries (order_id, leg_type, driver_id, status, scheduled_date, window_start, window_end, address_line1, address_city, address_state, address_zip, sequence)
  SELECT o.id, 'delivery', v_drv, 'scheduled', DATE '2026-06-08', TIME '15:00', TIME '17:00', o.address_line1, o.address_city, o.address_state, o.address_zip, 2
  FROM public.rental_orders o JOIN public.customers c ON c.id = o.customer_id
  WHERE c.full_name = 'Robert Thompson';

  RAISE NOTICE 'seed_demo_data: complete.';
END $$;
