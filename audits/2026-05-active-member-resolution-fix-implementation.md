# Active member resolution fix — implementation report (Part 1 of 2)

Date: 2026-05-25
Branch: `feat/kid-perms-wishlist-2026-05-25`
Status: **changes uncommitted** — Part 1 of a two-commit sequence (Part 2 is the Batch 5a Dart re-implementation; happens next on same branch but as a separate commit)

## Summary

Closes the latent bug surfaced during Batch 5a iPhone smoke-test: 4 screens were loading `_myMembership` (or `_householdMember`) via `.eq('auth_user_id', user.id)`, which always returned the JWT holder's (parent admin's) row. Kid sub_profiles have `auth_user_id IS NULL` so they could never be resolved this way. The profile switcher's "operate as Randi" state in `ActiveMemberService` was being ignored, making `Permissions.isKid(_myMembership)` silently false even when a kid profile was active.

This Part 1 commit:

1. Adds a single centralized helper `MembershipHelper.loadActiveMembership({includeHouseholdJoin})` at `apps/mobile/lib/utils/membership.dart` that does the correct overlay (JWT holder first, then if `ActiveMemberService.activeMemberId.value` is set + differs, load that row and return it instead).
2. Migrates the 4 affected screens to use the helper.
3. Adds `ActiveMemberService.instance.activeMemberId` listeners in each screen's `initState`/`dispose` so a mid-session profile switch triggers a reload.

No write-path branching changes here — Part 2 will re-apply Batch 5a's `Permissions.isKid` branching on top of this fix, so the kid path will finally fire end-to-end.

The 9 other screens using the same broken pattern for display/gating are NOT touched (per the investigation's Phase 5 recommendation — they're medium-severity and can migrate opportunistically).

## Files modified / created

| File | Type | Net LOC | Purpose |
|---|---|---|---|
| `apps/mobile/lib/utils/membership.dart` | **new** | +85 | `MembershipHelper.loadActiveMembership({includeHouseholdJoin})` — single source of truth for "who is the user operating as right now" |
| `apps/mobile/lib/screens/shopping_list_screen.dart` | modified | +14 | Replace JWT-only membership load with helper; add ActiveMemberService listener |
| `apps/mobile/lib/screens/meal_planner_screen.dart` | modified | +13 | Same |
| `apps/mobile/lib/screens/recipe_detail_screen.dart` | modified | +13 | Same; no realtime listener pre-existed, so this is the first listener added to that screen |
| `apps/mobile/lib/screens/chore_detail_screen.dart` | modified | +15 | Same; this is the surprise 5th affected screen that the investigation surfaced (Batch 4 chore_detail kid paths were silently broken) |

## Phase 1A — Helper file structure

**File**: `apps/mobile/lib/utils/membership.dart` (85 lines).

Single public method on a `MembershipHelper` class:

```dart
class MembershipHelper {
  MembershipHelper._();

  static Future<Map<String, dynamic>?> loadActiveMembership({
    bool includeHouseholdJoin = false,
  }) async { ... }
}
```

**Behavior**:
1. If no authenticated user → return null (handled gracefully by callers).
2. Load the JWT holder's row by `auth_user_id` + `is_active = true`. This always exists for an authenticated user with a household membership.
3. Read `ActiveMemberService.instance.activeMemberId.value`. If null or equal to the JWT holder's id → return the JWT row (adult is operating as themselves).
4. Otherwise, load the active member's row by `id` + `is_active = true`. Return that row instead.
5. **Stale-id fallback**: if the stored active_member_id no longer resolves (member was deleted or deactivated), return the JWT holder's row so the screen still loads. Doesn't auto-clear ActiveMemberService — caller decides.
6. **Household join carry-over**: when `includeHouseholdJoin: true` is passed and the overlaid (kid) row's separate query didn't re-join `households`, we copy `households` from the adult row into the kid's map so callers get the same shape regardless of which path resolved.

Documentation block at the top of the file explains why this overlay is necessary (sub_profiles have `auth_user_id IS NULL`) and references the investigation audit.

## Phase 1B — Per-screen migration

Each of the 4 screens follows the same pattern. Diff highlights:

### `shopping_list_screen.dart`

Imports added (line 5-6):
```dart
import '../services/active_member_service.dart';
import '../utils/membership.dart';
```

`initState` (line 84-89):
```dart
super.initState();
_loadData();
RealtimeService.instance.shoppingVersion.addListener(_onRealtimeUpdate);
ActiveMemberService.instance.activeMemberId.addListener(_onActiveMemberChanged);
```

`dispose` symmetric. New `_onActiveMemberChanged()` calls `_loadData()` on profile switch.

`_loadData` (line ~104) replaces the old 13-line `Supabase.instance.client.from('household_members').select(...).eq('auth_user_id', user.id)...` block with:
```dart
final membership = await MembershipHelper.loadActiveMembership(
  includeHouseholdJoin: true,
);
if (membership == null) {
  setState(() => _isLoading = false);
  return;
}
_myMembership = membership;
_household = membership['households'];
final householdId = _household!['id'];
```

### `meal_planner_screen.dart`

Identical pattern. Imports, listener wiring, `_loadData` replacement.

### `recipe_detail_screen.dart`

No realtime listener pre-existed; this is the first time-bound listener added to this screen. `initState` gains:
```dart
ActiveMemberService.instance.activeMemberId.addListener(_onActiveMemberChanged);
```
`dispose` removes it (placed BEFORE the controller `.dispose()` calls so any pending listener fire doesn't race with disposal).

### `chore_detail_screen.dart`

Same pattern. Comment in `_loadData` explicitly calls out why this matters for Batch 4's chore Quick Actions:

```dart
// Resolves to the active kid's row when one is selected via the
// profile switcher, otherwise the JWT holder's adult row. The kid
// path through Quick Actions (Re-do, Complete) depends on
// Permissions.isKid(_householdMember) which only returns true when
// the kid's row is loaded — not the parent's via auth.uid().
```

## Phase 1C — Batch 4 chore_detail verification path

The investigation surfaced that chore_detail's kid paths (Re-do chip, kid Complete chip routing through `submit_kid_chore_with_photo`) were silently broken because `Permissions.isKid(_householdMember)` was always false. After this fix:

1. Switch to Randi via profile switcher (verify it persists across navigation).
2. Navigate to a chore assigned to Randi → chore_detail.
3. Expected: Quick Actions wrap now renders her-eligible chips (Complete → kid path with photo-choice dialog; Re-do if status='rejected').
4. Verify by reading `_householdMember['kind']` (should be `'sub_profile'`) — can be confirmed via a temporary debugPrint, or just by triggering the kid-only flow.

Mark Complete from detail (previously fell through to adult `complete_chore_self`) should now route to `submit_kid_chore_with_photo` correctly. Re-do chip should render on rejected chores assigned to her.

**No test code added** per the brief's "no code changes beyond the migration" implicit scope.

## Phase 1 — Analyzer delta

| Scope | Before Part 1 | After Part 1 | Net new errors | Net new info/warnings |
|---|---|---|---|---|
| `flutter analyze apps/mobile/` | 353 | 353 | **0** | **0** |

The pre-existing `MyApp` error in `test/widget_test.dart:16` is unchanged.

No new lint or inference warnings — the helper has a clean signature, the screen migrations are net-negative LOC in the resulting compiled code (the old 13-line query collapses to a 3-line helper call).

## iPhone smoke test for Part 1

After this commit lands, before Part 2 starts:

1. **Switch to Randi via the profile switcher.** Confirm it persists across app navigation (close the switcher, open settings, come back — should still be Randi).
2. **Navigate to shopping_list_screen as Randi.** Reload the screen. Verify (via debug printing or RLS error path) that `_myMembership['kind']` would now read `'sub_profile'` — the previously-stuck "always admin" coercion is gone. (You can't fully test the kid wishlist flow yet because Part 2 hasn't shipped the branching; the underlying load is just correct now.)
3. **Navigate to chore_detail of a chore assigned to Randi.** Same verification: `_householdMember` should resolve to Randi's row.
4. **Mid-session profile switch test**: while on shopping_list_screen as Randi, switch to admin via the switcher. The screen should reload automatically (the new `_onActiveMemberChanged` handler fires). Switch back to Randi → reloads again.
5. **Edge case — stale active member**: this is hard to test by hand. If Randi were ever deactivated while still selected as the active member, the helper falls back to the adult's row. Behavior: screen loads as adult; switcher should be updated by another flow (e.g., the home_shell guard at line 117).

## Known followups (not part of this commit)

- **9 other screens** use the same `.eq('auth_user_id', user.id)` pattern for display/gating purposes only (calendar, activity_feed, achievements, announcements, etc.). They aren't write-attribution bugs — at worst they show the admin's perspective when a kid is active. Migrating them is a polish pass; many overlap with Batch 7's "kind-based UI hardening" so they can be batched together.
- The 9 affected files are listed in the investigation's Phase 5 table for reference.

## What this commit explicitly does NOT touch

- `apps/mobile/lib/services/active_member_service.dart` — the helper consumes it; doesn't modify it.
- `apps/mobile/lib/utils/permissions.dart` — its logic is correct; the fix is upstream of it.
- `chore_dashboard_screen.dart` — already had the correct overlay pattern; not migrated (would just rename the inline logic to use the helper — a future opportunistic cleanup).
- `home_shell_screen.dart` — also already correct; the switcher source-of-truth.
- Any of the 9 medium-severity screens.
- Shared preferences keys.
- Any write paths (Part 2's job).
- Migration 0021 (untracked from previous Batch 5a work; still on disk; will be part of Part 2's commit).

## Next steps

Part 1 changes are uncommitted. Suggested sequence:

1. User reviews diffs across the 5 files (1 new helper + 4 modified screens).
2. User commits Part 1 as its own commit (e.g., `fix(membership): resolve active member via overlay, not auth.uid()` ).
3. I proceed to Part 2 (re-apply Batch 5a's `Permissions.isKid` branching on the 4 shopping insert sites + the 3 shopping screens, using the now-correctly-resolving `_myMembership`).
4. Migration 0021 (currently untracked) gets committed together with Part 2's Dart re-implementation.

OR — single combined commit covering both Part 1 and Part 2 if the user prefers. The fix is self-contained so either shape works.
