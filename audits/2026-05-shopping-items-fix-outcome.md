# Shopping_items Insert Fix — Outcome

Date: 2026-05-21
Branch: `fix/shopping-items-insert-fix-2026-05-21` (off `fix/migration-bug-patch-2026-05-21`)
Reference: `audits/2026-05-pass-1a-flutter-v3.md`, `audits/2026-05-schema-drift-map.md`

## Problem

Adding recipe ingredients to a shopping list throws `42501: new row violates row-level security policy for table "shopping_items"`.

Root cause: `recipe_detail_screen.dart`'s "Add to Shopping List" insert omits `household_id`. The `household_scoped_shopping_items` RLS policy (`0001_initial_schema.sql:534`) checks `is_household_member(household_id)`; without `household_id` in the row, that check evaluates over a null and the policy denies. The same row also passes `''` (empty string) into the `numeric` column `quantity`, which would throw a type error if RLS let it through.

## Phase 1 — Inventory

`grep -rn "from('shopping_items').insert\|from('shopping_items').upsert" apps/mobile/lib/`:

| Site | File | Line |
|---|---|---|
| 1 | `lib/screens/meal_planner_screen.dart` | 712 |
| 2 | `lib/screens/recipe_detail_screen.dart` | 262 |
| 3 | `lib/screens/shopping_list_screen.dart` | 800 |
| 4 | `lib/screens/shopping_list_screen.dart` | 1076 |

Zero `.upsert` call sites.

## Phase 2 — Per-site verification

| Site | File:Line | `household_id` present? | `quantity` sanitized? | `purchased` field correct? | Verdict |
|---|---|---|---|---|---|
| Meal-planner auto-ingredients | `meal_planner_screen.dart:702` | ✓ `widget.householdId` | ✓ omitted (numeric column accepts NULL) | ✓ `'purchased'` | **OK** |
| Recipe-detail "Add to Shopping List" | `recipe_detail_screen.dart:262` | ✗ **missing** | ✗ `ingMap['quantity']?.toString() ?? ''` sends empty string to numeric | ✓ `'purchased'` | **BROKEN — fixed** |
| Shopping-list manual add sheet | `shopping_list_screen.dart:800` | ✓ `widget.householdId` | ✓ `double.tryParse(quantity)` returns null on empty | ✓ `'purchased'` | **OK** |
| Shopping-list from-recipe sheet | `shopping_list_screen.dart:1076` | ✓ `widget.householdId` | ✓ omitted | ✓ `'purchased'` | **OK** |

## Phase 3 — Fix

One site to fix: `recipe_detail_screen.dart:262`.

The screen already loads `_householdMember` in `_loadData` (lines 73-85). `_householdMember!['household_id']` is the canonical access, and the same screen already uses it at line 344 for the meal-plan insert.

For quantity, recipes in the import-flow store ingredients as `[{'raw': '1 cup flour', ...}]` etc. The `raw` field is the full display string. Some imports also produce a numeric `quantity`. The fix: if the source row has a parseable numeric quantity, send it; otherwise null. Also write the original `raw` text to `display_quantity` so the list still shows "1 cup flour" rather than just "flour".

### Diff — `apps/mobile/lib/screens/recipe_detail_screen.dart`

```diff
     if (confirmed == true && selectedListId != null) {
       try {
         final ingredients = _recipe?['ingredients'] as List<dynamic>? ?? [];
         for (final ing in ingredients) {
           final ingMap = ing is Map ? ing : {'raw': ing.toString()};
+          final rawQuantity = ingMap['quantity'];
+          final parsedQuantity = rawQuantity is num
+              ? rawQuantity
+              : num.tryParse(rawQuantity?.toString() ?? '');
           await Supabase.instance.client.from('shopping_items').insert({
+            'household_id': _householdMember!['household_id'],
             'shopping_list_id': selectedListId,
             'name': ingMap['raw'] ?? ingMap['name'] ?? ing.toString(),
-            'quantity': ingMap['quantity']?.toString() ?? '',
+            'quantity': parsedQuantity,
+            'display_quantity': ingMap['raw']?.toString(),
             'purchased': false,
           });
         }
```

## Phase 4 — Summary

| File | Line | `household_id` present? | `quantity` sanitized? | `purchased` field? | What was changed |
|---|---|---|---|---|---|
| `recipe_detail_screen.dart` | 262 | ✗ → ✓ | ✗ → ✓ | ✓ (unchanged) | Added `household_id` from `_householdMember`; replaced `.toString() ?? ''` with a `num.tryParse` that returns null when not parseable; added `display_quantity` carrying the human-readable text. |
| `meal_planner_screen.dart` | 712 | ✓ | ✓ | ✓ | No change — already correct. |
| `shopping_list_screen.dart` | 800 | ✓ | ✓ | ✓ | No change — already correct. |
| `shopping_list_screen.dart` | 1076 | ✓ | ✓ | ✓ | No change — already correct. |

## Analyzer

| | Total | Errors | Warnings | Infos |
|---|---|---|---|---|
| Before | 327 | 44 | 78 | 205 |
| After  | 327 | 44 | 78 | 205 |
| Delta  | 0 | 0 | 0 | 0 |

No new diagnostics introduced.

## Followups

Spotted while doing this pass; intentionally not fixed:

1. **`shopping_list_screen.dart:1066-1074` (from-recipe ingredient ingest path)** omits any structured handling of the recipe ingredient's `raw` text vs. `quantity`. It sends `'display_quantity': null` and `'name': ing` (where `ing` is a flat string built by the upstream `_AddFromRecipeSheet`). The behavior is correct (no error), but the user loses the parsed numeric quantity if the upstream ever passes structured ingredient maps. Not a current bug.

2. **`recipe_detail_screen.dart:343` "Add to Meal Plan" insert into `meal_plans`** correctly populates `household_id` (line 344) and `created_by_member_id` (line 348). No fix needed; noting it because it's in the same try block as the shopping-items insert and serves as a positive reference for the pattern.

3. **`household_setup_screen.dart:106-119` calendar_tags default-insert loop** has been mentioned in prior batches: each insert is fire-and-forget and the loop has no try/catch around it. If any single insert fails, subsequent ones still run, but no error is surfaced. Out of scope here.

4. **Other tables that take household-scoped writes** were not exhaustively re-audited. The previous drift map (`audits/2026-05-schema-drift-map.md`) tracks them. Notable adjacent risk: `chore_history` writes (none in app today) and `point_transactions` writes that go through the `award_points` RPC and bypass the screen-level RLS concern entirely.

5. **No `.upsert` call sites for `shopping_items`** — confirmed via grep. If an upsert is added later, it would need the same `household_id` discipline.

## Branch & files

- Branch: `fix/shopping-items-insert-fix-2026-05-21`
- Modified: `apps/mobile/lib/screens/recipe_detail_screen.dart` (+5/-1 lines)
- New: `audits/2026-05-shopping-items-fix-outcome.md` (this report)
- Nothing committed.
