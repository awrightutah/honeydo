# Kid Permissions Batch 5b-ii — Implementation Report

Date: 2026-05-25
Branch: `feat/kid-perms-necessity-categories-batch-5b-ii-2026-05-25`
Status: **changes uncommitted** — user reviews then commits

## Summary

Ships the admin-facing CRUD for `necessity_categories` — the household-level bypass list that lets kids add shopping items in certain categories without admin approval. Completes Batch 5b (5b-i shipped the unified Approvals dashboard; 5b-ii is the necessity admin screen + Settings entry).

All 7 locked decisions honored: free-text input with 50-char max, case-insensitive duplicate check, no inline edit (composite PK design), confirmation modal on delete, `Icons.category_outlined` for the Settings tile, description text per spec, kids don't see anything (deferred per Q6).

No new RPC, no migration. Existing RLS on `necessity_categories` (migration 0017 §9g) already permits admin INSERT/UPDATE/DELETE and household-wide SELECT.

## Files modified / created

| File | Type | Net LOC | Purpose |
|---|---|---|---|
| `apps/mobile/lib/screens/necessity_categories_screen.dart` | **new** | +306 | Full screen: state + load + add dialog + delete confirmation + ListView with cards + FAB |
| `apps/mobile/lib/screens/settings_screen.dart` | modified | +12 | Add `Necessity Categories` ListTile in the Household section + import |

**Net: +318 LOC** (vs ~+195 estimated in 5b investigation; +123 over because of the case-insensitive dup check, defensive admin gate, listener wiring, separate dialog StatefulWidget to avoid the controller-dispose bug from 5b-i, empty-state copy, description-text container, error-surfacing on three async paths).

## Phase 1 — `necessity_categories_screen.dart` structure

### State + lifecycle

```dart
Map<String, dynamic>? _myMembership;
Map<String, dynamic>? _household;
List<String> _categories = [];
bool _isLoading = true;
```

- `initState`: `_loadData()` + register `ActiveMemberService.activeMemberId` listener
- `dispose`: removes listener
- `_onActiveMemberChanged`: re-loads; if no longer admin → `Navigator.pop(context)`

Active-member-aware via `MembershipHelper.loadActiveMembership(includeHouseholdJoin: true)` — same pattern as approvals_screen, shopping_list_screen, etc.

### `_loadData`

1. Set loading
2. `MembershipHelper.loadActiveMembership(includeHouseholdJoin: true)`
3. Bail (with loading=false) if null OR not `canManageNecessityCategories`
4. Query `necessity_categories` for the household, ordered by category
5. setState with the categories list

Errors: `catch (e) → debugPrint → non-const SnackBar with $e`.

### `_addCategory`

Opens `_AddCategoryDialog` (separate `StatefulWidget` so its `TextEditingController` is owned by the State class and disposed post-animation — same lesson as the `showRejectReasonDialog` refactor in 5b-i, avoiding the "controller used after disposed" pitfall).

Dialog:
- AlertDialog title "Add necessity category"
- `TextField(autofocus: true, maxLength: 50, textCapitalization: TextCapitalization.words, decoration: hintText "Category name")`
- Cancel + Add (FilledButton)

After dialog returns the entered text:
1. If `null` (Cancel) → return
2. Trim, if empty → SnackBar "Please enter a category name"
3. Case-insensitive duplicate check against `_categories` → SnackBar `"$name" already exists`
4. INSERT (composite PK catches dupes server-side as a backstop)
5. SnackBar `Added "$name" to necessity categories` + reload

Errors caught as above.

### `_deleteCategory(String category)`

1. Confirmation modal — AlertDialog:
   - Title: "Delete category?"
   - Body: `"Remove "$category" from necessity categories? Existing items with this category aren't affected."`
   - Cancel + Delete (coral `FilledButton.styleFrom(backgroundColor: AppColors.coral)`)
2. If confirmed, DELETE `WHERE household_id=X AND category=Y`
3. SnackBar `Removed "$category" from necessity categories` + reload

### `build()`

- Defensive admin gate at top: if loaded but not admin → "Admins only" centered text
- Loading: `CircularProgressIndicator`
- Otherwise: `RefreshIndicator` wrapping `ListView` with:
  - Description container at top (honeyGold-tinted, copy: *"Items added by kids in these categories skip the wishlist and go directly to the shared shopping list."*)
  - Empty state if `_categories.isEmpty`: centered explanation `"No necessity categories yet. Add one below to let kids add items without admin approval."`
  - Otherwise: list of `Card` → `ListTile` per category:
    - leading: `Icon(Icons.check_circle_outline, color: AppColors.grassGreen)`
    - title: category name (bold)
    - trailing: `IconButton(Icons.delete_outline, color: AppColors.coral)` → `_deleteCategory`
    - `key: ValueKey(category)` (matches the Batch-5b-i pattern for dynamic list children to avoid the positional cascade)
- `FloatingActionButton.extended` "Add" → `_addCategory` (hidden during initial loading)

### `_AddCategoryDialog` (private nested widget)

```dart
class _AddCategoryDialog extends StatefulWidget {
  const _AddCategoryDialog({required this.controller});
  final TextEditingController controller;
  @override
  State<_AddCategoryDialog> createState() => _AddCategoryDialogState();
}

class _AddCategoryDialogState extends State<_AddCategoryDialog> {
  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }
  // ... build() returns the AlertDialog
}
```

The State owns the controller's `dispose()` so it fires after the dismissal animation completes. Same architectural fix shipped in 5b-i for `showRejectReasonDialog`.

## Phase 2 — Settings tile

Imports:
```dart
import 'necessity_categories_screen.dart';
```

In `_buildSectionHeader('Household')` section, after the existing Household-name `ListTile` (line ~493), added (admin-gated):

```dart
if (Permissions.canManageNecessityCategories(_myMembership))
  ListTile(
    leading: const Icon(Icons.category_outlined),
    title: const Text('Necessity Categories'),
    subtitle: const Text('Kids can add to these without admin approval'),
    trailing: const Icon(Icons.chevron_right),
    onTap: () => Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const NecessityCategoriesScreen()),
    ),
  ),
```

`Permissions.canManageNecessityCategories` already existed in the helper (delegates to `isAdmin`). Net Settings changes: ~12 LOC.

Kid sessions don't see the tile (the `if` gate hides it). On top of that, the screen itself has its own admin gate as defense in depth.

## Phase 3 — Analyzer

| Scope | Before | After | Net new errors | Net new info/warnings |
|---|---|---|---|---|
| `flutter analyze apps/mobile/` | 360 | 362 | **0** | +2 |

The pre-existing `MyApp` error in `test/widget_test.dart:16` is unchanged.

The +2 routine warnings:
- `withOpacity` deprecation in the new screen (line 232 — the description container's background tint). Same pattern as the rest of the codebase.
- An `inference_failure_on_instance_creation` on the new `MaterialPageRoute` in settings_screen's tile onTap (matches the existing pattern throughout the codebase).

The pre-existing `use_build_context_synchronously` errors in settings_screen.dart at lines 169-384 are unchanged — they live in code I didn't touch (my insertion sits around line 494).

## iPhone smoke test checklist

After rebuilding on this branch:

| # | Path | Expected |
|---|---|---|
| 1 | As admin, open Settings → Household section | New "Necessity Categories" tile visible with category icon, "Kids can add to these without admin approval" subtitle, chevron-right |
| 2 | Tap tile → screen opens | Lists the 4 seeded defaults: Hygiene, School Supplies, Basic Groceries, Medication. Description container at top with explanation copy. FAB "Add" visible. |
| 3 | Tap FAB → AlertDialog with TextField | TextField autofocused, char counter shows 0/50 |
| 4 | Submit empty input (or whitespace only) | SnackBar "Please enter a category name"; dialog dismissed |
| 5 | Try to add "hygiene" (lowercase, matches existing) | SnackBar `"hygiene" already exists`; nothing inserted |
| 6 | Add "Pet Supplies" (new) | Dialog closes, screen reloads with the new category visible; SnackBar `Added "Pet Supplies" to necessity categories` |
| 7 | Tap delete icon on "Pet Supplies" | Confirmation modal opens: "Delete category? Remove 'Pet Supplies' from necessity categories? Existing items with this category aren't affected." |
| 8 | Tap Delete (coral) | Category disappears; SnackBar `Removed "Pet Supplies" from necessity categories` |
| 9 | Tap Cancel in the confirmation | Modal dismisses; category remains |
| 10 | Switch to Randi (kid) → open Settings → Household section | "Necessity Categories" tile NOT visible (admin-gated) |
| 11 | (Edge case) While on the screen, switch to Randi via profile switcher | Screen pops back to home automatically (defensive listener) |
| 12 | Open Necessity Categories with no rows seeded (synthetic test — wouldn't happen in current state) | Empty-state copy renders: "No necessity categories yet. Add one below to let kids add items without admin approval." |

## Known followups

- **Necessity-category vs UI-dropdown mismatch persists** — the 4 seeded defaults (Hygiene, School Supplies, Basic Groceries, Medication) don't match any string in the app's hardcoded shopping category dropdown (Produce, Dairy, Pantry, Personal Care, etc.). So even with this admin UI shipping, the kid bypass path *as a feature* doesn't fire because no kid pick from the dropdown matches anything in `necessity_categories`. The category-architecture reconciliation lives in the smart-shopping-pantry vision stub (`/audits/2026-05-smart-shopping-pantry-vision-stub.md`); requires a strategic decision about a single source of truth across the dropdown + necessities + future store-section concept. Outside the scope of 5b-ii. The admin UI shipped here is correct and ready for whatever reconciliation lands later.
- **5b-ii's admin can manually fix this today** by deleting the 4 defaults and adding 4 new strings that match the dropdown (e.g., add "Pantry", "Dairy", "Personal Care", "Produce"). Kid bypass would then fire for items in those categories.
- **`_SectionHeader` duplication still in place** between chore_dashboard and approvals_screen; necessity_categories_screen didn't add a third copy because it has only one logical "section" (the list itself).

## What 5b-ii explicitly did NOT touch

- `necessity_categories` table schema or RLS (already correct from Batch 1+2)
- Approvals screen or anything from 5b-i
- `Permissions.canManageNecessityCategories` (already in helper)
- Any RPC or migration
- Kid-side view of necessity_categories (Q6 — deferred)
- Inline-edit affordance (composite-PK design uses delete + add)

## Next steps for the user

1. Review the 2 files (1 new screen + Settings tile patch).
2. Rebuild iOS on this branch.
3. Smoke-test the 12 paths above.
4. Commit + push.
5. **Optional immediate followup**: open Necessity Categories as admin and replace the 4 dropdown-mismatched defaults with 4 strings that match the actual dropdown ("Personal Care", "Pantry", "Dairy", "Produce" or similar) to make the kid bypass functional in the current build, pending the broader category-architecture reconciliation.

After 5b-i + 5b-ii ship, Pass 3 remaining: Batch 6 (Meals — drops in as third Approvals section), Batch 7 (UI hardening), Batch 8 (music app deep link).
