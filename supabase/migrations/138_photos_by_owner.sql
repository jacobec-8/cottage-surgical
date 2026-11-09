-- 138: product photos are filed by owner (BUSINESS-SHAPE.md, step 9).
--
-- Until now any owner could upload, replace or delete any photo in the
-- equipment-images bucket, whoever's product it showed. Now the first folder
-- of a photo's path says whose it is, and only they may write there:
--   <owner's business id>/...  that owner (an owner's products);
--   <pharmacy id>/...           that pharmacy's owner, and its staff when
--                               products are open to them (store-only products);
--   anything else (catalog/...) admins only; the starter photos live there.
-- Everyone can still see every photo: the bucket is public, as the website
-- needs. Products already using a starter photo keep showing it; a new photo
-- goes in the owner's folder.
--
-- Safe to re-run.

CREATE OR REPLACE FUNCTION public.can_write_product_photo(p_path text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN public.is_admin() THEN true
    WHEN split_part(p_path, '/', 1) !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN false
    ELSE (public.app_role() = 'owner' AND split_part(p_path, '/', 1)::uuid = public.current_business_id())
      OR public.staff_may(split_part(p_path, '/', 1)::uuid, 'edit_products')
  END;
$$;
REVOKE ALL ON FUNCTION public.can_write_product_photo(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_write_product_photo(text) TO authenticated, service_role;

DO $$
BEGIN
  IF to_regclass('storage.objects') IS NOT NULL THEN
    EXECUTE 'DROP POLICY IF EXISTS equipment_images_staff_upload ON storage.objects';
    EXECUTE 'DROP POLICY IF EXISTS equipment_images_staff_update ON storage.objects';
    EXECUTE 'DROP POLICY IF EXISTS equipment_images_staff_delete ON storage.objects';
    EXECUTE 'DROP POLICY IF EXISTS equipment_images_store_write ON storage.objects';
    EXECUTE 'DROP POLICY IF EXISTS equipment_images_write ON storage.objects';
    EXECUTE $p$CREATE POLICY equipment_images_write ON storage.objects FOR ALL TO authenticated
      USING (bucket_id = 'equipment-images' AND public.can_write_product_photo(name))
      WITH CHECK (bucket_id = 'equipment-images' AND public.can_write_product_photo(name))$p$;
  END IF;
END $$;
