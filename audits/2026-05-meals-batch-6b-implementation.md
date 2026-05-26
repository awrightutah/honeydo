# Batch 6b — Meal Requests Followup Implementation Report

Date: 2026-05-25
Branch: `feat/meals-batch-6b-2026-05-25`
Status: **changes uncommitted** — user reviews then commits

## Summary

Closes the three followup items from Batch 6a's deferred list: (1) `RealtimeService.mealRequestsVersion` notifier so meal-request live ticks reach the admin badge + Approvals screen + kid recent-requests tab; (2) `meal_request_decided` activity-feed entries via the existing client-side aggregator (6th source query block); (3) new kid-only "My Requests" tab on `recipe_library_screen`. Bundled the MembershipHelper migration on both `activity_feed_screen` and `recipe_library_screen` (Q4 + Q5) so the kid actually sees their own perspective rather than the admin's coerced one. No migrations, no new RPCs, no push notifications (those are 6c).

All 11 locked decisions honored.

## Files modified

| File | Type | Net LOC | Purpose |
|---|---|---|---|
| `apps/mobile/lib/services/realtime_service.dart` | modified | +14 | New `mealRequestsVersion` ValueNotifier, `meal_requests` Postgres subscription block, and `reset()` line. Copy-paste of existing 8 notifiers. |
| `apps/mobile/lib/screens/home_shell_screen.dart` | modified | +2, -5 | Hook the notifier to the existing `_onApprovalsSourceChanged` fan-in alongside chores+shopping. Dropped the 6a TODO comment that flagged this as missing. |
| `apps/mobile/lib/screens/approvals_screen.dart` | modified | +14 | New `mealRequestsVersion.addListener(_onRealtimeUpdate)` so admin mid-Approvals sees a kid's fresh submission appear without nav-return. Imports `realtime_service.dart`. |
| `apps/mobile/lib/screens/activity_feed_screen.dart` | modified | +85 | (Q4) Migrate to `MembershipHelper.loadActiveMembership`; add `ActiveMemberService` listener. Add 6th query block for `meal_requests` (decided only). New filter chip "Meals". New icon arm (`Icons.restaurant_menu`, green-vs-coral by status). New description arm with optional `decided_note` inline. |
| `apps/mobile/lib/screens/recipe_library_screen.dart` | modified | +260 | (Q5) Migrate to `MembershipHelper`; add `ActiveMemberService` listener. Dynamic `_tabCount` (2 for adult, 3 for kid). New `_buildMyRequestsTab` builder. New `_MyRequestCard` widget (recipe thumbnail + title + status pill + per-status second line). `mealRequestsVersion.addListener` for live status refresh. |

**Net: ~+370 LOC** — close to the upper end of the investigation's 340–390 estimate.

## Phase 1 — RealtimeService notifier

`apps/mobile/lib/services/realtime_service.dart`:

```dart
final ValueNotifier<int> mealRequestsVersion = ValueNotifier(0);
// ...
_channel!.onPostgresChanges(
  event: PostgresChangeEvent.all,
  callback: (_) => mealRequestsVersion.value++,
  filter: PostgresChangeFilter(
    type: PostgresChangeFilterType.eq,
    column: 'household_id',
    value: householdId,
  ),
  schema: 'public',
  table: 'meal_requests',
);
// ...
// reset():
mealRequestsVersion.value = 0;
```

Zero-risk copy-paste of the existing 8 notifiers. Tested by the simple fact that the same shape compiles and the analyzer shows no new errors.

## Phase 2 — home_shell wiring

```dart
// initState:
RealtimeService.instance.mealRequestsVersion.addListener(_onApprovalsSourceChanged);
// dispose:
RealtimeService.instance.mealRequestsVersion.removeListener(_onApprovalsSourceChanged);
```

Plus the 6a TODO comment block at the original lines 120-124 was removed in `_loadPendingTotal`. That comment had read: "Batch 6a — RealtimeService doesn't expose a mealRequestsVersion notifier today, so meal request count freshness relies on initial load + navigation-return refresh… Wire a real listener when Batch 6b adds the recent-requests UI or Batch 6c adds push notifications." That work is now done.

## Phase 3 — approvals_screen listener

Added `realtime_service.dart` import and:

```dart
// initState (after _loadData + ActiveMemberService listener):
RealtimeService.instance.mealRequestsVersion.addListener(_onRealtimeUpdate);
// dispose:
RealtimeService.instance.mealRequestsVersion.removeListener(_onRealtimeUpdate);
// new helper:
void _onRealtimeUpdate() {
  if (mounted) _loadData();
}
```

Comment notes the asymmetry: "Chores/wishlist still rely on navigation-return refresh; that hardening is captured for a future polish pass." The instructions only asked for the meal-request listener here, so chores+shopping listeners on this screen are out-of-scope for 6b.

## Phase 4 — activity_feed integration

### Q4 MembershipHelper migration (5-LOC fix bundled)

Replaced lines 32-34 of the legacy `.eq('auth_user_id', user.id)` pattern with:

```dart
final membership = await MembershipHelper.loadActiveMembership(
  includeHouseholdJoin: true,
);

if (membership == null) {
  setState(() => _isLoading = false);
  return;
}

_householdMember = membership;
final householdId = _householdMember!['household_id'];
```

Plus added the `ActiveMemberService.instance.activeMemberId.addListener(_onActiveMemberChanged)` in initState + matching `dispose` cleanup + `_onActiveMemberChanged` helper that triggers `_loadData`. Standard pattern from the 5b-i screens.

### 6th query block — meal_request_decided

Added after the 5th (household_members) block in `_loadData`:

```dart
try {
  final mealReqs = await Supabase.instance.client
      .from('meal_requests')
      .select(
          'id, decided_at, status, decided_note, '
          'household_recipes!meal_requests_recipe_id_fkey(title), '
          'household_members!meal_requests_requested_by_member_id_fkey(display_name, kind)')
      .eq('household_id', householdId)
      .neq('status', 'pending')
      .order('decided_at', ascending: false)
      .limit(20);

  for (final m in mealReqs) {
    allActivities.add({
      'type': 'meal_request_decided',
      'timestamp': m['decided_at'],
      'member_name': m['household_members']?['display_name'] ?? 'Someone',
      'member_kind': m['household_members']?['kind'] ?? 'adult_auth_user',
      'recipe_title': m['household_recipes']?['title'] ?? 'a meal',
      'status': m['status'],
      'decided_note': m['decided_note'],
      'id': m['id'],
    });
  }
} catch (_) {}
```

Pending requests don't surface — only decided ones (per the spec: "Same channels fire on both approve and deny").

### Filter chip "Meals"

Slotted between "Rewards" and "Members":

```dart
_buildFilterChip('meal_request_decided', 'Meals', Icons.restaurant_menu),
```

### Icon arm

New switch arm in `_buildActivityIcon`. Uses `Icons.restaurant_menu` (Q10) with `AppColors.grassGreen` for approved and `AppColors.coral` for denied (Q11). The arm is wrapped in a self-invoking closure because Dart switch arms don't allow inline `final` bindings without it:

```dart
'meal_request_decided' => () {
    final approved = activity['status'] == 'approved';
    final color = approved ? AppColors.grassGreen : AppColors.coral;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        shape: BoxShape.circle,
      ),
      child: Icon(Icons.restaurant_menu, color: color, size: 20),
    );
  }(),
```

### Description arm

```dart
'meal_request_decided' => () {
    final approved = activity['status'] == 'approved';
    final title = activity['recipe_title'] ?? 'a meal';
    final note = (activity['decided_note'] as String?)?.trim();
    if (approved) {
      return ' had "$title" approved for the meal plan';
    }
    if (note != null && note.isNotEmpty) {
      return ' had "$title" denied — "$note"';
    }
    return ' had "$title" denied';
  }(),
```

Reads naturally with the existing actor prefix: e.g., **Randi 👦** *had "Pad Thai" approved for the meal plan*.

## Phase 5 — Recipe library kid tab

### Q5 MembershipHelper migration

`_loadData` now starts with:

```dart
final membership = await MembershipHelper.loadActiveMembership(
  includeHouseholdJoin: true,
);
```

…then continues with the household recipes / master recipes / shopping lists queries as before, but with an added kid-only meal_requests query. Plus `ActiveMemberService.instance.activeMemberId.addListener(_onActiveMemberChanged)` so the kid-tab appears/disappears immediately when the user toggles profiles.

### Dynamic TabController length

TabController's `length` is fixed at construction. To swap between 2-tab (adult) and 3-tab (kid) layouts, the helper `_syncTabCount` recreates the controller in-place when the desired count changes:

```dart
int _tabCount = 2;

void _syncTabCount(int desired) {
  if (desired == _tabCount) return;
  final oldIndex = _tabController.index;
  _tabController.dispose();
  _tabCount = desired;
  _tabController = TabController(
    length: _tabCount,
    vsync: this,
    initialIndex: oldIndex.clamp(0, _tabCount - 1),
  );
}
```

Called from `_loadData` right before `setState`, with `_syncTabCount(isKid ? 3 : 2)`. The `.clamp` preserves the user's current tab when possible (e.g., if they were on Browse Library and switch profiles, they stay on Browse Library; if they were on "My Requests" as a kid and switch to admin, they fall back to Browse Library).

`TabBar.isScrollable: showRequestsTab` lets the 3-tab kid layout breathe a bit on narrow screens.

### Kid meal_requests query (in `_loadData`)

```dart
List<Map<String, dynamic>> myRequests = [];
if (isKid) {
  try {
    final reqs = await Supabase.instance.client
        .from('meal_requests')
        .select(
            'id, status, decided_at, decided_note, requested_for_date, '
            'meal_type, created_at, '
            'household_recipes!meal_requests_recipe_id_fkey(id, title, image_url)')
        .eq('requested_by_member_id', membership['id'])
        .order('created_at', ascending: false);
    myRequests = List<Map<String, dynamic>>.from(reqs);
  } catch (e) {
    debugPrint('load my meal requests failed: $e');
  }
}
```

All statuses (no `neq('status', 'pending')` here — the kid wants to see their pending row too, with a yellow pill). Filtered by `requested_by_member_id = membership['id']` — that's the kid sub_profile id once the MembershipHelper migration above resolves correctly.

Soft failure (debug-print only, no SnackBar): the rest of recipe_library should still load even if the meal_requests query trips an unexpected RLS edge case.

### `_buildMyRequestsTab` + `_MyRequestCard`

Built outside the State class as a separate `StatelessWidget` (`_MyRequestCard`). Each row has:

- 64×64 thumbnail with `errorBuilder` fallback to a honey-emoji placeholder (or fallback when `image_url` is null entirely).
- Recipe title (bold, 2-line max).
- Status pill (right): yellow "Pending", green "Approved", coral "Denied" — using `AppColors.honeyGold`/`grassGreen`/`coral` with 0.15 opacity background.
- Per-status second line:
  - **Pending**: "Submitted 3d ago" (relative).
  - **Approved**: "Scheduled for Mar 15 · 🌙 Dinner" (date + meal-type emoji + name). Falls back to "On the meal plan" if both are null (defensive — RPC enforces at least one is non-null on approve, so this branch shouldn't fire).
  - **Denied**: `"reason text"` if non-null, else "No reason given".

Empty state: "No meal requests yet. Tap 'Request this meal' on any recipe to start."

Q9 honored: `key: ValueKey(req['id'])` on every `_MyRequestCard`.

Read-only per Q3 — no buttons, no swipe actions, no long-press menu. Cancel/re-request affordances deferred entirely.

## Analyzer

| | Issues | Errors |
|---|---|---|
| Before (baseline) | 366 | 1 (pre-existing `MyApp` test) |
| After | 368 | 1 (same `MyApp` test) |
| **Net** | **+2** | **0** |

The 2 new info-level warnings are both `withOpacity` deprecation infos — one in activity_feed_screen's new icon arm (line 415), one in recipe_library_screen's `_MyRequestCard` status pill. Both are consistent with the existing codebase pattern (every icon arm in `activity_feed_screen._buildActivityIcon` uses `withOpacity`; same in `home_shell`, `approvals_screen`, `chore_dashboard`, etc.). A future hardening pass can sweep all of these at once.

No new errors. No new warnings beyond the codebase's established deprecated-member-use pattern.

## iPhone smoke test checklist

1. **As Randi, open Recipes tab** → "My Recipes" + "Browse Library" + "My Requests" all visible (3 tabs).
2. **As admin, open Recipes tab** → only "My Recipes" + "Browse Library" (2 tabs). No "My Requests".
3. **As Randi, "My Requests" tab empty initially** → empty-state copy: "No meal requests yet. Tap 'Request this meal' on any recipe to start."
4. **As Randi, submit a new meal request from recipe_detail** (existing 6a flow — meal FAB → MealRequestSheet → Send).
5. **Return to recipe_library "My Requests" tab** → new request appears with **yellow "Pending" pill** + "Submitted just now" second line. Recipe thumbnail visible.
6. **As admin on another device (or same after profile switch)**: badge increments without manual refresh thanks to the new `mealRequestsVersion` listener. The "Meal Requests" section in Approvals shows the new pending row.
7. **As admin, approve the request via Approvals screen** (existing 6a `decide_meal_request` flow).
8. **As Randi, observe My Requests tab refresh** (no manual swipe needed — `mealRequestsVersion` ticked) → status now **green "Approved"** + "Scheduled for Mar 15 · 🌙 Dinner" second line.
9. **As admin, open Activity Feed** → see "Randi 👦 had \"<recipe>\" approved for the meal plan" entry with restaurant_menu icon in green tint. Filter chip "Meals" available between "Rewards" and "Members".
10. **As Randi, open Activity Feed** → sees the SAME entry from Randi's perspective. Verifies Q4 MembershipHelper fix landed: pre-6b, Randi's session would silently coerce to admin's membership view; now it's resolved to Randi's actual sub_profile.
11. **As Randi, submit another request; as admin deny it with reason** ("Try tomorrow instead").
12. **As Randi, My Requests** → that row shows **coral "Denied"** pill + `"Try tomorrow instead"` second line (quoted).
13. **Both Randi + admin, Activity Feed** → "Randi 👦 had \"<recipe>\" denied — \"Try tomorrow instead\"" entry with restaurant_menu icon in coral tint.
14. **Mid-session profile switch on `recipe_library` or `activity_feed`** → screen reloads with new perspective immediately (no manual refresh). The "My Requests" tab disappears for admin and reappears for Randi as the active member toggles.

## Known followups

- **Batch 6c**: push notifications + APNs cert + `device_tokens` registration + edge function dispatch + 30-day `meal_requests` auto-archive (cron job or pg_cron). Spec line 143 mentions both auto-archive and APNs landing together as the first push-enabled feature.
- **Batch 7 UI hardening**:
  - 7 remaining screens still using legacy `.eq('auth_user_id', user.id)` pattern (this batch fixed activity_feed + recipe_library; 9 down to 7). List: `chore_dashboard_screen`, `chore_detail_screen`, `shopping_category_screen`, `meal_planner_screen`, `recipe_detail_screen` (post-6a removal), `household_settings_screen`, `members_screen` (verify exact list during Batch 7 inventory).
  - Latent `shopping_category_screen.dart:104` `TextEditingController.dispose` bug from 5b-i smoke.
  - Approvals screen's chores/wishlist sections still rely on navigation-return refresh — not on a realtime listener. The asymmetry was called out in the Phase 3 comment; a future polish pass could add `choresVersion` + `shoppingVersion` listeners on approvals_screen too.
  - `withOpacity` → `withValues` deprecation sweep (codebase-wide).
- **Future kid-side polish**: cancel-pending and re-request-denied affordances (Q3 deferred).

## What this batch deliberately did NOT include

- No migrations.
- No new RPCs.
- No push notifications / APNs / device_tokens / edge function. **All 6c.**
- No 30-day auto-archive. **6c.**
- No mass MembershipHelper migration of the remaining 7 screens. **Batch 7.**
- No chore/wishlist realtime listeners on approvals_screen — only meal_requests. **Batch 7 polish.**
- No cancel-pending or re-request-denied buttons in the kid view. **Deferred / future enhancement.**
- No changes to `decide_meal_request` / `create_meal_request` / `approve_chore` / `approve_wishlist_item` RPCs.
- No changes to `Permissions` helper.
- No StatefulWidget dialogs added (no TextEditingController disposal risk).

## Next steps (for the user)

1. Review the 5 modified files.
2. Rebuild iOS on this branch.
3. Smoke-test the 14 paths above. Particular attention to:
   - Q1/Q2: kid sees 3 tabs, admin sees 2.
   - Q9: filter chip + new icon arm + new description arm all render in activity_feed.
   - Q10: live refresh on profile switch (Q4/Q5 MembershipHelper fixes).
   - Q12: denied row shows `decided_note` as a quoted string.
4. Commit as a single commit on this branch.
5. Push and (optionally) tag a `v0.5.0-meals-followup` after merge.
