-- Public catalog images uploaded by staff/admin from Inventory.
-- The bucket is public because these URLs appear on the anonymous storefront;
-- object creation/replacement/deletion remains restricted to store staff.

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'equipment-images',
  'equipment-images',
  true,
  5242880,
  ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/gif']::text[]
)
ON CONFLICT (id) DO UPDATE SET
  public = EXCLUDED.public,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS "equipment_images_staff_upload" ON storage.objects;
CREATE POLICY "equipment_images_staff_upload" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'equipment-images'
    AND public.is_staff_or_admin()
  );

DROP POLICY IF EXISTS "equipment_images_staff_update" ON storage.objects;
CREATE POLICY "equipment_images_staff_update" ON storage.objects
  FOR UPDATE TO authenticated
  USING (
    bucket_id = 'equipment-images'
    AND public.is_staff_or_admin()
  )
  WITH CHECK (
    bucket_id = 'equipment-images'
    AND public.is_staff_or_admin()
  );

DROP POLICY IF EXISTS "equipment_images_staff_delete" ON storage.objects;
CREATE POLICY "equipment_images_staff_delete" ON storage.objects
  FOR DELETE TO authenticated
  USING (
    bucket_id = 'equipment-images'
    AND public.is_staff_or_admin()
  );
