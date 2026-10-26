-- EMAIL-001: customer email bodies contain the order's private customer data.
-- Staff can read only their own store's outbox. Admins retain global access;
-- drivers and anonymous callers gain no access. Dispatch is SECURITY DEFINER.
DROP POLICY IF EXISTS customer_email_outbox_staff_read ON public.customer_email_outbox;
CREATE POLICY customer_email_outbox_staff_read ON public.customer_email_outbox
  FOR SELECT TO authenticated
  USING (
    public.is_staff_or_admin()
    AND EXISTS (
      SELECT 1 FROM public.rental_orders o
       WHERE o.id = customer_email_outbox.order_id
         AND public.can_access_location(o.location_id)
    )
  );
