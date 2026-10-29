-- ═══════════════════════════════════════════════════════════════════════════
-- 113 — One-time cleanup: fold duplicate customer records into one
-- ───────────────────────────────────────────────────────────────────────────
-- Before 112, every website request made a new customer record, so one
-- person could appear many times at a store. This folds each set of
-- duplicates into its oldest record, using 112's rule: same store, same name,
-- and the same email or phone. Chains count too (A and B share an email, B and
-- C share a phone: all three are one person).
--
-- For each set: the oldest record is kept. Its empty fields are filled from
-- the newest duplicate that has them (the address moves as a whole). Staff
-- notes from duplicates are kept; the automatic "Storefront request…" notes
-- are not. Another email or phone a duplicate used is noted as "Also used".
-- A set whose records belong to two different website logins is skipped and
-- reported, never folded. Orders, monthly charges, deposits, refunds, payments and saved
-- payment methods move to the kept record, then the duplicates are deleted.
--
-- Run once, on Jacob's go. Rerunning finds nothing left to fold.
-- ═══════════════════════════════════════════════════════════════════════════

DO $$
DECLARE
  v_set RECORD;
  v_keep uuid;
  v_dupes uuid[];
  v_logins int;
  v_login uuid;
  v_changed int;
  v_sets int := 0;
  v_removed int := 0;
BEGIN
  DROP TABLE IF EXISTS fold_customers;
  CREATE TEMP TABLE fold_customers ON COMMIT DROP AS
  SELECT id, location_id,
         public.customer_name_key(full_name) AS name_key,
         NULLIF(lower(btrim(email)), '') AS email_key,
         public.customer_phone_key(phone) AS phone_key,
         row_number() OVER (ORDER BY created_at, id) AS rank,
         row_number() OVER (ORDER BY created_at, id) AS set_no
    FROM public.customers
   WHERE location_id IS NOT NULL AND public.customer_name_key(full_name) IS NOT NULL;

  -- Label each set with its oldest member by spreading the smallest rank
  -- across matching records until nothing changes.
  LOOP
    UPDATE fold_customers a SET set_no = m.low
      FROM (SELECT a2.id, min(b.set_no) AS low
              FROM fold_customers a2
              JOIN fold_customers b
                ON b.location_id = a2.location_id AND b.name_key = a2.name_key
               AND (b.email_key = a2.email_key OR b.phone_key = a2.phone_key)
             GROUP BY a2.id) m
     WHERE m.id = a.id AND m.low < a.set_no;
    GET DIAGNOSTICS v_changed = ROW_COUNT;
    EXIT WHEN v_changed = 0;
  END LOOP;

  FOR v_set IN
    SELECT set_no, array_agg(id ORDER BY rank) AS ids
      FROM fold_customers GROUP BY set_no HAVING count(*) > 1
  LOOP
    v_keep := v_set.ids[1];
    v_dupes := v_set.ids[2:];

    -- Two different website logins can't share one record: leave that set for
    -- staff to sort out rather than drop a login's link.
    SELECT count(DISTINCT user_id), max(user_id::text)::uuid INTO v_logins, v_login
      FROM public.customers WHERE id = ANY(v_set.ids) AND user_id IS NOT NULL;
    IF v_logins > 1 THEN
      RAISE NOTICE 'Skipped customer %: its duplicates belong to % different logins', v_keep, v_logins;
      CONTINUE;
    END IF;
    -- user_id is unique, so free it on the duplicate before the kept record takes it.
    IF v_login IS NOT NULL THEN
      UPDATE public.customers SET user_id = NULL WHERE id = ANY(v_dupes) AND user_id = v_login;
    END IF;

    UPDATE public.customers k SET
      phone = COALESCE(NULLIF(k.phone, ''), (SELECT d.phone FROM public.customers d WHERE d.id = ANY(v_dupes) AND NULLIF(d.phone, '') IS NOT NULL ORDER BY d.created_at DESC LIMIT 1)),
      email = COALESCE(NULLIF(k.email, ''), (SELECT d.email FROM public.customers d WHERE d.id = ANY(v_dupes) AND NULLIF(d.email, '') IS NOT NULL ORDER BY d.created_at DESC LIMIT 1)),
      date_of_birth = COALESCE(k.date_of_birth, (SELECT d.date_of_birth FROM public.customers d WHERE d.id = ANY(v_dupes) AND d.date_of_birth IS NOT NULL ORDER BY d.created_at DESC LIMIT 1)),
      coverage_type = COALESCE(k.coverage_type, (SELECT d.coverage_type FROM public.customers d WHERE d.id = ANY(v_dupes) AND d.coverage_type IS NOT NULL ORDER BY d.created_at DESC LIMIT 1)),
      insurance_notes = COALESCE(NULLIF(k.insurance_notes, ''), (SELECT d.insurance_notes FROM public.customers d WHERE d.id = ANY(v_dupes) AND NULLIF(d.insurance_notes, '') IS NOT NULL ORDER BY d.created_at DESC LIMIT 1)),
      user_id = COALESCE(k.user_id, v_login),
      -- Any other email or phone a duplicate used stays findable in the notes.
      notes = NULLIF(concat_ws(E'\n', NULLIF(k.notes, ''), (
        SELECT 'Also used: ' || string_agg(v, ', ') FROM (
          SELECT DISTINCT d.email AS v FROM public.customers d
           WHERE d.id = ANY(v_dupes) AND NULLIF(btrim(d.email), '') IS NOT NULL
             AND lower(btrim(d.email)) IS DISTINCT FROM lower(btrim(k.email)) AND NULLIF(btrim(k.email), '') IS NOT NULL
          UNION
          SELECT DISTINCT d.phone FROM public.customers d
           WHERE d.id = ANY(v_dupes) AND public.customer_phone_key(d.phone) IS NOT NULL
             AND public.customer_phone_key(d.phone) IS DISTINCT FROM public.customer_phone_key(k.phone) AND NULLIF(btrim(k.phone), '') IS NOT NULL) y), (
        SELECT string_agg(n, E'\n') FROM (
          SELECT DISTINCT btrim(d.notes) AS n FROM public.customers d
           WHERE d.id = ANY(v_dupes) AND NULLIF(btrim(d.notes), '') IS NOT NULL
             AND d.notes !~* '^storefront (request|purchase|rental)'
             AND btrim(d.notes) IS DISTINCT FROM btrim(k.notes)) x)), '')
    WHERE k.id = v_keep;

    -- The address moves as a whole, from the newest duplicate that has one.
    UPDATE public.customers k SET
      address_line1 = d.address_line1, address_city = d.address_city,
      address_state = d.address_state, address_zip = d.address_zip
      FROM (SELECT * FROM public.customers
             WHERE id = ANY(v_dupes) AND NULLIF(btrim(address_line1), '') IS NOT NULL
             ORDER BY created_at DESC LIMIT 1) d
     WHERE k.id = v_keep AND NULLIF(btrim(k.address_line1), '') IS NULL;

    -- Only one default payment method per customer.
    IF EXISTS (SELECT 1 FROM public.payment_methods WHERE customer_id = v_keep AND is_default) THEN
      UPDATE public.payment_methods SET is_default = false WHERE customer_id = ANY(v_dupes) AND is_default;
    END IF;
    UPDATE public.payment_methods SET is_default = false
     WHERE id IN (SELECT id FROM public.payment_methods WHERE customer_id = ANY(v_dupes) AND is_default
                   ORDER BY created_at DESC OFFSET 1);

    UPDATE public.rental_orders SET customer_id = v_keep WHERE customer_id = ANY(v_dupes);
    UPDATE public.recurring_charges SET customer_id = v_keep WHERE customer_id = ANY(v_dupes);
    UPDATE public.deposits SET customer_id = v_keep WHERE customer_id = ANY(v_dupes);
    UPDATE public.refunds SET customer_id = v_keep WHERE customer_id = ANY(v_dupes);
    UPDATE public.rental_payment_receipts SET customer_id = v_keep WHERE customer_id = ANY(v_dupes);
    UPDATE public.payment_methods SET customer_id = v_keep WHERE customer_id = ANY(v_dupes);
    DELETE FROM public.customers WHERE id = ANY(v_dupes);

    v_sets := v_sets + 1;
    v_removed := v_removed + cardinality(v_dupes);
    RAISE NOTICE 'Folded % duplicate(s) into customer %', cardinality(v_dupes), v_keep;
  END LOOP;

  RAISE NOTICE 'Done: % people had duplicates; % duplicate records removed.', v_sets, v_removed;
END;
$$;
