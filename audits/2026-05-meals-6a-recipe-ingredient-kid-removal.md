# Batch 6a Followup — Recipe-Ingredient Kid Path Removal

Date: 2026-05-25
Branch: `feat/meals-batch-6a-2026-05-25` (2nd commit on this branch after `3bb7e01` Batch 6a)
Status: **changes uncommitted** — user reviews then commits

## Summary

Closes the architectural gap surfaced during Batch 6a smoke test: kids could still pull recipe ingredients into the shopping list independently of the meal-request approval flow, bypassing the intended "request meal → admin approves → meal_plan created" path. This commit hides both recipe-ingredient entry points from kid sessions (recipe_detail's cart FAB + popup menu's "Add to Shopping List" item, plus shopping_list_screen's "From recipe" button) and removes the now-unreachable kid branches in the underlying handlers. The single-item wishlist path (Batch 5a Site 1) is untouched — kids retain the legitimate "request a specific item" affordance.

## Files modified

| File | Lines changed | Purpose |
|---|---|---|
| `apps/mobile/lib/screens/recipe_detail_screen.dart` | +14 / −34 | Gate cart FAB and popup-menu "Add to Shopping List" on `!Permissions.isKid`; strip kid branch from `_addToShoppingList` |
| `apps/mobile/lib/screens/shopping_list_screen.dart` | +9 / −41 | Gate "From recipe" button on `!Permissions.isKid`; strip kid branch from `_addIngredients`; remove now-unused `isKid` field from `_AddFromRecipeSheet` + its callsite |

Net **−52 LOC** (more removed than added — dead-code cleanup).

## Phase 1 — Entry points found

**recipe_detail_screen.dart** had TWO entry points to `_addToShoppingList`:
1. **Cart FAB** at line 541-546 (`heroTag: 'cart'`) — was gated only by `!_isEditing && canEdit` where `canEdit = widget.isHouseholdRecipe`. No permission gate.
2. **Popup menu item** "Add to Shopping List" at line 505 — same target, no permission gate.

**shopping_list_screen.dart** had ONE entry point:
- **"From recipe" OutlinedButton** at line 530-536 (`onPressed: _showAddFromRecipeSheet`) — top-level button in the main screen's quick-actions row, no permission gate.

The underlying handlers (`recipe_detail._addToShoppingList` and `_AddFromRecipeSheetState._addIngredients`) both already had `if (widget.isKid)` / `if (isKid)` branches from Batch 5a that routed kid inserts through `add_shopping_item` RPC. With UI entry points now hidden, those branches became unreachable.

## Phase 2 — Entry points gated

### recipe_detail cart FAB (lines ~541-559)

Wrapped both the FAB and its trailing `SizedBox(width: 8)` spacer in `if (!Permissions.isKid(_householdMember))`:

```dart
floatingActionButton: !_isEditing && canEdit
    ? Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!Permissions.isKid(_householdMember))
            FloatingActionButton.small(
              heroTag: 'cart',
              onPressed: _addToShoppingList,
              backgroundColor: AppColors.grassGreen,
              child: const Icon(Icons.shopping_cart, color: Colors.white),
            ),
          if (!Permissions.isKid(_householdMember))
            const SizedBox(width: 8),
          // Meal FAB stays (kid's legitimate meal-request entry point
          // from Batch 6a).
          FloatingActionButton.small(
            heroTag: 'meal',
            ...
          ),
        ],
      )
    : null,
```

Result for kid sessions: row shows only the meal FAB. Adults see both FABs unchanged.

### recipe_detail popup menu item (lines ~504-510)

Wrapped just the "Add to Shopping List" `PopupMenuItem` in the same kid-not check:

```dart
itemBuilder: (context) => [
  if (!Permissions.isKid(_householdMember))
    const PopupMenuItem(value: 'shopping', ...),
  const PopupMenuItem(value: 'mealplan', ...),
  const PopupMenuDivider(),
  const PopupMenuItem(value: 'delete', ...),
],
```

Kid sees the menu but without the shopping option.

### shopping_list "From recipe" button (lines ~519-541)

Wrapped both the spacer and the OutlinedButton in `if (!Permissions.isKid(_myMembership)) ...[ ]`:

```dart
Row(
  children: [
    Expanded(
      child: FilledButton.icon(
        onPressed: _showAddItemSheet,
        icon: const Icon(Icons.add_rounded, size: 18),
        label: const Text('Add item'),
      ),
    ),
    if (!Permissions.isKid(_myMembership)) ...[
      const SizedBox(width: 12),
      Expanded(
        child: OutlinedButton.icon(
          onPressed: _showAddFromRecipeSheet,
          icon: const Icon(Icons.restaurant_menu_rounded, size: 18),
          label: const Text('From recipe'),
        ),
      ),
    ],
  ],
),
```

Kid sees only the single "Add item" button (centered by Expanded's flex). Adult sees both side-by-side as before.

## Phase 3 — Dead kid branches removed

### recipe_detail `_addToShoppingList` (lines ~264-322)

Before: `for` loop with `if (isKid) { rpc(...) } else { insert(...) }` branches per ingredient + SnackBar copy ternary.
After: just the adult INSERT loop + plain "Added N ingredients to shopping list!" SnackBar.

- Eliminated `final isKid = Permissions.isKid(_householdMember);` line
- Eliminated the entire RPC kid branch and its `if/else` wrapper
- Eliminated the SnackBar ternary string

The method now does what it always did for adults; the kid-friendly wording and RPC routing are gone.

### shopping_list_screen `_addIngredients` (lines ~1141-1175)

Before: `try { if (widget.isKid) { N RPC calls + kid SnackBar + pop } else { bulk INSERT + pop } } catch ...`
After: `try { bulk INSERT + pop } catch ...`

- Eliminated `if (widget.isKid) { ... } else` branching
- Eliminated the kid-specific SnackBar copy
- Adult path unchanged

### `_AddFromRecipeSheet` constructor (lines ~1011-1025)

- Removed `required this.isKid` from the constructor's named params
- Removed `final bool isKid;` field declaration
- Updated comment to reflect that the sheet is now adult-only by gating

### `_showAddFromRecipeSheet` caller (line ~239)

Removed the `isKid: Permissions.isKid(_myMembership),` argument from the constructor call.

## Phase 4 — Untouched paths (verified)

- **`shopping_list_screen._addItem`** (single-item manual add, Batch 5a Site 1): UNCHANGED. Kid still uses the `add_shopping_item` RPC path; adult still uses direct INSERT. This is the kid's legitimate wishlist-single-item flow.
- **`meal_planner_screen._createMealPlan`** (auto-add ingredients when admin creates meal plan, Batch 5a Site 3): UNCHANGED. Admin-only territory in practice (kids don't create meal plans); kid branch left as defense-in-depth.

## Phase 5 — Analyzer

| Scope | Before | After | Net new errors | Net new info/warnings |
|---|---|---|---|---|
| `flutter analyze apps/mobile/` | 368 | 366 | **0** | **−2** |

The pre-existing `MyApp` test error is unchanged. The −2 reflects the two `inference_failure_on_function_invocation` warnings that lived on the deleted `.rpc('add_shopping_item', ...)` call sites in the kid branches. Cleaner codebase, no functional change.

## iPhone smoke-test checklist

After rebuilding on this branch:

| # | Path | Expected |
|---|---|---|
| 1 | As Randi, open a `recipe_detail` for a household recipe | Cart FAB is **gone**. Only the meal FAB (Icons.calendar_month) is visible. The 'meal' FAB is now the leftmost (and only) FAB in the row. |
| 2 | As Randi, tap the popup menu (3-dot / actions) on `recipe_detail` | "Add to Shopping List" item is **gone**. Menu still has "Add to Meal Plan" + the delete divider/item. |
| 3 | As Randi, open `shopping_list_screen` | The "From recipe" OutlinedButton is **gone**. The "Add item" FilledButton occupies the full Row width (Expanded flex). |
| 4 | As Randi, tap "Add item" → fill name + category + Save | Existing Batch 5a single-item path fires — `add_shopping_item` RPC → wishlist row (or necessity bypass) → SnackBar "Added to wishlist — waiting for approval". Unchanged. |
| 5 | Switch to admin, open the same recipe_detail | Cart FAB is visible again. Popup menu shows "Add to Shopping List". |
| 6 | Admin taps cart FAB → adds ingredients | Existing flow: bulk INSERT into shopping_items. Items appear on the active list directly (admin bypass, unchanged). |
| 7 | Admin opens shopping_list_screen | "From recipe" button is visible alongside "Add item". |
| 8 | Admin taps "From recipe" → opens recipe sheet → selects ingredients → Add | Bulk INSERT into shopping_items with `source_recipe_id` populated. Unchanged from pre-removal behavior. |
| 9 | SQL verify (during Randi session) | Query `shopping_items WHERE source_recipe_id IS NOT NULL AND added_by_member_id = <Randi's id> AND created_at > now() - interval '5 minutes'` should return **zero rows** — kid cannot insert recipe-sourced items anymore. |
| 10 | SQL verify (during admin session) | Same query but for admin's member_id should still work — admin direct INSERTs continue to write `source_recipe_id`. |
| 11 | Approvals screen after meal-request approve | When admin approves a kid's meal_request via the Batch 6a flow, `decide_meal_request` RPC inserts the meal_plans row. Ingredients DO NOT auto-populate the shopping list (that's a future workstream — see Smart Shopping + Pantry Vision stub). This commit doesn't change that; just confirms the only ingredient flow is via meal_plans creation, not direct kid action. |

## Known followups (unchanged from Batch 6a's followups)

- **Batch 6b**: kid recent-requests view + activity feed entries on decide + `RealtimeService.mealRequestsVersion` wire-up.
- **Batch 6c**: push notifications + APNs cert + edge function dispatch.
- **Auto-populate shopping list from approved meal plans**: not in this commit's scope. Today, `decide_meal_request` creates the meal_plans row but doesn't ingredient-explode. The Smart Shopping + Pantry Vision stub (`/audits/2026-05-smart-shopping-pantry-vision-stub.md`) captures the recipe-aggregation + pantry-deduction architecture that would close this loop properly.
- **Latent `shopping_category_screen.dart:104` dispose bug** (from 5b-ii) — still pending.
- **Necessity-vs-dropdown mismatch** (smart-shopping-pantry workstream stub).

## What this commit explicitly did NOT touch

- `shopping_list_screen._addItem` (Batch 5a Site 1 — single-item wishlist add for kids stays)
- `meal_planner_screen._createMealPlan` (Batch 5a Site 3 — admin-only in practice)
- Any RPC or migration
- `Permissions.isKid` helper
- Approvals screen or any other Batch 6a code
- Adult recipe-ingredient paths (the adult INSERT path is what remains as the only path in both handlers now)

## Next steps for the user

1. Review the 2 files (only modifications, no new files).
2. Rebuild iOS on this branch.
3. Smoke-test the 11 paths above. Particular attention to:
   - Randi's recipe_detail showing ONLY the meal FAB (Q1)
   - Randi's shopping_list_screen showing ONLY "Add item" button (Q3)
   - Randi can still add individual items via the wishlist single-item flow (Q4)
   - Admin flows completely unchanged (Q5-Q8)
4. Commit this as a second commit on `feat/meals-batch-6a-2026-05-25` (this branch already has the `3bb7e01` Batch 6a commit).
5. Push the branch when ready.
