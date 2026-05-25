# Kid Permissions Batch 5a — Implementation Report

Date: 2026-05-25
Branch: `feat/kid-perms-wishlist-2026-05-25`
Status: **changes uncommitted** — user reviews then commits

## Summary

Closes the two Batch 5 backend gaps surfaced in the investigation:

- **Gap 1 (`add_shopping_item` param-narrow)**: amended the RPC signature to accept three new optional trailing params — `p_source_recipe_id`, `p_source_meal_plan_id`, `p_display_quantity` — and to pass them through to the INSERT. Kid inserts via the RPC no longer lose lineage.
- **Gap 2 (`shopping_items` UPDATE permissiveness)**: added `approve_wishlist_item(p_item_id) RETURNS void` SECURITY DEFINER RPC (admin-only flip to `is_wishlist=false` with audit trail) plus a BEFORE UPDATE trigger that raises if any non-admin tries to change `is_wishlist`. Existing UPDATE policy stays as-is so qty/purchased/store edits keep working for everyone.

App-side: branched all 4 shopping_items insert sites by `Permissions.isKid(_myMembership)`. Kid path routes to the RPC; adult path stays direct INSERT. SnackBar copy differentiates wishlist vs direct-add. Error surfacing upgraded at all 4 sites per Pass 2 standing rule (catch + debugPrint + non-const SnackBar with `$e`).

All 4 decisions locked in the brief honored: Q1 (RPC amendment), Q2 (RPC + trigger), Q10 (inline branching, no shared helper), Q12 (no optimistic UI).

## Files modified / created

| File | Type | Net LOC | Purpose |
|---|---|---|---|
| `supabase/migrations/0021_amend_add_shopping_item_and_approve_wishlist.sql` | **new** | +320 | Drop+create amended `add_shopping_item`; new `approve_wishlist_item` RPC; `guard_shopping_items_wishlist_change` trigger; REVOKE/GRANT for new signatures; verification queries |
| `apps/mobile/lib/screens/shopping_list_screen.dart` | modified | +95 | `necessity_categories` side-query in `_loadData`; pass `isKid` + `necessityCategoriesLower` to sheets; branch `_addItem` (site 1) + `_addIngredients` (site 2) by kid; upgrade error surfacing |
| `apps/mobile/lib/screens/meal_planner_screen.dart` | modified | +35 | Pass `isKid` to `_AddMealPlanSheet`; branch site 3 (auto-add ingredients on meal plan create); replace silent `catch (_)` with surfaced error |
| `apps/mobile/lib/screens/recipe_detail_screen.dart` | modified | +25 | Branch site 4 (`_addToShoppingList`) by kid; SnackBar copy differentiates |

No changes to `chore_dashboard_screen.dart`, settings, or any new screen — that's Batch 5b territory.

## Phase 1 — Migration 0021 structure

**File**: `supabase/migrations/0021_amend_add_shopping_item_and_approve_wishlist.sql` (320 lines).

Sections:
- **Lines 1-65** — Header. Explains both gaps; explains why a trigger over restructured RLS (Postgres RLS doesn't expose OLD vs NEW in WITH CHECK); explains why `DROP FUNCTION + CREATE FUNCTION` instead of `CREATE OR REPLACE` (Postgres requires identical parameter list for replace).
- **Lines 68-178** — **Section 1: amend `add_shopping_item`**. `DROP FUNCTION IF EXISTS public.add_shopping_item(uuid, uuid, text, numeric, text, text, uuid, uuid);` followed by `CREATE FUNCTION` with 11 params (3 new appended: `p_source_recipe_id`, `p_source_meal_plan_id`, `p_display_quantity`, all DEFAULT NULL). Validation chain is byte-for-byte identical to migration 0017 §5; only the signature and INSERT column list change.
- **Lines 181-226** — **Section 2: `approve_wishlist_item`**. New SECURITY DEFINER RPC. 4 validations (item exists; currently `is_wishlist=true`; caller is admin via `is_household_admin`; admin's member_id resolves). Atomic UPDATE setting `is_wishlist=false, approved_by_member_id, approved_at`.
- **Lines 229-260** — **Section 3: `guard_shopping_items_wishlist_change` trigger**. `BEFORE UPDATE FOR EACH ROW` on `shopping_items`. Trigger function uses `SECURITY INVOKER` + `SET search_path = public`. Logic: `IF NEW.is_wishlist IS DISTINCT FROM OLD.is_wishlist AND NOT is_household_admin(NEW.household_id) THEN RAISE`. Non-wishlist updates pass through untouched.
- **Lines 263-275** — **Section 4: REVOKE/GRANT**. New signatures + Pattern 3 (FROM PUBLIC, anon + TO authenticated). The trigger function itself doesn't need a user-facing EXECUTE grant.
- **Lines 278-320** — **Verification queries** (comments only). 7 checks (A-G): function existence + SECURITY DEFINER + `pronargdefaults`; role privileges; old 8-arg signature gone; trigger installed + enabled; Gap 2 enforcement smoke (non-admin direct UPDATE should raise); approve happy path + already-approved error; Gap 1 lineage smoke.

**Patterns applied** (per `/audits/supabase-patterns-learned.md`):
- **Pattern 1**: `SECURITY DEFINER` + `SET search_path = public` on both functions; `SET search_path = public` on the trigger function too (defensive).
- **Pattern 3**: `REVOKE ALL ... FROM PUBLIC, anon` then `GRANT EXECUTE ... TO authenticated` on both new/amended functions.

### Key design choice — trigger over restructured RLS

The brief authorized either path. Chose trigger because:
1. Postgres RLS doesn't natively support per-column "must not change unless admin" constraints. Workarounds (sub-selecting OLD value inside WITH CHECK) are awkward and easy to misread.
2. The existing UPDATE policy stays simple (any household member). All non-wishlist mutations (purchased toggle, qty edit, store change) work unchanged through that policy. Only the wishlist column has the extra guard.
3. The `approve_wishlist_item` RPC's UPDATE is admin-authorized inside the RPC, so when it fires the trigger's `is_household_admin(...)` re-check passes (Supabase `auth.uid()` reflects the original JWT caller regardless of SECURITY DEFINER context).
4. Trigger composes with all future shopping_items mutation paths without revisiting RLS.

## Phase 2 — `shopping_list_screen.dart` (sites 1 + 2)

### State additions

- New field `_necessityCategoriesLower: List<String>` (line ~46) — lowercased necessity-category names for the household. Loaded alongside the other parallel queries in `_loadData` (results[3]).
- `_loadData` adds a 4th parallel `select` against `necessity_categories` filtered by household_id.

### Sheet param plumbing

- `_AddShoppingItemSheet` constructor gains `isKid` (bool) + `necessityCategoriesLower` (List<String>).
- `_AddFromRecipeSheet` constructor gains `isKid` (bool).
- Both `_show*Sheet` methods pass `Permissions.isKid(_myMembership)` + (for the first) `_necessityCategoriesLower`.

### Site 1 — `_addItem` (~lines 805-895)

Branched on `widget.isKid`:
- **Kid path**: `rpc('add_shopping_item', ...)` with all 11 params. SnackBar copy depends on `_selectedCategory` being in `necessityCategoriesLower` (lowercase compare): necessity → "Added to shopping list"; otherwise → "Added to wishlist — waiting for approval".
- **Adult path**: existing direct INSERT unchanged.
- Error surfacing upgraded: `catch (e) → debugPrint('add shopping item failed: $e') → non-const SnackBar with $e`.

### Site 2 — `_addIngredients` (~lines 1085-1160)

Branched on `widget.isKid`:
- **Kid path**: N RPC calls in a `for` loop (one per selected ingredient). Each call passes `p_source_recipe_id` (now accepted post-migration 0021). No per-ingredient category → all land in wishlist server-side. SnackBar: "Added N item(s) to wishlist — waiting for approval".
- **Adult path**: existing bulk INSERT unchanged.
- Error surfacing upgraded.

## Phase 3 — Actually Phase 2 above covered shopping_list_screen

(Phase 3 = site 2 was bundled into the Phase 2 edits since both sites live in the same file.)

## Phase 4 — `meal_planner_screen.dart` (site 3)

### Sheet param plumbing

`_AddMealPlanSheet` constructor gains `isKid` (bool). `_showAddMealSheet` passes `Permissions.isKid(_myMembership)`.

### Site 3 — Auto-add recipe ingredients inside `_createMealPlan` (~lines 695-755)

Branched on `widget.isKid`:
- **Kid path**: N RPC calls with both `p_source_recipe_id` AND `p_source_meal_plan_id` (this is the only site that has both). All land in wishlist.
- **Adult path**: existing bulk INSERT unchanged.
- Replaced silent `catch (_)` with surfaced error: `debugPrint('auto-add ingredients failed: $e') → SnackBar('Meal plan saved, but ingredients failed: $e')`. Note: meal plan is already saved by this point, so partial failure is recoverable; the user just knows.

## Phase 5 — `recipe_detail_screen.dart` (site 4)

### `_addToShoppingList` (~lines 257-310)

Site 4 is inside the main `_RecipeDetailScreenState` class (not a child sheet), so no param plumbing needed — uses `_householdMember` directly.

Branched on `Permissions.isKid(_householdMember)` computed once at the top of the function. Loop body checks `isKid`:
- **Kid path**: `rpc('add_shopping_item', ...)` with `p_source_recipe_id: widget.recipeId` + `p_display_quantity` + `p_quantity`.
- **Adult path**: existing direct INSERT unchanged. Note: site 4 doesn't write `source_recipe_id` for adults today (inconsistency vs sites 2 and 3) — preserved that for now to keep the diff minimal.

SnackBar copy differentiates: kid → "Added N ingredient(s) to wishlist — waiting for approval"; adult → existing "Added N ingredients to shopping list!".

Error surfacing already had `$e` interpolation; added `debugPrint` for parity.

## Phase 6 — Analyzer deltas

| Scope | Before | After | Net new errors | Net new info/warnings |
|---|---|---|---|---|
| `flutter analyze apps/mobile/` | 353 | 357 | **0** | +4 |

The pre-existing `error` (`MyApp` in `test/widget_test.dart:16`) is unchanged.

The +4 are all `inference_failure_on_function_invocation` warnings on the 4 new `.rpc('add_shopping_item', ...)` call sites (Phase 2 site 1, Phase 2 site 2, Phase 4 site 3, Phase 5 site 4). Matches the existing codebase pattern (every `.rpc()` call in the codebase produces this warning per Supabase Dart SDK type inference).

Other lines that appeared in the scoped output as `error` (`unawaited_futures` in `_togglePurchased`, `_deleteItem`, `_addNewListSheet`; `use_build_context_synchronously` in `_addNewListSheet`; `unawaited_futures` in `_addStoreSheet`; `_loadMealPlans` calls in meal_planner) — all pre-existing, not in code I touched.

## Verification checklist for iPhone testing

After applying migration 0021 (push to remote Supabase or run via SQL editor) and rebuilding:

| # | Path | Expected |
|---|---|---|
| 1 | Kid taps Add on shopping_list_screen, fills name + selects a non-necessity category, taps Save | Item appears server-side with `is_wishlist=true`; SnackBar shows **"Added to wishlist — waiting for approval"**; item does NOT appear in the main shopping list view (filtered to `is_wishlist=false`) |
| 2 | Kid same flow but selects Hygiene (a default necessity category) | Item appears server-side with `is_wishlist=false`; SnackBar shows **"Added to shopping list"**; item appears immediately on the shared list |
| 3 | Kid taps "Add from Recipe", selects ingredients, taps confirm | All ingredients added via N RPC calls; `source_recipe_id` preserved on all rows; SnackBar shows **"Added N items to wishlist — waiting for approval"** |
| 4 | Kid opens a recipe in `recipe_detail_screen`, taps "Add to shopping list" | All ingredients via N RPC calls; `source_recipe_id` populated (new behavior — site 4 didn't write this for adults); kid SnackBar shows wishlist copy |
| 5 | Adult flows on all 4 sites | Direct INSERT path unchanged; no behavior change; existing SnackBar copy |
| 6 | (SQL editor as kid's adult JWT) Direct UPDATE attempt: `UPDATE shopping_items SET is_wishlist = false WHERE id = '<wishlist row>'` while signed in as a non-admin | EXCEPTION `'Only household admins can change wishlist status'` (trigger fires) |
| 7 | (SQL editor as admin JWT) Same UPDATE statement | 1 row updated successfully (trigger's `is_household_admin` check passes) |
| 8 | (SQL editor as admin) `SELECT public.approve_wishlist_item(p_item_id := '<wishlist row>')` | Returns void; row flips to `is_wishlist=false`; `approved_by_member_id` and `approved_at` populated |
| 9 | (SQL editor as admin) Same call on already-approved item | EXCEPTION `'Item is already approved (not on the wishlist)'` |
| 10 | Verify migration 0021 functional | Run sections A-G verification queries at the bottom of the migration file |

## Known followups (Batch 5b)

- Admin "Pending Wishlist" section on `chore_dashboard_screen.dart` (recommended Phase 3 Option A from the investigation)
  - Side-query alongside `_pendingVerification` for `WHERE is_wishlist = true`
  - New `_WishlistCard` widget with Approve / Deny buttons
  - Approve calls `approve_wishlist_item` RPC (shipped here in 5a)
  - Deny does `client.from('shopping_items').delete().eq('id', itemId)` (RLS allows admin DELETE)
- New `apps/mobile/lib/screens/necessity_categories_screen.dart` with CRUD on the household's necessity_categories rows
- Settings entry point for the Necessity Categories screen (gated by `Permissions.canManageNecessityCategories`)

## What 5a explicitly did NOT touch

- `chore_dashboard_screen.dart` (5b territory)
- Settings screen (5b territory)
- No new admin-facing UI (5b)
- No `addShoppingItemForCurrentMember` helper (Q10: inline branching)
- No optimistic UI (Q12)
- No changes to existing `add_shopping_item` validation logic (only signature + INSERT, per the brief's lock)
- No changes to RLS UPDATE policy itself (the trigger handles the new guard; existing policy stays permissive for everyone on non-wishlist updates)

## Next steps for the user

1. Review the diffs across the 4 files (1 new migration + 3 modified screens).
2. Apply migration 0021 to remote Supabase (or local dev DB).
3. Rebuild iOS app on `feat/kid-perms-wishlist-2026-05-25`.
4. Smoke-test the 10 verification paths above.
5. Commit + push.
6. Schedule Batch 5b (admin Pending Wishlist + Necessity Categories screen).

After 5a + 5b ship, Pass 3 remaining: Batches 6 (meal requests + push), 7 (UI hardening), 8 (music deep link).
