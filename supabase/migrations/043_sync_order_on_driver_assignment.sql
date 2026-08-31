-- Keep the parent order in sync when assigning or removing a delivery driver.
-- deliveries_normalize_status changes NEW.status from a driver_id update, but
-- an UPDATE OF status trigger does not fire unless status appeared in the SET
-- list. Listen to driver_id as well so the normalized status reaches the order.

DROP TRIGGER IF EXISTS trg_sync_order_on_delivery_schedule ON public.deliveries;
CREATE TRIGGER trg_sync_order_on_delivery_schedule
  AFTER INSERT OR UPDATE OF status, driver_id ON public.deliveries
  FOR EACH ROW EXECUTE FUNCTION public.sync_order_on_delivery_schedule();

-- Repair any current open orders whose delivery is already scheduled/en route.
UPDATE public.rental_orders o
   SET status = 'scheduled'
 WHERE o.status = 'open'
   AND EXISTS (
     SELECT 1
       FROM public.deliveries d
      WHERE d.order_id = o.id
        AND d.leg_type = 'delivery'
        AND d.status IN ('scheduled', 'en_route')
   );
