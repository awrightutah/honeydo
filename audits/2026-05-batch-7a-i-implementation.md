# Batch 7a-i — MembershipHelper Migration (HIGH-risk write-attribution screens)

Date: 2026-05-26
Branch: `feat/ui-hardening-batch-7a-i-2026-05-26`
Status: **changes uncommitted** — user reviews then commits

## Summary

Migrates 6 HIGH-risk screens off the legacy `.eq('auth_user_id', user.id)` pattern that always returned the parent admin's row instead of the active kid sub_profile. These 6 are the priority subset of the 17-screen Batch 7a work list because each has a real write-attribution or admin-gating bug: kid actions today attribute to the parent admin's `member_id`, OR kid sessions see admin-only UI affordances. The proven 5-step pattern from commits `0a9684a` + `abb2c6b` + `da1392a` (MembershipHelper + ActiveMemberService listener + `_onActiveMemberChanged` reload) is applied to each. The most critical fix is `rewards_screen.dart` — pre-7a-i, a kid's reward redemption would debit the admin's points balance and write the redemption row attributed to the admin.

No migration, no RPC, no new dependency. Net ~91 LOC additions across 6 files.

## Files modified

| File | Net LOC | Risk class | Primary fix |
|---|---|---|---|
| `apps/mobile/lib/screens/announcements_screen.dart` | +14 | HIGH | `_isAdmin = Permissions.canManageAnnouncements(_myMembership)` now reflects active member (kid no longer sees admin Create FAB); `created_by_member_id` on writes attributes correctly |
| `apps/mobile/lib/screens/members_screen.dart` | +18 | HIGH | `Permissions.canManageMembers` gate + admin-only sections now reflect active member; admin write attribution via `_myMembership['id']` correct |
| `apps/mobile/lib/screens/rewards_screen.dart` | +18 | **HIGH (critical)** | `_myPoints` getter now returns kid's balance; redemption writes (`memberId: _myMembership!['id']`) attribute to kid; no more "kid redemption debits admin's balance" |
| `apps/mobile/lib/screens/settings_screen.dart` | +28 | HIGH | `notification_preferences` read/write scoped to active member's id; display-name edit writes to active member's row |
| `apps/mobile/lib/screens/calendar_screen.dart` | +18 | HIGH | Event creation `created_by_member_id` attribution correct; new listener wired alongside existing `choresVersion` listener |
| `apps/mobile/lib/screens/chore_templates_screen.dart` | +17 | HIGH | Template `created_by_member_id` attribution correct |
| **Total** | **~+91 LOC net** | | |

## Per-screen highlights

### 1. `announcements_screen.dart` (+14 LOC net)

- Added `services/active_member_service.dart` + `utils/membership.dart` imports.
- New `dispose()` override (class had none previously).
- `_onActiveMemberChanged` reloads silently.
- `_loadData` swapped legacy `.eq('auth_user_id', ...).limit(1)` lookup for `MembershipHelper.loadActiveMembership(includeHouseholdJoin: true)`.
- Added explicit `debugPrint` on catch path (Pass 2 pattern).
- Added the explicit `else { setState(() => _isLoading = false); }` branch the original code was missing when membership came back empty.

**Bug fixed**: pre-7a-i, kid sessions saw `_isAdmin = true` because `_myMembership` resolved to the parent admin's row, exposing the admin-only Create button. RLS would have blocked an actual kid INSERT, but the UI was wrong. After: kid sees no admin affordances.

### 2. `members_screen.dart` (+18 LOC net)

- Standard 5-step migration. No surprises.
- `Permissions.canManageMembers(_myMembership)` (line 128 — body unchanged) now reflects the active member correctly. Kid sessions no longer see the "Invite" or "Remove member" affordances.
- `adminMemberId: _myMembership!['id']` write attribution at the call to `_showAddSubProfileSheet` (line 121, unchanged) now attributes correctly.

### 3. `rewards_screen.dart` (+18 LOC net) — **CRITICAL FIX**

The most consequential migration in this batch. Pre-7a-i:
- `_myPoints` getter (`_myMembership?['points_balance']`) returned the **parent admin's** balance even when a kid was active.
- Redemption writes attributed `member_id` to the admin's id.
- A kid could see admin's full balance, redeem against it, and the redemption record would attribute to the admin — the kid's own balance never decremented.

Post-7a-i:
- `_myPoints` returns the kid's balance.
- Redemption writes (lines 200, 251 — bodies unchanged) attribute to the kid.
- The affordability check (`if (currentPoints >= pointCost)`) gates against the kid's actual balance.

Added an explicit comment in `_loadData` flagging this as the critical path. Existing `SingleTickerProviderStateMixin` (line 15 — unchanged) is fine; the TabController is created with a fixed length so no ticker churn issues.

### 4. `settings_screen.dart` (+28 LOC net) — **subtlety**

The brief flagged a `TextEditingController` concern: mid-edit profile switch could clobber unsaved input or write to the wrong member.

**Resolution**: settings_screen's State class holds **NO persistent TextEditingController**. The only controller — `nameController` in `_showEditProfileSheet` — is created inside the bottom-sheet builder method, scoped to the sheet's own lifecycle. So no dirty-state confirm dialog is needed in `_onActiveMemberChanged`.

**However**, a pre-existing race condition exists: if the user opens the edit-profile bottom sheet, starts typing, and then a profile switch happens (from another part of the app via `ActiveMemberService`), the sheet's `_myMembership!['id']` read at Save time would write to whichever member is now active. **This is NOT introduced by this migration** — pre-7a-i, `_myMembership` was always the admin, so the sheet always wrote to admin. Post-7a-i, the active member is reflected, so the race becomes visible.

The race is documented in the in-source comment on `_onActiveMemberChanged`. A fix would require capturing `_myMembership['id']` when the sheet opens (closure over the value, not the reactive State) — flagged as a future polish item. Not blocking.

Other notes on this screen:
- The JWT-holder's `profiles` row is still loaded via `currentUser.id` (line 62, post-edit). This is intentional — `profiles` is the JWT-holder's account, not the active member's. Kids have no `profiles` row.
- The `notification_preferences` lookup at line 73 (post-edit) now scopes to the active member's id. Each member (including each kid) gets their own prefs row going forward.

### 5. `calendar_screen.dart` (+18 LOC net) — **multi-listener interaction**

The screen already subscribed to `RealtimeService.choresVersion`. Added `ActiveMemberService.activeMemberId` alongside it:

```dart
RealtimeService.instance.choresVersion.addListener(_onRealtimeUpdate);
ActiveMemberService.instance.activeMemberId.addListener(_onActiveMemberChanged);
```

Both listeners call `_loadData()` via separate handler functions. No double-fire problem: each callback respects the `_isLoading` flag and `setState(() => _isLoading = true)` is idempotent. Worst case is two concurrent reloads if both ticks fire within the same frame — wasted network query but no state corruption.

`_AddEventSheet` (used in event creation) reads `myMemberId: _myMembership!['id']` from the State. Now resolves to the correct active member.

### 6. `chore_templates_screen.dart` (+17 LOC net)

Standard migration. The screen has an existing `_searchController` in State — `dispose()` already cleans it up, and the new `ActiveMemberService.removeListener` slot in before the controller dispose:

```dart
@override
void dispose() {
  ActiveMemberService.instance.activeMemberId
      .removeListener(_onActiveMemberChanged);
  _searchController.dispose();
  super.dispose();
}
```

Template create writes still attribute correctly via `_myMembership['id']` (line 135 — body unchanged). The orthogonal admin-gating issue on the menu entry remains a future-batch followup per the brief.

## Analyzer

| | Issues | Errors |
|---|---|---|
| Before | 368 | 1 (pre-existing `MyApp` test) |
| After | **368** | 1 (same) |
| **Net** | **0** | **0** |

Verified no new hits on any of the 6 touched files. Existing pre-existing hits (multiple `withOpacity` deprecations, a few `unawaited_futures` errors in code I didn't touch, form field `value` deprecations) are unchanged.

## iPhone smoke test checklist (12 paths)

Path 7 (settings TextEditingController) collapsed to a documentation note — no dialog needed since State has no persistent controllers.

1. **As Randi, navigate to announcements_screen** → list loads, no admin Create FAB visible, no admin actions on existing announcements.
2. **As admin, announcements_screen** → Create FAB visible; create an announcement; verify SQL: `select created_by_member_id from announcements where id = <new>` → admin's id.
3. **As Randi, members_screen** → list of members visible; no Invite/Remove affordances; tap a member opens their profile (read-only).
4. **As Randi, rewards_screen** → her points balance shown (NOT admin's); browse rewards; attempt to redeem one within her budget → redemption row created with her `member_id` (SQL verify).
5. **SQL verify**: `select member_id from reward_redemptions where redeemed_at > now() - interval '5 minutes' and member_id = <Randi's id>` → returns the new row. Cross-check Randi's `points_balance` decremented by the cost, admin's `points_balance` unchanged.
6. **As Randi, settings_screen** → her notification prefs row loaded (or defaults if none exists yet); display name shown is Randi's, not admin's; toggle a pref → SQL verify: `select * from notification_preferences where member_id = <Randi's id>` shows the toggle.
7. **(Documentation only)** Settings has no persistent TextEditingController. Mid-sheet edit during profile switch is a pre-existing race (admin opens edit-profile sheet, profile switches to Randi, admin taps Save → would write to Randi). Flagged in code comment for future polish. No dialog added per the brief's fallback option ("just always reload silently + document").
8. **As Randi, calendar_screen** → calendar loads; create an event; SQL verify: `select created_by_member_id from calendar_events where id = <new>` → Randi's id.
9. **SQL verify**: cross-check on a sibling event from admin — admin's id on hers.
10. **As Randi, chore_templates_screen** → list loads (currently kid can reach this through the menu — orthogonal admin-gating issue not fixed here); reading templates works; no template-create attempted by kid (no UI gate yet).
11. **Mid-session profile switch on each of the 6 screens** → each reloads silently; correct member's data appears; no UI freeze.
12. **Admin paths on all 6 screens** → unchanged from before; smoke each: list views render, write paths attribute to admin's id, no regressions.

## Realtime listener double-trigger check

Per the investigation's risk surface item:

- **calendar_screen.dart**: already had `choresVersion.addListener`. Added `activeMemberId.addListener` alongside. Both call `_loadData()`. **No race**: `_loadData` is idempotent and uses `_isLoading` flag.
- **The other 5 screens**: none had existing realtime listeners. Single-listener pattern.

No double-fire problems surfaced during edit. Worst case is an extra reload if both ticks fire in the same frame; harmless.

## Known followups

- **`settings_screen` mid-sheet race**: capture `_myMembership['id']` as a closure variable when `_showEditProfileSheet` opens, instead of reading dynamically. ~5 LOC fix; defer to a polish pass.
- **`chore_templates_screen` admin-gating on menu entry**: orthogonal to MembershipHelper migration; flag for a future batch.
- **Batch 7a-ii** (MEDIUM): 4 screens — `achievements_screen`, `point_history_screen`, `feedback_screen`, `invite_management_screen`. (`notification_preferences_screen` deferred to 6c-iii.)
- **Batch 7a-iii** (LOW + cleanup): 7 screens — `search`, `subscription`, `shopping_category`, `data_export`, `household_stats`, `home_shell` (cleanup), `chore_dashboard` (cleanup).
- **Batch 6c-i**: `notification_service.dart` 3 hits — handled there.
- **Codebase-wide `withOpacity` → `withValues` sweep**: long-term polish.

## What this batch deliberately did NOT include

- No 7a-ii or 7a-iii screens.
- No `notification_service.dart` migration (owned by 6c-i).
- No `notification_preferences_screen.dart` migration (owned by 6c-iii).
- No `home_shell` or `chore_dashboard` manual-overlay refactor (7a-iii).
- No `chore_templates_screen` admin-gating fix on the menu entry.
- No new dialog component (settings has no persistent controllers — dirty-state confirm not needed).
- No RPC or migration changes.

## Next steps (for the user)

1. Review the 6 modified files.
2. Rebuild iOS on this branch (no Info.plist change, so hot restart should suffice; full clean rebuild also fine).
3. Run through the 12 smoke paths above. Particular attention to:
   - Path 4 + 5: rewards critical path — verify points balance attribution.
   - Path 6: settings prefs per-member scoping.
   - Path 11: profile-switch live reload on each screen.
   - Path 12: admin regression check.
4. Commit as a single commit on `feat/ui-hardening-batch-7a-i-2026-05-26`.
5. Push when ready.
