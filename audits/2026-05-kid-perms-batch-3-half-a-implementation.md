# Kid Permissions Batch 3 Half A — Implementation

Date: 2026-05-22
Branch: `feat/kid-perms-helper-batch-3-half-a-2026-05-22` (working-tree only; no commits)
Scope: new `apps/mobile/lib/utils/permissions.dart` + 11 functional gate refactors + `'admin'` → `'owner'` flip in household setup
Status: code complete — **not committed; analyzer delta = 0**

## Summary

Half A is done. The new `permissions.dart` introduces a `Permissions` class with 3 identity helpers + 10 named action helpers, all static, all delegating to a single `isAdmin(m)` check that includes the `kind != 'sub_profile'` defense-in-depth clause. 11 functional role gates across 9 screens migrated to use the named action helpers; 5 display-only role reads were left intact per the investigation. `household_setup_screen.dart:96` flipped from `'role': 'admin'` to `'role': 'owner'` so new household creators land with the correct role going forward.

Analyzer: **333 issues both before and after — net delta zero, no new errors**. The only error (`MyApp` in `widget_test.dart`) is pre-existing and unrelated.

## Files created

| File | Lines | Purpose |
|---|---|---|
| `apps/mobile/lib/utils/permissions.dart` | 109 | New `Permissions` class — identity helpers (`isKid`, `isAdmin`, `isOwner`) + 10 action helpers (`canEditHousehold`, `canVerifyChores`, `canEditAnyChore`, `canManageMembers`, `canInviteMembers`, `canManageRewards`, `canDecideRequests`, `canManageNecessityCategories`, `canManageBilling`, `canManageAnnouncements`) |
| `audits/2026-05-kid-perms-batch-3-half-a-implementation.md` | this | Implementation report |

## Files modified

10 files total (9 screen refactors + household setup flip). Each modified screen also gained `import '../utils/permissions.dart';`.

| File | Sites | Change |
|---|---|---|
| `screens/announcements_screen.dart` | 1 | Line 42: assignment to `_isAdmin` → `Permissions.canManageAnnouncements(_myMembership)`. Lines 205, 226, 316 unchanged (still read `_isAdmin` local). Already widened from old `'owner' \|\| 'admin'` to identical helper semantics. |
| `screens/chore_detail_screen.dart` | 2 | Line 345: `isAdmin` local → `Permissions.canEditAnyChore(_householdMember)`. Line 380 (inside `_buildViewMode`): `isAdmin` local → `Permissions.canVerifyChores(_householdMember)`. **Widened** from `role == 'admin'` to owner-or-admin. |
| `screens/chore_dashboard_screen.dart` | 2 | Line 106: inline `_myMembership!['role'] == 'admin'` → `Permissions.canVerifyChores(_myMembership)` (also removed the bang — helper is null-safe). Line 281: `isAdmin` local → `Permissions.canVerifyChores(_myMembership)`. **Both widened.** |
| `screens/settings_screen.dart` | 1 | Line 441: `isAdmin` local → `Permissions.isAdmin(_myMembership)`. Lines 468 (display) and 489-490 (gate) keep consuming the local. **Widened.** |
| `screens/rewards_screen.dart` | 1 | Line 833: inline `_myMembership?['role'] == 'admin'` → `Permissions.canManageRewards(_myMembership)`. **Widened.** |
| `screens/members_screen.dart` | 1 | Line 127: `isAdmin` local → `Permissions.canManageMembers(_myMembership)`. Display sites at 350/354/358 left untouched. **Widened.** |
| `screens/invite_management_screen.dart` | 1 | Line 62: `_isAdmin` getter → `Permissions.canInviteMembers(_myMembership)`. Already widened semantics. |
| `screens/home_shell_screen.dart` | 1 | Lines 564-565 (`_promptToSetMissingPin`): removed `final role = _myMembership?['role']` + replaced isAdmin computation with `Permissions.canManageMembers(_myMembership)`. Already widened semantics. |
| `screens/household_setup_screen.dart` | 1 | Line 95-96: comment + `'role': 'admin'` → `'role': 'owner'`. Not a refactor — sets the role for new household creators going forward. |

5 display-only sites that were explicitly NOT touched (per investigation): `profile_screen.dart:418-420`, `member_profile_screen.dart:221`, `members_screen.dart:350/354/358`. These render different labels/styles for different roles, not gates.

## Analyzer deltas

| | Total | Errors |
|---|---|---|
| Baseline (pre-edit) | 333 | 1 (pre-existing `MyApp` test) |
| After all 11 refactors + household_setup flip | 333 | 1 (same pre-existing) |

Net delta: **0 issues, 0 new errors**. Type-stable refactor as expected.

## Verification checklist for iPhone testing

Per the investigation's Q4 flag, **6 gates were widened** from "admin-only" to "owner OR admin." The Wrights creator is now `role='owner'` (per migration 0016's backfill), so these 6 should all START WORKING for that user (whereas before Half A they would have silently denied). Worth a smoke test:

| # | Site | Action to test as the Wrights owner | Expected |
|---|---|---|---|
| 1 | `chore_detail_screen.dart:345` | Open a chore detail. Verify the "Edit" and "Delete" icons are visible in the app bar. | Visible. |
| 2 | `chore_detail_screen.dart:380→515` | Find a chore in `pending_verification` status. Verify the "Approve" / "Reject" affordance is shown. | Visible. |
| 3 | `chore_dashboard_screen.dart:106` | Open the Chores tab. Verify pending-verification list loads. | Pending list loads. |
| 4 | `chore_dashboard_screen.dart:281→331+347` | Same screen, the "Pending Verification" UI section. | Section renders. |
| 5 | `settings_screen.dart:441→489-490` | Open Settings. Verify "Edit household" is tappable with edit icon trailing. | Tappable; icon shown. |
| 6 | `rewards_screen.dart:833` | If there's a pending redemption, verify the "Approve" button appears. | Visible (when pending exists). |
| 7 | `members_screen.dart:127→190` | Open Household Members. Verify "Invite Others" section AND "Add Kid Profile" FAB are visible. | Both visible. |

The 3 gates that already accepted owner OR admin (and should continue to work unchanged):

| # | Site | Action | Expected |
|---|---|---|---|
| 8 | `announcements_screen.dart:42→205/226/316` | Open Announcements; verify FAB + edit/delete affordances are visible. | Visible. |
| 9 | `invite_management_screen.dart:62→383` | Open Invite Management. Verify the FAB is shown. | Visible. |
| 10 | `home_shell_screen.dart:565` | Open the profile switcher, tap a kid that doesn't have a PIN set. Verify the "Set PIN" dialog appears (not the "ask an admin" snackbar). | Dialog appears. |

Plus the one creator-role smoke test:

| # | Action | Expected |
|---|---|---|
| 11 | **New** household signup (create a fresh household from scratch) | The newly-created household_members row for the creator should have `role='owner'` (verify via the SQL editor: `select role from household_members where auth_user_id = '<that user>' order by created_at desc limit 1`). |

## Known followups (carry forward into Half B and later)

**Half B scope** (separate investigation later):
- Migrate `chore_dashboard_screen.dart:_verifyChore` (line ~192) to use `approve_chore(p_chore_id, p_approved, p_reason)` RPC. The existing kid/adult-branching logic moves server-side.
- Migrate `chore_dashboard_screen.dart:_completeChore` (line ~130) to use `complete_chore_self(p_chore_id, p_member_id)` RPC. Required for non-admin adults after 0017 tightened the chores RLS (today it would break for them — see Batch 2 implementation report).
- Migrate `chore_detail_screen.dart` direct UPDATEs (~lines 196, 880) — they'll also need to route through the RPC layer for admin-gated chore mutations.
- Test the rejected-chore "Re-do" flow per Q1 (kid taps Re-do → status back to 'assigned'). UI work for the re-do button is Batch 4.

**Other open items unchanged:**
- pg_cron photo retention migration still deferred (approve_chore already writes `delete_after`; actual cron job pending).
- Spec amendment per Batch 1 followup #3 (drop `is_household_kid`, drop `chore_verification_photos.rejected_reason`, note pg_cron deferral, reword the "not backfilled" line).
- The 5 display-only role reads could be centralized into a small `RoleDisplay` helper as a separate cleanup pass (would let `member_profile_screen:221`, `members_screen:350-358`, `profile_screen:418-420` share label/color logic). Not in any current batch scope.
- Possible Permissions extension when Batch 5 wishlist UI lands: `canSeeWishlist(membership)` might be useful for the admin "Pending Wishlist" section. Add then.

## Next steps

1. **You review** the diff. `git diff --stat` will show 9 modified screens + 2 new files (the helper and this report).
2. **Smoke-test on iPhone**: log in as the Wrights owner, run the 11-item checklist above. The 6 widened gates are the most interesting — they should now grant permission where previously they would have denied.
3. **Optional manual test**: create a fresh household with a different account; confirm new creator row has `role='owner'`.
4. **Commit** the helper + 10 modified files as a single Half A commit on `feat/kid-perms-helper-batch-3-half-a-2026-05-22`. Push with `--set-upstream`.
5. **Schedule Half B investigation** when ready — that's where the chore RPC migration lands and the previously-flagged non-admin-adult `_completeChore` breakage gets resolved.

## Git state (uncommitted)

```
$ git status --short
M apps/mobile/lib/screens/announcements_screen.dart
M apps/mobile/lib/screens/chore_dashboard_screen.dart
M apps/mobile/lib/screens/chore_detail_screen.dart
M apps/mobile/lib/screens/home_shell_screen.dart
M apps/mobile/lib/screens/household_setup_screen.dart
M apps/mobile/lib/screens/invite_management_screen.dart
M apps/mobile/lib/screens/members_screen.dart
M apps/mobile/lib/screens/rewards_screen.dart
M apps/mobile/lib/screens/settings_screen.dart
?? apps/mobile/lib/utils/permissions.dart
?? audits/2026-05-kid-perms-batch-3-half-a-implementation.md
?? audits/2026-05-kid-perms-batch-3-half-a-investigation.md
```

9 modified screens + 1 new helper file + 2 new audit docs. Working tree otherwise clean on `feat/kid-perms-helper-batch-3-half-a-2026-05-22`.
