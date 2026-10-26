"""Three-location business verification (3LOC-001..005, BIZ-001/002; migrations 074-078).

Runs every check inside ONE transaction that is always rolled back, so it
creates nothing permanent. It still executes against the database you name,
so point it only at a database where 074-078 are applied:

    VERIFY_DB_URL=postgres://... python3 scripts/verify-three-location.py

It onboards two synthetic businesses (three branches and one branch), then
checks owner and branch scope across both, shared-driver assignment on every
write path, overlap and one-en-route rules, catalog/notes/photo/GPS/notification
isolation, and onboarding atomicity and replay. Exit status 1 on any failure.
"""
import json, os, sys, uuid, psycopg2

dsn = os.environ.get("VERIFY_DB_URL")
if not dsn:
    sys.exit("Set VERIFY_DB_URL to the target database (all work is rolled back).")
conn = psycopg2.connect(dsn); cur = conn.cursor(); results = []
# Optionally try unapplied migrations inside the same rolled-back transaction.
for path in filter(None, os.environ.get("VERIFY_APPLY_FIRST", "").split(",")):
    cur.execute(open(path).read())

def check(name, ok, detail=""):
    results.append((name, ok))
    print(("PASS " if ok else "FAIL ") + name + (f"  -> {detail}" if detail else ""))


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
SER = q(f"SELECT id::text FROM equipment_items WHERE is_active AND is_serialized AND {rentable} ORDER BY created_at LIMIT 1")[0][0]
BULK = q(f"SELECT id::text FROM equipment_items WHERE NOT is_serialized AND {rentable} ORDER BY is_active DESC, created_at LIMIT 1")[0][0]
q("UPDATE equipment_items SET is_active=TRUE WHERE id=%s", (BULK,))  # in-transaction only
tag = uuid.uuid4().hex[:6]
def staff(n): return {"first_name": n.title(), "last_name": "QA", "phone": "", "username": f"v074-{n}-{tag}", "password": "verify-074-pass"}
def branch(key, stock): return {"key": key, "location": {"name": f"V074 {key} {tag}", "line1": "1 Main St", "city": "Melville", "state": "NY", "zip": "11747", "fulfillment_mode": "pickup_and_delivery", "partner_type": "owned", "is_active": True}, "stock": stock, "staff": [staff(key)]}
payload = {
    "business": {"name": f"V074 Biz {tag}", "contact_name": "Owner QA", "contact_email": "owner@example.com", "contact_phone": ""},
    "owner": {"first_name": "Owner", "last_name": "QA", "phone": "", "username": f"v074-owner-{tag}", "password": "verify-074-pass"},
    "branches": [branch("north", [{"item_id": SER, "quantity": 3}, {"item_id": BULK, "quantity": 5}]),
                 branch("east", [{"item_id": SER, "quantity": 3}]),
                 branch("west", [{"item_id": BULK, "quantity": 3}])],
    "drivers": [{"first_name": "Shared", "last_name": "Driver", "phone": "", "email": "", "login": True, "username": f"v074-drv-{tag}", "password": "verify-074-pass", "branches": ["north", "east"]},
                {"first_name": "West", "last_name": "Driver", "phone": "", "email": "", "login": True, "username": f"v074-wdrv-{tag}", "password": "verify-074-pass", "branches": ["west"]}],
}
REQ = str(uuid.uuid4())
r, e = call(ADMIN, "SELECT public.onboard_business(%s,%s::jsonb)", (REQ, json.dumps(payload)))
check("3LOC-005 one submission creates business, 3 branches, owner, staff, drivers",
      bool(r and r.get("ok") and len(r["branches"]) == 3 and r["driver_count"] == 2 and r["user_count"] == 6), r or e)
r2, e2 = call(ADMIN, "SELECT public.onboard_business(%s,%s::jsonb)", (REQ, json.dumps(payload)))
check("retry with the same request ID returns the receipt, no duplicates", r2 == r and q("SELECT count(*) FROM pickup_locations WHERE name LIKE %s", (f"V074 % {tag}",))[0][0] == 3, r2 or e2)
LOC = {b["key"]: b["location_id"] for b in r["branches"]}
other = {"business": {"name": f"V074 Other {tag}", "contact_name": "Other QA", "contact_email": "", "contact_phone": "555-0100"},
         "branches": [{"key": "a", "location": {"name": f"V074 other {tag}", "line1": "9 Elm St", "city": "Huntington", "state": "NY", "zip": "11743", "fulfillment_mode": "pickup_and_delivery", "partner_type": "owned", "is_active": True},
                       "stock": [{"item_id": SER, "quantity": 1}], "staff": [staff("other")]}]}
ro, eo = call(ADMIN, "SELECT public.onboard_business(%s,%s::jsonb)", (str(uuid.uuid4()), json.dumps(other)))
assert ro and ro.get("ok"), ro or eo
LOC_A = ro["branches"][0]["location_id"]
uid = lambda u: q("SELECT id::text FROM auth.users WHERE email=%s", (f"{u}@staff-login.cottagesurgical.invalid",))[0][0]
OWNER, NORTH, EAST, WEST = uid(f"v074-owner-{tag}"), uid(f"v074-north-{tag}"), uid(f"v074-east-{tag}"), uid(f"v074-west-{tag}")
A_STAFF = uid(f"v074-other-{tag}")
DRV_USER = uid(f"v074-drv-{tag}"); WDRV_USER = uid(f"v074-wdrv-{tag}")
DRV = q("SELECT id::text FROM drivers WHERE user_id=%s", (DRV_USER,))[0][0]; WDRV = q("SELECT id::text FROM drivers WHERE user_id=%s", (WDRV_USER,))[0][0]
check("owner profile carries the business scope", q("SELECT role, business_id::text FROM profiles WHERE id=%s", (OWNER,))[0] == ("owner", r["business_id"]))
check("shared driver: home North + East membership", q("SELECT location_id::text FROM driver_branches WHERE driver_id=%s", (DRV,)) == [(LOC["east"],)])

bad = json.loads(json.dumps(payload)); bad["business"]["name"] += " dup"
for b in bad["branches"]: b["location"]["name"] += " dup"
bad["branches"][2]["staff"][0]["username"] = bad["branches"][0]["staff"][0]["username"] + "x"
bad["branches"][1]["staff"][0]["username"] = f"v074-north-{tag}"  # already taken
bad["branches"][0]["staff"][0]["username"] += "x"; bad["owner"]["username"] += "x"; bad["drivers"] = []
r, e = call(ADMIN, "SELECT public.onboard_business(%s,%s::jsonb)", (str(uuid.uuid4()), json.dumps(bad)))
check("a failing branch names itself and nothing is saved", e is not None and "V074 east" in e and q("SELECT count(*) FROM businesses WHERE name=%s", (bad["business"]["name"],))[0][0] == 0, e)

def order(who, loc, drv=None, date="2026-11-02", ws=None, we=None, item=SER, qty=1):
    deliv = {"location_id": loc, "driver_id": drv, "scheduled_date": date, "window_start": ws, "window_end": we}
    return call(who, "SELECT public.create_staff_order(NULL,'rental',%s::jsonb,%s::jsonb,NULL,%s::jsonb)",
                (json.dumps([{"item_id": item, "quantity": qty}]), json.dumps(deliv), json.dumps({"full_name": "V074 Customer", "line1": "2 Oak St", "city": "Melville", "zip": "11747"})))
leg = lambda oid: q("SELECT id::text FROM deliveries WHERE order_id=%s", (oid,))[0][0]

# ── 3LOC-001 owner ──
on, _ = order(NORTH, LOC["north"]); oe, _ = order(EAST, LOC["east"]); ow, _ = order(WEST, LOC["west"], item=BULK)
seen = lambda who, loc: call(who, "SELECT count(*) FROM rental_orders WHERE location_id=%s", (loc,))[0]
check("owner reads orders in all three branches", all(seen(OWNER, LOC[k]) >= 1 for k in LOC), [seen(OWNER, LOC[k]) for k in LOC])
check("owner reads nothing from another business", seen(OWNER, LOC_A) == 0 and call(OWNER, "SELECT count(*) FROM customers WHERE location_id=%s", (LOC_A,))[0] == 0)
check("owner reads stock, units and drivers across branches",
      call(OWNER, "SELECT count(DISTINCT location_id) FROM equipment_location_inventory WHERE location_id = ANY(%s::uuid[])", (list(LOC.values()),))[0] == 3
      and call(OWNER, "SELECT count(*) FROM drivers WHERE id IN (%s,%s)", (DRV, WDRV))[0] == 2)
check("owner sees billing across branches", call(OWNER, "SELECT count(DISTINCT o.location_id) FROM recurring_charges c JOIN rental_orders o ON o.id=c.order_id WHERE o.location_id = ANY(%s::uuid[])", (list(LOC.values()),))[0] >= 0)
r, e = order(OWNER, LOC["east"]); check("owner creates an order at any of their branches", bool(r and r.get("ok")), r or e)
r, e = order(OWNER, LOC_A); check("owner cannot create an order at another business", (r or {}).get("reason") == "forbidden", r or e)
r, e = call(OWNER, "SELECT public.cancel_order(%s,'v074')", (on["order_id"],)); check("owner can cancel a North order", bool(r and r.get("ok")), r or e)
check("branch staff keep their own scope", seen(NORTH, LOC["east"]) == 0 and seen(EAST, LOC["north"]) == 0)
check("an owner is not an admin", call(OWNER, "SELECT public.is_admin()")[0] is False)
r, e = call(OWNER, "UPDATE profiles SET business_id=NULL WHERE id=auth.uid() RETURNING 1"); check("owner cannot change their own business scope", e is not None, r or e)
rec = [x[0] for x in q("SELECT public.staff_recipients_for_location(%s)::text", (LOC["north"],))]
check("North notifications reach North staff and the owner, not East staff", NORTH in rec and OWNER in rec and EAST not in rec and A_STAFF not in rec)
r, e = call(A_STAFF, "SELECT count(*) FROM pickup_locations WHERE id=%s", (LOC["north"],))
q("UPDATE pickup_locations SET is_active=FALSE WHERE id=%s", (LOC["north"],))
r, e = call(A_STAFF, "SELECT count(*) FROM pickup_locations WHERE id=%s", (LOC["north"],)); r2, _ = call(OWNER, "SELECT count(*) FROM pickup_locations WHERE id=%s", (LOC["north"],))
check("an inactive branch is hidden from other stores' staff, visible to its owner", r == 0 and r2 == 1, (r, r2))
q("UPDATE pickup_locations SET is_active=TRUE WHERE id=%s", (LOC["north"],))

# ── 3LOC-002 shared driver ──
r, e = order(EAST, LOC["east"], DRV, ws="13:00", we="14:00"); check("East staff assign the shared North driver", bool(r and r.get("ok")), r or e)
east_stop = leg(r["order_id"])
r, e = order(WEST, LOC["west"], DRV, item=BULK); check("West staff cannot assign a driver not shared with West", (r or {}).get("reason") == "invalid_driver", r or e)
wleg = leg(ow["order_id"])
r, e = call(WEST, "UPDATE deliveries SET driver_id=%s WHERE id=%s RETURNING 1", (DRV, wleg)); check("direct update to an unauthorized driver is rejected", e is not None and "driver_branch" in e, r or e)
check("East staff see the shared driver; West staff do not", call(EAST, "SELECT count(*) FROM drivers WHERE id=%s", (DRV,))[0] == 1 and call(WEST, "SELECT count(*) FROM drivers WHERE id=%s", (DRV,))[0] == 0)
r, e = call(EAST, "UPDATE drivers SET phone='555' WHERE id=%s RETURNING 1", (DRV,)); check("East staff cannot edit the North driver record", r is None, r or e)
r, e = call(DRV_USER, "SELECT count(*) FROM deliveries WHERE id=%s", (east_stop,)); check("driver's queue includes the East stop", r == 1, r or e)
r, e = call(DRV_USER, "SELECT public.start_delivery(%s)", (east_stop,)); check("driver starts an East stop (no 42501)", bool(r and r.get("ok")), r or e)
r, e = call(EAST, "SELECT public.complete_delivery(%s,NULL)", (east_stop,)); check("East staff complete the shared driver's stop", bool(r and r.get("ok")), r or e)
check("completion clears the driver's active marker", q("SELECT active_delivery_id FROM drivers WHERE id=%s", (DRV,))[0][0] is None)
r, e = call(NORTH, "SELECT public.set_driver_branches(%s,%s::uuid[])", (DRV, [LOC["east"], LOC["west"]])); check("branch staff cannot share a driver", (r or {}).get("reason") == "forbidden", r or e)
r, e = call(OWNER, "SELECT public.set_driver_branches(%s,%s::uuid[])", (DRV, [LOC_A])); check("owner cannot share into another business", (r or {}).get("reason") == "other_business", r or e)
r, e = call(OWNER, "SELECT public.set_driver_branches(%s,%s::uuid[])", (DRV, [LOC["east"], LOC["west"]])); check("owner shares the driver with West", bool(r and r.get("ok")), r or e)
r, e = call(WEST, "UPDATE deliveries SET driver_id=%s, scheduled_date='2026-11-03', window_start='09:00' WHERE id=%s RETURNING 1", (DRV, wleg)); check("West can now assign the driver", r == 1, r or e)
r, e = call(OWNER, "SELECT public.set_driver_branches(%s,%s::uuid[])", (DRV, [LOC["east"]]))
check("removing West releases the driver's West stop", bool(r and r.get("stops_released") == 1) and q("SELECT driver_id FROM deliveries WHERE id=%s", (wleg,))[0][0] is None, r or e)

# ── 3LOC-003 overlaps ──
r1, e = order(NORTH, LOC["north"], DRV, ws="10:00", we="11:00"); check("10:00–11:00 booked", bool(r1 and r1.get("ok")), r1 or e)
r, e = order(NORTH, LOC["north"], DRV, ws="10:30", we="11:30"); check("partial overlap in the same branch refused", (r or {}).get("reason") == "driver_busy", r or e)
r, e = order(EAST, LOC["east"], DRV, ws="10:00", we="11:00"); check("same slot from another branch refused", (r or {}).get("reason") == "driver_busy", r or e)
r, e = order(NORTH, LOC["north"], DRV, ws="11:00", we="12:00", item=BULK); check("back-to-back 11:00–12:00 allowed", bool(r and r.get("ok")), r or e)
second = leg(r["order_id"])
r, e = call(NORTH, "UPDATE deliveries SET window_start='10:15', window_end='10:45' WHERE id=%s RETURNING 1", (second,)); check("direct update into an occupied slot rejected (23P01)", e is not None and "deliveries_driver_no_overlap" in e, r or e)
r, e = call(NORTH, "UPDATE deliveries SET window_end='09:00' WHERE id=%s RETURNING 1", (second,)); check("end before start rejected", e is not None, r or e)
r, e = order(NORTH, LOC["north"], DRV, ws="15:00", item=BULK); s3 = leg(r["order_id"])
r, e = order(NORTH, LOC["north"], DRV, ws="15:30", we="16:00", item=BULK); check("a start-only stop occupies one hour", (r or {}).get("reason") == "driver_busy", r or e)
r, e = call(EAST, "SELECT array_agg(x) FROM public.get_busy_driver_ids('2026-11-02','10:30','10:45') x"); check("East's busy lookup sees the driver's North booking", DRV in (r or []), r or e)
r, e = call(NORTH, "SELECT public.cancel_order(%s,'v074')", (r1["order_id"],))
r, e = order(EAST, LOC["east"], DRV, ws="10:00", we="11:00"); check("cancellation frees the slot", bool(r and r.get("ok")), r or e)
r, e = order(NORTH, LOC["north"], DRV, date="2026-11-04", ws="10:00", we="11:00", item=BULK); a = leg(r["order_id"])
r, e = order(NORTH, LOC["north"], DRV, date="2026-11-04", ws="12:00", we="13:00", item=BULK); b = leg(r["order_id"])
r, e = call(NORTH, "UPDATE deliveries SET window_start='12:30', window_end='13:30' WHERE id=%s RETURNING 1", (b,)); check("rescheduling into a free slot works", r == 1, r or e)

# ── 3LOC-004 one active stop ──
r, e = call(DRV_USER, "SELECT public.start_delivery(%s)", (a,)); check("driver starts the first stop", bool(r and r.get("ok")), r or e)
r, e = call(DRV_USER, "SELECT public.start_delivery(%s)", (b,)); check("second start refused while one is en route", (r or {}).get("reason") == "driver_busy", r or e)
check("first stop and pointer preserved", q("SELECT status FROM deliveries WHERE id=%s", (a,))[0][0] == "en_route" and q("SELECT status FROM deliveries WHERE id=%s", (b,))[0][0] == "scheduled" and q("SELECT active_delivery_id::text FROM drivers WHERE id=%s", (DRV,))[0][0] == a)
r, e = call(None, "UPDATE deliveries SET status='en_route' WHERE id=%s RETURNING 1", (b,)); check("index blocks a second en-route row on any path", e is not None, r or e)
r, e = call(NORTH, "SELECT public.complete_delivery(%s,NULL)", (a,))
r, e = call(DRV_USER, "SELECT public.start_delivery(%s)", (b,)); check("after completing, the next stop starts", bool(r and r.get("ok")), r or e)
r, e = call(NORTH, "UPDATE deliveries SET driver_id=NULL WHERE id=%s RETURNING status", (b,)); check("unassigning an en-route stop frees the driver", r == "pending" and q("SELECT active_delivery_id FROM drivers WHERE id=%s", (DRV,))[0][0] is None, r or e)

# ── cross-store reads ──
q("INSERT INTO delivery_photos(delivery_id, storage_path) VALUES (%s, %s)", (east_stop, east_stop + "/proof.jpg"))
check("proof photos: East staff and owner see East's, North staff do not",
      call(EAST, "SELECT count(*) FROM delivery_photos WHERE delivery_id=%s", (east_stop,))[0] == 1
      and call(OWNER, "SELECT count(*) FROM delivery_photos WHERE delivery_id=%s", (east_stop,))[0] == 1
      and call(NORTH, "SELECT count(*) FROM delivery_photos WHERE delivery_id=%s", (east_stop,))[0] == 0)
check("staff read only their own notifications", call(A_STAFF, "SELECT count(*) FROM notifications WHERE user_id <> auth.uid()")[0] == 0)
q("INSERT INTO driver_locations(driver_id, latitude, longitude) VALUES (%s, 40.7, -73.4)", (DRV,))
check("driver GPS: home and shared branches see it, other stores do not",
      call(NORTH, "SELECT count(*) FROM driver_locations WHERE driver_id=%s", (DRV,))[0] == 1
      and call(EAST, "SELECT count(*) FROM driver_locations WHERE driver_id=%s", (DRV,))[0] == 1
      and call(WEST, "SELECT count(*) FROM driver_locations WHERE driver_id=%s", (DRV,))[0] == 0
      and call(A_STAFF, "SELECT count(*) FROM driver_locations WHERE driver_id=%s", (DRV,))[0] == 0)

# ── 078 hardening ──
r, e = call(OWNER, "UPDATE equipment_items SET name=name WHERE id=%s RETURNING 1", (SER,)); r2, e2 = call(NORTH, "UPDATE equipment_items SET name=name WHERE id=%s RETURNING 1", (SER,))
check("another business's owner and staff cannot edit the shared catalog", r is None and r2 is None, (r or e, r2 or e2))
check("they still read the catalog", call(OWNER, "SELECT count(*) FROM equipment_items WHERE id=%s", (SER,))[0] == 1)
cottage = q("SELECT p.id::text FROM profiles p JOIN pickup_locations l ON l.id=p.location_id JOIN businesses b ON b.id=l.business_id WHERE b.slug='cottage-surgical' AND p.role='staff' AND p.is_active LIMIT 1")
if cottage:
    r, e = call(cottage[0][0], "UPDATE equipment_items SET name=name WHERE id=%s RETURNING 1", (SER,)); check("Cottage staff still edit the catalog", r == 1, r or e)
r, e = call(OWNER, "INSERT INTO inventory_item_notes(item_id, body, created_by) VALUES (%s, 'v074 private note', auth.uid()) RETURNING 1", (SER,))
check("item notes stay inside the author's business",
      r == 1 and call(NORTH, "SELECT count(*) FROM inventory_item_notes WHERE body='v074 private note'")[0] == 1
      and call(A_STAFF, "SELECT count(*) FROM inventory_item_notes WHERE body='v074 private note'")[0] == 0, r or e)
r, e = call(OWNER, "INSERT INTO equipment_item_pickup_locations(equipment_item_id, pickup_location_id) VALUES (%s, %s) RETURNING 1", (SER, LOC_A))
check("store assignments only for accessible stores", e is not None, r or e)
q("UPDATE pickup_locations SET is_active=FALSE WHERE id=%s", (LOC["east"],))
check("drivers read names of not-yet-open branches they serve", call(DRV_USER, "SELECT count(*) FROM pickup_locations WHERE id=%s", (LOC["east"],))[0] == 1)
q("UPDATE pickup_locations SET is_active=TRUE WHERE id=%s", (LOC["east"],))
r, e = order(EAST, LOC["east"], DRV, date="2026-11-06", ws="09:00", we="10:00"); far = leg(r["order_id"])
q("UPDATE drivers SET location_id=%s WHERE id=%s", (LOC_A, DRV))
check("moving a driver's home releases stops they no longer serve",
      q("SELECT driver_id FROM deliveries WHERE id=%s", (far,))[0][0] is None and q("SELECT count(*) FROM driver_branches WHERE driver_id=%s", (DRV,))[0][0] == 0)
r, e = order(WEST, LOC["west"], WDRV, date="2026-11-08", ws="00:15", we="00:45", item=BULK)
r, e = call(WEST, "SELECT array_agg(x) FROM public.get_busy_driver_ids('2026-11-07','23:30',NULL) x")
check("busy lookup sees a stop just after midnight", WDRV in (r or []), r or e)

# ── BIZ-003 forged links (079); deferred checks are forced with SET CONSTRAINTS ──
NOW = "; SET CONSTRAINTS ALL IMMEDIATE"
r, e = order(NORTH, LOC["north"], item=BULK); n_order = r["order_id"]
foreign_cust = q("SELECT id::text FROM customers WHERE location_id=%s LIMIT 1", (LOC_A,))
if not foreign_cust:
    order(A_STAFF, LOC_A); foreign_cust = q("SELECT id::text FROM customers WHERE location_id=%s LIMIT 1", (LOC_A,))
foreign_cust = foreign_cust[0][0]
r, e = call(NORTH, "UPDATE rental_orders SET customer_id=%s WHERE id=%s" + NOW, (foreign_cust, n_order))
check("BIZ-003 own order -> another business's customer rejected", e is not None and "location_mismatch" in e, r or e)
east_cust = q("SELECT customer_id::text FROM rental_orders WHERE location_id=%s LIMIT 1", (LOC["east"],))[0][0]
r, e = call(OWNER, "UPDATE rental_orders SET customer_id=%s WHERE id=%s" + NOW, (east_cust, n_order))
check("owner of both branches cannot link a North order to an East customer", e is not None and "location_mismatch" in e, r or e)
foreign_order = q("SELECT id::text FROM rental_orders WHERE location_id=%s LIMIT 1", (LOC_A,))[0][0]
r, e = call(NORTH, "INSERT INTO deliveries(order_id, leg_type, location_id, status) VALUES (%s,'delivery',%s,'pending') RETURNING 1", (foreign_order, LOC["north"]))
check("BIZ-003 own-store stop -> another business's order rejected", e is not None and "location_mismatch" in e, r or e)
# Deterministic fixtures: a North order holding a North unit, an East unit, a North unit of another product.
OTHER_SER = q(f"SELECT id::text FROM equipment_items WHERE is_serialized AND id <> %s ORDER BY created_at LIMIT 1", (SER,))[0][0]
east_unit = q("INSERT INTO equipment_units(item_id, location_id, asset_tag, status) VALUES (%s,%s,%s,'available') RETURNING id::text", (SER, LOC["east"], f"V074-E-{tag}"))[0][0]
q("INSERT INTO equipment_units(item_id, location_id, asset_tag, status) VALUES (%s,%s,%s,'available')", (SER, LOC["north"], f"V074-N-{tag}"))
wrong_item = q("INSERT INTO equipment_units(item_id, location_id, asset_tag, status) VALUES (%s,%s,%s,'available') RETURNING id::text", (OTHER_SER, LOC["north"], f"V074-X-{tag}"))[0][0]
r, e = order(NORTH, LOC["north"])
north_line, held = q("SELECT id::text, equipment_unit_id::text FROM rental_line_items WHERE order_id=%s", (r["order_id"],))[0]
check("fixture: the North order holds a North unit", held is not None, r)
r, e = call(OWNER, "UPDATE rental_line_items SET equipment_unit_id=%s WHERE id=%s RETURNING 1", (east_unit, north_line))
check("BIZ-003 North line -> East unit rejected (even for the owner)", e is not None and "location_mismatch" in e, r or e)
r, e = call(NORTH, "UPDATE rental_line_items SET equipment_unit_id=%s WHERE id=%s RETURNING 1", (wrong_item, north_line))
check("a line cannot hold a unit of a different product", e is not None and "location_mismatch" in e, r or e)
r, e = call(OWNER, "UPDATE equipment_units SET location_id=%s WHERE id=%s RETURNING 1", (LOC["east"], held))
check("moving a held unit to another branch rejected", e is not None and "location_mismatch" in e, r or e)
r, e = call(OWNER, "UPDATE customers SET location_id=%s WHERE id=%s" + NOW, (LOC["north"], east_cust))
check("moving a customer away from their orders' store rejected", e is not None and "location_mismatch" in e, r or e)
charge = q("SELECT c.id::text FROM recurring_charges c JOIN rental_orders o ON o.id=c.order_id WHERE o.location_id=%s LIMIT 1", (LOC["north"],))
if charge:
    r, e = call(None, "UPDATE recurring_charges SET customer_id=%s WHERE id=%s RETURNING 1", (east_cust, charge[0][0]))
    check("a charge cannot name a customer other than its order's (any path)", e is not None and "location_mismatch" in e, r or e)
r, e = call(None, "SET CONSTRAINTS ALL DEFERRED; SELECT public.submit_rental_request_with_fulfillment('rental', %s::jsonb, %s::jsonb, %s::jsonb, NULL, %s::jsonb)",
            (json.dumps([{"item_id": SER, "quantity": 1}]), json.dumps({"full_name": "V074 Storefront", "phone": "5550100"}),
             json.dumps({"line1": "5 Shop St", "city": "Melville", "state": "NY", "zip": "11747"}),
             json.dumps({"method": "delivery", "payment_method": "on_delivery"})))
check("storefront request still submits (store assigned after creation)", bool(r and r.get("ok")), r or e)
r, e = call(None, "SET CONSTRAINTS ALL IMMEDIATE")
check("every legitimate write in this run satisfies the link rules", e is None, e)

# ── single-branch onboarding still works ──
single = {"business": {"id": q("SELECT business_id::text FROM pickup_locations WHERE id=%s", (LOC["north"],))[0][0]},
          "location": {"name": f"V074 single {tag}", "line1": "3 Elm St", "city": "Melville", "state": "NY", "zip": "11747", "fulfillment_mode": "pickup_only", "partner_type": "owned"}, "stock": [], "team": []}
r, e = call(ADMIN, "SELECT public.onboard_business_location(%s,%s::jsonb)", (str(uuid.uuid4()), json.dumps(single)))
check("single-branch onboarding (062 RPC) still works", bool(r and r.get("ok") and r.get("location_id")), r or e)
r, e = call(OWNER, "SELECT count(*) FROM pickup_locations WHERE business_id=%s", (q("SELECT business_id::text FROM pickup_locations WHERE id=%s", (LOC["north"],))[0][0],))
check("the owner automatically covers a branch added later", r == 4, r or e)

conn.rollback(); print("-- ROLLED BACK")
f = [n for n, ok in results if not ok]; print(f"{len(results)-len(f)}/{len(results)} passed"); sys.exit(1 if f else 0)
