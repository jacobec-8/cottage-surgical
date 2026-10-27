-- 095: Who may see and flip the website's retail sales switch (094).
CREATE OR REPLACE FUNCTION public.can_manage_online_retail()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.is_admin()
      OR (public.app_role() = 'owner'
          AND public.current_business_id() = (SELECT id FROM public.businesses WHERE slug = 'cottage-surgical'));
$$;
REVOKE EXECUTE ON FUNCTION public.can_manage_online_retail() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_manage_online_retail() TO authenticated;
