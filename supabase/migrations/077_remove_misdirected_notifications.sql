-- 077 — Remove notification copies sent to the wrong store (BIZ-001).
-- Before 074, request and stop-status notifications went to every active
-- staff account, so other stores' and businesses' staff hold copies with
-- customer names and order numbers. 074 scoped new fanout; this deletes the
-- existing copies whose recipient cannot access the referenced order's store.
-- Admins, owners within their business, the store's own staff, and drivers who
-- serve that store keep theirs. Notifications with no order/stop reference
-- (driver assignment rows addressed to the assigned driver) are untouched.

WITH refs AS (
  SELECT n.id, n.user_id,
    CASE WHEN n.reference_id ~ '^order_[0-9a-f-]{36}_' THEN (SELECT location_id FROM rental_orders WHERE id = substring(n.reference_id from 7 for 36)::uuid)
         WHEN n.reference_id ~ '^delivery_[0-9a-f-]{36}_' THEN (SELECT location_id FROM deliveries WHERE id = substring(n.reference_id from 10 for 36)::uuid)
    END AS loc
  FROM notifications n
), judged AS (
  SELECT r.id, p.role, r.loc,
    CASE
      WHEN p.role = 'admin' THEN true
      WHEN p.role = 'staff' THEN r.loc = p.location_id
      WHEN p.role = 'owner' THEN EXISTS (SELECT 1 FROM pickup_locations l WHERE l.id = r.loc AND l.business_id = p.business_id)
      WHEN p.role = 'driver' THEN EXISTS (SELECT 1 FROM drivers d WHERE d.user_id = p.id AND public.driver_serves_location(d.id, r.loc))
      ELSE true
    END AS allowed
  FROM refs r JOIN profiles p ON p.id = r.user_id
  WHERE r.loc IS NOT NULL
)
DELETE FROM public.notifications n
 USING judged j
 WHERE n.id = j.id AND NOT j.allowed;
