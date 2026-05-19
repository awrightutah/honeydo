# Supabase Storage and Auth Setup

## Auth Configuration

In Supabase Dashboard → Authentication → Providers:

1. Enable Email provider.
2. For development, email confirmations can remain off if you want faster testing.
3. Before production, enable email confirmation.
4. Add Google and Apple OAuth later when the app bundle IDs, domains, and redirect URLs are finalized.

Recommended redirect URLs later:

- Mobile deep link: `honeydo://auth/callback`
- Admin dashboard: production dashboard URL once deployed
- Local dashboard: `http://localhost:5173`

## Storage Buckets

Create these buckets in Supabase Dashboard → Storage:

### 1. avatars

- Public bucket: yes
- Purpose: profile and sub-profile avatars
- Suggested max file size: 2 MB
- Allowed types: image/png, image/jpeg, image/webp

### 2. recipe-images

- Public bucket: yes
- Purpose: household and master recipe images
- Suggested max file size: 5 MB
- Allowed types: image/png, image/jpeg, image/webp

### 3. chore-verification-photos

- Public bucket: no/private
- Purpose: temporary chore proof photos
- Suggested max file size: 5 MB
- Allowed types: image/png, image/jpeg, image/webp
- Retention goal: auto-delete after 7 days via backend scheduled job later

## Storage RLS Policy Plan

Storage policies should be finalized after app path conventions are implemented.

Planned path conventions:

```text
avatars/{household_id}/{member_id}/{filename}
recipe-images/households/{household_id}/{recipe_id}/{filename}
recipe-images/master/{master_recipe_id}/{filename}
chore-verification-photos/{household_id}/{chore_id}/{filename}
```

The backend may handle uploads for private/protected paths using the Supabase service role key to keep storage policies simpler for v1.
