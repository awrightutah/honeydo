# Shopping list — wishlist items leak onto main display

Date: 2026-05-25
Branch: `feat/kid-perms-wishlist-2026-05-25` (read-only investigation; no code changes)
Status: investigation complete — **bug confirmed**; **1-line fix** in `_loadShoppingItems`.

## Summary

The main list query in `shopping_list_screen.dart:_loadShoppingItems` filters only by `shopping_list_id` — it does NOT filter `is_wishlist = false`. So wishlist items (kid-pending submissions) appear on the active list as if approved, despite their `is_wishlist=true` flag being correctly written by `add_shopping_item` RPC (Batch 5a + Part-1 fix).

Spec explicitly calls for the filter (line 15 and again at line 65, 136). The fix is one chained `.eq('is_wishlist', false)` on the existing query. ~1 line change, 1 file.

No other queries in this screen need the filter — every other `.from('shopping_items')` call is either an UPDATE/DELETE keyed by `id` (not affected), or scoped narrowly enough that the wishlist concern doesn't apply. RLS doesn't enforce visibility either way (the SELECT policy is household-scoped, by design — admins must be able to see wishlist items in the upcoming Batch 5b Pending Wishlist UI).

## Phase 1 — Main list query (file: `shopping_list_screen.dart`, lines 198-216)

```dart
Future<void> _loadShoppingItems() async {
  if (_activeListId == null) return;

  try {
    final items = await Supabase.instance.client
        .from('shopping_items')
        .select('*, store:stores(name)')
        .eq('shopping_list_id', _activeListId!)
        .order('purchased', ascending: true)
        .order('sort_order');

    setState(() {
      _shoppingItems = List<Map<String, dynamic>>.from(items);
      _isLoading = false;
    });
  } catch (_) {
    if (mounted) setState(() => _isLoading = false);
  }
}
```

- **Filter present**: `.eq('shopping_list_id', _activeListId!)` (scope to the active list)
- **Ordering**: by `purchased` then `sort_order`
- **Filter absent**: `is_wishlist`. No `.eq('is_wishlist', false)`, no `.neq('is_wishlist', true)`, no `.or(...)` workaround.
- **State variable**: `_shoppingItems` (line 42), rendered by the main `ListView` in the build method.

## Phase 2 — Filter status

**No `is_wishlist` filter exists** on this query.

The result is: every row in the active shopping list comes back, including kid-added wishlist items (`is_wishlist=true`). The build method renders them indistinguishably from regular items. From the kid's perspective the wishlist "works" (item disappears from the add-sheet, SnackBar confirms "Added to wishlist") but when they look at the main list they see their item already there — same outcome as if it had been auto-approved.

RLS doesn't hide it either: the `shopping_items_household_select` policy is `USING (is_household_member(household_id))` — by design admin-and-everyone can SELECT wishlist rows, because Batch 5b's Pending Wishlist admin UI will need to query for them.

So the visibility decision lives entirely in the client query. And the client query is missing it.

## Phase 3 — Spec confirmation

Direct quotes from `/audits/2026-05-kid-profile-permissions-spec.md`:

- **Line 15** (Decisions table, row 2 — Wishlist approval UX): *"Admin approve flips `is_wishlist = false` on the existing `shopping_items` row. Active shopping list view filters `where is_wishlist = false`, so the item appears automatically. No row migration, no separate list."*
- **Line 65** (Implementation Notes — Database changes): *"Admin approve flips `is_wishlist = false`; active list view filters `where is_wishlist = false`."*
- **Line 136** (Resolved Questions #2): *"`is_wishlist=true` means 'pending kid request'; admin approve flips to `false` and the item appears in the active shopping list view (which filters `where is_wishlist = false`)."*

The expected behavior is unambiguous: the active list view MUST filter `where is_wishlist = false`. The current implementation doesn't, hence the bug.

## Phase 4 — Recommended fix

Smallest viable fix:

```dart
final items = await Supabase.instance.client
    .from('shopping_items')
    .select('*, store:stores(name)')
    .eq('shopping_list_id', _activeListId!)
    .eq('is_wishlist', false)            // ← add this line
    .order('purchased', ascending: true)
    .order('sort_order');
```

**Why this is the right approach:**

1. Matches the spec language exactly ("filters where is_wishlist = false").
2. Uses Supabase's partial index from migration 0016 — `idx_shopping_items_wishlist (household_id, is_wishlist) WHERE is_wishlist = true` is the inverse, so this filter excludes those rows from the partial index's coverage and stays on the main b-tree scan with `shopping_list_id` (which is well-indexed for the active list lookup). Zero perf concern.
3. Doesn't disturb any other path. UPDATE/DELETE handlers in the same file are all `id`-keyed and don't need this filter.
4. Mirrors the upcoming Batch 5b admin "Pending Wishlist" query, which will be the inverse: `.eq('is_wishlist', true)` to fetch just the pending items.

**Should we filter elsewhere?** Audit of the 9 other `.from('shopping_items')` references in this file:

| Line | Operation | Needs is_wishlist filter? |
|---|---|---|
| 250 | `_togglePurchased` UPDATE keyed by `id` | No (single row by id) |
| 270 | `_deleteItem` DELETE keyed by `id` | No |
| 364 | (Manual purchased toggle from category screen) UPDATE keyed by `id` | No |
| 419 | (Bulk operation) UPDATE keyed by `id` | No |
| 833 | `add_shopping_item` RPC call (kid path, Batch 5a) | Not a SELECT; doesn't apply |
| 924 | Direct INSERT (adult path, Batch 5a) | Not a SELECT |
| 1056 | Direct bulk INSERT (adult site 2) | Not a SELECT |
| 1139 | `add_shopping_item` RPC call (kid path site 2) | Not a SELECT |

**Only `_loadShoppingItems` needs the filter.** One-line change in one file.

### Scope

- File: `apps/mobile/lib/screens/shopping_list_screen.dart`
- Change: add `.eq('is_wishlist', false)` after `.eq('shopping_list_id', _activeListId!)` on line ~205
- LOC: +1
- Migration: none
- Test impact: kid-added items disappear from the main list (correct behavior); they remain visible to admins via the Pending Wishlist section (Batch 5b territory).

### Followup implications

Once the filter lands and kid-added wishlist items are properly hidden from the main list, Batch 5b's Pending Wishlist UI becomes the only place admins see them. **Until 5b ships, admins won't have any in-app view of wishlist items at all** — they'd need SQL access to inspect or approve. Worth noting as a deliberate (short-term) gap; it's the right shape for the long-term but does mean kid-added items pile up invisibly between now and 5b.

If 5b is more than a day away, consider adding a tiny "X pending wishlist items" badge somewhere on shopping_list_screen as an interim — but that's polish, not required for this bug fix.

## Read-only constraint honored

No code, no migrations, no commits. Only this audit file written.
