# Batch 7a-ii — MembershipHelper Migration (MEDIUM-risk display + UI gating screens)

Date: 2026-05-26
Branch: `feat/ui-hardening-batch-7a-ii-2026-05-26`
Status: **changes uncommitted** — user reviews then commits

## Summary

Migrates 4 MEDIUM-risk screens off the legacy `.eq('auth_user_id', user.id)` pattern. Unlike 7a-i (write attribution bugs), these are display + UI gating bugs: pre-migration, kid sessions saw the parent admin's badges, point transaction history, attributed feedback submissions, and the admin-only "Generate Invite" FAB. The proven 5-step pattern from 13 prior migrations applied consistently. The most consequential of the four is **point_history_screen** — pre-fix, a kid sub_profile session displayed the parent admin's *entire* point transaction history. That's privacy-adjacent (the kid could see admin's earnings, spends, and admin-applied adjustments).

No migration, no RPC, no new dependency. **`notification_preferences_screen.dart` deliberately deferred to 6c-iii** per investigation locked decisions.

## Files modified

| File | Net LOC | Risk class | Primary fix |
|---|---|---|---|
| `apps/mobile/lib/screens/achievements_screen.dart` | +18 | MEDIUM | Kid now sees their own earned badges, not admin's |
| `apps/mobile/lib/screens/point_history_screen.dart` | +25 | **MEDIUM (privacy-adjacent)** | Kid now sees their own transactions, not admin's history |
| `apps/mobile/lib/screens/feedback_screen.dart` | +9 net | MEDIUM | Both lookups migrated; kid feedback attributed to kid's `submitted_by_member_id` |
| `apps/mobile/lib/screens/invite_management_screen.dart` | +24 | MEDIUM | `_isAdmin` gate reflects active member; kid no longer sees Generate Invite FAB |
| **Total** | **~+76 LOC net** | | |

## Per-screen highlights

### 1. `achievements_screen.dart` (+18 LOC)

Standard 5-step migration:
- Added `services/active_member_service.dart` + `utils/membership.dart` imports.
- New `dispose()` override added (class had none previously).
- `_loadData()` swapped the legacy lookup for `MembershipHelper.loadActiveMembership(includeHouseholdJoin: true)`.
- `_onActiveMemberChanged` reloads silently.
- Added `debugPrint` on catch path.

The `achievements` query at line 58-63 (post-edit) already filtered by `member_id` — once `_myMembership` resolves correctly, the query naturally returns the kid's badges. No SQL changes.

### 2. `point_history_screen.dart` (+25 LOC) — **PRIVACY FIX**

The single most impactful migration in this batch.

**Pre-fix**: a kid session resolved `_myMembership` to the parent admin's row. The downstream filter `.eq('member_id', memberId)` then returned the admin's complete point_transactions history — including chore earnings, reward spends, and any admin-applied point adjustments. The kid could see every dollar (point) the admin earned or spent.

**Post-fix**: `_myMembership` resolves to the kid's row, `memberId` is the kid's id, and the filter scopes to the kid's own transactions. Admin's transaction history is no longer visible to the kid.

Migration is mechanically the same as the others — the privacy implication is what makes this MEDIUM-risk worth calling out. Added an explicit comment in `_loadData` flagging the privacy framing for future maintainers.

`_myPoints` getter (line 73, body unchanged) now returns the kid's `points_balance` rather than admin's. Side benefit on top of the privacy fix.

### 3. `feedback_screen.dart` (+9 LOC net) — **TWO LOOKUPS**

Investigation flagged that this screen had two separate `.eq('auth_user_id')` instances — one in `_loadFeedback()` (read scope) and one in `_submitFeedback()` (write attribution). The user brief offered two strategies: migrate each in place, or consolidate into a single lookup with State storage.

**Chosen: migrate each in place.** Both methods now call `MembershipHelper.loadActiveMembership()` independently. The screen has no `_myMembership` State field today, and adding one would force restructuring the State (more LOC, more diff surface). In-place migration matches the brief's "each instance gets the migration treatment" option exactly.

- `_loadFeedback()`: helper call (no `includeHouseholdJoin` needed — only `household_id` is read for the list query).
- `_submitFeedback()`: helper call. **Bug fixed**: pre-migration, kid feedback was attributed to the parent admin's `submitted_by_member_id`. Post: attributed correctly to the kid.

Added the standard listener + `_onActiveMemberChanged` callback (which reloads via `_loadFeedback`).

Existing `_titleController` + `_descriptionController` cleanup in `dispose` stays; new `removeListener` call slotted at the top of `dispose` per the established ordering pattern.

Also added `debugPrint` on the previously-empty catch paths (both methods). Pass 2 compliance.

### 4. `invite_management_screen.dart` (+24 LOC)

`_isAdmin` is a getter (line 63): `Permissions.canInviteMembers(_myMembership)`. Pre-migration, `_myMembership` resolved to the parent admin, so `_isAdmin` returned true for kid sessions. The "Generate Invite" FAB (controlled by `_isAdmin` per investigation context) was incorrectly visible to kids.

Post-migration, `_myMembership` reflects the active member. `Permissions.canInviteMembers` returns false for kid sub_profiles. The FAB now correctly disappears.

RLS would have caught any actual write attempt the kid made — so this is a UI gating bug, not a data integrity bug. But UI honesty matters.

Replaced the catch-all `catch (_)` with `catch (e)` + `debugPrint` + `$e` in the SnackBar (Pass 2 pattern uplift while migrating).

## Realtime listener double-trigger check

Per investigation risk surface:

- **achievements_screen.dart**: no existing realtime listeners. Single-listener pattern. Safe.
- **point_history_screen.dart**: no existing realtime listeners. Safe.
- **feedback_screen.dart**: no existing realtime listeners. Safe.
- **invite_management_screen.dart**: no existing realtime listeners. Safe.

None of these 4 screens had pre-existing `RealtimeService.instance.*.addListener` calls. Each gets exactly one listener (`activeMemberId`). Zero double-trigger risk.

## Analyzer

| | Issues | Errors |
|---|---|---|
| Before | 368 | 1 (pre-existing `MyApp` test) |
| After | **367** | 1 (same) |
| **Net** | **-1** | **0** |

The single-issue *reduction* came from one of the touched files — the legacy `.eq('auth_user_id', user.id).limit(1)` chain (with its trailing list-indexing pattern) was generating one info-level lint that disappeared when the chain was replaced with `MembershipHelper.loadActiveMembership(...)`. Net: cleaner codebase + zero new issues.

## iPhone smoke test checklist

1. **As Randi, navigate to achievements_screen** → her earned badges visible (or empty state if she has none yet); admin's badges NOT visible.
2. **As admin** → admin's badges visible (regression check passes).
3. **As Randi, navigate to point_history_screen** → her transaction list; admin's transactions NOT visible. `_myPoints` shows her balance.
4. **SQL verify (privacy)**: `select count(*) from point_transactions pt where pt.member_id = <admin_id> and pt.id in (<ids Randi just saw>)` → **zero**. Kid only sees own rows.
5. **As Randi, navigate to feedback_screen** → loads; she can submit a feedback row.
6. **If Randi submits feedback** → SQL verify: `select submitted_by_member_id from feedback_requests where id = <new>` returns **Randi's id**, not admin's.
7. **As Randi, navigate to invite_management_screen** → list of household invites visible (read scope is household-wide), but **no Generate Invite FAB**.
8. **As admin, invite_management_screen** → Generate Invite FAB visible (regression check passes).
9. **Mid-session profile switches** on each of the 4 screens → each reloads silently; correct member's data appears; no UI freeze.
10. **Admin paths on all 4 screens** → unchanged from before. Smoke each.

## Known followups (carried forward — unchanged from 7a-i)

- **Batch 7a-iii** (LOW + cleanup): 7 screens — `search`, `subscription`, `shopping_category`, `data_export`, `household_stats`, `home_shell` (cleanup), `chore_dashboard` (cleanup).
- **Batch 6c-i**: `notification_service.dart` 3 hits.
- **Batch 6c-iii**: `notification_preferences_screen.dart` (deferred per investigation; bundles with prefs UI/DB schema reconcile).
- **Batch 9 (new)**: Kid redemption requests via Approvals — captured during 7a-i smoke when rewards_screen RLS blocked kid redeems. Wishlist-style approval flow.
- **Batch 7b polish**: settings_screen edit-profile sheet race; chore_templates_screen menu-entry admin gate; Add Chore FAB admin-gate on chore_dashboard; active-member identity indicator in home_shell AppBar.
- **Codebase-wide `withOpacity` → `withValues` sweep**: long-term polish.

## What this batch deliberately did NOT include

- No `notification_preferences_screen.dart` migration (6c-iii).
- No `notification_service.dart` migration (6c-i).
- No 7a-iii screens (5 LOW + 2 cleanup).
- No 7a-i screens (already committed in `77d71bb`).
- No RPC or migration changes.
- No state-structure refactor of `feedback_screen.dart` (chose in-place migration over adding `_myMembership` State field).
- No new dialog widgets.
- No `withOpacity` deprecation sweeps.

## Next steps (for the user)

1. Review the 4 modified files.
2. Rebuild iOS on this branch (no Info.plist change, hot restart suffices).
3. Run through the 10 smoke paths above. Particular attention to:
   - Paths 3 + 4: point_history privacy fix (SQL cross-check).
   - Path 6: feedback write attribution verified via SQL.
   - Paths 7 + 8: invite_management FAB visibility flips correctly with active member.
4. Commit as a single commit on `feat/ui-hardening-batch-7a-ii-2026-05-26`.
5. Push when ready.
