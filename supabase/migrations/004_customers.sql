-- ═══════════════════════════════════════════════════════════════════════════
-- 004 — Customers & payment methods on file
-- ───────────────────────────────────────────────────────────────────────────
-- From the Customer Directory + Patient Intake designs: each customer (patient)
-- has contact info, a service address, DOB, an insurance/coverage type, and one
-- or more stored payment methods (display metadata only — brand + last4 / bank
-- label; NO real card/account numbers, NO payment processing in v1).
--
-- The "Active / Overdue / No Rental" badge shown per customer is DERIVED from
-- their rentals at query time, not stored here.
--
-- Idempotent: CREATE TABLE/INDEX IF NOT EXISTS, DROP-then-CREATE policies.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── Customers ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.customers (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  full_name      TEXT NOT NULL,
  phone          TEXT,
  email          TEXT,
  date_of_birth  DATE,
  coverage_type  TEXT CHECK (coverage_type IN
                   ('medicare', 'medicaid', 'private_pay', 'commercial_insurance')),
  insurance_notes TEXT,
  -- Default service address (per-order delivery address is snapshotted on the order).
  address_line1  TEXT,
  address_city   TEXT,
  address_state  TEXT DEFAULT 'NY',
  address_zip    TEXT,
  notes          TEXT,
  created_by     UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_customers_full_name ON public.customers (full_name);
CREATE INDEX IF NOT EXISTS idx_customers_phone     ON public.customers (phone);

-- ── Payment methods on file (display metadata only) ────────────────────────
CREATE TABLE IF NOT EXISTS public.payment_methods (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id    UUID NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
  method_type    TEXT NOT NULL CHECK (method_type IN ('card', 'ach')),
  -- For cards: brand = Visa/Mastercard/Amex, last4 = '4242'.
  -- For ACH:   brand = bank name (Chase/BofA), account_label = 'Checking'/'Savings'.
  brand          TEXT,
  last4          TEXT,
  account_label  TEXT,
  is_default     BOOLEAN NOT NULL DEFAULT FALSE,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_payment_methods_customer ON public.payment_methods (customer_id);
-- At most one default payment method per customer.
CREATE UNIQUE INDEX IF NOT EXISTS uq_payment_methods_one_default
  ON public.payment_methods (customer_id) WHERE is_default;

-- ── RLS ────────────────────────────────────────────────────────────────────
ALTER TABLE public.customers       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_methods ENABLE ROW LEVEL SECURITY;

-- Staff & admin: full operational access to customer records.
DROP POLICY IF EXISTS "customers_all_staff" ON public.customers;
CREATE POLICY "customers_all_staff" ON public.customers
  FOR ALL USING (public.is_staff_or_admin()) WITH CHECK (public.is_staff_or_admin());

DROP POLICY IF EXISTS "payment_methods_all_staff" ON public.payment_methods;
CREATE POLICY "payment_methods_all_staff" ON public.payment_methods
  FOR ALL USING (public.is_staff_or_admin()) WITH CHECK (public.is_staff_or_admin());

-- Drivers: read-only access to customers they are currently delivering to is
-- granted in 008_deliveries.sql (after the deliveries/drivers join exists), to
-- avoid a forward reference here.

DROP TRIGGER IF EXISTS set_updated_at ON public.customers;
CREATE TRIGGER set_updated_at
  BEFORE UPDATE ON public.customers
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS set_updated_at ON public.payment_methods;
CREATE TRIGGER set_updated_at
  BEFORE UPDATE ON public.payment_methods
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
