# Kid Permissions Batch 2 (migration 0017) — Implementation

Date: 2026-05-22
Branch: `feat/kid-perms-rls-rpcs-batch-2-2026-05-22` (working-tree only; no commits)
Migration introduced: `supabase/migrations/0017_kid_perms_rls_rpcs.sql` (1023 lines)
Status: code complete — **migration not yet applied to Supabase, not committed**

## Summary

Migration 0017 is written and ready for review. It implements all 8 resolved decisions from the Batch 2 investigation:

- New helper function `is_member_kid(p_member_id uuid)`
- 6 SECURITY DEFINER RPCs (one more than the investigation proposed, per Q3 decision: `complete_chore_self`)
- RLS tightening on all 8 tables (drop the existing `for all using is_household_member` policy on 6 of them; add 4 narrower policies per table; meal_requests and necessity_categories had no policies yet from 0016)
- REVOKE PUBLIC + GRANT authenticated on every RPC
- Verification queries at the bottom for post-apply confirmation

No Dart code touched. No other migration files modified. No commits. Idempotent end-to-end.

## Files created

| File | Lines | Purpose |
|---|---|---|
| `supabase/migrations/0017_kid_perms_rls_rpcs.sql` | 1023 | The migration (header + helper + 6 RPCs + REVOKE/GRANT + 8 RLS blocks + verification queries) |
| `audits/2026-05-kid-perms-batch-2-implementation.md` | this | Implementation report |

## Per-RPC pseudocode + line range

All 6 RPCs are `SECURITY DEFINER LANGUAGE plpgsql SET search_path = public`. Each validates calling JWT against household membership / kind before mutating. Pseudocode descriptions follow; full SQL in the file.

### 1. `is_member_kid(p_member_id uuid) → boolean` (lines 67–87)

`sql STABLE SECURITY DEFINER SET search_path = public`. Returns true iff the row at `p_member_id` is `is_active=true, kind='sub_profile'`. Mirrors existing `is_household_member` / `is_household_admin` style.

### 2. `approve_chore(p_chore_id, p_approved, p_reason)` (lines 91–199, ~110 lines)

1. Load chore (household_id, assignee, status, points). Raise if not found.
2. Verify caller is `is_household_admin(v_household_id)`. Raise if not.
3. Look up caller's `member_id` for `verified_by_member_id`.
4. Validate status is `'pending_verification'`. Raise on other states.
5. If `p_approved`:
   - UPDATE chores: status='verified', verified_at=now(), verified_by_member_id=caller.
   - Branch on assignee.kind:
     - `'sub_profile'` → `award_points_to_member` + `check_and_award_achievements_for_member`.
     - `'adult_auth_user'` → `award_points` + `check_and_award_achievements`.
   - `v_total_points = point_value + COALESCE(bonus_points, 0)`.
6. Else (reject per Q1):
   - UPDATE chores: status='rejected', rejected_reason=p_reason, verified_at=now(), verified_by_member_id=caller (audit).
7. Schedule any `chore_verification_photos` rows for this chore: `delete_after = now() + interval '30 days'` (where delete_after IS NULL — so a re-decide doesn't reset the clock).

### 3. `complete_chore_self(p_chore_id, p_member_id)` (lines 203–291, ~89 lines)

Per Q3: adult-only self-complete, skips pending_verification (status → 'verified' directly).
1. Load chore. Raise if not found.
2. Verify in one SELECT: `id = p_member_id AND auth_user_id = auth.uid() AND household_id = chore.household_id AND kind = 'adult_auth_user' AND is_active = true`. Raise "Only the assigned adult can self-complete this chore" if any fail.
3. Verify `chore.assigned_to_member_id = p_member_id`. Raise "You can only complete chores assigned to you".
4. Verify status in `('assigned','in_progress')`. Raise otherwise.
5. UPDATE chores: status='verified', completed_at=now(), verified_at=now(), verified_by_member_id=p_member_id.
6. Award points via `award_points(member.auth_user_id, household_id, total_points, 'self_completed', 'chores', p_chore_id)` + `check_and_award_achievements(...)`.

### 4. `submit_kid_chore_with_photo(p_chore_id, p_member_id, p_storage_path)` (lines 295–388, ~94 lines)

Kid-only path. Returns the new `chore_verification_photos.id`.
1. Validate `p_storage_path` non-null and non-empty. Raise otherwise.
2. Verify `is_member_kid(p_member_id) = true`. Raise "Only sub_profiles can submit chores with photos".
3. Load chore (household_id, assignee, status). Raise if not found.
4. Verify the kid's `household_id` matches the chore's. Raise on mismatch.
5. Verify calling adult JWT is in the chore's household via `is_household_member`. Raise otherwise.
6. Verify `chore.assigned_to_member_id = p_member_id`. Raise "You can only submit chores assigned to you".
7. Verify status in `('assigned','in_progress')`. Raise otherwise.
8. UPDATE chores: status='pending_verification', completed_at=now().
9. INSERT into chore_verification_photos: (chore_id, household_id, uploaded_by_member_id=p_member_id, storage_path=p_storage_path). RETURNING id.

### 5. `add_shopping_item(p_household_id, p_member_id, p_name, p_quantity, p_unit, p_category, p_store_id, p_shopping_list_id)` (lines 392–517, ~126 lines)

Returns the new `shopping_items.id`. Handles all 4 existing direct-INSERT sites (Batch 5 migrates them).
1. Validate `p_name` non-empty.
2. Verify calling adult JWT is in `p_household_id` via `is_household_member`.
3. Load `(kind, is_active)` for `p_member_id` from `household_members` filtered by `p_household_id`. Raise "Member is not in this household" or "Member is not active" appropriately.
4. Resolve `p_shopping_list_id` (Q6):
   - If null: SELECT id FROM shopping_lists WHERE household_id=p_household_id AND is_active=true ORDER BY created_at ASC LIMIT 1. Raise "No active shopping list found. Create one first." if zero rows.
   - If provided: confirm it belongs to `p_household_id`. Raise "Shopping list not found in this household" otherwise.
5. Determine `is_wishlist`:
   - If `v_member_kind = 'sub_profile'`: `EXISTS (SELECT 1 FROM necessity_categories WHERE household_id = p_household_id AND lower(category) = lower(COALESCE(p_category, '')))` → `is_wishlist := NOT v_is_necessity`.
   - Else: `is_wishlist := false`.
6. INSERT into shopping_items with `added_by_member_id := p_member_id`, `is_wishlist := v_is_wishlist`, all passed fields, `name := trim(p_name)`. RETURNING id.

### 6. `create_meal_request(p_household_id, p_member_id, p_recipe_id, p_requested_for_date, p_meal_type)` (lines 521–594, ~74 lines)

Kid-only. Date and meal_type optional per Q7. Returns the new `meal_requests.id`.
1. Verify calling adult JWT is in `p_household_id` via `is_household_member`.
2. Verify `is_member_kid(p_member_id)`. Raise "Only sub_profiles can create meal requests".
3. Verify the kid's household matches `p_household_id`. Raise "Member is not in this household" otherwise.
4. Verify `p_recipe_id` exists in `household_recipes` AND belongs to `p_household_id`. Raise "Recipe not found" or "Recipe is not in this household".
5. INSERT into meal_requests with status='pending', `requested_by_member_id := p_member_id`. RETURNING id.

### 7. `decide_meal_request(p_request_id, p_approved, p_note, p_planned_for_override, p_meal_type_override) → jsonb` (lines 598–708, ~111 lines)

Per Q5: returns `jsonb_build_object('status', 'approved'|'denied', 'meal_request_id', p_request_id, 'meal_plans_id', uuid|null)`. Per Q4: raises on already-decided. Per Q7: optional overrides on approve.
1. Load request (household_id, recipe_id, requested_for_date, meal_type, status). Raise "Meal request not found" if missing.
2. Verify caller is `is_household_admin(v_household_id)`. Raise "Only household admins can decide meal requests".
3. Look up caller's member_id for `decided_by_member_id`.
4. Verify status='pending'. Raise "Meal request has already been decided (current status: %)" otherwise (Q4).
5. If `p_approved`:
   - `v_final_planned_for = COALESCE(p_planned_for_override, v_requested_for_date)`
   - `v_final_meal_type = COALESCE(p_meal_type_override, v_request_meal_type)`
   - Raise "Specify a date and meal type to add to meal plan" if either is null (Q7).
   - INSERT into meal_plans (household_id, planned_for=v_final_planned_for, meal_type=v_final_meal_type, recipe_id, created_by_member_id=caller) RETURNING id.
   - UPDATE meal_requests: status='approved', decided_by_member_id, decided_at=now(), decided_note=p_note.
   - RETURN jsonb {status='approved', meal_request_id, meal_plans_id}.
6. Else:
   - UPDATE meal_requests: status='denied', decided_by_member_id, decided_at=now(), decided_note=p_note.
   - RETURN jsonb {status='denied', meal_request_id, meal_plans_id=null}.

## Per-table RLS changes

All in Section 9 of the file. Pattern: `DROP POLICY IF EXISTS <old_name> ON <table>` (where one exists), then 4 narrower `CREATE POLICY` statements per table.

| Table | Lines | Drop | SELECT | INSERT | UPDATE | DELETE |
|---|---|---|---|---|---|---|
| `chores` | 739–758 | `household_scoped_chores` | `is_household_member` | `is_household_admin` | `is_household_admin` | `is_household_admin` |
| `chore_verification_photos` | 760–780 | `household_scoped_chore_photos` | `is_household_member` | `false` (RPC-only) | `is_household_admin` | `is_household_admin` |
| `rewards` | 782–801 | `household_scoped_rewards` | `is_household_member` | `is_household_admin` | `is_household_admin` | `is_household_admin` |
| `meal_plans` | 803–832 | `household_scoped_meal_plans` | `is_household_member` | `is_household_member` AND caller's `kind='adult_auth_user'` | `is_household_member` | `is_household_member` |
| `shopping_items` | 834–867 | `household_scoped_shopping_items` | `is_household_member` | `is_wishlist=false` AND `is_household_member` AND caller's `kind='adult_auth_user'` | `is_household_member` (Q8) | `is_household_admin` (Q8) |
| `meal_requests` | 869–892 | (none — 0016 had zero policies) | `is_household_member` | `false` (RPC-only) | `is_household_admin` | `is_household_admin` |
| `necessity_categories` | 894–913 | (none — 0016 had zero policies) | `is_household_member` | `is_household_admin` | `is_household_admin` | `is_household_admin` |
| `analytics_events` | 915–922 | `household_scoped_analytics` | (collapsed to a single `FOR ALL` policy: `household_id IS NULL OR is_household_admin(household_id)`) | same | same | same |

The `meal_plans` and `shopping_items` adult-only INSERT checks use a correlated `EXISTS (SELECT 1 FROM household_members WHERE auth_user_id = auth.uid() AND household_id = <new row's household_id> AND kind = 'adult_auth_user' AND is_active = true)`. Architecturally, "kid" can't be distinguished by JWT (kids have NULL `auth_user_id`), so this clause is defense-in-depth against unusual auth contexts (service-role calls, anon, etc.) rather than the primary kid block — that's enforced via app-layer routing to the RPCs. See Pass 2 investigation for the architectural background.

## Idempotency notes

- `CREATE OR REPLACE FUNCTION` on all 7 functions (6 RPCs + helper).
- `DROP POLICY IF EXISTS <name> ON <table>` before each `CREATE POLICY`. The 8 dropped policies are the original `household_scoped_*` `for all` policies from 0001 (5 of them) plus the analytics one. The 2 new tables from 0016 (meal_requests, necessity_categories) had zero policies, so no DROP needed for them.
- REVOKE PUBLIC + GRANT authenticated are no-ops if already in desired state.
- Safe to re-run end to end.

## Verification queries (in the migration file as comments, lines 925–1023)

Six checks. Summary:

| Check | What it confirms |
|---|---|
| A. 6 RPCs exist with `prosecdef=true` and matching `pronargs` | RPCs landed; SECURITY DEFINER set; signatures match |
| B. `is_member_kid` exists with `prosecdef=true`, `provolatile='s'` | Helper landed and is stable |
| C. Policy counts per table | 4 each for 7 tables; 1 for analytics_events |
| D. `has_function_privilege` checks for `authenticated` vs `anon` | authenticated=true on all 6; anon=false |
| E. Functional smoke test: `create_meal_request` → `decide_meal_request` → second `decide_meal_request` (expect raise) | End-to-end happy path + Q4 idempotency raise |
| F. Direct INSERT into `meal_requests` (expect RLS denial) | The "no direct insert" policy works |

E and F require some real UUIDs from your test data; A/B/C/D run as-is.

## Known followups (Batches 3–6 work)

This migration introduces 6 RPCs and tightens 8 tables but **changes zero Dart code**. The Dart migration into these RPCs is split across the upcoming batches per the spec's Batch plan:

1. **Batch 3 — Permissions helper.** `apps/mobile/lib/utils/permissions.dart` with `isAdmin`, `isKid`, etc. Migrates the 14 existing `role == 'admin'` checks to the helper. Updates `household_setup_screen.dart:96` to insert creator as `'owner'`. Also a good moment to update `chore_dashboard:_completeChore` and `_verifyChore` to call `complete_chore_self` and `approve_chore` respectively — the existing direct-UPDATE paths still work for admins after this batch's RLS, but the spec wants everything through RPCs.
2. **Batch 4 — Chore submit-with-photo.** Kid UI calls `submit_kid_chore_with_photo`. Admin UI calls `approve_chore` (replacing `_verifyChore`). Photo viewer + reject-reason field.
3. **Batch 5 — Wishlist + necessity.** All 4 shopping-items insert sites migrate to `add_shopping_item` RPC. Admin "Pending Wishlist" UI + "Edit Necessity Categories" screen.
4. **Batch 6 — Meal requests.** Kid "Request this meal" calls `create_meal_request`. Admin approves via `decide_meal_request`. Plus the 3-channel notification work (activity feed + recent requests view + iOS push).

Until those batches land, the RPCs and tightened RLS sit silently. Adult flows continue to work because: (a) the chores UPDATE policy is admin-only and existing admin code still updates chores directly; (b) shopping_items adult inserts still pass via the `is_wishlist=false AND adult` policy; (c) meal_plans adult inserts likewise; (d) rewards CRUD was already admin-gated by UI. Zero behavior regression for current users.

The only **new app-side breakage** the RLS introduces is non-admin adult `_completeChore`, which today does direct UPDATE on chores.status. This was the focus of Q3 / `complete_chore_self`. The app code in `chore_dashboard_screen.dart:130-145` will fail after 0017 lands until Batch 3 migrates it to call `complete_chore_self`. Test households today have only admin adults, so practical impact is zero in the testing window.

Additional carried-forward items from earlier batches:

5. **pg_cron 30-day photo cleanup** — still deferred. The `approve_chore` and other code now write `chore_verification_photos.delete_after` correctly; the actual deletion job is its own migration after pg_cron is confirmed and Storage cleanup is designed.
6. **Spec amendment** — small task carried from Batch 1. Update spec to reflect: (a) `is_household_kid` was redefined as `is_member_kid`; (b) `chore_verification_photos.rejected_reason` was skipped (using `chores.rejected_reason`); (c) Batch 2 added `complete_chore_self` as a 6th RPC.

## Next steps

1. **You review** `supabase/migrations/0017_kid_perms_rls_rpcs.sql`. Skim each RPC and each policy block. Flag anything that looks off.
2. **Apply 0017 to Supabase** via SQL editor (one block; idempotent; safe to re-run).
3. **Run verification queries A–D** from the bottom of the file. Confirm expected counts/booleans.
4. **Run queries E and F** with real UUIDs from your test household to smoke-test create_meal_request → decide_meal_request → idempotency raise + direct-INSERT RLS denial.
5. **Report back** any discrepancies, or confirm clean.
6. **Commit** the migration + this report on `feat/kid-perms-rls-rpcs-batch-2-2026-05-22`. Push with `--set-upstream`.
7. **Begin Batch 3** (permissions helper + migrate chore RPCs in Dart) on a separate branch.

## Git state (uncommitted)

```
$ git status --short
?? audits/2026-05-kid-perms-batch-2-implementation.md
?? supabase/migrations/0017_kid_perms_rls_rpcs.sql
```

Both untracked, on `feat/kid-perms-rls-rpcs-batch-2-2026-05-22`. Working tree otherwise clean.
