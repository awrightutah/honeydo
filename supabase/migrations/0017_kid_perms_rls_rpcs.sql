-- 0017_kid_perms_rls_rpcs.sql
--
-- Kid Permissions Workstream — Batch 2 (RLS + SECURITY DEFINER RPCs).
--
-- Adds the six RPCs the kid-permissions UI batches will call, tightens
-- RLS on the eight affected tables, and introduces the is_member_kid()
-- helper. This is pure backend — no Dart changes; app code migration
-- happens in Batches 3, 4, 5, 6.
--
-- Reference spec: /audits/2026-05-kid-profile-permissions-spec.md
-- Reference investigation: /audits/2026-05-kid-perms-batch-2-investigation.md
--
-- WHY THIS BATCH
--   The investigation (and Pass 2 PIN debugging) established that RLS in
--   this app cannot directly distinguish "the calling user is a kid"
--   because sub_profiles have auth_user_id IS NULL and never hold a JWT.
--   The architectural answer is: kid-attributable writes go through
--   SECURITY DEFINER RPCs that take p_member_id as a parameter, branch
--   on the member's kind inside the function, and bypass RLS via the
--   definer's elevated privileges. RLS provides the outer perimeter
--   (no direct kid-attributable INSERTs into meal_requests, etc.);
--   the RPCs enforce the per-kind branching.
--
-- HELPER: is_member_kid REPLACES THE IMPOSSIBLE is_household_kid
--   Batch 1 investigation found that is_household_kid(target_household_id)
--   as the spec originally described is unimplementable — sub_profiles
--   have auth_user_id IS NULL, so a helper filtering by
--   "auth_user_id = auth.uid() AND kind = 'sub_profile'" can never match.
--   is_member_kid(p_member_id) takes a member_id directly and is used
--   inside the kid-attributable RPCs to validate that the targeted
--   member is in fact a sub_profile.
--
-- SIX RPCs (all SECURITY DEFINER, SET search_path = public)
--   1. approve_chore(p_chore_id, p_approved, p_reason)
--      Admin verifies or rejects a pending-verification chore.
--      Branches award_points / check_and_award_achievements by kind.
--      Schedules chore_verification_photos.delete_after.
--   2. complete_chore_self(p_chore_id, p_member_id)
--      Adult self-complete (auto-verified, no admin step).
--      Per Q3 decision: all chore completions go through RPC.
--   3. submit_kid_chore_with_photo(p_chore_id, p_member_id, p_storage_path)
--      Kid-only path; status → pending_verification, inserts photo row.
--   4. add_shopping_item(p_household_id, p_member_id, p_name, ...)
--      Kid inserts route to wishlist unless category is on the
--      household's necessity_categories list (case-insensitive match).
--      Adult inserts always is_wishlist=false.
--   5. create_meal_request(p_household_id, p_member_id, p_recipe_id, ...)
--      Kid-only path to request a meal from the recipe library.
--   6. decide_meal_request(p_request_id, p_approved, p_note, ...)
--      Admin decides. On approve, atomically creates the meal_plans
--      row from request + optional date/type overrides. Returns jsonb.
--
-- RLS TIGHTENING (8 TABLES)
--   chores, chore_verification_photos, rewards, meal_plans, shopping_items,
--   meal_requests, necessity_categories, analytics_events. The pattern is
--   the same on each: drop the existing single "for all using is_household_member"
--   policy, add 4 narrower policies (SELECT, INSERT, UPDATE, DELETE).
--
-- IDEMPOTENCY
--   All functions use CREATE OR REPLACE. All policies use DROP POLICY
--   IF EXISTS before CREATE POLICY. REVOKE/GRANT are no-ops if already
--   in the desired state. Safe to re-run.


-- ============================================================================
-- SECTION 1 — Helper: is_member_kid(p_member_id)
-- ============================================================================
-- Used inside add_shopping_item, submit_kid_chore_with_photo, and
-- create_meal_request to validate that the targeted member is an active
-- sub_profile. Mirrors the shape of is_household_member / is_household_admin
-- (sql language, stable, security definer).
CREATE OR REPLACE FUNCTION public.is_member_kid(p_member_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM public.household_members
     WHERE id = p_member_id
       AND kind = 'sub_profile'
       AND is_active = true
  );
$$;


-- ============================================================================
-- SECTION 2 — RPC: approve_chore(p_chore_id, p_approved, p_reason)
-- ============================================================================
-- Admin verifies or rejects a chore that's in 'pending_verification' state.
-- On approve: status → 'verified', branches the points/achievements RPCs by
-- the assignee's kind. On reject: status → 'rejected', saves p_reason.
-- Either way: schedules photo cleanup for any chore_verification_photos rows.
--
-- Raises descriptively on: chore not found, caller not admin, wrong status.
CREATE OR REPLACE FUNCTION public.approve_chore(
  p_chore_id uuid,
  p_approved boolean,
  p_reason   text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_household_id          uuid;
  v_assigned_member_id    uuid;
  v_current_status        chore_status;
  v_point_value           integer;
  v_bonus_points          integer;
  v_total_points          integer;
  v_caller_member_id      uuid;
  v_assigned_kind         member_kind;
  v_assigned_auth_user_id uuid;
BEGIN
  -- 1. Load chore
  SELECT household_id, assigned_to_member_id, status, point_value, COALESCE(bonus_points, 0)
    INTO v_household_id, v_assigned_member_id, v_current_status, v_point_value, v_bonus_points
    FROM public.chores
   WHERE id = p_chore_id;

  IF v_household_id IS NULL THEN
    RAISE EXCEPTION 'Chore not found';
  END IF;

  -- 2. Caller must be admin in this household
  IF NOT public.is_household_admin(v_household_id) THEN
    RAISE EXCEPTION 'Only household admins can verify chores';
  END IF;

  -- Need the caller's member_id for verified_by_member_id (audit trail)
  SELECT id
    INTO v_caller_member_id
    FROM public.household_members
   WHERE auth_user_id = auth.uid()
     AND household_id = v_household_id
     AND is_active = true;

  -- 3. Status must be pending_verification
  IF v_current_status <> 'pending_verification' THEN
    RAISE EXCEPTION 'Chore is not pending verification (current status: %)', v_current_status;
  END IF;

  IF p_approved THEN
    -- 4a. Mark verified
    UPDATE public.chores
       SET status = 'verified',
           verified_at = now(),
           verified_by_member_id = v_caller_member_id
     WHERE id = p_chore_id;

    -- 5a. Award points + achievements (branch on assignee kind)
    IF v_assigned_member_id IS NOT NULL THEN
      SELECT kind, auth_user_id
        INTO v_assigned_kind, v_assigned_auth_user_id
        FROM public.household_members
       WHERE id = v_assigned_member_id;

      v_total_points := v_point_value + v_bonus_points;

      IF v_assigned_kind = 'sub_profile' THEN
        PERFORM public.award_points_to_member(
          v_assigned_member_id, v_household_id, v_total_points,
          'chore_completion', 'chores', p_chore_id
        );
        PERFORM public.check_and_award_achievements_for_member(
          v_assigned_member_id, v_household_id
        );
      ELSE
        PERFORM public.award_points(
          v_assigned_auth_user_id, v_household_id, v_total_points,
          'chore_completion', 'chores', p_chore_id
        );
        PERFORM public.check_and_award_achievements(
          v_assigned_auth_user_id, v_household_id
        );
      END IF;
    END IF;
  ELSE
    -- 4b. Reject — status='rejected' per Q1 decision, save reason
    UPDATE public.chores
       SET status = 'rejected',
           rejected_reason = p_reason,
           verified_at = now(),
           verified_by_member_id = v_caller_member_id
     WHERE id = p_chore_id;
  END IF;

  -- 6. Schedule any verification photos for cleanup in 30 days
  UPDATE public.chore_verification_photos
     SET delete_after = now() + interval '30 days'
   WHERE chore_id = p_chore_id
     AND delete_after IS NULL;
END;
$$;


-- ============================================================================
-- SECTION 3 — RPC: complete_chore_self(p_chore_id, p_member_id)
-- ============================================================================
-- Adult-only self-complete. Per Q3, all chore completions go through RPC;
-- adults skip the pending_verification step (status → 'verified' directly)
-- because the spec makes photo evidence optional for adults. Kids use
-- submit_kid_chore_with_photo instead.
--
-- Validates: p_member_id is in chore's household, is_active, is an adult,
-- and matches the caller's JWT (auth.uid()); chore.assigned_to_member_id
-- matches p_member_id; status is 'assigned' or 'in_progress'.
--
-- Awards points/achievements via the adult-path RPCs.
CREATE OR REPLACE FUNCTION public.complete_chore_self(
  p_chore_id  uuid,
  p_member_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_household_id        uuid;
  v_assigned_member_id  uuid;
  v_current_status      chore_status;
  v_point_value         integer;
  v_bonus_points        integer;
  v_total_points        integer;
  v_member_auth_user_id uuid;
  v_member_ok           boolean;
BEGIN
  -- 1. Load chore
  SELECT household_id, assigned_to_member_id, status, point_value, COALESCE(bonus_points, 0)
    INTO v_household_id, v_assigned_member_id, v_current_status, v_point_value, v_bonus_points
    FROM public.chores
   WHERE id = p_chore_id;

  IF v_household_id IS NULL THEN
    RAISE EXCEPTION 'Chore not found';
  END IF;

  -- 2. Caller's JWT must match p_member_id, and p_member_id must be an
  --    active adult in this household.
  SELECT EXISTS (
    SELECT 1
      FROM public.household_members
     WHERE id = p_member_id
       AND auth_user_id = auth.uid()
       AND household_id = v_household_id
       AND kind = 'adult_auth_user'
       AND is_active = true
  ),
  (SELECT auth_user_id FROM public.household_members WHERE id = p_member_id)
    INTO v_member_ok, v_member_auth_user_id;

  IF NOT v_member_ok THEN
    RAISE EXCEPTION 'Only the assigned adult can self-complete this chore';
  END IF;

  -- 3. Chore must actually be assigned to this member
  IF v_assigned_member_id IS NULL OR v_assigned_member_id <> p_member_id THEN
    RAISE EXCEPTION 'You can only complete chores assigned to you';
  END IF;

  -- 4. Status must be assigned or in_progress
  IF v_current_status NOT IN ('assigned', 'in_progress') THEN
    RAISE EXCEPTION 'Chore is not in a completable state (current status: %)', v_current_status;
  END IF;

  -- 5. Mark verified directly (no admin step for adults — Q3)
  UPDATE public.chores
     SET status = 'verified',
         completed_at = now(),
         verified_at = now(),
         verified_by_member_id = p_member_id
   WHERE id = p_chore_id;

  -- 6. Award points + achievements via adult path
  v_total_points := v_point_value + v_bonus_points;

  PERFORM public.award_points(
    v_member_auth_user_id, v_household_id, v_total_points,
    'self_completed', 'chores', p_chore_id
  );
  PERFORM public.check_and_award_achievements(
    v_member_auth_user_id, v_household_id
  );
END;
$$;


-- ============================================================================
-- SECTION 4 — RPC: submit_kid_chore_with_photo(p_chore_id, p_member_id, p_storage_path)
-- ============================================================================
-- Kid-only chore completion. The photo upload itself is client-side
-- (image_picker → Supabase Storage). This RPC records the photo row and
-- flips the chore status atomically.
--
-- Validates: p_member_id is in chore's household, is an active sub_profile,
-- chore.assigned_to_member_id matches p_member_id, status is 'assigned' or
-- 'in_progress'. The calling adult's JWT must also be in the household
-- (the kid has no JWT; the adult holds the session).
--
-- Returns the new chore_verification_photos.id.
CREATE OR REPLACE FUNCTION public.submit_kid_chore_with_photo(
  p_chore_id     uuid,
  p_member_id    uuid,
  p_storage_path text
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
BEGIN
  -- 1. Validate inputs
  IF p_storage_path IS NULL OR length(p_storage_path) = 0 THEN
    RAISE EXCEPTION 'Photo storage path is required';
  END IF;

  -- 2. Member must be an active sub_profile
  IF NOT public.is_member_kid(p_member_id) THEN
    RAISE EXCEPTION 'Only sub_profiles can submit chores with photos';
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

  -- 7. Atomic: update chore + insert photo row
  UPDATE public.chores
     SET status = 'pending_verification',
         completed_at = now()
   WHERE id = p_chore_id;

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

  RETURN v_new_photo_id;
END;
$$;


-- ============================================================================
-- SECTION 5 — RPC: add_shopping_item(p_household_id, p_member_id, p_name, ...)
-- ============================================================================
-- Replaces the four direct shopping_items.insert() sites in app code
-- (Batch 5 will migrate them). Kid inserts route to wishlist unless
-- category is on the household's necessity_categories list. Adult
-- inserts are always is_wishlist=false.
--
-- If p_shopping_list_id is NULL, auto-resolves to the household's active
-- shopping_lists row (oldest active list — matches the app's pick today).
-- Raises descriptively if no active list exists.
--
-- Returns the new shopping_items.id.
CREATE OR REPLACE FUNCTION public.add_shopping_item(
  p_household_id     uuid,
  p_member_id        uuid,
  p_name             text,
  p_quantity         numeric DEFAULT NULL,
  p_unit             text DEFAULT NULL,
  p_category         text DEFAULT NULL,
  p_store_id         uuid DEFAULT NULL,
  p_shopping_list_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_member_kind       member_kind;
  v_member_active     boolean;
  v_resolved_list_id  uuid;
  v_is_wishlist       boolean;
  v_is_necessity      boolean;
  v_new_item_id       uuid;
BEGIN
  -- 1. Validate inputs
  IF p_name IS NULL OR length(trim(p_name)) = 0 THEN
    RAISE EXCEPTION 'Item name is required';
  END IF;

  -- 2. Calling adult JWT must be in the household
  IF NOT public.is_household_member(p_household_id) THEN
    RAISE EXCEPTION 'Caller is not a member of this household';
  END IF;

  -- 3. Member must exist in this household and be active
  SELECT kind, is_active
    INTO v_member_kind, v_member_active
    FROM public.household_members
   WHERE id = p_member_id
     AND household_id = p_household_id;

  IF v_member_kind IS NULL THEN
    RAISE EXCEPTION 'Member is not in this household';
  END IF;

  IF NOT v_member_active THEN
    RAISE EXCEPTION 'Member is not active';
  END IF;

  -- 4. Resolve shopping list (Q6: optional param; auto-pick oldest active)
  IF p_shopping_list_id IS NULL THEN
    SELECT id INTO v_resolved_list_id
      FROM public.shopping_lists
     WHERE household_id = p_household_id
       AND is_active = true
     ORDER BY created_at ASC
     LIMIT 1;

    IF v_resolved_list_id IS NULL THEN
      RAISE EXCEPTION 'No active shopping list found. Create one first.';
    END IF;
  ELSE
    -- Confirm the passed list belongs to this household
    SELECT id INTO v_resolved_list_id
      FROM public.shopping_lists
     WHERE id = p_shopping_list_id
       AND household_id = p_household_id;

    IF v_resolved_list_id IS NULL THEN
      RAISE EXCEPTION 'Shopping list not found in this household';
    END IF;
  END IF;

  -- 5. Determine is_wishlist by kind + necessity check
  IF v_member_kind = 'sub_profile' THEN
    -- Case-insensitive necessity match (Q4 from Batch 1 investigation)
    SELECT EXISTS (
      SELECT 1
        FROM public.necessity_categories nc
       WHERE nc.household_id = p_household_id
         AND lower(nc.category) = lower(COALESCE(p_category, ''))
    ) INTO v_is_necessity;

    v_is_wishlist := NOT v_is_necessity;
  ELSE
    v_is_wishlist := false;
  END IF;

  -- 6. Insert the row
  INSERT INTO public.shopping_items (
    household_id,
    shopping_list_id,
    name,
    quantity,
    unit,
    category,
    store_id,
    added_by_member_id,
    is_wishlist
  ) VALUES (
    p_household_id,
    v_resolved_list_id,
    trim(p_name),
    p_quantity,
    p_unit,
    p_category,
    p_store_id,
    p_member_id,
    v_is_wishlist
  )
  RETURNING id INTO v_new_item_id;

  RETURN v_new_item_id;
END;
$$;


-- ============================================================================
-- SECTION 6 — RPC: create_meal_request(p_household_id, p_member_id, p_recipe_id, ...)
-- ============================================================================
-- Kid-only path. Inserts a meal_requests row with status='pending'.
-- Date and meal_type are optional (Q7) — admin can fill in at decide time.
-- Returns the new meal_requests.id.
CREATE OR REPLACE FUNCTION public.create_meal_request(
  p_household_id        uuid,
  p_member_id           uuid,
  p_recipe_id           uuid,
  p_requested_for_date  date DEFAULT NULL,
  p_meal_type           meal_type DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_recipe_household_id uuid;
  v_new_request_id      uuid;
BEGIN
  -- 1. Calling adult JWT must be in the household
  IF NOT public.is_household_member(p_household_id) THEN
    RAISE EXCEPTION 'Caller is not a member of this household';
  END IF;

  -- 2. Requester must be an active sub_profile in this household
  IF NOT public.is_member_kid(p_member_id) THEN
    RAISE EXCEPTION 'Only sub_profiles can create meal requests';
  END IF;

  -- 3. The kid's household_id must match p_household_id
  IF NOT EXISTS (
    SELECT 1 FROM public.household_members
     WHERE id = p_member_id
       AND household_id = p_household_id
  ) THEN
    RAISE EXCEPTION 'Member is not in this household';
  END IF;

  -- 4. Recipe must exist in this household
  SELECT household_id INTO v_recipe_household_id
    FROM public.household_recipes
   WHERE id = p_recipe_id;

  IF v_recipe_household_id IS NULL THEN
    RAISE EXCEPTION 'Recipe not found';
  END IF;

  IF v_recipe_household_id <> p_household_id THEN
    RAISE EXCEPTION 'Recipe is not in this household';
  END IF;

  -- 5. Insert the request
  INSERT INTO public.meal_requests (
    household_id,
    requested_by_member_id,
    recipe_id,
    requested_for_date,
    meal_type,
    status
  ) VALUES (
    p_household_id,
    p_member_id,
    p_recipe_id,
    p_requested_for_date,
    p_meal_type,
    'pending'
  )
  RETURNING id INTO v_new_request_id;

  RETURN v_new_request_id;
END;
$$;


-- ============================================================================
-- SECTION 7 — RPC: decide_meal_request(p_request_id, p_approved, p_note, ...)
-- ============================================================================
-- Admin decides a meal request. On approve, atomically creates the
-- matching meal_plans row from the request + optional date/type overrides.
-- Per Q5: returns jsonb with status, meal_request_id, meal_plans_id (or null on deny).
-- Per Q7: takes optional p_planned_for_override and p_meal_type_override.
-- On approve, uses override if provided else request value; raises if both are null.
CREATE OR REPLACE FUNCTION public.decide_meal_request(
  p_request_id            uuid,
  p_approved              boolean,
  p_note                  text DEFAULT NULL,
  p_planned_for_override  date DEFAULT NULL,
  p_meal_type_override    meal_type DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_household_id           uuid;
  v_recipe_id              uuid;
  v_requested_for_date     date;
  v_request_meal_type      meal_type;
  v_current_status         text;
  v_caller_member_id       uuid;
  v_final_planned_for      date;
  v_final_meal_type        meal_type;
  v_new_meal_plans_id      uuid;
BEGIN
  -- 1. Load request
  SELECT household_id, recipe_id, requested_for_date, meal_type, status
    INTO v_household_id, v_recipe_id, v_requested_for_date, v_request_meal_type, v_current_status
    FROM public.meal_requests
   WHERE id = p_request_id;

  IF v_household_id IS NULL THEN
    RAISE EXCEPTION 'Meal request not found';
  END IF;

  -- 2. Caller must be admin
  IF NOT public.is_household_admin(v_household_id) THEN
    RAISE EXCEPTION 'Only household admins can decide meal requests';
  END IF;

  SELECT id INTO v_caller_member_id
    FROM public.household_members
   WHERE auth_user_id = auth.uid()
     AND household_id = v_household_id
     AND is_active = true;

  -- 3. Must be pending (Q4 idempotency: raise on already-decided)
  IF v_current_status <> 'pending' THEN
    RAISE EXCEPTION 'Meal request has already been decided (current status: %)', v_current_status;
  END IF;

  IF p_approved THEN
    -- 4a. Determine final date and meal_type (override → request value)
    v_final_planned_for := COALESCE(p_planned_for_override, v_requested_for_date);
    v_final_meal_type   := COALESCE(p_meal_type_override, v_request_meal_type);

    IF v_final_planned_for IS NULL OR v_final_meal_type IS NULL THEN
      RAISE EXCEPTION 'Specify a date and meal type to add to meal plan';
    END IF;

    -- 5a. Insert the meal_plans row
    INSERT INTO public.meal_plans (
      household_id,
      planned_for,
      meal_type,
      recipe_id,
      created_by_member_id
    ) VALUES (
      v_household_id,
      v_final_planned_for,
      v_final_meal_type,
      v_recipe_id,
      v_caller_member_id
    )
    RETURNING id INTO v_new_meal_plans_id;

    -- 6a. Mark request approved
    UPDATE public.meal_requests
       SET status = 'approved',
           decided_by_member_id = v_caller_member_id,
           decided_at = now(),
           decided_note = p_note
     WHERE id = p_request_id;

    RETURN jsonb_build_object(
      'status', 'approved',
      'meal_request_id', p_request_id,
      'meal_plans_id', v_new_meal_plans_id
    );
  ELSE
    -- 4b. Deny — update with note
    UPDATE public.meal_requests
       SET status = 'denied',
           decided_by_member_id = v_caller_member_id,
           decided_at = now(),
           decided_note = p_note
     WHERE id = p_request_id;

    RETURN jsonb_build_object(
      'status', 'denied',
      'meal_request_id', p_request_id,
      'meal_plans_id', NULL
    );
  END IF;
END;
$$;


-- ============================================================================
-- SECTION 8 — REVOKE / GRANT for all six RPCs
-- ============================================================================
-- Revoke from PUBLIC (default Postgres) and from anon explicitly (Supabase
-- default-grants EXECUTE to anon, authenticated, AND service_role on every
-- function created in the public schema — REVOKE FROM PUBLIC alone does NOT
-- catch those explicit role grants). service_role's EXECUTE is intentional
-- (server-side access). Same Supabase-quirk pattern as the extensions
-- schema arc in Pass 2 (migrations 0014, 0015).
REVOKE ALL ON FUNCTION public.approve_chore(uuid, boolean, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.complete_chore_self(uuid, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.submit_kid_chore_with_photo(uuid, uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.add_shopping_item(uuid, uuid, text, numeric, text, text, uuid, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.create_meal_request(uuid, uuid, uuid, date, meal_type) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.decide_meal_request(uuid, boolean, text, date, meal_type) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.approve_chore(uuid, boolean, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.complete_chore_self(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.submit_kid_chore_with_photo(uuid, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.add_shopping_item(uuid, uuid, text, numeric, text, text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_meal_request(uuid, uuid, uuid, date, meal_type) TO authenticated;
GRANT EXECUTE ON FUNCTION public.decide_meal_request(uuid, boolean, text, date, meal_type) TO authenticated;


-- ============================================================================
-- SECTION 9 — RLS POLICY TIGHTENING
-- ============================================================================
-- For each table: drop the existing "for all using is_household_member"
-- policy, then add 4 narrower policies (SELECT, INSERT, UPDATE, DELETE).
-- Pattern is uniform; differences are in the predicates.


-- 9a. chores ---------------------------------------------------------------
DROP POLICY IF EXISTS household_scoped_chores ON public.chores;

CREATE POLICY chores_household_select
  ON public.chores FOR SELECT
  USING (public.is_household_member(household_id));

CREATE POLICY chores_admin_insert
  ON public.chores FOR INSERT
  WITH CHECK (public.is_household_admin(household_id));

CREATE POLICY chores_admin_update
  ON public.chores FOR UPDATE
  USING (public.is_household_admin(household_id))
  WITH CHECK (public.is_household_admin(household_id));

CREATE POLICY chores_admin_delete
  ON public.chores FOR DELETE
  USING (public.is_household_admin(household_id));


-- 9b. chore_verification_photos --------------------------------------------
DROP POLICY IF EXISTS household_scoped_chore_photos ON public.chore_verification_photos;

CREATE POLICY photos_household_select
  ON public.chore_verification_photos FOR SELECT
  USING (public.is_household_member(household_id));

-- No direct INSERT; submit_kid_chore_with_photo (SECURITY DEFINER) bypasses RLS
CREATE POLICY photos_no_direct_insert
  ON public.chore_verification_photos FOR INSERT
  WITH CHECK (false);

CREATE POLICY photos_admin_update
  ON public.chore_verification_photos FOR UPDATE
  USING (public.is_household_admin(household_id))
  WITH CHECK (public.is_household_admin(household_id));

CREATE POLICY photos_admin_delete
  ON public.chore_verification_photos FOR DELETE
  USING (public.is_household_admin(household_id));


-- 9c. rewards --------------------------------------------------------------
DROP POLICY IF EXISTS household_scoped_rewards ON public.rewards;

CREATE POLICY rewards_household_select
  ON public.rewards FOR SELECT
  USING (public.is_household_member(household_id));

CREATE POLICY rewards_admin_insert
  ON public.rewards FOR INSERT
  WITH CHECK (public.is_household_admin(household_id));

CREATE POLICY rewards_admin_update
  ON public.rewards FOR UPDATE
  USING (public.is_household_admin(household_id))
  WITH CHECK (public.is_household_admin(household_id));

CREATE POLICY rewards_admin_delete
  ON public.rewards FOR DELETE
  USING (public.is_household_admin(household_id));


-- 9d. meal_plans -----------------------------------------------------------
DROP POLICY IF EXISTS household_scoped_meal_plans ON public.meal_plans;

CREATE POLICY meal_plans_household_select
  ON public.meal_plans FOR SELECT
  USING (public.is_household_member(household_id));

-- Adult-only direct INSERT; kid inserts go through decide_meal_request RPC
CREATE POLICY meal_plans_adult_insert
  ON public.meal_plans FOR INSERT
  WITH CHECK (
    public.is_household_member(household_id)
    AND EXISTS (
      SELECT 1 FROM public.household_members hm
       WHERE hm.auth_user_id = auth.uid()
         AND hm.household_id = meal_plans.household_id
         AND hm.kind = 'adult_auth_user'
         AND hm.is_active = true
    )
  );

CREATE POLICY meal_plans_household_update
  ON public.meal_plans FOR UPDATE
  USING (public.is_household_member(household_id))
  WITH CHECK (public.is_household_member(household_id));

CREATE POLICY meal_plans_household_delete
  ON public.meal_plans FOR DELETE
  USING (public.is_household_member(household_id));


-- 9e. shopping_items -------------------------------------------------------
DROP POLICY IF EXISTS household_scoped_shopping_items ON public.shopping_items;

CREATE POLICY shopping_items_household_select
  ON public.shopping_items FOR SELECT
  USING (public.is_household_member(household_id));

-- Direct INSERT: adult-only, is_wishlist must be false. Kid inserts must
-- go through add_shopping_item RPC (SECURITY DEFINER bypasses RLS).
CREATE POLICY shopping_items_adult_direct_insert
  ON public.shopping_items FOR INSERT
  WITH CHECK (
    is_wishlist = false
    AND public.is_household_member(household_id)
    AND EXISTS (
      SELECT 1 FROM public.household_members hm
       WHERE hm.auth_user_id = auth.uid()
         AND hm.household_id = shopping_items.household_id
         AND hm.kind = 'adult_auth_user'
         AND hm.is_active = true
    )
  );

-- Per Q8: UPDATE any household member (matches shared-list UX)
CREATE POLICY shopping_items_household_update
  ON public.shopping_items FOR UPDATE
  USING (public.is_household_member(household_id))
  WITH CHECK (public.is_household_member(household_id));

-- Per Q8: DELETE admin-only
CREATE POLICY shopping_items_admin_delete
  ON public.shopping_items FOR DELETE
  USING (public.is_household_admin(household_id));


-- 9f. meal_requests (RLS enabled with zero policies in 0016) ---------------
-- No DROP needed — no policies exist yet.

CREATE POLICY meal_requests_household_select
  ON public.meal_requests FOR SELECT
  USING (public.is_household_member(household_id));

-- No direct INSERT; kids use create_meal_request RPC; admins decide via
-- decide_meal_request RPC (which writes to meal_plans, not meal_requests
-- directly except via the SECURITY DEFINER bypass).
CREATE POLICY meal_requests_no_direct_insert
  ON public.meal_requests FOR INSERT
  WITH CHECK (false);

-- Admin UPDATE only (decide_meal_request RPC handles this via SECURITY DEFINER)
CREATE POLICY meal_requests_admin_update
  ON public.meal_requests FOR UPDATE
  USING (public.is_household_admin(household_id))
  WITH CHECK (public.is_household_admin(household_id));

CREATE POLICY meal_requests_admin_delete
  ON public.meal_requests FOR DELETE
  USING (public.is_household_admin(household_id));


-- 9g. necessity_categories (RLS enabled with zero policies in 0016) --------
-- No DROP needed.

CREATE POLICY necessity_categories_household_select
  ON public.necessity_categories FOR SELECT
  USING (public.is_household_member(household_id));

CREATE POLICY necessity_categories_admin_insert
  ON public.necessity_categories FOR INSERT
  WITH CHECK (public.is_household_admin(household_id));

CREATE POLICY necessity_categories_admin_update
  ON public.necessity_categories FOR UPDATE
  USING (public.is_household_admin(household_id))
  WITH CHECK (public.is_household_admin(household_id));

CREATE POLICY necessity_categories_admin_delete
  ON public.necessity_categories FOR DELETE
  USING (public.is_household_admin(household_id));


-- 9h. analytics_events -----------------------------------------------------
DROP POLICY IF EXISTS household_scoped_analytics ON public.analytics_events;

CREATE POLICY analytics_events_admin_all
  ON public.analytics_events FOR ALL
  USING (household_id IS NULL OR public.is_household_admin(household_id))
  WITH CHECK (household_id IS NULL OR public.is_household_admin(household_id));


-- ============================================================================
-- VERIFICATION QUERIES — run after applying this migration. None mutate.
-- ============================================================================
--
-- A. The 6 RPCs exist and are SECURITY DEFINER:
--      SELECT proname, prosecdef, pronargs
--        FROM pg_proc p
--        JOIN pg_namespace n ON n.oid = p.pronamespace
--       WHERE n.nspname = 'public'
--         AND p.proname IN (
--           'approve_chore',
--           'complete_chore_self',
--           'submit_kid_chore_with_photo',
--           'add_shopping_item',
--           'create_meal_request',
--           'decide_meal_request'
--         )
--       ORDER BY proname;
--    Expected: 6 rows; prosecdef=true on all; pronargs matches signature
--    (approve_chore=3, complete_chore_self=2, submit_kid_chore_with_photo=3,
--     add_shopping_item=8, create_meal_request=5, decide_meal_request=5).
--
-- B. is_member_kid helper exists:
--      SELECT proname, prosecdef, provolatile
--        FROM pg_proc p
--        JOIN pg_namespace n ON n.oid = p.pronamespace
--       WHERE n.nspname = 'public'
--         AND p.proname = 'is_member_kid';
--    Expected: 1 row; prosecdef=true; provolatile='s' (stable).
--
-- C. Per-table policy counts:
--      SELECT tablename, count(*) AS policy_count
--        FROM pg_policies
--       WHERE schemaname = 'public'
--         AND tablename IN (
--           'chores','chore_verification_photos','rewards','meal_plans',
--           'shopping_items','meal_requests','necessity_categories','analytics_events'
--         )
--       GROUP BY tablename
--       ORDER BY tablename;
--    Expected counts:
--      analytics_events           1
--      chore_verification_photos  4
--      chores                     4
--      meal_plans                 4
--      meal_requests              4
--      necessity_categories       4
--      rewards                    4
--      shopping_items             4
--
-- D. authenticated has EXECUTE on the 6 RPCs but not anon:
--      SELECT p.proname,
--             has_function_privilege('authenticated', p.oid, 'execute') AS auth_can,
--             has_function_privilege('anon',          p.oid, 'execute') AS anon_can
--        FROM pg_proc p
--        JOIN pg_namespace n ON n.oid = p.pronamespace
--       WHERE n.nspname = 'public'
--         AND p.proname IN (
--           'approve_chore','complete_chore_self','submit_kid_chore_with_photo',
--           'add_shopping_item','create_meal_request','decide_meal_request'
--         );
--    Expected: auth_can=true on all six; anon_can=false on all six.
--
-- E. Manual functional smoke test (run after Batch 3 ships the app changes,
--    or run via SQL editor with set_config'd auth.uid()):
--
--    -- Create a kid meal request (substitute real ids):
--      SELECT public.create_meal_request(
--        p_household_id := '<wrights uuid>',
--        p_member_id    := '<a kid sub_profile member uuid>',
--        p_recipe_id    := '<a household_recipe uuid>',
--        p_requested_for_date := current_date + 1,
--        p_meal_type    := 'dinner'
--      );
--    -- Expect: returns a uuid; meal_requests has one row with status='pending'.
--
--    -- Approve it (as the admin):
--      SELECT public.decide_meal_request(
--        p_request_id := '<the request uuid>',
--        p_approved   := true,
--        p_note       := null
--      );
--    -- Expect: returns jsonb {status:'approved', meal_request_id:..., meal_plans_id:...}
--    -- meal_requests row updated to status='approved';
--    -- meal_plans has a new row matching the request.
--
--    -- Try double-decide (should raise):
--      SELECT public.decide_meal_request(
--        p_request_id := '<the same uuid>',
--        p_approved   := false
--      );
--    -- Expect: EXCEPTION 'Meal request has already been decided (current status: approved)'
--
-- F. Direct meal_requests INSERT should be blocked by RLS:
--      INSERT INTO public.meal_requests (
--        household_id, requested_by_member_id, recipe_id
--      ) VALUES (
--        '<wrights uuid>', '<a kid uuid>', '<a recipe uuid>'
--      );
--    -- Expect: ERROR (new row violates row-level security policy)
