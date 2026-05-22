# Kid Permissions Batch 2 (migration 0017) — Investigation

Date: 2026-05-22
Branch: `feat/kid-perms-rls-rpcs-batch-2-2026-05-22` (read-only investigation; no edits, no commits)
Spec reference: `/audits/2026-05-kid-profile-permissions-spec.md` (Batch plan row 2)
Status: investigation complete — open questions and risk flags below

## Summary

Batch 2 is the heaviest of the workstream: it adds the 5 SECURITY DEFINER RPCs that the spec calls for, plus tightens RLS on 8 tables. Most of the RPCs are straightforward, but two themes need user decisions before SQL is written:

1. **Status semantics on chore rejection** — the spec says reject sets `status='rejected'`; the existing `_verifyChore` code sets `status='assigned'` (so the kid can re-try). One of those has to win. Reading the chore_status enum, `'rejected'` exists — both are valid; choose the UX.

2. **App-code coupling.** Tightening RLS on `chores`, `shopping_items`, `chore_verification_photos`, `meal_plans` lands *before* the app code (Batch 3+) migrates to call the RPCs. For three of those tables, current adult code paths still work after tightening (admins can still UPDATE chores directly, can still INSERT shopping items directly with `is_wishlist=false`). For one — `chore_verification_photos` — there's no current writer, so no break. The one risk: any kid-attributable insert path that exists today silently breaks. Investigation found no such kid-attributable paths in current Dart code (kids never insert directly), so the risk is low.

The 5 RPCs and `is_member_kid()` helper are well-defined. Eight open questions for the user are at Phase 8.

## Phase 1 — Spec confirmation

Batch 2 row from spec line 114, verbatim:

> **2** — Migration 0017 (RLS): tighten chores verify, chore_verification_photos inserts, rewards CRUD, meal_plans kid-insert block, shopping_items wishlist enforcement, meal_requests policies, necessity_categories policies, analytics defense. Plus SECURITY DEFINER RPCs: `approve_chore`, `add_shopping_item`, `submit_kid_chore_with_photo`, `create_meal_request`, `decide_meal_request`. Complexity: Medium (many policies + RPCs, careful testing). Dependencies: Batch 1.

RLS implementation notes from spec lines 71–83 (verbatim):

> Almost every existing table policy is `for all using is_household_member(household_id)` — too permissive for the kid model. The tightening:
>
> - New helper function `public.is_household_kid(target_household_id uuid)` returning boolean, mirroring `is_household_member` and `is_household_admin`.
> - `chores`: verify/approve actions move behind a SECURITY DEFINER RPC `approve_chore(p_chore_id, p_approved, p_reason)` that checks caller is `is_household_admin`. RLS for UPDATE tightened to admin-only on the `status` column path.
> - `chore_verification_photos`: kid INSERT must reference their own member_id; admin UPDATE allowed for `rejected_reason`; SELECT remains household-scoped.
> - `rewards`: SELECT remains household-scoped; INSERT/UPDATE/DELETE admin-only.
> - `meal_plans`: kid INSERT blocked. Kid inserts go through `meal_requests`; admin-approved requests are inserted into `meal_plans` by the approve RPC.
> - `shopping_items`: kid INSERT goes through SECURITY DEFINER RPC `add_shopping_item(p_household_id, p_member_id, p_name, p_category, ...)` that sets `is_wishlist=true` unless `category` is in `necessity_categories` for the household. Adult INSERT can stay direct (RLS `WITH CHECK` ensures adult-only direct insert with `is_wishlist=false`).
> - `meal_requests`: kids INSERT their own; SELECT own + same-household; admins SELECT all and UPDATE to decide.
> - `necessity_categories`: SELECT household-scoped (kids need to know which categories bypass wishlist); INSERT/UPDATE/DELETE admin-only.
> - `analytics_events`: tighten to admin-only as defense-in-depth (Disallowed #8).

**Deviation from spec** (already agreed during Batch 1 investigation): `is_household_kid(target_household_id)` is architecturally impossible because sub_profiles have `auth_user_id IS NULL`. The realistic helper is `is_member_kid(p_member_id uuid)` — different signature, used inside the RPCs.

Plus the user's brief adds:
- The `is_member_kid(p_member_id uuid)` helper
- All five RPCs with the exact signatures listed in the brief's Phase 3

## Phase 2 — Existing RLS inventory

All 8 affected tables currently have the **same** policy: `for all using is_household_member(household_id)`. From 0001:521–536:

| Table | Current policy | Source line |
|---|---|---|
| `chores` | `for all using is_household_member(household_id)` | 521 |
| `chore_verification_photos` | `for all using is_household_member(household_id)` | 522 |
| `rewards` | `for all using is_household_member(household_id)` | 524 |
| `meal_plans` | `for all using is_household_member(household_id)` | 531 |
| `shopping_items` | `for all using is_household_member(household_id)` | 534 |
| `meal_requests` (new in 0016) | RLS enabled, no policies (defense in depth) | 0016:182 |
| `necessity_categories` (new in 0016) | RLS enabled, no policies (defense in depth) | 0016:83 |
| `analytics_events` | `for all using (household_id is null or is_household_member(household_id))` | 536 |

No policies were added in migrations 0002–0015 for any of these tables. The `for all` policy means SELECT, INSERT, UPDATE, DELETE are all governed by the same household-membership check — kid acting via adult's session passes, since the adult IS a household member.

## Phase 3 — 5 RPC signatures with full pseudocode

All five follow the Pass 2 PIN pattern: `SECURITY DEFINER`, `SET search_path = public`, take `p_member_id` for kid-attributable writes, validate caller is in same household, raise descriptive errors. None of these RPCs need pgcrypto (no extension-schema qualification needed).

### 3a. `approve_chore(p_chore_id uuid, p_approved boolean, p_reason text DEFAULT NULL) → void`

Centralizes the chore approve/reject flow that today lives in `chore_dashboard_screen.dart:_verifyChore` (lines 192–262). Internally branches on the assigned member's kind to call the correct points/achievements RPC, mirroring existing app logic.

**Validation:**
1. `p_chore_id` must exist; lookup `(household_id, assigned_to_member_id, status, point_value, bonus_points)`.
2. Caller must be admin of that household — `is_household_admin(v_household_id)` returns true.
3. Status must be `'pending_verification'`. If not — raise `'Chore is not pending verification'` (idempotency: re-approving a verified chore is rejected, see Open Question 4).

**Behavior on approve (p_approved = true):**
1. UPDATE chores SET status='verified', verified_at=now(), verified_by_member_id=<caller's member row id>.
2. Look up `assigned_member.kind, auth_user_id`.
3. Branch:
   - `'sub_profile'`: call `award_points_to_member(p_member_id, p_household_id, total_points, 'chore_completion', 'chores', p_chore_id)` + `check_and_award_achievements_for_member(p_member_id, p_household_id)`.
   - `'adult_auth_user'`: call `award_points(p_auth_user_id, p_household_id, total_points, 'chore_completion', 'chores', p_chore_id)` + `check_and_award_achievements(p_auth_user_id, p_household_id)`.
4. `total_points = point_value + COALESCE(bonus_points, 0)`.
5. Mark any `chore_verification_photos` rows for this chore: `delete_after = now() + interval '30 days'` (so the future cron picks them up).

**Behavior on reject (p_approved = false):**
- **DECISION NEEDED (Open Q1):** spec says `status='rejected'`; existing `_verifyChore` says `status='assigned'`. The spec semantics + `chores.rejected_reason` field suggest the spec wins for the new flow, but UX-wise putting the chore back to `'assigned'` is friendlier — the kid can re-try without admin re-creating it.
- Suggest: `status='rejected'`, save `p_reason` to `chores.rejected_reason`, also bump `delete_after` on photo rows the same way. UI in Batch 4/7 surfaces a "Re-do" affordance that flips `'rejected'` → `'assigned'` if the admin wants to give a retry.

**Return:** `void`. App re-queries chores after.

**Pseudocode:**

```sql
CREATE OR REPLACE FUNCTION public.approve_chore(
  p_chore_id uuid,
  p_approved boolean,
  p_reason text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_household_id uuid;
  v_assigned_member_id uuid;
  v_assigned_kind member_kind;
  v_assigned_auth_user_id uuid;
  v_current_status chore_status;
  v_point_value int;
  v_bonus_points int;
  v_total_points int;
  v_caller_member_id uuid;
BEGIN
  -- 1. Load chore
  SELECT household_id, assigned_to_member_id, status, point_value, bonus_points
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

  -- Need the caller's member_id for verified_by_member_id
  SELECT id INTO v_caller_member_id
    FROM public.household_members
   WHERE auth_user_id = auth.uid()
     AND household_id = v_household_id
     AND is_active = true;

  -- 3. Must be pending
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

    -- 5a. Award points (branch on assignee kind)
    SELECT kind, auth_user_id
      INTO v_assigned_kind, v_assigned_auth_user_id
      FROM public.household_members
     WHERE id = v_assigned_member_id;

    v_total_points := v_point_value + COALESCE(v_bonus_points, 0);

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
  ELSE
    -- 4b. Reject — status='rejected' per spec, save reason
    UPDATE public.chores
       SET status = 'rejected',
           rejected_reason = p_reason,
           verified_by_member_id = v_caller_member_id  -- audit trail
     WHERE id = p_chore_id;
  END IF;

  -- 6. Schedule any verification photos for cleanup in 30 days
  UPDATE public.chore_verification_photos
     SET delete_after = now() + interval '30 days'
   WHERE chore_id = p_chore_id
     AND delete_after IS NULL;
END;
$$;
```

### 3b. `add_shopping_item(p_household_id uuid, p_member_id uuid, p_name text, p_quantity numeric DEFAULT NULL, p_unit text DEFAULT NULL, p_category text DEFAULT NULL, p_store_id uuid DEFAULT NULL, p_shopping_list_id uuid DEFAULT NULL) → uuid`

Replaces the 4 direct `.insert()` sites on `shopping_items` (Batch 5 migrates the app). Routes kid inserts to wishlist unless the category is a necessity for that household.

**Validation:**
1. `p_member_id` must be an active member of `p_household_id`. Otherwise raise `'Member not in household'`.
2. The calling adult's JWT (`auth.uid()`) must also be in the household — verify via the existing `is_household_member` helper (this prevents an adult from being tricked into adding items to a household they don't belong to).
3. `p_name` non-empty.
4. If `p_shopping_list_id` is null: find the household's default `shopping_lists` row (the active one) and use that. Otherwise verify it belongs to `p_household_id`.

**Behavior:**
1. Look up `p_member_id`'s `kind`.
2. If `kind = 'sub_profile'`:
   - Compare `lower(p_category)` against `lower(necessity_categories.category)` for `p_household_id`.
   - If the category is on the necessity list (case-insensitive match): `v_is_wishlist := false` — direct add.
   - Otherwise: `v_is_wishlist := true` — kid wishlist, pending admin approval.
3. If `kind = 'adult_auth_user'`: `v_is_wishlist := false` always.
4. INSERT into shopping_items with `is_wishlist := v_is_wishlist`, `added_by_member_id := p_member_id`, all the other params.
5. Return the new row's `id`.

**Return:** `uuid` (the new shopping_item id) — useful for optimistic UI updates in Batch 5.

### 3c. `submit_kid_chore_with_photo(p_chore_id uuid, p_member_id uuid, p_storage_path text) → uuid`

Kid-only chore completion. The actual photo upload is client-side (image_picker → Supabase Storage). This RPC just records the photo + flips the chore status atomically.

**Validation:**
1. `p_chore_id` must exist; lookup `(household_id, assigned_to_member_id, status, requires_photo)`.
2. `p_member_id` must be an active sub_profile in the chore's household — raise if any of those fail.
3. `chores.assigned_to_member_id` must equal `p_member_id` (kid can only submit their own chores) — raise `'You can only submit your own chores'` otherwise.
4. Calling adult JWT must be in the household.
5. `p_storage_path` non-empty.
6. Chore status must be `'assigned'` or `'in_progress'` — raise if already submitted/verified/rejected.

**Behavior:**
1. UPDATE chores SET status='pending_verification', completed_at=now().
2. INSERT into chore_verification_photos: `(chore_id, household_id, uploaded_by_member_id, storage_path)`. `delete_after` stays NULL until approve_chore sets it.
3. Return the new photo row's `id`.

**Adult symmetry:** there is no `submit_adult_chore_with_photo`. Adults use the existing direct UPDATE in `_completeChore` (no photo required). Spec Decision 6/Q-A makes this asymmetric on purpose — kids require photo, adults don't.

### 3d. `create_meal_request(p_household_id uuid, p_member_id uuid, p_recipe_id uuid, p_requested_for_date date DEFAULT NULL, p_meal_type meal_type DEFAULT NULL) → uuid`

Kid-only meal request creation.

**Validation:**
1. `p_member_id` active sub_profile in `p_household_id`.
2. Calling adult JWT must be in the household.
3. `p_recipe_id` must exist in `household_recipes` AND belong to `p_household_id` (cross-household recipe-poaching prevention).

**Behavior:**
1. INSERT into meal_requests `(household_id, requested_by_member_id, recipe_id, requested_for_date, meal_type, status='pending')`.
2. Return the new row's `id`.

**Return:** `uuid`.

### 3e. `decide_meal_request(p_request_id uuid, p_approved boolean, p_note text DEFAULT NULL) → uuid`

Admin decides a meal request. On approve, creates the matching `meal_plans` row atomically.

**Validation:**
1. `p_request_id` must exist; lookup `(household_id, recipe_id, requested_for_date, meal_type, status)`.
2. Caller must be admin of the household.
3. `status` must be `'pending'` — raise if already decided. (See Open Q4 on idempotency.)
4. `requested_for_date` and `meal_type` may be null. If approve and either is null, raise (admin should backfill in the UI before approving) — or accept null and create a meal_plans row with the same nulls (depends on meal_plans schema; both columns are NOT NULL in 0001:285-286, so we must require both before approve).

**Behavior:**
1. Need the caller's member_id for `decided_by_member_id`.
2. If `p_approved`:
   - UPDATE meal_requests SET status='approved', decided_by_member_id=v_caller, decided_at=now(), decided_note=p_note.
   - INSERT into meal_plans `(household_id, planned_for, meal_type, recipe_id, created_by_member_id)` using request's values.
3. If not `p_approved`:
   - UPDATE meal_requests SET status='denied', decided_by_member_id, decided_at, decided_note.
4. Return the new `meal_plans.id` if approved, OR `p_request_id` if denied. App uses the result to navigate.

**Return:** `uuid` (newly-created meal_plans id on approve; the original meal_request id on deny — slightly confusing; alternative is `void` and let the caller re-query). See Open Q5.

## Phase 4 — RLS policy proposals per table

For each table: existing policy → drop → re-add tighter. Plus a per-table app-code impact assessment.

### 4a. `chores`

**Drop:** `household_scoped_chores` (0001:521).

**New policies:**
```sql
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
```

**App-code impact:**

| Site | Operation | Caller role today | Survives Batch 2? |
|---|---|---|---|
| `chore_dashboard_screen.dart:132` (`_completeChore`) | UPDATE chores SET status='pending_verification' | adult member (any role) | **BREAKS for non-admin adults** — see Open Q3. Today's UI lets adults complete their own chores. Tightening to admin-only blocks that. |
| `chore_dashboard_screen.dart:189, 718` (chore creation) | INSERT chores | admin (UI gated) | ✓ |
| `chore_dashboard_screen.dart:199, 251` (`_verifyChore`) | UPDATE chores | admin (UI gated) | ✓, but should migrate to `approve_chore` RPC in Batch 3 for consistency |
| `chore_detail_screen.dart:196, 880` (UPDATE) | UPDATE chores | admin or assignee (canEdit gate) | **BREAKS for assignee-but-not-admin** — same as `_completeChore`. |
| `chore_detail_screen.dart:243` (DELETE) | DELETE chores | admin (gated) | ✓ |
| `chore_detail_screen.dart:946` (INSERT recurring next) | INSERT chores | admin (via `_verifyChore` flow) | ✓ |
| `chore_templates_screen.dart:130` (INSERT) | INSERT chores | admin (UI gated) | ✓ |

**Risk:** non-admin adult completing their own chore breaks under strict admin-only UPDATE. Options:
- Loosen: allow UPDATE if `is_household_admin` OR `assigned_to_member_id = caller's member_id`.
- Funnel adult self-complete through a new `complete_chore` RPC (no photo) — symmetric to `submit_kid_chore_with_photo`.

See Open Q3.

### 4b. `chore_verification_photos`

**Drop:** `household_scoped_chore_photos` (0001:522).

**New policies:**
```sql
CREATE POLICY photos_household_select
  ON public.chore_verification_photos FOR SELECT
  USING (public.is_household_member(household_id));

-- No direct INSERT; all writes go through submit_kid_chore_with_photo (SECURITY DEFINER bypasses RLS)
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
```

**App-code impact:** **zero** — no current app code writes this table.

### 4c. `rewards`

**Drop:** `household_scoped_rewards` (0001:524).

**New policies:**
```sql
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
```

**App-code impact:**

| Site | Operation | Caller role today | Survives? |
|---|---|---|---|
| `rewards_screen.dart:360, 445` (INSERT) | INSERT rewards | admin (UI gated) | ✓ |
| (no UPDATE or DELETE in app) | — | — | — |

Defense-in-depth tightening; zero behavior change.

### 4d. `meal_plans`

**Drop:** `household_scoped_meal_plans` (0001:531).

**New policies:**
```sql
CREATE POLICY meal_plans_household_select
  ON public.meal_plans FOR SELECT
  USING (public.is_household_member(household_id));

-- Adult-only direct INSERT; kid inserts must go through decide_meal_request RPC
CREATE POLICY meal_plans_adult_insert
  ON public.meal_plans FOR INSERT
  WITH CHECK (
    public.is_household_member(household_id)
    AND EXISTS (
      SELECT 1 FROM public.household_members hm
      WHERE hm.auth_user_id = auth.uid()
        AND hm.household_id = meal_plans.household_id
        AND hm.kind = 'adult_auth_user'
    )
  );

CREATE POLICY meal_plans_household_update
  ON public.meal_plans FOR UPDATE
  USING (public.is_household_member(household_id))
  WITH CHECK (public.is_household_member(household_id));

CREATE POLICY meal_plans_household_delete
  ON public.meal_plans FOR DELETE
  USING (public.is_household_member(household_id));
```

**App-code impact:**

| Site | Operation | Caller role today | Survives? |
|---|---|---|---|
| `meal_planner_screen.dart:650` (INSERT) | INSERT meal_plans | adult member | ✓ (only adults have direct sessions) |
| `recipe_detail_screen.dart:349` (INSERT) | INSERT meal_plans | adult member | ✓ |

Both are adult-initiated today (kid switcher exists but kid recipe library doesn't have an "Add to meal plan" affordance — only "Request this meal" in Batch 6). Defense-in-depth.

### 4e. `shopping_items`

**Drop:** `household_scoped_shopping_items` (0001:534).

**New policies:**
```sql
CREATE POLICY shopping_items_household_select
  ON public.shopping_items FOR SELECT
  USING (public.is_household_member(household_id));

-- Direct INSERT: adult-only, and is_wishlist must be false.
-- Kid inserts must go through add_shopping_item RPC.
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
    )
  );

CREATE POLICY shopping_items_household_update
  ON public.shopping_items FOR UPDATE
  USING (public.is_household_member(household_id))
  WITH CHECK (public.is_household_member(household_id));

CREATE POLICY shopping_items_household_delete
  ON public.shopping_items FOR DELETE
  USING (public.is_household_member(household_id));
```

**App-code impact:**

| Site | Operation | Caller role today | Survives? |
|---|---|---|---|
| `shopping_list_screen.dart:805, 1081` (INSERT) | INSERT shopping_items | adult or kid via adult JWT | **OK for adult**; today no kid path inserts (kids can't add today) |
| `meal_planner_screen.dart:712` (INSERT from recipe → shopping list) | INSERT shopping_items | adult | ✓ |
| `recipe_detail_screen.dart:266` (INSERT) | INSERT shopping_items | adult | ✓ |
| `shopping_list_screen.dart` (UPDATE for purchased, DELETE) | UPDATE/DELETE | adult | ✓ |

**Risk note:** Batch 5 migrates kid-add to `add_shopping_item` RPC. Between Batch 2 and Batch 5, no kid can add — but kids can't add today anyway. No regression.

### 4f. `meal_requests` (new table from 0016)

```sql
CREATE POLICY meal_requests_household_select
  ON public.meal_requests FOR SELECT
  USING (public.is_household_member(household_id));

-- No direct INSERT; kids use create_meal_request RPC, admins create via decide_meal_request → meal_plans path
CREATE POLICY meal_requests_no_direct_insert
  ON public.meal_requests FOR INSERT
  WITH CHECK (false);

-- Admin can UPDATE to decide (status, decided_by, decided_at, decided_note)
CREATE POLICY meal_requests_admin_update
  ON public.meal_requests FOR UPDATE
  USING (public.is_household_admin(household_id))
  WITH CHECK (public.is_household_admin(household_id));

CREATE POLICY meal_requests_admin_delete
  ON public.meal_requests FOR DELETE
  USING (public.is_household_admin(household_id));
```

**App-code impact:** **zero** — new table.

### 4g. `necessity_categories` (new table from 0016)

```sql
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
```

**App-code impact:** **zero** — new table.

### 4h. `analytics_events`

**Drop:** `household_scoped_analytics` (0001:536).

**New policy:**
```sql
CREATE POLICY analytics_events_admin_all
  ON public.analytics_events FOR ALL
  USING (household_id IS NULL OR public.is_household_admin(household_id))
  WITH CHECK (household_id IS NULL OR public.is_household_admin(household_id));
```

**App-code impact:** **zero** — no app code reads or writes `analytics_events` today (confirmed via grep).

## Phase 5 — `is_member_kid()` helper

Renamed from the broken `is_household_kid`. Takes `p_member_id` instead of `target_household_id`, used inside the RPCs above.

```sql
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
```

Mirrors the shape of `is_household_member` / `is_household_admin` (sql language, stable, security definer). Returns true only for active sub_profile rows.

Used by `add_shopping_item` (to branch on kind), `submit_kid_chore_with_photo` (to verify the submitting member is a kid), `create_meal_request` (same). Not used by `approve_chore` or `decide_meal_request` (those check `is_household_admin` instead).

## Phase 6 — Supabase quirk precautions

Apply lessons from the Pass 2 PIN debugging arc to all of Batch 2:

1. **`SET search_path = public`** on every SECURITY DEFINER function — done in all 5 RPCs + `is_member_kid` helper. Prevents search-path injection attacks against the elevated definer.

2. **No pgcrypto in Batch 2.** None of the RPCs need `gen_salt` or `crypt`. The schema-qualification issue that bit us in Pass 2 doesn't recur here. But: if any future RPC uses pgcrypto, fully qualify as `extensions.crypt(...)`.

3. **Explicit type casts.** None of the RPCs pass untyped string literals to overloaded functions in this batch — but the regex `!~ '^[0-9]+$'` style from Pass 2 isn't used here either. If we end up needing `enum_string_compare`, cast explicitly.

4. **REVOKE ALL FROM PUBLIC + GRANT EXECUTE TO authenticated** on every RPC. Default Postgres grants EXECUTE TO PUBLIC; we must revoke and grant explicitly. Pattern (used in 0013, 0015):

```sql
REVOKE ALL ON FUNCTION public.approve_chore(uuid, boolean, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.add_shopping_item(uuid, uuid, text, numeric, text, text, uuid, uuid) FROM PUBLIC;
-- etc. for all 5

GRANT EXECUTE ON FUNCTION public.approve_chore(uuid, boolean, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.add_shopping_item(uuid, uuid, text, numeric, text, text, uuid, uuid) TO authenticated;
-- etc.
```

5. **`is_member_kid` helper grant:** following the existing `is_household_member` pattern, the helper does NOT need explicit REVOKE/GRANT — it's `STABLE` and used only from within other SECURITY DEFINER functions. The existing two helpers at 0001:456–477 don't have explicit grants either.

6. **Error messages should reveal cause but not leak data.** "Chore not found" is OK; "Chore not found (chore_id=<uuid>)" exposes the UUID and is fine for an authenticated caller but rises in concern if logs leak. Keep messages descriptive but generic.

7. **No silent catches in Dart (Batch 3 lesson, not Batch 2).** When Batch 3+ ports `_verifyChore` to call `approve_chore`, the catch block must interpolate `$e` and `debugPrint`, not use `const SnackBar`. (This is the Pass 2 Fix 1 pattern; the codebase still has `catch (_)` antipattern in many places.)

8. **RPC parameter ordering** is positional in the wire protocol. Once published, changing parameter order is a breaking change. Use named-args in PostgREST calls (`rpc('name', params: {…})` in supabase_flutter does this) for forward compatibility.

## Phase 7 — Proposed migration file structure

Working title: `supabase/migrations/0017_kid_perms_rls_rpcs.sql`.

Statement order:

```
1. Helper: is_member_kid(p_member_id)                       [no deps]
2. RPC: approve_chore                                        [uses is_household_admin, award_points*, check_and_award_achievements*]
3. RPC: add_shopping_item                                    [uses necessity_categories table, household_members]
4. RPC: submit_kid_chore_with_photo                          [uses chores, chore_verification_photos]
5. RPC: create_meal_request                                  [uses household_recipes, meal_requests]
6. RPC: decide_meal_request                                  [uses meal_requests, meal_plans]
7. REVOKE ALL FROM PUBLIC on all 5 RPCs
8. GRANT EXECUTE TO authenticated on all 5 RPCs
9. RLS policies — chores: drop old, add 4 new (SELECT, INSERT, UPDATE, DELETE)
10. RLS policies — chore_verification_photos: drop old, add 4 new
11. RLS policies — rewards: drop old, add 4 new
12. RLS policies — meal_plans: drop old, add 4 new
13. RLS policies — shopping_items: drop old, add 4 new
14. RLS policies — meal_requests: add 4 (no drop; table created in 0016 with zero policies)
15. RLS policies — necessity_categories: add 4 (no drop)
16. RLS policies — analytics_events: drop old, add 1 new (FOR ALL admin)
17. Verification queries (in comments at bottom)
```

Idempotency:
- All function CREATE OR REPLACE
- All policies: `DROP POLICY IF EXISTS <name> ON <table>;` before each `CREATE POLICY`
- REVOKE/GRANT idempotent (no-op if already in the desired state)

Migration is ~400–500 lines depending on policy verbosity. Should be split into logical blocks with section headers, similar to 0016.

## Phase 8 — Open questions for user

These are the calls we need before SQL is written.

**Q1. Reject status: `'rejected'` (spec) or `'assigned'` (current code)?**
Current `_verifyChore` sets `status='assigned'` and clears `completed_at` so the kid can re-attempt. Spec says `'rejected'`. Both are valid `chore_status` enum values. Recommend: **spec wins** — use `'rejected'`, save `rejected_reason`. The retry UX becomes a separate "Re-do" button in Batch 4 admin UI that flips `'rejected'` → `'assigned'` (or a new `complete_again` RPC).

**Q2. Should `approve_chore` also call `check_and_award_achievements*`?**
Current `_verifyChore` does. Yes, recommend the RPC does the same. Documented in the pseudocode above.

**Q3. Non-admin adult completing their own chore — keep or block?**
Current chore-complete (`chore_dashboard:_completeChore` at line 130–145) lets any household member set `status='pending_verification'`. After tightening RLS to admin-only UPDATE on chores, only admins can mark their own chore complete directly. Two ways to keep the behavior:
- (a) Loosen the UPDATE policy: `USING (is_household_admin(household_id) OR assigned_to_member_id IN (SELECT id FROM household_members WHERE auth_user_id = auth.uid()))`.
- (b) Add a `complete_chore_self(p_chore_id)` RPC that bypasses the policy via SECURITY DEFINER.

Recommend (b) for consistency with the kid path. Six-line RPC.

**Q4. RPC idempotency on double-decide.**
- `approve_chore` called twice on the same chore — second call sees `status='verified'` and raises (per pseudocode). Same for `decide_meal_request` on already-decided request.
- Alternative: silently no-op on second call (return success).
- Recommend: **raise on second call.** Double-tap is usually a UI bug; raising surfaces it. Catch in Dart with a friendly message.

**Q5. `decide_meal_request` return value: `meal_plans.id` on approve vs `meal_requests.id` on deny.**
Asymmetric return is awkward. Three options:
- Return `meal_plans.id` on approve, NULL on deny.
- Return `meal_requests.id` always (caller re-queries).
- Return `void`, caller re-queries.

Recommend the first — gives the approve path enough info for navigation; NULL signals deny.

**Q6. `add_shopping_item.p_shopping_list_id` — required or auto-detect?**
The current `shopping_items` schema requires a `shopping_list_id` (FK NOT NULL). Today the app picks the household's active list. The RPC could either accept it as a required param or look it up internally. Recommend: optional param; if null, look up the active `shopping_lists` row for the household and use it. Less work for callers, more sensible default.

**Q7. `meal_requests` requested_for_date and meal_type — required at request time, or at decide time?**
Schema (0016) made both nullable. The spec's flow says the kid taps "Request this meal" on a recipe — they may not specify a date or meal type. The admin's `decide_meal_request` needs them to be set before INSERT into `meal_plans` (NOT NULL in 0001).

Options:
- (a) Require at request time. Kid UI prompts for date + meal type. Decide step just creates meal_plans directly.
- (b) Optional at request time. Decide UI lets admin fill them in before approving. Approve RPC takes optional `p_planned_for`, `p_meal_type` overrides.

Recommend (b) — kid friction matters more than admin friction. Admin can fill in missing values during approval.

This affects the `decide_meal_request` signature; needs to take `p_planned_for_override` and `p_meal_type_override` params (with reasonable null-handling: error if both request and override are null on approve).

**Q8. shopping_items existing UPDATE rules.**
Today UPDATE is used for: marking purchased (`purchased = true`), editing quantity/name, deleting items. After tightening should be:
- Any household member can UPDATE the row (consistent with today).
- OR only the adder can update; admin can update everything.

Recommend the first — least disruption, consistent with shared-list UX.

## Next steps

1. **You answer the 8 open questions above** (most have a clear recommendation; Q1, Q3, Q5, Q7 are the consequential ones).

2. **Once decided, I write `0017_kid_perms_rls_rpcs.sql`** following the structure in Phase 7 with the agreed-upon RPC signatures and policies. Estimated 400–500 lines.

3. **Apply 0017 to Supabase** — paste into SQL editor, watch for errors. Test each RPC manually from the SQL editor with realistic args. Test RLS denial paths (try inserting into a meal_requests row as a non-RPC caller, expect failure).

4. **Commit 0017 + this investigation** on `feat/kid-perms-rls-rpcs-batch-2-2026-05-22`. Push.

5. **Schedule Batch 3** (permissions helper) as the next workstream. The role-gate migration from 14 direct `role == 'admin'` checks to `apps/mobile/lib/utils/permissions.dart` helpers. Independent of any RPC migration, so it can land in any order.

6. **Eventually migrate app code to use the RPCs** (Batches 4/5/6). Until then, the new RPCs are unused but harmless. The tightened RLS is the operative change — adult flows continue to work, kid-attributable direct writes (which don't exist today) are blocked.
