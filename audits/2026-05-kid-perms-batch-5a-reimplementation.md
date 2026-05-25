# Kid Permissions Batch 5a — Re-implementation Report (Part 2 of 2)

Date: 2026-05-25
Branch: `feat/kid-perms-wishlist-2026-05-25`
Status: **changes uncommitted** — Part 2 of a two-commit sequence; Part 1 (active-member resolution fix) is the prerequisite and lives at `/audits/2026-05-active-member-resolution-fix-implementation.md`

## Summary

Re-applies the Batch 5a Dart branching that was previously stashed at `stash@{0}`. Doesn't unstash — re-implements cleanly on top of Part 1's `MembershipHelper`. The result is functionally equivalent to the original 5a (decisions Q1-Q12 from the brief honored) but now the kid path actually fires when operating as a kid, because Part 1 fixed the upstream `_myMembership` resolution.

Migration `0021_amend_add_shopping_item_and_approve_wishlist.sql` from the original 5a work is still on disk (untracked); it lands in this commit alongside the Dart re-implementation. No re-write of the migration — it was correct.

All 4 locked decisions still honored: Q1 (RPC param amendment), Q2 (`approve_wishlist_item` RPC + UPDATE trigger), Q10 (inline branching, no shared helper for the per-site logic), Q12 (no optimistic UI).

## Files modified / created

| File | Type | Net LOC | Purpose |
|---|---|---|---|
| `supabase/migrations/0021_amend_add_shopping_item_and_approve_wishlist.sql` | **new** (carried from original 5a) | +320 | Amended `add_shopping_item` (3 new optional params) + new `approve_wishlist_item` RPC + BEFORE UPDATE trigger on is_wishlist |
| `apps/mobile/lib/screens/shopping_list_screen.dart` | modified | +95 | `necessity_categories` side-query in `_loadData`; pass `isKid` + `necessityCategoriesLower` to sheets; branch sites 1 + 2; upgrade error surfacing |
| `apps/mobile/lib/screens/meal_planner_screen.dart` | modified | +35 | Pass `isKid` to `_AddMealPlanSheet`; branch site 3; replace silent `catch (_)` with surfaced error |
| `apps/mobile/lib/screens/recipe_detail_screen.dart` | modified | +30 | Branch site 4 inline; SnackBar copy differentiates |

Total for Part 2: ~480 LOC across 1 migration + 3 modified screens.

(Reminder of Part 1's separate scope: `apps/mobile/lib/utils/membership.dart` +85 LOC + 4 screen migrations +55 LOC. Total fix+re-implementation across both parts: ~620 LOC.)

## Phase 2A — `shopping_list_screen.dart` (sites 1 + 2)

### Top-level state addition

```dart
List<String> _necessityCategoriesLower = [];
```

### `_loadData` parallel queries — added a 4th query

After Part 1's `MembershipHelper.loadActiveMembership` returns, the existing `Future.wait([shopping_lists, stores, household_recipes])` block grows to 4 parallel queries by adding `necessity_categories`:

```dart
Supabase.instance.client
    .from('necessity_categories')
    .select('category')
    .eq('household_id', householdId),
```

Result is lowercased into `_necessityCategoriesLower` for the SnackBar-copy lookup.

### `_show*Sheet` call sites — pass new constructor args

```dart
_AddShoppingItemSheet(
  ...
  isKid: Permissions.isKid(_myMembership),
  necessityCategoriesLower: _necessityCategoriesLower,
  ...
)

_AddFromRecipeSheet(
  ...
  isKid: Permissions.isKid(_myMembership),
  ...
)
```

### Site 1 — `_AddShoppingItemSheet._addItem` (~line 805)

Branched on `widget.isKid`:

- **Kid path**: `rpc('add_shopping_item', ...)` with all 11 params from migration 0021's amended signature. `source_recipe_id` and `source_meal_plan_id` are null for manual add. SnackBar copy depends on `_selectedCategory` being in `necessityCategoriesLower`:
  - In necessity list → "Added to shopping list" (server set is_wishlist=false)
  - Otherwise → "Added to wishlist — waiting for approval"
- **Adult path**: existing direct INSERT preserves all columns (including `display_quantity`).
- Error surfacing upgraded: `catch (e) → debugPrint('add shopping item failed: $e') → non-const SnackBar('Could not add item: $e')`.

### Site 2 — `_AddFromRecipeSheet._addIngredients` (~line 1081)

Branched on `widget.isKid`:

- **Kid path**: `for` loop over `_selectedIngredients`, one `rpc('add_shopping_item', ...)` call per ingredient with `p_source_recipe_id: _selectedRecipeId`. No per-ingredient category → all land in wishlist server-side. SnackBar: "Added N item(s) to wishlist — waiting for approval".
- **Adult path**: existing bulk INSERT unchanged.
- Error surfacing upgraded.

## Phase 2B — `meal_planner_screen.dart` (site 3)

`_AddMealPlanSheet` constructor gains `isKid` bool. `_showAddMealSheet` passes `Permissions.isKid(_myMembership)`.

### Site 3 — Auto-add ingredients inside `_createMealPlan` (~line 712)

Branched on `widget.isKid`:

- **Kid path**: `for` loop with `rpc('add_shopping_item', ...)`. This is the only site that passes BOTH `p_source_recipe_id` AND `p_source_meal_plan_id`. All land in wishlist (no category).
- **Adult path**: existing bulk INSERT.
- **Replaced silent `catch (_)`** with surfaced error per Pass 2 standing rule: meal plan was already saved at this point, so partial failure is recoverable; the user just sees "Meal plan saved, but ingredients failed: $e".

## Phase 2C — `recipe_detail_screen.dart` (site 4)

Site 4 lives in the main `_RecipeDetailScreenState` class (no child sheet), so no constructor plumbing needed — uses `_householdMember` directly (now correctly resolving to the kid post-Part-1).

### `_addToShoppingList` (~line 266)

`final isKid = Permissions.isKid(_householdMember)` computed once at the top of the function. Loop body branches:

- **Kid path**: `rpc('add_shopping_item', ...)` with `p_source_recipe_id: widget.recipeId` + `p_quantity` + `p_display_quantity`. Note: site 4 didn't write `source_recipe_id` for adults today (inconsistency vs sites 2 and 3); preserved the adult inconsistency to keep the diff minimal.
- **Adult path**: existing direct INSERT unchanged.

SnackBar copy:
- Kid → "Added N ingredient(s) to wishlist — waiting for approval"
- Adult → existing "Added N ingredients to shopping list!"

Error surfacing was already correct (used `$e`); added `debugPrint` for parity.

## Consolidated analyzer delta (Part 1 + Part 2)

| Stage | Issue count | Net new errors | Net new info/warnings |
|---|---|---|---|
| Baseline (pre-Part-1) | 353 | n/a | n/a |
| After Part 1 (helper + 4 screen migrations) | 353 | 0 | 0 |
| **After Part 2 (site branching)** | **357** | **0** | **+4** |

The pre-existing `MyApp` error in `test/widget_test.dart:16` is unchanged.

The +4 are all `inference_failure_on_function_invocation` warnings on the 4 new `.rpc('add_shopping_item', ...)` call sites (Phase 2A site 1, Phase 2A site 2, Phase 2B site 3, Phase 2C site 4). Matches every other `.rpc()` call in the codebase per Supabase Dart SDK type-inference behavior.

Part 1's helper file itself is 0-issue (no inference warnings, no deprecated-member-use; the `.select(...)` calls use the default inference path which the analyzer accepts).

## iPhone smoke test for Part 2

After applying migration 0021 (push to remote Supabase or run via SQL editor) and rebuilding:

| # | Path | Expected |
|---|---|---|
| 1 | **Switch to Randi** via profile switcher. Open shopping_list_screen. Tap Add, fill name + non-necessity category, Save | Item lands server-side with `added_by_member_id = randi_member_id` and `is_wishlist = true`. SnackBar shows "Added to wishlist — waiting for approval". Item is NOT visible on the main shopping list (filtered to `is_wishlist=false`). |
| 2 | Same as #1 but select **Hygiene** (default necessity category) | Same row with `is_wishlist = false`. SnackBar shows "Added to shopping list". Item appears immediately on the main list. |
| 3 | Switch to Randi, open shopping_list_screen, tap "Add from recipe", select a recipe + ingredients | All N items inserted via N RPC calls, all with `is_wishlist=true` and `source_recipe_id` set. SnackBar shows "Added N items to wishlist — waiting for approval". |
| 4 | Switch to Randi, open a recipe in recipe_detail_screen, tap "Add to shopping list" | All ingredients via N RPC calls with `source_recipe_id` set (new for site 4 — adult version doesn't write this). Kid SnackBar shows wishlist copy. |
| 5 | Switch back to admin. Repeat all 4 sites | Direct INSERT path unchanged. `added_by_member_id` is admin's. No `is_wishlist=true` (server defaults to false for adults). SnackBar matches original copy. |
| 6 | Verify in Supabase SQL editor: `SELECT added_by_member_id, is_wishlist, name, source_recipe_id FROM shopping_items WHERE created_at > now() - interval '10 minutes' ORDER BY created_at DESC` | Rows from #1 + #3 + #4 (kid-added) show Randi's member_id + `is_wishlist=true`. Row from #2 shows Randi's member_id + `is_wishlist=false` (necessity bypass). Rows from #5 (adult) show admin's member_id + `is_wishlist=false`. |
| 7 | (SQL editor) Direct UPDATE attempt as kid: `UPDATE shopping_items SET is_wishlist=false WHERE id='<a kid wishlist row>'` while signed in as a non-admin auth | EXCEPTION `'Only household admins can change wishlist status'` (the trigger from migration 0021's Section 3 fires) |
| 8 | (SQL editor) Same UPDATE as admin auth | 1 row updated (trigger's `is_household_admin` check passes) |
| 9 | (SQL editor) `SELECT public.approve_wishlist_item(p_item_id := '<wishlist row>')` as admin | Returns void. Row flips to `is_wishlist=false`. `approved_by_member_id` set to admin's member_id. `approved_at` populated. |
| 10 | Pre-flight: mid-session profile switch | While on shopping_list_screen as Randi, switch to admin via the home_shell profile switcher. The screen should reload automatically (Part 1's `_onActiveMemberChanged` listener), and subsequent adds use the adult path. |

## What Part 2 explicitly does NOT touch

- `apps/mobile/lib/utils/membership.dart` — already shipped in Part 1.
- `apps/mobile/lib/screens/chore_detail_screen.dart` — that was Part 1 territory; Part 2 doesn't touch chore code.
- `chore_dashboard_screen.dart` — unchanged.
- `home_shell_screen.dart` — unchanged.
- No `addShoppingItemForCurrentMember` shared helper (Q10: inline at 4 sites).
- No optimistic UI (Q12).
- No changes to existing `add_shopping_item` validation logic (only the signature + INSERT, per the original 5a's lock).
- No RLS UPDATE policy restructure (the trigger from migration 0021 handles the new guard).

## Known followups (Batch 5b)

- Admin "Pending Wishlist" section on `chore_dashboard_screen.dart` (recommended Phase 3 Option A from the original 5 investigation)
- New `apps/mobile/lib/screens/necessity_categories_screen.dart` with CRUD
- Settings entry point for the Necessity Categories screen

## Next steps for the user

The two commits stack cleanly:

### Suggested commit 1 — Part 1 (active-member fix)

Files:
- `apps/mobile/lib/utils/membership.dart` (new)
- `apps/mobile/lib/screens/shopping_list_screen.dart` (membership-load portion only)
- `apps/mobile/lib/screens/meal_planner_screen.dart` (membership-load portion only)
- `apps/mobile/lib/screens/recipe_detail_screen.dart` (membership-load portion only)
- `apps/mobile/lib/screens/chore_detail_screen.dart` (membership-load portion only)
- `audits/2026-05-shopping-screen-active-member-bug-investigation.md` (the investigation that surfaced this)
- `audits/2026-05-active-member-resolution-fix-implementation.md` (Part 1 report)

But — because Part 1 and Part 2 touched overlapping ranges of shopping_list_screen / meal_planner_screen / recipe_detail_screen in the same file, separating them into two commits would require `git add -p` (interactive hunk staging) to split the diffs. That's tedious. Two simpler options:

### Suggested commit 2 — Part 2 (Batch 5a re-implementation)

Files:
- `supabase/migrations/0021_amend_add_shopping_item_and_approve_wishlist.sql`
- The site-branching portions of shopping_list_screen / meal_planner_screen / recipe_detail_screen
- `audits/2026-05-kid-perms-batch-5-investigation.md` (the original Batch 5 investigation)
- `audits/2026-05-kid-perms-batch-5a-implementation.md` (the original 5a report — still accurate for the architectural decisions, though it predates this fix)
- `audits/2026-05-kid-perms-batch-5a-reimplementation.md` (this report)

### **Alternative: single combined commit**

Both parts are self-consistent — the helper fix is needed for the site branching to actually fire as intended, so they're naturally one logical change. A single commit covering both works fine. Decide based on commit-history preference.

### Recommended

Use **one combined commit** (`feat(perms): centralized active-member resolution + Batch 5a wishlist routing`). The two changes are tightly coupled in purpose and the file overlaps make splitting awkward. The two audit reports provide the conceptual separation for future readers.

Once committed:
1. Apply migration 0021 to Supabase.
2. Rebuild iOS app on `feat/kid-perms-wishlist-2026-05-25`.
3. Smoke-test the 10 verification paths above.
4. Push.
5. Schedule Batch 5b (Pending Wishlist admin UI + Necessity Categories screen).
