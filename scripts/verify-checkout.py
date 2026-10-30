"""Checkout page: one payment for the cart, cancel keeps the cart (migration 118).

Runs inside ONE transaction that is always rolled back, with _stripe_request
replaced by a fake inside that transaction, so it creates nothing permanent and
never calls Stripe:

    VERIFY_DB_URL=postgres://... [VERIFY_APPLY_FIRST=supabase/migrations/118_checkout_page.sql] python3 scripts/verify-checkout.py

Exit status 1 on any failure.
"""
import json, os, sys, uuid, psycopg2

dsn = os.environ.get("VERIFY_DB_URL")
if not dsn:
    sys.exit("Set VERIFY_DB_URL to the target database (all work is rolled back).")
conn = psycopg2.connect(dsn); cur = conn.cursor(); results = []
for path in filter(None, os.environ.get("VERIFY_APPLY_FIRST", "").split(",")):
    cur.execute(open(path).read())

# Fake Stripe. v118.stripe: open (default) | paid | down.
cur.execute("CREATE TABLE public._v118_stripe_calls(n serial, method text, path text, body text, key text)")
cur.execute("""
CREATE OR REPLACE FUNCTION public._stripe_request(p_method text, p_path text, p_body text DEFAULT NULL, p_idempotency_key text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_state TEXT := COALESCE(NULLIF(current_setting('v118.stripe', true), ''), 'open'); v_n INT;
BEGIN
  IF v_state = 'down' THEN RAISE EXCEPTION 'stripe down'; END IF;
  INSERT INTO public._v118_stripe_calls(method, path, body, key) VALUES (p_method, p_path, p_body, p_idempotency_key) RETURNING n INTO v_n;
  IF p_path = 'checkout/sessions' THEN RETURN jsonb_build_object('id', 'cs_fake_' || v_n, 'url', 'https://stripe.test/' || v_n); END IF;
  IF p_path LIKE '%/expire' THEN
    IF v_state = 'paid' THEN RETURN jsonb_build_object('error', jsonb_build_object('message', 'already complete')); END IF;
    RETURN jsonb_build_object('status', 'expired', 'payment_status', 'unpaid');
  END IF;
  IF p_path = 'refunds' THEN RETURN jsonb_build_object('id', 're_fake_' || v_n, 'status', 'succeeded'); END IF;
  RETURN jsonb_build_object('status', CASE WHEN v_state = 'paid' THEN 'complete' ELSE 'open' END,
    'payment_status', CASE WHEN v_state = 'paid' THEN 'paid' ELSE 'unpaid' END, 'payment_intent', 'pi_fake');
END; $f$
""")


def stripe(state):
    cur.execute("SELECT set_config('v118.stripe', %s, true)", (state,))


def check(name, ok, detail=""):
    results.append((name, ok))
    print(("PASS " if ok else "FAIL ") + name + (f"  -> {detail}" if detail and not ok else ""))


def as_user(uid):
    cur.execute("RESET ROLE")
    if uid is None:
        cur.execute("SELECT set_config('request.jwt.claims', '', true)")
        return
    cur.execute("SELECT set_config('request.jwt.claims', %s, true)", (json.dumps({"sub": uid, "role": "authenticated"}),))
    cur.execute("SET LOCAL ROLE authenticated")


def call(uid, sql, args=(), role=None):
    """Run in a savepoint; return (result, error_message). role='anon' calls as a website guest."""
    cur.execute("SAVEPOINT s")
    try:
        as_user(uid)
        if role:
            cur.execute(f"SET LOCAL ROLE {role}")
        cur.execute(sql, args)
        row = cur.fetchone() if cur.description else None
        as_user(None)
        cur.execute("RELEASE SAVEPOINT s")
        return (row[0] if row else None), None
    except Exception as e:
        cur.execute("ROLLBACK TO SAVEPOINT s")
        cur.execute("RELEASE SAVEPOINT s")
        as_user(None)
        return None, str(e).splitlines()[0]


def q(sql, args=()):
    as_user(None)
    cur.execute(sql, args)
    return cur.fetchall() if cur.description else None


ADMIN = q("SELECT id::text FROM profiles WHERE role='admin' AND is_active ORDER BY created_at LIMIT 1")[0][0]
rentable = "is_rentable AND delivery_enabled AND delivery_rental_price IS NOT NULL"
SERIALS = [r[0] for r in q(f"SELECT id::text FROM equipment_items WHERE is_active AND is_serialized AND {rentable} ORDER BY created_at LIMIT 2")]
tag = uuid.uuid4().hex[:6]
ZIP, OTHER_ZIP = "11747", "11999"


def store(key, stock, zips):
    return {"key": key, "location": {"name": f"V118 {key} {tag}", "line1": "1 Main St", "city": "Melville", "state": "NY", "zip": "11747",
                                     "fulfillment_mode": "pickup_and_delivery", "partner_type": "owned", "is_active": True, "delivery_zips": zips},
            "stock": stock, "staff": [{"first_name": key, "last_name": "QA", "phone": "", "username": f"v118-{key}-{tag}", "password": "verify-118-pass"}]}


payload = {
    "business": {"name": f"V118 Biz {tag}", "contact_name": "Owner QA", "contact_email": "owner@example.com", "contact_phone": ""},
    "owner": {"first_name": "Owner", "last_name": "QA", "phone": "", "username": f"v118-owner-{tag}", "password": "verify-118-pass"},
    "branches": [store("north", [{"item_id": SERIALS[0], "quantity": 2}, {"item_id": SERIALS[1], "quantity": 2}], [ZIP])],
    "drivers": [],
}
r, e = call(ADMIN, "SELECT public.onboard_business(%s,%s::jsonb)", (str(uuid.uuid4()), json.dumps(payload)))
assert r and r.get("ok"), r or e
LOC = r["branches"][0]["location_id"]
BIZ = r["business_id"]
RENT = q("SELECT public.business_product(%s,%s)::text", (SERIALS[0], BIZ))[0][0]
BUY = q("SELECT public.business_product(%s,%s)::text", (SERIALS[1], BIZ))[0][0]
STAFF = q("SELECT id::text FROM auth.users WHERE email=%s", (f"v118-north-{tag}@staff-login.cottagesurgical.invalid",))[0][0]
# Keep the fixture's store the only one serving this ZIP, with known prices at the store.
q("UPDATE pickup_locations SET delivery_zips=array_remove(delivery_zips,%s) WHERE id<>%s AND %s=ANY(delivery_zips)", (ZIP, LOC, ZIP))
q("UPDATE pickup_locations SET delivery_zips=%s, online_retail_enabled=TRUE WHERE id=%s", ([ZIP], LOC))
q("UPDATE equipment_items SET is_active=TRUE, is_rentable=TRUE, delivery_enabled=TRUE, delivery_rental_price=99 WHERE id=%s", (RENT,))
q("UPDATE equipment_items SET is_active=TRUE, is_purchasable=TRUE, delivery_enabled=TRUE, sale_price=999 WHERE id=%s", (BUY,))
q("UPDATE equipment_location_inventory SET delivery_rental_price=125 WHERE equipment_item_id=%s AND location_id=%s", (RENT, LOC))
q("UPDATE equipment_location_inventory SET sale_price=300 WHERE equipment_item_id=%s AND location_id=%s", (BUY, LOC))

CUSTOMER = {"full_name": f"V118 Customer {tag}", "phone": "5165550100", "email": f"v118-{tag}@example.com"}
ADDRESS = {"line1": "2 Oak St", "city": "Melville", "state": "NY", "zip": ZIP}
FULFILL = {"method": "delivery", "pickup_location_id": None, "delivery_zip": ZIP, "payment_method": "online"}
BASE = q("SELECT 'https://www.cottagesurgical.com'")[0][0]


def cart(rentals=(), purchases=(), notes="Ring the bell", customer=None, address=None):
    return call(None, "SELECT public.create_stripe_cart_checkout(%s::jsonb,%s::jsonb,%s::jsonb,%s::jsonb,%s,%s,%s::jsonb)",
                (json.dumps([{"item_id": i, "quantity": n} for i, n in rentals]), json.dumps([{"item_id": i, "quantity": n} for i, n in purchases]),
                 json.dumps(customer or CUSTOMER), json.dumps(address or ADDRESS), notes, BASE, json.dumps({**FULFILL, "delivery_zip": (address or ADDRESS)["zip"]})), role="anon")


def order(oid):
    return q("SELECT status, payment_status, order_type, stripe_session_id, location_id::text, special_notes FROM rental_orders WHERE id=%s", (oid,))[0]


def units(item):
    return dict(q("SELECT status, count(*) FROM equipment_units WHERE item_id=%s AND location_id=%s GROUP BY 1", (item, LOC)))


def last_call(path_like):
    rows = q("SELECT method, path, body, key FROM _v118_stripe_calls WHERE path LIKE %s ORDER BY n DESC LIMIT 1", (path_like,))
    return rows[0] if rows else None


def calls():
    return q("SELECT count(*) FROM _v118_stripe_calls")[0][0]


def money(oid, kind):
    # Money records are written by a deferred trigger; run it as a commit would.
    cur.execute("SET CONSTRAINTS ALL IMMEDIATE")
    cur.execute("SET CONSTRAINTS ALL DEFERRED")
    return float(q("SELECT COALESCE(sum(cash_amount),0) FROM money_records WHERE order_id=%s AND kind=%s", (oid, kind))[0][0])


# ── the quote is what checkout will charge ──
r, e = call(None, "SELECT public.quote_storefront_cart(%s::jsonb,%s::jsonb,%s::jsonb)",
            (json.dumps([{"item_id": RENT, "quantity": 1}]), json.dumps([{"item_id": BUY, "quantity": 1}]), json.dumps(FULFILL)), role="anon")
check("the quote uses the store's rental and sale prices, not the catalog's",
      bool(r and r.get("ok")) and float(r["prices"][RENT]) == 125 and float(r["sale_prices"][BUY]) == 300, r or e)
q("UPDATE pickup_locations SET online_retail_enabled=FALSE WHERE id=%s", (LOC,))
r, e = call(None, "SELECT public.quote_storefront_cart(%s::jsonb,%s::jsonb,%s::jsonb)", ("[]", json.dumps([{"item_id": BUY, "quantity": 1}]), json.dumps(FULFILL)), role="anon")
check("the quote says so when the store doesn't sell online", (r or {}).get("reason") == "purchases_disabled", r or e)
r, e = cart(rentals=[(RENT, 1)], purchases=[(BUY, 1)])
check("a mixed cart is refused while retail is off, nothing charged", (r or {}).get("reason") == "purchases_disabled" and last_call("checkout/sessions") is None, r or e)
q("UPDATE pickup_locations SET online_retail_enabled=TRUE WHERE id=%s", (LOC,))

# ── one payment, two orders ──
r, e = cart(rentals=[(RENT, 1)], purchases=[(BUY, 1)])
check("a mixed cart starts one payment", bool(r and r.get("ok") and r.get("checkout_url")) and calls() == 1, r or e)
RO, PO = r["order_id"], r["purchase_order_id"]
ro, po = order(RO), order(PO)
check("it makes a rental order and a purchase order", ro[2] == "rental" and po[2] == "purchase" and r["purchase_order_no"] != r["order_no"])
check("both come from one store and share the session", ro[4] == po[4] == LOC and ro[3] == po[3] and ro[3] is not None)
check("both wait for payment, holding their stock", ro[0] == po[0] == "pending_payment" and units(RENT).get("reserved") == 1 and units(BUY).get("reserved") == 1)
check("delivery instructions reach both orders", ro[5] == po[5] == "Ring the bell")
body = last_call("checkout/sessions")[2]
check("Stripe charges the first month plus the purchase at store prices",
      "First%20month%20rental" in body and "unit_amount%5D=12500" not in body and "[unit_amount]=12500" in body and "[unit_amount]=30000" in body, body[:300])
check("cancel returns to the checkout page, success to the success page", f"%2Fcheckout%3Fcancelled%3D{RO}" in body and f"%2Fcheckout%2Fsuccess%3Fref%3D{RO}" in body, body[:400])

# ── paid ──
stripe("paid")
r, e = call(None, "SELECT public.verify_stripe_payment(%s)", (RO,), role="anon")
check("verifying the payment promotes both orders", bool(r and r.get("paid")) and order(RO)[:2] == ("requested", "paid") and order(PO)[:2] == ("requested", "paid"), r or e)
check("the reply names both orders for their emails", sorted((r or {}).get("order_ids", [])) == sorted([RO, PO]), r)
check("each order records its own amount, adding up to the charge", money(RO, "payment") == 125 and money(PO, "payment") == 300, (money(RO, "payment"), money(PO, "payment")))
sub = q("SELECT subject FROM customer_email_outbox WHERE order_id=%s AND event_key LIKE '%%payment_received%%'", (PO,))
check("the purchase's payment email doesn't call it a rental", bool(sub) and "rental" not in sub[0][0].lower(), sub)
r, e = call(None, "SELECT public.verify_stripe_payment(%s)", (PO,), role="anon")
check("verifying the other order finds it already paid, no second record", bool(r and r.get("paid")) and money(PO, "payment") == 300, r or e)

# ── cancelling one order of a shared payment ──
before = calls()
r, e = call(STAFF, "SELECT public.cancel_order(%s,%s)", (PO, "Customer changed their mind"))
refund = last_call("refunds")
check("cancelling one order refunds only its share", bool(r and r.get("refunded")) and refund and "&amount=30000" in refund[2], r or e)
check("the other order keeps its payment", order(RO)[:2] == ("requested", "paid") and order(PO)[:2] == ("cancelled", "refunded") and money(RO, "payment") == 125)
check("its refund is on its own idempotency key", refund and refund[3] == f"cancel-order-{PO}", refund)
r, e = call(STAFF, "SELECT public.cancel_order(%s,%s)", (RO, "Customer changed their mind"))
refund = last_call("refunds")
check("cancelling the other refunds the rest, not the whole payment again", bool(r and r.get("refunded")) and "&amount=12500" in refund[2], r or e)
stripe("open")

# ── cancelled in Stripe ──
r, e = cart(rentals=[(RENT, 2)], purchases=[(BUY, 2)])
check("the last units can be held", bool(r and r.get("ok")) and units(RENT).get("available", 0) == 0 and units(BUY).get("available", 0) == 0, r or e)
RO, PO = r["order_id"], r["purchase_order_id"]
r2, e2 = cart(rentals=[(RENT, 1)], customer={**CUSTOMER, "email": f"other-{tag}@example.com"})
check("another customer can't take held stock", (r2 or {}).get("reason") == "out_of_stock", r2 or e2)
emails = q("SELECT count(*) FROM customer_email_outbox WHERE order_id IN (%s,%s)", (RO, PO))[0][0]
r, e = call(None, "SELECT public.cancel_stripe_checkout(%s)", (RO,), role="anon")
check("cancelling expires the session and releases everything", bool(r and r.get("released")) and order(RO)[0] == order(PO)[0] == "cancelled"
      and units(RENT).get("available") == 2 and units(BUY).get("available") == 2 and last_call("%/expire") is not None, r or e)
check("the customer gets no cancellation email", q("SELECT count(*) FROM customer_email_outbox WHERE order_id IN (%s,%s)", (RO, PO))[0][0] == emails)
check("nothing is refunded or recorded", money(RO, "payment") == 0 and money(RO, "refund") == 0)
r, e = call(None, "SELECT public.cancel_stripe_checkout(%s)", (RO,), role="anon")
check("cancelling twice is harmless", bool(r and r.get("ok")) and not r.get("released"), r or e)
r, e = cart(rentals=[(RENT, 2)], purchases=[(BUY, 2)])
check("the same customer can retry straight away, as one customer record", bool(r and r.get("ok")) and q("SELECT count(*) FROM customers WHERE location_id=%s", (LOC,))[0][0] == 1, r or e)
RO, PO = r["order_id"], r["purchase_order_id"]

stripe("down")
r, e = call(None, "SELECT public.cancel_stripe_checkout(%s)", (RO,), role="anon")
check("if Stripe can't be reached the hold stays, because they could still pay", (r or {}).get("reason") == "stripe_unreachable" and order(RO)[0] == "pending_payment" and units(RENT).get("available", 0) == 0, r or e)
stripe("paid")
r, e = call(None, "SELECT public.cancel_stripe_checkout(%s)", (RO,), role="anon")
check("a session paid at the last moment is promoted, never released", bool(r and r.get("paid")) and not r.get("released") and order(RO)[:2] == ("requested", "paid") and order(PO)[:2] == ("requested", "paid"), r or e)
r, e = call(None, "SELECT public.cancel_stripe_checkout(%s)", (str(uuid.uuid4()),), role="anon")
check("an unknown order is refused", (r or {}).get("reason") == "not_found", r or e)
money(RO, "payment")  # runs the deferred money trigger, as the commit would
for o in (RO, PO):
    call(STAFF, "SELECT public.cancel_order(%s,%s)", (o, "Cleanup"))
stripe("open")

# ── staff cancelling, and records staff changed ──
r, e = cart(rentals=[(RENT, 1)], purchases=[(BUY, 1)])
RO, PO = r["order_id"], r["purchase_order_id"]
expired_before = q("SELECT count(*) FROM _v118_stripe_calls WHERE path LIKE %s", ("%/expire",))[0][0]
r, e = call(STAFF, "SELECT public.cancel_order(%s,%s)", (RO, "Customer called to cancel"))
check("staff cancelling an unpaid checkout closes it in Stripe, so it can't be paid afterwards",
      bool(r and r.get("ok")) and q("SELECT count(*) FROM _v118_stripe_calls WHERE path LIKE %s", ("%/expire",))[0][0] == expired_before + 1, r or e)
check("the other order on that payment is cancelled with it, stock back, reason kept",
      order(RO)[0] == order(PO)[0] == "cancelled" and units(RENT).get("available") == 2 and units(BUY).get("available") == 2
      and q("SELECT closed_reason FROM rental_orders WHERE id=%s", (PO,))[0][0] == "Customer called to cancel", order(PO))

r, e = cart(rentals=[(RENT, 1)], purchases=[(BUY, 1)])
RO, PO = r["order_id"], r["purchase_order_id"]
stripe("down")
r, e = call(STAFF, "SELECT public.cancel_order(%s,%s)", (RO, "Customer called to cancel"))
check("if Stripe can't be reached the order isn't cancelled", (r or {}).get("reason") == "checkout_open" and order(RO)[0] == "pending_payment", r or e)
stripe("paid")
r, e = call(STAFF, "SELECT public.cancel_order(%s,%s)", (RO, "Customer called to cancel"))
check("a checkout paid just before the cancel is kept, and staff are told", (r or {}).get("reason") == "just_paid" and order(RO)[:2] == ("requested", "paid") and order(PO)[:2] == ("requested", "paid"), r or e)
money(RO, "payment"); money(PO, "payment")
before = calls()
q("UPDATE rental_orders SET payment_preference='on_delivery' WHERE id=%s", (PO,))
r, e = call(STAFF, "SELECT public.cancel_order(%s,%s)", (PO, "Marked paid in store"))
check("a share staff moved off the card isn't refunded from the other order's payment", (r or {}).get("reason") == "refund_amount_unknown" and calls() <= before + 1 and last_call("refunds")[3] != f"cancel-order-{PO}", r or e)
q("UPDATE rental_orders SET payment_preference='online' WHERE id=%s", (PO,))
r, e = call(STAFF, "SELECT public.cancel_order(%s,%s)", (PO, "Customer changed their mind"))
check("back to the card, the normal share refunds", bool(r and r.get("refunded")) and "&amount=30000" in last_call("refunds")[2], r or e)
call(STAFF, "SELECT public.cancel_order(%s,%s)", (RO, "Customer changed their mind"))

stripe("open")

# ── the scheduled sweep ──
r, e = cart(rentals=[(RENT, 1)], purchases=[(BUY, 1)])
RO, PO = r["order_id"], r["purchase_order_id"]
sid = order(RO)[3]
cur.execute("SAVEPOINT sweep")
check("the sweep's Stripe call is outside this fake, so it's checked by definition instead",
      "stripe_session_id = v_sid AND status = 'pending_payment'" in q("SELECT prosrc FROM pg_proc WHERE proname='reconcile_pending_stripe_orders'")[0][0])
cur.execute("RELEASE SAVEPOINT sweep")
call(None, "SELECT public.cancel_stripe_checkout(%s)", (RO,), role="anon")

# ── one type only, and Stripe failing ──
r, e = cart(rentals=[(RENT, 1)])
check("a rental-only cart makes one order and no purchase", bool(r and r.get("ok")) and r.get("purchase_order_id") is None and order(r["order_id"])[2] == "rental", r or e)
call(None, "SELECT public.cancel_stripe_checkout(%s)", (r["order_id"],), role="anon")
r, e = cart(purchases=[(BUY, 1)])
check("a purchase-only cart makes one order and no rental", bool(r and r.get("ok")) and r.get("purchase_order_id") is None and order(r["order_id"])[2] == "purchase", r or e)
check("the purchase keeps its delivery instructions", order(r["order_id"])[5] == "Ring the bell")
call(None, "SELECT public.cancel_stripe_checkout(%s)", (r["order_id"],), role="anon")
stripe("down")
r, e = cart(rentals=[(RENT, 1)], purchases=[(BUY, 1)])
check("Stripe down at the start cancels both orders and releases the stock", (r or {}).get("reason") == "stripe_unreachable" and units(RENT).get("available") == 2 and units(BUY).get("available") == 2, r or e)
stripe("open")
r, e = cart()
check("an empty cart is refused", (r or {}).get("reason") == "no_items", r or e)
r, e = cart(rentals=[(RENT, 3)])
check("more than the store has is refused", (r or {}).get("reason") == "out_of_stock", r or e)
r, e = cart(rentals=[(RENT, 1)], customer={**CUSTOMER, "email": "nope"})
check("a bad email is refused", (r or {}).get("reason") == "missing_email", r or e)
q("UPDATE pickup_locations SET delivers_anywhere=FALSE")
r, e = cart(rentals=[(RENT, 1)], purchases=[(BUY, 1)], address={**ADDRESS, "zip": OTHER_ZIP})
check("a ZIP no store serves is refused", (r or {}).get("reason") in ("outside_delivery_area", "delivery_unavailable"), r or e)

# ── who can call what ──
for fn, sig, allowed in (("_stripe_request", "text,text,text,text", False), ("cancel_stripe_checkout", "uuid", True),
                         ("create_stripe_cart_checkout", "jsonb,jsonb,jsonb,jsonb,text,text,jsonb", True), ("quote_storefront_cart", "jsonb,jsonb,jsonb", True)):
    for role in ("anon", "authenticated"):
        got = q(f"SELECT has_function_privilege('{role}', 'public.{fn}({sig})', 'EXECUTE')")[0][0]
        check(f"{fn}: {role} {'may' if allowed else 'may not'} call it", got is allowed, got)

conn.rollback()
failed = [n for n, ok in results if not ok]
print(f"\n{len(results) - len(failed)}/{len(results)} passed (rolled back)")
sys.exit(1 if failed else 0)
