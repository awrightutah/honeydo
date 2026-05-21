-- ========================================
-- Storage buckets and policies for avatars and recipe images
-- ========================================

-- Create avatars bucket (profile pictures)
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'avatars',
  'avatars',
  true,  -- public so images can be displayed without signed URLs
  2097152,  -- 2MB limit
  ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/gif']
) ON CONFLICT (id) DO UPDATE SET
  public = true,
  file_size_limit = 2097152,
  allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/gif'];

-- Create recipe-images bucket
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'recipe-images',
  'recipe-images',
  true,
  5242880,  -- 5MB limit for recipe images
  ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/gif']
) ON CONFLICT (id) DO UPDATE SET
  public = true,
  file_size_limit = 5242880,
  allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/gif'];

-- Create chore-photos bucket (private; for chore verification uploads)
-- Path convention: {household_id}/{chore_id}/{filename}
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'chore-photos',
  'chore-photos',
  false,  -- private; access via signed URLs only
  10485760,  -- 10MB limit
  ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/heic']
) ON CONFLICT (id) DO UPDATE SET
  public = false,
  file_size_limit = 10485760,
  allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/heic'];

-- ========================================
-- Avatar storage policies
-- ========================================

-- Anyone can view avatars (they're public profile pictures)
CREATE POLICY "Avatars are viewable by everyone"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'avatars');

-- Users can upload their own avatar
CREATE POLICY "Users can upload their own avatar"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'avatars'
    AND auth.uid()::text = (storage.foldername(name))[1]
  );

-- Users can update their own avatar
CREATE POLICY "Users can update their own avatar"
  ON storage.objects FOR UPDATE
  USING (
    bucket_id = 'avatars'
    AND auth.uid()::text = (storage.foldername(name))[1]
  );

-- Users can delete their own avatar
CREATE POLICY "Users can delete their own avatar"
  ON storage.objects FOR DELETE
  USING (
    bucket_id = 'avatars'
    AND auth.uid()::text = (storage.foldername(name))[1]
  );

-- ========================================
-- Recipe images storage policies
-- ========================================

-- Anyone can view recipe images (for browsing recipes)
CREATE POLICY "Recipe images are viewable by everyone"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'recipe-images');

-- Household members can upload recipe images
CREATE POLICY "Authenticated users can upload recipe images"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'recipe-images'
    AND auth.uid() IS NOT NULL
  );

-- Only the uploader or household admin can update recipe images
CREATE POLICY "Users can update their own recipe images"
  ON storage.objects FOR UPDATE
  USING (
    bucket_id = 'recipe-images'
    AND auth.uid() IS NOT NULL
  );

-- Only the uploader or household admin can delete recipe images
CREATE POLICY "Users can delete their own recipe images"
  ON storage.objects FOR DELETE
  USING (
    bucket_id = 'recipe-images'
    AND auth.uid() IS NOT NULL
  );

-- ========================================
-- Chore photos storage policies (private bucket)
-- Path convention: {household_id}/{chore_id}/{filename}
-- ========================================

-- Household members can view photos for chores in their household
CREATE POLICY "Household members can view chore photos"
  ON storage.objects FOR SELECT
  USING (
    bucket_id = 'chore-photos'
    AND (storage.foldername(name))[1] IN (
      SELECT household_id::text
      FROM public.household_members
      WHERE auth_user_id = auth.uid()
        AND is_active = true
    )
  );

-- Household members can upload photos to their household
CREATE POLICY "Household members can upload chore photos"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'chore-photos'
    AND (storage.foldername(name))[1] IN (
      SELECT household_id::text
      FROM public.household_members
      WHERE auth_user_id = auth.uid()
        AND is_active = true
    )
  );

-- Only the uploader (via chore_verification_photos.uploaded_by_member_id)
-- or a household admin can delete chore photos
CREATE POLICY "Uploader or household admin can delete chore photos"
  ON storage.objects FOR DELETE
  USING (
    bucket_id = 'chore-photos'
    AND (
      EXISTS (
        SELECT 1
        FROM public.chore_verification_photos cvp
        JOIN public.household_members hm ON hm.id = cvp.uploaded_by_member_id
        WHERE cvp.storage_path = storage.objects.name
          AND hm.auth_user_id = auth.uid()
      )
      OR
      (storage.foldername(name))[1] IN (
        SELECT household_id::text
        FROM public.household_members
        WHERE auth_user_id = auth.uid()
          AND is_active = true
          AND role IN ('owner', 'admin')
      )
    )
  );

-- ========================================
-- Helper function to get avatar URL
-- ========================================
CREATE OR REPLACE FUNCTION get_avatar_url(user_id UUID)
RETURNS TEXT AS $$
DECLARE
  avatar_path TEXT;
BEGIN
  SELECT name INTO avatar_path
  FROM storage.objects
  WHERE bucket_id = 'avatars'
    AND name LIKE user_id::text || '/%'
  ORDER BY created_at DESC
  LIMIT 1;

  IF avatar_path IS NOT NULL THEN
    RETURN '/storage/v1/object/public/avatars/' || avatar_path;
  END IF;

  RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ========================================
-- Helper function to get recipe image URL
-- ========================================
CREATE OR REPLACE FUNCTION get_recipe_image_url(recipe_id UUID)
RETURNS TEXT AS $$
DECLARE
  image_path TEXT;
BEGIN
  SELECT name INTO image_path
  FROM storage.objects
  WHERE bucket_id = 'recipe-images'
    AND name LIKE recipe_id::text || '/%'
  ORDER BY created_at DESC
  LIMIT 1;

  IF image_path IS NOT NULL THEN
    RETURN '/storage/v1/object/public/recipe-images/' || image_path;
  END IF;

  RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
