"""Scan or type a unit on an order (migration 117).

Runs inside ONE transaction that is always rolled back, so it creates nothing
permanent. It still executes against the database you name:

    VERIFY_DB_URL=postgres://... [VERIFY_APPLY_FIRST=supabase/migrations/117_scan_unit_on_order.sql] python3 scripts/verify-unit-scan.py

The rule: approving holds the oldest available unit. Staff or the owner can
scan or type another available unit of the same product at that order's store;
the held unit goes back to available. Nobody scans: the oldest goes out. Rentals
can be corrected after handoff; a sale closes at handoff and stays locked.
Exit status 1 on any failure.
"""
import json, os, sys, uuid, psycopg2

dsn = os.environ.get("VERIFY_DB_URL")
if not dsn:
    sys.exit("Set VERIFY_DB_URL to the target database (all work is rolled back).")
conn = psycopg2.connect(dsn); cur = conn.cursor(); results = []
for path in filter(None, os.environ.get("VERIFY_APPLY_FIRST", "").split(",")):
    cur.execute(open(path).read())


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


def call(uid, sql, args=()):
    """Run in a savepoint; return (result, error_message)."""
    cur.execute("SAVEPOINT s")
    try:
        as_user(uid)
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
BULK = q(f"SELECT id::text FROM equipment_items WHERE NOT is_serialized AND {rentable} ORDER BY is_active DESC, created_at LIMIT 1")[0][0]
q("UPDATE equipment_items SET is_active=TRUE WHERE id=%s", (BULK,))
tag = uuid.uuid4().hex[:6]


def staff(n):
    return {"first_name": n.title(), "last_name": "QA", "phone": "", "username": f"v117-{n}-{tag}", "password": "verify-117-pass"}


def store(key, stock):
    return {"key": key, "location": {"name": f"V117 {key} {tag}", "line1": "1 Main St", "city": "Melville", "state": "NY", "zip": "11747",
                                     "fulfillment_mode": "pickup_and_delivery", "partner_type": "owned", "is_active": True},
            "stock": stock, "staff": [staff(key)]}


payload = {
    "business": {"name": f"V117 Biz {tag}", "contact_name": "Owner QA", "contact_email": "owner@example.com", "contact_phone": ""},
    "owner": {"first_name": "Owner", "last_name": "QA", "phone": "", "username": f"v117-owner-{tag}", "password": "verify-117-pass"},
    "branches": [store("north", [{"item_id": SERIALS[0], "quantity": 12}, {"item_id": SERIALS[1], "quantity": 1}, {"item_id": BULK, "quantity": 5}]),
                 store("east", [{"item_id": SERIALS[0], "quantity": 1}])],
    "drivers": [{"first_name": "Store", "last_name": "Driver", "phone": "", "email": "", "login": True, "username": f"v117-drv-{tag}", "password": "verify-117-pass", "branches": ["north"]}],
}
r, e = call(ADMIN, "SELECT public.onboard_business(%s,%s::jsonb)", (str(uuid.uuid4()), json.dumps(payload)))
assert r and r.get("ok"), r or e
LOC = {b["key"]: b["location_id"] for b in r["branches"]}
BIZ = r["business_id"]
SER = q("SELECT public.business_product(%s,%s)::text", (SERIALS[0], BIZ))[0][0]
SER2 = q("SELECT public.business_product(%s,%s)::text", (SERIALS[1], BIZ))[0][0]
BULK = q("SELECT public.business_product(%s,%s)::text", (BULK, BIZ))[0][0]
SER2_NAME = q("SELECT name FROM equipment_items WHERE id=%s", (SER2,))[0][0]

other = {"business": {"name": f"V117 Other {tag}", "contact_name": "Other QA", "contact_email": "", "contact_phone": "555-0100"},
         "branches": [{"key": "a", "location": {"name": f"V117 other {tag}", "line1": "9 Elm St", "city": "Huntington", "state": "NY", "zip": "11743",
                                                "fulfillment_mode": "pickup_and_delivery", "partner_type": "owned", "is_active": True},
                       "stock": [{"item_id": SERIALS[0], "quantity": 1}], "staff": [staff("other")]}]}
ro, eo = call(ADMIN, "SELECT public.onboard_business(%s,%s::jsonb)", (str(uuid.uuid4()), json.dumps(other)))
assert ro and ro.get("ok"), ro or eo
uid = lambda u: q("SELECT id::text FROM auth.users WHERE email=%s", (f"{u}@staff-login.cottagesurgical.invalid",))[0][0]
OWNER, NORTH, EAST, OTHER = uid(f"v117-owner-{tag}"), uid(f"v117-north-{tag}"), uid(f"v117-east-{tag}"), uid(f"v117-other-{tag}")
DRV_USER = uid(f"v117-drv-{tag}")
DRV = q("SELECT id::text FROM drivers WHERE user_id=%s", (DRV_USER,))[0][0]

# Every unit has the same created_at inside one transaction: age them explicitly.
units = [r[0] for r in q("SELECT id::text FROM equipment_units WHERE item_id=%s AND location_id=%s ORDER BY id", (SER, LOC["north"]))]
for i, u in enumerate(units):
    q("UPDATE equipment_units SET asset_tag=%s, created_at=now() - make_interval(days => %s) WHERE id=%s", (f"T{i}-{tag}".upper(), 100 - i, u))
TAG = lambda i: f"T{i}-{tag}".upper()
q("UPDATE equipment_units SET asset_tag=%s WHERE item_id=%s AND location_id=%s", (f"EAST-{tag}".upper(), SER, LOC["east"]))
q("UPDATE equipment_units SET asset_tag=%s WHERE item_id=%s AND location_id=%s", (f"OTHERP-{tag}".upper(), SER2, LOC["north"]))
q("UPDATE equipment_location_inventory SET scan_code=%s WHERE equipment_item_id=%s AND location_id=%s", (f"PRODCODE-{tag}", SER, LOC["north"]))


def order(who=NORTH, loc=None, item=SER, otype="rental"):
    deliv = {"location_id": loc or LOC["north"], "driver_id": DRV, "scheduled_date": "2026-11-02", "window_start": None, "window_end": None}
    r, e = call(who, "SELECT public.create_staff_order(NULL,%s,%s::jsonb,%s::jsonb,NULL,%s::jsonb)",
                (otype, json.dumps([{"item_id": item, "quantity": 1}]), json.dumps(deliv),
                 json.dumps({"full_name": f"V117 Customer {uuid.uuid4().hex[:6]}", "line1": "2 Oak St", "city": "Melville", "zip": "11747"})))
    assert r and r.get("ok"), r or e
    return r["order_id"]


def line(oid):
    return q("SELECT id::text FROM rental_line_items WHERE order_id=%s", (oid,))[0][0]


def on_line(lid):
    return q("SELECT u.asset_tag FROM rental_line_items li LEFT JOIN equipment_units u ON u.id=li.equipment_unit_id WHERE li.id=%s", (lid,))[0][0]


def status(asset_tag):
    return q("SELECT status FROM equipment_units WHERE asset_tag=%s", (asset_tag,))[0][0]


def scan(who, lid, code, record=False):
    return call(who, "SELECT public.set_line_unit(%s,%s,%s)", (lid, code, record))


def avail():
    return q("SELECT count(*) FROM equipment_units WHERE item_id=%s AND location_id=%s AND status='available'", (SER, LOC["north"]))[0][0]


def handoff(oid):
    stop = q("SELECT id::text FROM deliveries WHERE order_id=%s AND leg_type='delivery'", (oid,))[0][0]
    r, e = call(DRV_USER, "SELECT public.start_delivery(%s)", (stop,))
    assert r and r.get("ok"), r or e
    r, e = call(NORTH, "SELECT public.complete_delivery(%s,NULL)", (stop,))
    assert r and r.get("ok"), r or e


# ── nobody scans: the oldest is held and goes out ──
O1 = order(); L1 = line(O1)
check("approval/new order holds the oldest available unit", on_line(L1) == TAG(0) and status(TAG(0)) == "reserved", on_line(L1))

# ── scan or type another unit ──
before = avail()
r, e = scan(NORTH, L1, f"  {TAG(5).lower()} ")
check("typed tag (any case, stray spaces) moves the hold to that unit", bool(r and r.get("ok")) and on_line(L1) == TAG(5), r or e)
check("the result names both units", (r or {}).get("unit_label") == TAG(5) and (r or {}).get("previous_label") == TAG(0), r)
check("the picked unit is reserved and the old one is available", status(TAG(5)) == "reserved" and status(TAG(0)) == "available")
check("the store's available count does not move", avail() == before, avail())
q("UPDATE equipment_units SET serial_number=%s WHERE asset_tag=%s", (f"SN-{tag}", TAG(4)))
r, e = scan(NORTH, L1, f"sn-{tag}")
check("a serial number finds its unit too", bool(r and r.get("ok")) and on_line(L1) == TAG(4), r or e)
r, e = scan(NORTH, L1, TAG(4))
check("scanning the unit already on the line changes nothing", bool(r and r.get("ok") and r.get("unchanged")) and on_line(L1) == TAG(4), r or e)
r, e = scan(NORTH, L1, "   ")
check("an empty scan is refused", (r or {}).get("reason") == "no_code", r or e)

# ── refusals: nothing changes ──
O2 = order(); L2 = line(O2)
held_by_o2 = on_line(L2)
r, e = scan(NORTH, L1, held_by_o2)
check("a unit held by another order is refused and names that order",
      (r or {}).get("reason") == "unit_unavailable" and (r or {}).get("order_no") == q("SELECT order_no FROM rental_orders WHERE id=%s", (O2,))[0][0]
      and on_line(L1) == TAG(4) and on_line(L2) == held_by_o2, r or e)
q("UPDATE equipment_units SET status='retired' WHERE asset_tag=%s", (TAG(7),))
r, e = scan(NORTH, L1, TAG(7))
check("a retired unit is refused", (r or {}).get("reason") == "unit_unavailable" and (r or {}).get("status") == "retired" and on_line(L1) == TAG(4), r or e)
r, e = scan(NORTH, L1, f"EAST-{tag}")
check("another store's unit is unknown here, nothing leaks", (r or {}).get("reason") == "unit_not_found" and "product" not in (r or {}) and on_line(L1) == TAG(4), r or e)
r, e = scan(NORTH, L1, f"OTHERP-{tag}")
check("another product's unit is refused and named", (r or {}).get("reason") == "wrong_product" and (r or {}).get("product") == SER2_NAME and on_line(L1) == TAG(4), r or e)
r, e = scan(NORTH, L1, f"prodcode-{tag}")
check("the product's own scan code is explained, not treated as unknown", (r or {}).get("reason") == "product_code", r or e)
r, e = scan(NORTH, L1, "NOPE")
check("an unknown number on a unit that already has a serial offers nothing", (r or {}).get("reason") == "unit_not_found" and not (r or {}).get("can_record_serial"), r or e)

OS = order(); LA = line(OS)
q("INSERT INTO rental_line_items(order_id, equipment_item_id, line_type, quantity, monthly_rate, is_active) SELECT order_id, equipment_item_id, line_type, 1, monthly_rate, FALSE FROM rental_line_items WHERE id=%s", (LA,))
LB2 = q("SELECT id::text FROM rental_line_items WHERE order_id=%s AND id<>%s", (OS, LA))[0][0]
r, e = scan(NORTH, LB2, on_line(LA))
check("a unit on another line of the same order says so", (r or {}).get("reason") == "unit_unavailable" and (r or {}).get("same_order") is True, r or e)

# ── the number isn't in the system and the held unit's serial is blank ──
O3 = order(); L3 = line(O3); T3 = on_line(L3)
r, e = scan(NORTH, L3, "MFR-12345")
check("an unknown number on a blank-serial unit offers to save it, writes nothing",
      (r or {}).get("reason") == "unit_not_found" and (r or {}).get("can_record_serial") is True and (r or {}).get("unit_label") == T3
      and q("SELECT serial_number FROM equipment_units WHERE asset_tag=%s", (T3,))[0][0] is None, r or e)
r, e = scan(NORTH, L3, "MFR-12345", True)
check("confirming saves it as that unit's serial and keeps the unit",
      bool(r and r.get("ok") and r.get("recorded_serial")) and on_line(L3) == T3 and q("SELECT serial_number FROM equipment_units WHERE asset_tag=%s", (T3,))[0][0] == "MFR-12345", r or e)
r, e = scan(NORTH, L3, f"OTHERP-{tag}", True)
check("confirming never overrides a number that belongs to a real unit", (r or {}).get("reason") == "wrong_product", r or e)

# ── who ──
r, e = scan(EAST, L1, TAG(6)); check("staff at another store of the owner are refused", (r or {}).get("reason") == "forbidden" and on_line(L1) == TAG(4), r or e)
r, e = scan(OTHER, L1, TAG(6)); check("another business is refused", (r or {}).get("reason") == "forbidden" and on_line(L1) == TAG(4), r or e)
r, e = scan(DRV_USER, L1, TAG(6)); check("drivers are refused", (r or {}).get("reason") == "forbidden" and on_line(L1) == TAG(4), r or e)
r, e = scan(OWNER, L1, TAG(6)); check("the owner can change it", bool(r and r.get("ok")) and on_line(L1) == TAG(6), r or e)
r, e = call(None, "SELECT has_function_privilege('anon', 'public.set_line_unit(uuid,text,boolean)', 'EXECUTE')"); check("the public cannot call it", r is False, r or e)
r, e = scan(NORTH, str(uuid.uuid4()), TAG(6)); check("an unknown line is refused", (r or {}).get("reason") == "not_found", r or e)

# ── kinds of line and order ──
OB = order(item=BULK); LB = line(OB)
r, e = scan(NORTH, LB, "ANY"); check("a bulk line has no units to scan", (r or {}).get("reason") == "not_serialized", r or e)
q("UPDATE rental_orders SET status='requested' WHERE id=%s", (O2,))
r, e = scan(NORTH, L2, TAG(6)); check("a request not yet approved is refused", (r or {}).get("reason") == "bad_state", r or e)
q("UPDATE rental_orders SET status='pending_payment' WHERE id=%s", (O2,))
r, e = scan(NORTH, L2, TAG(6)); check("an unpaid checkout is refused", (r or {}).get("reason") == "bad_state", r or e)
q("UPDATE rental_orders SET status='open' WHERE id=%s", (O2,))
q("UPDATE equipment_units SET status='available' WHERE asset_tag=%s", (held_by_o2,))
q("UPDATE rental_line_items SET equipment_unit_id=NULL, is_active=FALSE WHERE id=%s", (L2,))
r, e = scan(NORTH, L2, held_by_o2)
check("a line with no unit gets the scanned one", bool(r and r.get("ok")) and on_line(L2) == held_by_o2 and status(held_by_o2) == "reserved"
      and q("SELECT is_active FROM rental_line_items WHERE id=%s", (L2,))[0][0] is True and (r or {}).get("unallocated") == 0, r or e)

# ── handoff ──
O4 = order(); L4 = line(O4); oldest = on_line(L4)
handoff(O4)
check("nobody scanned: the held oldest unit goes out as rented", status(oldest) == "rented" and on_line(L4) == oldest)
free = q("SELECT asset_tag FROM equipment_units WHERE item_id=%s AND location_id=%s AND status='available' ORDER BY created_at LIMIT 1", (SER, LOC["north"]))[0][0]
r, e = scan(NORTH, L4, free)
check("after handoff a rental can be corrected: new unit rented, old one available",
      bool(r and r.get("ok")) and on_line(L4) == free and status(free) == "rented" and status(oldest) == "available", r or e)
q("UPDATE rental_line_items SET is_active=FALSE WHERE id=%s", (L4,))
r, e = scan(NORTH, L4, oldest)
check("a returned line stays as it was", (r or {}).get("reason") == "line_ended" and on_line(L4) == free, r or e)

O5 = order(); L5 = line(O5)
free = q("SELECT asset_tag FROM equipment_units WHERE item_id=%s AND location_id=%s AND status='available' ORDER BY created_at LIMIT 1", (SER, LOC["north"]))[0][0]
r, e = scan(NORTH, L5, free)
handoff(O5)
check("a unit scanned before handoff is the one that goes out", bool(r and r.get("ok")) and status(free) == "rented" and on_line(L5) == free, r or e)

q("UPDATE equipment_items SET is_purchasable=TRUE, sale_price=100 WHERE id=%s", (SER,))
O6 = order(otype="purchase"); L6 = line(O6); sold = on_line(L6)
handoff(O6)
free = q("SELECT asset_tag FROM equipment_units WHERE item_id=%s AND location_id=%s AND status='available' ORDER BY created_at LIMIT 1", (SER, LOC["north"]))[0][0]
r, e = scan(NORTH, L6, free)
check("a sale is locked once handed over", (r or {}).get("reason") == "bad_state" and on_line(L6) == sold and status(sold) == "retired", r or e)

conn.rollback()
failed = [n for n, ok in results if not ok]
print(f"\n{len(results) - len(failed)}/{len(results)} passed (rolled back)")
sys.exit(1 if failed else 0)
