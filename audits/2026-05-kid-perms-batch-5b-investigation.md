# Kid Permissions Batch 5b — Investigation

Date: 2026-05-25
Branch: `feat/kid-perms-wishlist-batch-5b-2026-05-25` (read-only investigation; no edits, no commits)
Base: 5a shipped (`843f4cd` + `527b958`); approve_wishlist_item RPC, the guard trigger, and the wishlist-display filter are all in place.
Status: investigation complete — **no blockers**; **no new migration needed**; ~315 LOC across 3 files.

## Summary

5b is pure Dart UI work that lights up two affordances the 5a backend already supports:

1. **Admin Pending Wishlist section** on `chore_dashboard_screen.dart`, sitting directly below the existing Pending Verification section. Approve calls the `approve_wishlist_item` RPC shipped in migration 0021; Deny does a direct DELETE on `shopping_items` (RLS already permits admin DELETE).
2. **Necessity Categories admin screen** (new file) reachable from `settings_screen.dart`'s Household section. Lists current categories, allows Add via dialog, Delete via confirmation.
3. **Settings tile** wiring the screen up, gated on `Permissions.canManageNecessityCategories` (already in the helper).

No new RPC, no migration, no schema change. Existing RLS policies cover every query and write. Single Batch 5b, ~315 LOC across 1 new file + 2 modified files.

The one tweak worth noting: 5a's `add_shopping_item` RPC sets `added_by_member_id` to the kid's member id, so the requester join in Phase 1's query is straightforward — `shopping_items.added_by_member_id` → `household_members.display_name`.

## Phase 1 — Query design

### Proposed Supabase query (placed inside chore_dashboard's `_loadData`)

```dart
List<Map<String, dynamic>> pendingWishlist = [];
if (Permissions.canVerifyChores(_myMembership)) {
  pendingWishlist = await Supabase.instance.client
      .from('shopping_items')
      .select(
        '*, requester:household_members!added_by_member_id(display_name, avatar_url, kind)'
      )
      .eq('household_id', householdId)
      .eq('is_wishlist', true)
      .order('created_at', ascending: false);
}
```

Mirrors the existing `_pendingVerification` query pattern (line 116-121 of `chore_dashboard_screen.dart` — same `assignee:household_members!assigned_to_member_id(display_name)` foreign-table syntax).

### RLS verification

- **`shopping_items` SELECT** policy (migration 0017:840-842): `USING (is_household_member(household_id))` — any household member can SELECT. Admin's JWT passes this trivially. ✅
- **`shopping_items` DELETE** policy (0017:867-869): `USING (is_household_admin(household_id))` — admin can DELETE directly without an RPC. ✅
- **The trigger from 5a** (`guard_shopping_items_wishlist_change`) is BEFORE UPDATE, not BEFORE DELETE — so direct admin DELETE is unaffected. ✅

### State field for `chore_dashboard_screen`

Add alongside `_pendingVerification` (line 25):

```dart
List<Map<String, dynamic>> _pendingWishlist = [];
```

Load in the existing `if (Permissions.canVerifyChores(_myMembership)) { ... }` block. Update the `setState` in `_loadData` to include `_pendingWishlist = ...;`.

### Count badge for the section header?

Existing pattern: Pending Verification has a count badge via `_SectionHeader(title: 'Pending Verification', count: totalVerification)` (line 502). The badge style is honeyGold pill (lines 611-618). Recommend **yes** — same pattern for Pending Wishlist; match the existing UX. Surfaced as Q1.

## Phase 2 — Pending Wishlist card design

### Skeleton (parallel to `_VerificationCard`)

```dart
class _WishlistCard extends StatelessWidget {
  const _WishlistCard({
    required this.item,
    required this.onApprove,
    required this.onDeny,
  });
  final Map<String, dynamic> item;
  final VoidCallback onApprove;
  final VoidCallback onDeny;

  @override
  Widget build(BuildContext context) {
    final name = item['name'] ?? 'Unnamed item';
    final category = item['category'] as String?;
    final displayQty = item['display_quantity'] as String?;
    final requester = item['requester'] as Map<String, dynamic>?;
    final requestedBy = requester?['display_name'] ?? 'Someone';
    final createdAt = item['created_at'] as String?;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(name,
                    style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w800)),
                ),
                if (displayQty != null && displayQty.isNotEmpty)
                  Text(displayQty,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    )),
              ],
            ),
            if (category != null && category.isNotEmpty) ...[
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.honeyGold.withOpacity(.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(category,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.honeyGold,
                  )),
              ),
            ],
            const SizedBox(height: 4),
            Text(
              'Requested by $requestedBy · ${_formatRelative(createdAt)}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onDeny,
                    icon: const Icon(Icons.close_rounded, size: 18),
                    label: const Text('Deny'),
                    style: OutlinedButton.styleFrom(foregroundColor: AppColors.coral),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: onApprove,
                    icon: const Icon(Icons.check_rounded, size: 18),
                    label: const Text('Approve'),
                    style: FilledButton.styleFrom(backgroundColor: AppColors.grassGreen),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
```

Roughly mirrors `_VerificationCard` (lines 801-915 of chore_dashboard) — same Card → Padding → Column → title row → metadata → button row layout. The button colors match (coral for the destructive Deny, grassGreen for Approve), preserving visual consistency between Pending Verification and Pending Wishlist sections.

`_formatRelative` would be a small helper (e.g., "2h ago", "yesterday") — can be reused if already in the file; if not, ~15 LOC for a basic formatter.

### Approve handler

```dart
Future<void> _approveWishlistItem(String itemId) async {
  try {
    await Supabase.instance.client.rpc('approve_wishlist_item', params: {
      'p_item_id': itemId,
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Item added to shopping list')),
      );
    }
    _loadData();
  } catch (e) {
    debugPrint('approve_wishlist_item failed: $e');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not approve item: $e')),
      );
    }
  }
}
```

Pass 2 error-surfacing pattern honored: `catch (e) → debugPrint → non-const SnackBar with $e`.

### Deny handler

```dart
Future<void> _denyWishlistItem(String itemId, String itemName) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Delete this wishlist item?'),
      content: Text("This can't be undone. \"$itemName\" will be removed."),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: FilledButton.styleFrom(backgroundColor: AppColors.coral),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;

  try {
    await Supabase.instance.client
        .from('shopping_items')
        .delete()
        .eq('id', itemId);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Wishlist item removed')),
      );
    }
    _loadData();
  } catch (e) {
    debugPrint('deny wishlist item failed: $e');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not delete item: $e')),
      );
    }
  }
}
```

Confirmation modal copy per Q10's pattern from 5a. RLS permits admin DELETE directly — no RPC needed for this path.

## Phase 3 — chore_dashboard integration

### Existing structure relevant to the integration

`chore_dashboard_screen.dart` already has the scaffolding:
- Line 25: `List<Map<String, dynamic>> _pendingVerification = [];` (state field pattern)
- Lines 112-145: parallel admin-only query block under `if (Permissions.canVerifyChores(_myMembership))`
- Lines 147-153: `setState` block in `_loadData` that captures the results
- Lines 500-515: `if (isAdmin && _pendingVerification.isNotEmpty) ...[` section in `build()` (just above "My Chores")
- Lines 600-622: `_SectionHeader` widget (Text + count badge)
- Lines 801+: `_VerificationCard` widget (the analog of what `_WishlistCard` will be)

### Changes needed

1. **State field** (~1 LOC at line ~26):
   ```dart
   List<Map<String, dynamic>> _pendingWishlist = [];
   ```

2. **Parallel query in `_loadData`** (~10 LOC inside the existing `if (Permissions.canVerifyChores(_myMembership))` block, alongside the photo-loading code):
   - The shopping_items SELECT shown in Phase 1
   - Captures into `pendingWishlist` local var

3. **setState capture** (~1 LOC):
   ```dart
   _pendingWishlist = List<Map<String, dynamic>>.from(pendingWishlist);
   ```

4. **New section in `build()`** (~15 LOC) — directly below the existing Pending Verification section block, before "My Chores":
   ```dart
   // Pending Wishlist section (admin only)
   if (isAdmin && _pendingWishlist.isNotEmpty) ...[
     _SectionHeader(title: 'Pending Wishlist', count: _pendingWishlist.length),
     const SizedBox(height: 8),
     ..._pendingWishlist.map((item) => _WishlistCard(
           item: item,
           onApprove: () => _approveWishlistItem(item['id']),
           onDeny: () => _denyWishlistItem(item['id'], item['name'] ?? 'Item'),
         )),
     const SizedBox(height: 24),
   ],
   ```

5. **Two new handler methods** (~50 LOC) — placed near `_verifyChore` (line 289). The skeletons are shown in Phase 2.

6. **`_WishlistCard` widget** (~90 LOC) — placed near `_VerificationCard` (line 801). Skeleton shown in Phase 2.

7. **`_formatRelative` helper** (~15 LOC if not already present in the file) — small Dart formatter for "2h ago", "yesterday", "3d ago". Reusable.

**Total chore_dashboard impact**: ~120-135 LOC additions, no removals, no structural changes.

### Card extraction vs inline

`_VerificationCard` (the chore equivalent) is its own `StatelessWidget` class. Recommend **extract `_WishlistCard`** — matches `_VerificationCard` pattern, keeps the build() method readable, and the duplication-saving from sharing logic between approve/deny rendering is minimal but real. Surfaced as Q2 (low-stakes; either works).

## Phase 4 — Necessity Categories screen design

### Proposed structure: `apps/mobile/lib/screens/necessity_categories_screen.dart` (~180 LOC)

```dart
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../services/active_member_service.dart';
import '../utils/membership.dart';
import '../utils/permissions.dart';

class NecessityCategoriesScreen extends StatefulWidget {
  const NecessityCategoriesScreen({super.key});

  @override
  State<NecessityCategoriesScreen> createState() => _NecessityCategoriesScreenState();
}

class _NecessityCategoriesScreenState extends State<NecessityCategoriesScreen> {
  Map<String, dynamic>? _myMembership;
  String? _householdId;
  List<Map<String, dynamic>> _categories = [];
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadData();
    ActiveMemberService.instance.activeMemberId.addListener(_onActiveMemberChanged);
  }

  @override
  void dispose() {
    ActiveMemberService.instance.activeMemberId.removeListener(_onActiveMemberChanged);
    super.dispose();
  }

  void _onActiveMemberChanged() {
    if (mounted) _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final membership = await MembershipHelper.loadActiveMembership(
        includeHouseholdJoin: true,
      );
      if (membership == null) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'No household membership found';
        });
        return;
      }
      _myMembership = membership;
      _householdId = membership['household_id'];

      final rows = await Supabase.instance.client
          .from('necessity_categories')
          .select()
          .eq('household_id', _householdId!)
          .order('category');

      setState(() {
        _categories = List<Map<String, dynamic>>.from(rows);
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('necessity_categories load failed: $e');
      setState(() {
        _isLoading = false;
        _errorMessage = 'Could not load categories: $e';
      });
    }
  }

  Future<void> _showAddDialog() async {
    final controller = TextEditingController();
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add necessity category'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          maxLength: 50,
          decoration: const InputDecoration(
            hintText: 'e.g. Personal Care',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty) return;

    // Duplicate check (case-insensitive)
    final existsCi = _categories.any(
      (row) => (row['category'] as String).toLowerCase() == result.toLowerCase(),
    );
    if (existsCi) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('"$result" already exists')),
        );
      }
      return;
    }

    try {
      await Supabase.instance.client.from('necessity_categories').insert({
        'household_id': _householdId!,
        'category': result,
      });
      _loadData();
    } catch (e) {
      debugPrint('necessity_category insert failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not add category: $e')),
        );
      }
    }
  }

  Future<void> _confirmAndDelete(String category) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete category?'),
        content: Text(
          "Remove \"$category\" from necessity categories? Existing items with this category aren't affected.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.coral),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await Supabase.instance.client
          .from('necessity_categories')
          .delete()
          .eq('household_id', _householdId!)
          .eq('category', category);
      _loadData();
    } catch (e) {
      debugPrint('necessity_category delete failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not delete category: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = Permissions.canManageNecessityCategories(_myMembership);

    return Scaffold(
      appBar: AppBar(title: const Text('Necessity Categories')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
              ? Center(child: Text(_errorMessage!))
              : !isAdmin
                  ? const Center(child: Text('Admins only'))
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            'Items added by kids in these categories skip the wishlist and go directly to the shared shopping list.',
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (_categories.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(32),
                            child: Center(
                              child: Text('No necessity categories yet.'),
                            ),
                          )
                        else
                          ..._categories.map((row) {
                            final name = row['category'] as String;
                            return Card(
                              margin: const EdgeInsets.only(bottom: 8),
                              child: ListTile(
                                leading: const Icon(Icons.category_outlined),
                                title: Text(name),
                                trailing: IconButton(
                                  icon: Icon(Icons.delete_outline, color: AppColors.coral),
                                  onPressed: () => _confirmAndDelete(name),
                                  tooltip: 'Delete',
                                ),
                              ),
                            );
                          }),
                      ],
                    ),
      floatingActionButton: isAdmin
          ? FloatingActionButton.extended(
              onPressed: _showAddDialog,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add'),
            )
          : null,
    );
  }
}
```

### Notes

- **Active-member-aware load** via `MembershipHelper.loadActiveMembership` (the helper from Part 1 of the wishlist hotfix). Listener wiring lets the screen reload if user switches profile mid-screen.
- **Admin gate** at the build level. Defensive — only admins ever reach this screen via the Settings entry, but the runtime check costs nothing and matches the workstream pattern.
- **Free-text input** per Q7 with `maxLength: 50` (kept tidy, doesn't break the UI). Surfaced as Q4 — whether 50 is right or should be different.
- **Case-insensitive duplicate check** on the client before INSERT (matches the case-insensitive necessity-bypass logic in `add_shopping_item`). Composite PK in the table catches duplicates server-side too, but the client check prevents a confusing "succeeded but nothing changed" UX on conflict.
- **No inline edit**. Edit-by-rename would require DELETE + INSERT (composite PK); the UI is delete-and-readd, which is what the spec specifies.
- **No kid-side view of necessity_categories** — surfaced as Q6 (defer).

## Phase 5 — Settings entry point

### Existing pattern

`settings_screen.dart` uses a section-based `ListView`:
- `_buildSectionHeader('Household')` (line 479) introduces the Household section
- Then `ListTile(leading: Text(emoji), title: ..., subtitle: ..., onTap: ...)` for "Household" itself (line 480-492)

The Necessity Categories tile fits naturally inside the **Household** section, after the existing household-name tile.

### Permissions helper confirmation

From `apps/mobile/lib/utils/permissions.dart` (already verified in prior reads):
```dart
static bool canManageNecessityCategories(Map<String, dynamic>? m) => isAdmin(m);
```

Helper exists, delegates to `isAdmin`. Ready to use.

### Proposed tile

```dart
// Add after the existing Household ListTile (~line 493)
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

Plus add the import at the top of `settings_screen.dart`:
```dart
import 'necessity_categories_screen.dart';
```

**~15 LOC** of settings_screen changes. Gated on `canManageNecessityCategories` — kids won't see it.

### Icon choice

`Icons.category_outlined` reads as "categories" cleanly. Alternatives: `Icons.shopping_basket_outlined` (more explicitly shopping), `Icons.list_alt` (generic list). Surfaced as Q5.

## Phase 6 — Scope estimate

| Component | LOC | Files |
|---|---|---|
| `chore_dashboard_screen.dart` — state + query + section + 2 handlers + `_WishlistCard` widget + `_formatRelative` helper | ~120-135 | modified |
| `apps/mobile/lib/screens/necessity_categories_screen.dart` — full screen | ~180 | **new** |
| `settings_screen.dart` — tile + import | ~15 | modified |

**Total: ~315-330 LOC across 1 new file + 2 modified files. No migration. No new RPC.** Single Batch 5b, no split warranted.

**Scope-creep check**: nothing in the plan creeps into 5c territory. The only items I could imagine adding (kid-side My Pending Wishlist, multi-select bulk delete on categories, unified Pending Requests screen with tabs) are all explicitly out of scope per the brief.

## Phase 7 — Open questions

**UX (mostly low-stakes; all have recommendations):**

- **Q1.** Section count badge on "Pending Wishlist" header — yes/no? Recommend **yes** (matches the Pending Verification pattern; UX consistency).
- **Q2.** `_WishlistCard` extracted widget OR inline in build()? Recommend **extracted** (matches `_VerificationCard`).
- **Q3.** Necessity screen description text wording — proposed: *"Items added by kids in these categories skip the wishlist and go directly to the shared shopping list."* Confirm or tweak.
- **Q4.** Category name `maxLength` — proposed 50 chars. Confirm or pick different.
- **Q5.** Settings tile icon — proposed `Icons.category_outlined`. Alternatives: `Icons.shopping_basket_outlined`, `Icons.list_alt`. Confirm or pick.
- **Q6.** Should kids see the necessity_categories list anywhere? Recommend **no** for 5b (defer; not in spec).
- **Q7.** SnackBar wording for approve/deny:
  - Approve: *"Item added to shopping list"*
  - Deny: *"Wishlist item removed"*
  Confirm or tweak.
- **Q8.** `_formatRelative` for the "Requested by X · 2h ago" line — is there an existing helper anywhere in the codebase (e.g., a `time_ago.dart` util) I should reuse, or just inline a small one in chore_dashboard? Quick scan didn't surface one but worth double-checking before duplicating.

**Architecture (already resolved from 5a's investigation but worth re-confirming):**

- **Q3 from 5a — Pending Wishlist UI location**: confirmed Option A (chore_dashboard second admin section). No change.
- **Q4 from 5a — Deny UX**: confirmed Option 4A (hard delete + confirmation modal). No change.
- **Q11 from 5a — single 5b vs split**: confirmed single batch. ~315 LOC is comfortably in one-batch territory.

## Next steps

1. **You answer Q1-Q8.** Q3, Q4, Q5, Q7, Q8 are the consequential ones; Q1, Q2, Q6 have clear defaults.
2. **I write Batch 5b** — chore_dashboard additions + new screen + Settings tile. Analyzer baseline + after; expect +2-3 info warnings on the two new `.rpc()` + `.delete()` calls in chore_dashboard.
3. **Commit + push** with the standard 2-part-rule template.
4. **iPhone smoke test**:
   - Kid (Randi) adds 3 items → none of them appear on Randi's main list (already correct from 5a).
   - Switch to admin → Pending Wishlist section appears on chore_dashboard with all 3 items, kid name + relative time.
   - Approve one → it appears on main shopping list; Pending Wishlist count decrements.
   - Deny one → confirmation modal → confirm → it's gone; Pending Wishlist count decrements.
   - Open Settings → Household section → tap "Necessity Categories" → screen opens, lists the 4 defaults.
   - Add a new category → appears in list.
   - Delete an existing category → confirmation modal → confirm → it's gone.
   - Add a kid item in a now-necessity category (after the category-alignment workstream lands — out of scope for 5b, but the bypass logic will work once categories match).

After 5b ships, Pass 3 remaining: Batches 6 (meal requests + push), 7 (UI hardening — including migrating the 9 lower-severity screens away from the broken `.eq('auth_user_id', user.id)` pattern), 8 (music app deep link).
