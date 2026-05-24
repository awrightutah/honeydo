-- 0019_submit_kid_chore_optional_photo.sql
--
-- Kid Permissions Workstream — Batch 4a revision: make photo optional.
--
-- Behavior change to an EXISTING RPC (not a new function).
-- CREATE OR REPLACE on public.submit_kid_chore_with_photo so that
-- p_storage_path becomes nullable: when the kid skips the photo, the
-- function now performs the chore status flip without inserting a
-- chore_verification_photos row.
--
-- WHY THIS CHANGE
--   The Q6/A resolution in /audits/2026-05-kid-profile-permissions-spec.md
--   originally codified "photo required for kids, optional for adults."
--   Batch 4a iPhone smoke-testing surfaced that the actual user intent is
--   "photo OPTIONAL for everyone; kid chooses each submission." Migration
--   0017 enforces the old policy via an early raise; this migration drops
--   that raise and makes the photo INSERT conditional.
--
-- REFERENCES
--   Investigation: /audits/2026-05-kid-perms-photo-optional-investigation.md
--   Implementation: /audits/2026-05-kid-perms-photo-optional-implementation.md
--   Source RPC:    supabase/migrations/0017_kid_perms_rls_rpcs.sql (Section 4)
--   Spec amendment will follow in a separate commit on the same branch.
--
-- IDEMPOTENCY
--   CREATE OR REPLACE handles re-runs. REVOKE/GRANT are no-ops when
--   already in the desired state (same Supabase pattern as 0017 Section 8).
--
-- WHAT CHANGED VS 0017 SECTION 4
--   1. p_storage_path: now `text DEFAULT NULL` (was required positional).
--   2. Removed: the "Photo storage path is required" early raise.
--   3. Added:   local v_has_photo boolean.
--   4. Changed: chore_verification_photos INSERT is now inside
--               `IF v_has_photo THEN ... END IF`.
--   5. Same:    all other validation (sub_profile membership, household
--               match, assignee check, status check) — unchanged.
--   6. Same:    chores UPDATE (status → pending_verification, completed_at).
--   7. Same:    REVOKE FROM PUBLIC, anon; GRANT EXECUTE TO authenticated.
--   8. Return:  v_new_photo_id (now NULL when no photo was submitted).


-- ============================================================================
-- SECTION 1 — RPC: submit_kid_chore_with_photo (nullable p_storage_path)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.submit_kid_chore_with_photo(
  p_chore_id     uuid,
  p_member_id    uuid,
  p_storage_path text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_household_id       uuid;
  v_assigned_member_id uuid;
  v_current_status     chore_status;
  v_kid_household_id   uuid;
  v_new_photo_id       uuid;
  v_has_photo          boolean;
BEGIN
  -- 1. Compute photo presence (no longer required, just informational)
  v_has_photo := p_storage_path IS NOT NULL AND length(p_storage_path) > 0;

  -- 2. Member must be an active sub_profile
  IF NOT public.is_member_kid(p_member_id) THEN
    RAISE EXCEPTION 'Only sub_profiles can submit chores via this RPC';
  END IF;

  -- 3. Load chore + kid's household
  SELECT household_id, assigned_to_member_id, status
    INTO v_household_id, v_assigned_member_id, v_current_status
    FROM public.chores
   WHERE id = p_chore_id;

  IF v_household_id IS NULL THEN
    RAISE EXCEPTION 'Chore not found';
  END IF;

  SELECT household_id INTO v_kid_household_id
    FROM public.household_members
   WHERE id = p_member_id;

  IF v_kid_household_id <> v_household_id THEN
    RAISE EXCEPTION 'Member is not in this chore''s household';
  END IF;

  -- 4. Calling adult JWT must be in the same household (the kid has no JWT)
  IF NOT public.is_household_member(v_household_id) THEN
    RAISE EXCEPTION 'Caller is not a member of this household';
  END IF;

  -- 5. Chore must be assigned to this kid
  IF v_assigned_member_id IS NULL OR v_assigned_member_id <> p_member_id THEN
    RAISE EXCEPTION 'You can only submit chores assigned to you';
  END IF;

  -- 6. Status must be assigned or in_progress
  IF v_current_status NOT IN ('assigned', 'in_progress') THEN
    RAISE EXCEPTION 'Chore is not in a submittable state (current status: %)', v_current_status;
  END IF;

  -- 7. Atomic: update chore + conditionally insert photo row
  UPDATE public.chores
     SET status = 'pending_verification',
         completed_at = now()
   WHERE id = p_chore_id;

  IF v_has_photo THEN
    INSERT INTO public.chore_verification_photos (
      chore_id,
      household_id,
      uploaded_by_member_id,
      storage_path
    ) VALUES (
      p_chore_id,
      v_household_id,
      p_member_id,
      p_storage_path
    )
    RETURNING id INTO v_new_photo_id;
  END IF;

  RETURN v_new_photo_id;  -- NULL when no photo was submitted
END;
$$;


-- ============================================================================
-- SECTION 2 — Re-state grants (idempotent)
-- ============================================================================
-- Same signature as 0017 (uuid, uuid, text). CREATE OR REPLACE preserves
-- the existing grant state, but we re-state for safety and to keep this
-- migration self-documenting.
REVOKE ALL ON FUNCTION public.submit_kid_chore_with_photo(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.submit_kid_chore_with_photo(uuid, uuid, text) TO authenticated;


-- ============================================================================
-- VERIFICATION QUERIES — run after applying this migration. None mutate.
-- ============================================================================
--
-- A. Function still exists and is SECURITY DEFINER:
--      SELECT proname, prosecdef, pronargs
--        FROM pg_proc p
--        JOIN pg_namespace n ON n.oid = p.pronamespace
--       WHERE n.nspname = 'public'
--         AND p.proname = 'submit_kid_chore_with_photo';
--    Expected: 1 row; prosecdef=true; pronargs=3.
--
-- B. p_storage_path now has a default (proves nullability):
--      SELECT proname,
--             proargnames,
--             pg_get_function_arguments(oid) AS args,
--             pronargdefaults
--        FROM pg_proc p
--        JOIN pg_namespace n ON n.oid = p.pronamespace
--       WHERE n.nspname = 'public'
--         AND p.proname = 'submit_kid_chore_with_photo';
--    Expected: args contains "p_storage_path text DEFAULT NULL";
--              pronargdefaults = 1 (one trailing default).
--
-- C. authenticated has EXECUTE; anon does not:
--      SELECT has_function_privilege('authenticated',
--               'public.submit_kid_chore_with_photo(uuid, uuid, text)',
--               'execute') AS auth_can,
--             has_function_privilege('anon',
--               'public.submit_kid_chore_with_photo(uuid, uuid, text)',
--               'execute') AS anon_can,
--             has_function_privilege('service_role',
--               'public.submit_kid_chore_with_photo(uuid, uuid, text)',
--               'execute') AS svc_can;
--    Expected: auth_can=true, anon_can=false, svc_can=true.
--
-- D. Functional smoke (run via SQL editor with set_config'd auth.uid):
--    -- Photo-less submission (NEW behavior):
--      SELECT public.submit_kid_chore_with_photo(
--        p_chore_id  := '<a kid-assigned, "assigned"-state chore uuid>',
--        p_member_id := '<that kid sub_profile member uuid>'
--      );
--    -- Expect: returns NULL; chores.status flips to 'pending_verification';
--    --         NO new row in chore_verification_photos.
--
--    -- Photo submission (UNCHANGED behavior):
--      SELECT public.submit_kid_chore_with_photo(
--        p_chore_id     := '<a kid-assigned, "assigned"-state chore uuid>',
--        p_member_id    := '<that kid sub_profile member uuid>',
--        p_storage_path := '<household_id>/<chore_id>/<filename>.jpg'
--      );
--    -- Expect: returns a uuid; chores.status flips; one new
--    --         chore_verification_photos row referencing the path.
--
-- E. Confirm migration 0017's old-behavior raise is gone:
--    -- This call (which would have raised under 0017) must succeed now:
--      SELECT public.submit_kid_chore_with_photo(
--        p_chore_id     := '<a valid chore>',
--        p_member_id    := '<a valid kid>',
--        p_storage_path := ''  -- empty string, would have raised pre-0019
--      );
--    -- Expect: succeeds, returns NULL, no photo row inserted.
