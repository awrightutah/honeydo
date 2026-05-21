-- 0010_image_mime_aliases.sql
--
-- Safety net for the "image/jpg" mime type that iOS produces when a user
-- picks a .jpg file. Supabase Storage rejects unrecognized MIME types with
-- HTTP 415; the canonical type is "image/jpeg" but clients sometimes send
-- "image/jpg" (no "e"). The app now normalizes this at upload time in
-- ImageUploadService, but we widen the bucket allowlists to be defensive.
--
-- Idempotent: re-running the file just rewrites the array.

update storage.buckets
set allowed_mime_types = ARRAY['image/jpeg', 'image/jpg', 'image/png', 'image/webp', 'image/gif']
where id = 'avatars';

update storage.buckets
set allowed_mime_types = ARRAY['image/jpeg', 'image/jpg', 'image/png', 'image/webp', 'image/gif']
where id = 'recipe-images';

update storage.buckets
set allowed_mime_types = ARRAY['image/jpeg', 'image/jpg', 'image/png', 'image/webp', 'image/heic']
where id = 'chore-photos';
