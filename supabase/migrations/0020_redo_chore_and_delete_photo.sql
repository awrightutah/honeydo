-- 0020_redo_chore_and_delete_photo.sql
--
-- Kid Permissions Workstream — Batch 4b: close the chore-photo loop.
--
-- Adds two RPCs:
--   1. redo_chore(p_chore_id, p_member_id) — kid reverts a rejected chore
--      back to 'assigned' so they can re-submit.
--   2. delete_chore_photo(p_photo_id) — admin removes a chore_verification_photos
--      row and returns the storage_path so the client can call
--      storage.from('chore-photos').remove([path]) to remove the file.
--
-- REFERENCES
--   Spec:           /audits/2026-05-kid-profile-permissions-spec.md (Batch 4 row, photo-optional amendment 2026-05-24)
--   Investigation:  /audits/2026-05-kid-perms-batch-4b-investigation.md (2026-05-25)
--   Prior 4a:       /audits/2026-05-kid-perms-batch-4a-implementation.md (commit ed626bb)
--   Patterns:       /audits/supabase-patterns-learned.md (Pattern 1: SECURITY DEFINER
--                   + SET search_path = public; Pattern 3: REVOKE FROM PUBLIC, anon).
--
-- WHY redo_chore
--   When admin rejects a kid's submission via approve_chore (migration 0017),
--   chores.status flips to 'rejected' and rejected_reason is recorded. There's
--   no existing path for the kid to revert to 'assigned' — RLS UPDATE on chores
--   is admin-only, so a kid can't simply update the row. redo_chore is the
--   SECURITY DEFINER bypass that lets the kid initiate a re-submission cycle.
--
-- WHY delete_chore_photo (separate from approve_chore + 30-day cron)
--   approve_chore schedules photo cleanup 30 days post-decision. delete_chore_photo
--   is the manual safety knob: admin sees a photo they shouldn't have (wrong photo,
--   inappropriate content, kid privacy concern) and removes it immediately.
--   Existing RLS on chore_verification_photos already permits admin DELETE, and
--   migration 0003's Storage DELETE policy already permits admin removal — so
--   technically the client could do this without a server RPC. The RPC exists for
--   pattern consistency with the rest of the kid-perms workstream (centralized
--   admin validation + future extension point for audit logging) and returns the
--   storage_path so the client can finalize the Storage removal in one round-trip.
--
-- WHY THE RPC DOESN'T DELETE FROM storage.objects
--   Supabase's Storage service manages files on an S3-compatible backend.
--   The storage.objects table is a metadata index, not the canonical file store.
--   Direct DELETE FROM storage.objects within Postgres may leave the underlying
--   file orphaned on disk. The Storage HTTP API (.remove([path])) is the only
--   reliable removal path — and that's a client call, not an SQL operation.
--   So: RPC deletes the chore_verification_photos row + returns the path; client
--   completes the Storage removal via the SDK.
--
-- IDEMPOTENCY
--   Both functions use CREATE OR REPLACE. REVOKE/GRANT are no-ops in the
--   desired state. Safe to re-run.


-- ============================================================================
-- SECTION 1 — RPC: redo_chore(p_chore_id, p_member_id)
-- ============================================================================
-- Kid reverts a rejected chore back to 'assigned' so they can try again.
-- Clears rejected_reason, completed_at, verified_at, verified_by_member_id —
-- the chore looks newly-assigned. Prior chore_verification_photos rows are
-- NOT deleted; their delete_after was already set by approve_chore's reject
-- path, so the 30-day cron (deferred) will clean them up.
--
-- Validations (raise descriptively on each failure):
--   1. Chore exists
--   2. Member is an active sub_profile (via is_member_kid)
--   3. Member's household matches chore's household
--   4. Calling JWT is in that household (the kid has no JWT; adult holds session)
--   5. Chore is assigned to this member
--   6. Chore status is 'rejected'
CREATE OR REPLACE FUNCTION public.redo_chore(
  p_chore_id  uuid,
  p_member_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_household_id       uuid;
  v_assigned_member_id uuid;
  v_current_status     chore_status;
  v_kid_household_id   uuid;
BEGIN
  -- 1. Load chore
  SELECT household_id, assigned_to_member_id, status
    INTO v_household_id, v_assigned_member_id, v_current_status
    FROM public.chores
   WHERE id = p_chore_id;

  IF v_household_id IS NULL THEN
    RAISE EXCEPTION 'Chore not found';
  END IF;

  -- 2. Member must be an active sub_profile
  IF NOT public.is_member_kid(p_member_id) THEN
    RAISE EXCEPTION 'Only sub_profiles can re-do chores';
  END IF;

  -- 3. Member's household must match chore's household
  SELECT household_id INTO v_kid_household_id
    FROM public.household_members
   WHERE id = p_member_id;

  IF v_kid_household_id <> v_household_id THEN
    RAISE EXCEPTION 'Member is not in this chore''s household';
  END IF;

  -- 4. Calling adult JWT must be in the same household (kid has no JWT)
  IF NOT public.is_household_member(v_household_id) THEN
    RAISE EXCEPTION 'Caller is not a member of this household';
  END IF;

  -- 5. Chore must be assigned to this kid
  IF v_assigned_member_id IS NULL OR v_assigned_member_id <> p_member_id THEN
    RAISE EXCEPTION 'You can only re-do chores assigned to you';
  END IF;

  -- 6. Chore must currently be 'rejected'
  IF v_current_status <> 'rejected' THEN
    RAISE EXCEPTION 'Chore is not rejected (current status: %)', v_current_status;
  END IF;

  -- 7. Atomic: reset to 'assigned' + clear all rejection/completion metadata.
  --    Prior chore_verification_photos rows are kept; their delete_after was
  --    set 30 days out by approve_chore's reject branch.
  UPDATE public.chores
     SET status                = 'assigned',
         rejected_reason       = NULL,
         completed_at          = NULL,
         verified_at           = NULL,
         verified_by_member_id = NULL
   WHERE id = p_chore_id;
END;
$$;


-- ============================================================================
-- SECTION 2 — RPC: delete_chore_photo(p_photo_id)
-- ============================================================================
-- Admin removes a chore_verification_photos row and returns the storage_path.
-- Client uses the returned path to call storage.from('chore-photos').remove([path])
-- to remove the underlying file. The RPC validates admin auth + does the row
-- delete atomically; the Storage removal is a separate client-side step (see
-- header comment above for why we can't remove from storage.objects in SQL).
--
-- Returns the storage_path. Raises descriptively on:
--   - photo not found
--   - caller not admin in the photo's household
CREATE OR REPLACE FUNCTION public.delete_chore_photo(
  p_photo_id uuid
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_household_id uuid;
  v_storage_path text;
BEGIN
  -- 1. Load photo + its household
  SELECT household_id, storage_path
    INTO v_household_id, v_storage_path
    FROM public.chore_verification_photos
   WHERE id = p_photo_id;

  IF v_household_id IS NULL THEN
    RAISE EXCEPTION 'Photo not found';
  END IF;

  -- 2. Caller must be admin in this household
  IF NOT public.is_household_admin(v_household_id) THEN
    RAISE EXCEPTION 'Only household admins can delete chore photos';
  END IF;

  -- 3. Delete the row; client will remove the Storage object using the
  --    returned path.
  DELETE FROM public.chore_verification_photos
   WHERE id = p_photo_id;

  RETURN v_storage_path;
END;
$$;


-- ============================================================================
-- SECTION 3 — REVOKE / GRANT for both RPCs (Pattern 3)
-- ============================================================================
-- Revoke from PUBLIC AND anon explicitly. Supabase default-grants EXECUTE
-- to anon, authenticated, and service_role on every function created in
-- the public schema. REVOKE FROM PUBLIC alone doesn't catch the explicit
-- anon grant. service_role's EXECUTE is intentional (server-side access).
-- Same pattern as migrations 0017 Section 8 and 0019 Section 2.
REVOKE ALL ON FUNCTION public.redo_chore(uuid, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.delete_chore_photo(uuid) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.redo_chore(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_chore_photo(uuid) TO authenticated;


-- ============================================================================
-- VERIFICATION QUERIES — run after applying this migration. None mutate.
-- ============================================================================
--
-- A. Both functions exist and are SECURITY DEFINER:
--      SELECT proname, prosecdef, pronargs
--        FROM pg_proc p
--        JOIN pg_namespace n ON n.oid = p.pronamespace
--       WHERE n.nspname = 'public'
--         AND p.proname IN ('redo_chore', 'delete_chore_photo')
--       ORDER BY proname;
--    Expected: 2 rows; prosecdef=true on both;
--              pronargs = 1 (delete_chore_photo), 2 (redo_chore).
--
-- B. authenticated has EXECUTE on both; anon does not:
--      SELECT p.proname,
--             has_function_privilege('authenticated', p.oid, 'execute') AS auth_can,
--             has_function_privilege('anon',          p.oid, 'execute') AS anon_can,
--             has_function_privilege('service_role',  p.oid, 'execute') AS svc_can
--        FROM pg_proc p
--        JOIN pg_namespace n ON n.oid = p.pronamespace
--       WHERE n.nspname = 'public'
--         AND p.proname IN ('redo_chore', 'delete_chore_photo')
--       ORDER BY p.proname;
--    Expected: auth_can=true, anon_can=false, svc_can=true for both.
--
-- C. Functional smoke (run via SQL editor with set_config'd auth.uid):
--
--    -- 1. Reject a kid's chore (set up):
--      SELECT public.approve_chore(
--        p_chore_id := '<a pending_verification chore uuid>',
--        p_approved := false,
--        p_reason   := 'try again, room still messy'
--      );
--    -- Expect: chores.status = 'rejected', rejected_reason set.
--
--    -- 2. Kid re-does the chore:
--      SELECT public.redo_chore(
--        p_chore_id  := '<that same chore uuid>',
--        p_member_id := '<that kid sub_profile member uuid>'
--      );
--    -- Expect: chores.status = 'assigned'; rejected_reason, completed_at,
--    --         verified_at, verified_by_member_id all NULL.
--    --         chore_verification_photos rows unchanged.
--
--    -- 3. Try redo on a non-rejected chore (should raise):
--      SELECT public.redo_chore(
--        p_chore_id  := '<an "assigned"-state chore>',
--        p_member_id := '<a kid uuid>'
--      );
--    -- Expect: EXCEPTION 'Chore is not rejected (current status: assigned)'
--
-- D. delete_chore_photo functional smoke:
--
--    -- 1. Insert a test photo (substitute real ids):
--      INSERT INTO public.chore_verification_photos (
--        chore_id, household_id, uploaded_by_member_id, storage_path
--      ) VALUES (
--        '<a chore uuid>',
--        '<that chore''s household uuid>',
--        '<a kid member uuid in that household>',
--        '<household_id>/<chore_id>/test.jpg'
--      ) RETURNING id;
--
--    -- 2. Admin deletes it (as auth.uid() set to that admin's user id):
--      SELECT public.delete_chore_photo(p_photo_id := '<returned id>');
--    -- Expect: returns the storage_path '<household_id>/<chore_id>/test.jpg';
--    --         row no longer in chore_verification_photos.
--
--    -- 3. Try as a non-admin (should raise):
--      -- After set_config'ing auth.uid() to a kid's auth_user_id (kids have NULL
--      -- auth_user_id so this can't actually happen via the app; but a member-
--      -- role adult could be tested):
--      SELECT public.delete_chore_photo(p_photo_id := '<another id>');
--    -- Expect: EXCEPTION 'Only household admins can delete chore photos'
--
--    -- 4. Try a non-existent photo (should raise):
--      SELECT public.delete_chore_photo(p_photo_id := '00000000-0000-0000-0000-000000000000');
--    -- Expect: EXCEPTION 'Photo not found'
