-- 099: Customer emails give the customer's own pharmacy's phone, not the business
-- main line (found in the busy-day scenario: Montauk customers were told to call Woodbury).

CREATE OR REPLACE FUNCTION public.order_brand(p_order_id uuid)
 RETURNS TABLE(name text, phone text, email text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(NULLIF(btrim(s.display_name), ''), b.name),
         -- The customer's own pharmacy first; the business's main line only as a fallback (099).
         COALESCE(NULLIF(btrim(l.phone), ''), NULLIF(btrim(s.phone), '')),
         NULLIF(btrim(s.email), '')
    FROM public.rental_orders o
    JOIN public.pickup_locations l ON l.id = o.location_id
    JOIN public.businesses b ON b.id = l.business_id
    LEFT JOIN public.pharmacy_settings s ON s.business_id = b.id
   WHERE o.id = p_order_id;
$function$;
