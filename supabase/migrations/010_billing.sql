-- ═══════════════════════════════════════════════════════════════════════════
-- 010 — Billing records: recurring charges, deposits, refunds
-- ───────────────────────────────────────────────────────────────────────────
-- Backs the Billing module (Recurring + Refunds tabs). RECORD-KEEPING ONLY —
-- there is NO payment processor / gateway in v1 (per scope: internal-only, no
-- payments). These tables track what is owed/held/refunded so staff can manage
-- monthly rental billing and deposit returns; actual money movement happens
-- out-of-band.
--
--   recurring_charges — one monthly subscription per rental order. Billing runs
--                       from delivery until pickup completes. Status (current/
--                       overdue) drives the Recurring tab + Monthly Revenue.
--   deposits          — refundable deposit held per order.
--   refunds           — refund issued against a deposit on return/pickup.
--
-- Idempotent: CREATE TABLE/INDEX IF NOT EXISTS, DROP-then-CREATE policies.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── Recurring monthly charges ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.recurring_charges (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id       UUID NOT NULL REFERENCES public.rental_orders(id) ON DELETE CASCADE,
  customer_id    UUID NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
  amount         NUMERIC(10,2) NOT NULL CHECK (amount >= 0),  -- per month
  status         TEXT NOT NULL DEFAULT 'current'
                   CHECK (status IN ('current', 'overdue', 'paused', 'ended')),
  billing_start  DATE,           -- begins on delivery
  billing_end    DATE,           -- set when pickup completes
  next_due_date  DATE,
  last_billed_on DATE,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_recurring_charges_order    ON public.recurring_charges (order_id);
CREATE INDEX IF NOT EXISTS idx_recurring_charges_customer ON public.recurring_charges (customer_id);
CREATE INDEX IF NOT EXISTS idx_recurring_charges_status   ON public.recurring_charges (status);
CREATE INDEX IF NOT EXISTS idx_recurring_charges_due      ON public.recurring_charges (next_due_date);

-- ── Deposits held ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.deposits (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id    UUID NOT NULL REFERENCES public.rental_orders(id) ON DELETE CASCADE,
  customer_id UUID NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
  amount      NUMERIC(10,2) NOT NULL CHECK (amount >= 0),
  status      TEXT NOT NULL DEFAULT 'held'
                CHECK (status IN ('held', 'pending_refund', 'refunded', 'forfeited')),
  held_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_deposits_order  ON public.deposits (order_id);
CREATE INDEX IF NOT EXISTS idx_deposits_status ON public.deposits (status);

-- ── Refunds issued ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.refunds (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  deposit_id  UUID REFERENCES public.deposits(id) ON DELETE SET NULL,
  order_id    UUID NOT NULL REFERENCES public.rental_orders(id) ON DELETE CASCADE,
  customer_id UUID NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
  amount      NUMERIC(10,2) NOT NULL CHECK (amount >= 0),
  status      TEXT NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending', 'issued', 'cancelled')),
  issued_at   TIMESTAMPTZ,
  issued_by   UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  notes       TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_refunds_order   ON public.refunds (order_id);
CREATE INDEX IF NOT EXISTS idx_refunds_deposit ON public.refunds (deposit_id);
CREATE INDEX IF NOT EXISTS idx_refunds_status  ON public.refunds (status);

-- ── RLS (staff & admin only — billing is back-office) ──────────────────────
ALTER TABLE public.recurring_charges ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.deposits          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.refunds           ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "recurring_charges_all_staff" ON public.recurring_charges;
CREATE POLICY "recurring_charges_all_staff" ON public.recurring_charges
  FOR ALL USING (public.is_staff_or_admin()) WITH CHECK (public.is_staff_or_admin());

DROP POLICY IF EXISTS "deposits_all_staff" ON public.deposits;
CREATE POLICY "deposits_all_staff" ON public.deposits
  FOR ALL USING (public.is_staff_or_admin()) WITH CHECK (public.is_staff_or_admin());

DROP POLICY IF EXISTS "refunds_all_staff" ON public.refunds;
CREATE POLICY "refunds_all_staff" ON public.refunds
  FOR ALL USING (public.is_staff_or_admin()) WITH CHECK (public.is_staff_or_admin());

DROP TRIGGER IF EXISTS set_updated_at ON public.recurring_charges;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.recurring_charges
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS set_updated_at ON public.deposits;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.deposits
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS set_updated_at ON public.refunds;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.refunds
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
