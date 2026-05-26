# Batch 7a-iii — MembershipHelper Migration (LOW-risk + cleanup) [final 7a sub-batch]

Date: 2026-05-26
Branch: `feat/ui-hardening-batch-7a-iii-2026-05-26`
Status: **changes uncommitted** — user reviews then commits

## Summary

Closes the Batch 7a workstream. Migrates the final 7 screens: 5 LOW-risk (household-id-only lookups; legacy pattern was functionally correct because kid + parent admin share a household) plus 2 cleanup (`home_shell` + `chore_dashboard` already had functional manual overlays — replaced with the helper for code uniformity). Net **−17 LOC** thanks to the two cleanups collapsing ~15-LOC manual overlays into single helper calls. After this commit, **every legacy `.eq('auth_user_id', user.id)` membership lookup in screens has been migrated** (17 screens total across 7a-i + 7a-ii + 7a-iii, plus 7 in the original Batch 5a + 6b + 8 commits). The only remaining legacy uses are by-design (MembershipHelper's own internal lookup, `main.dart` pre-household gate, `household_setup_screen` onboarding) or in scope for separate batches (`notification_service.dart` → 6c-i, `notification_preferences_screen.dart` → 6c-iii).

No migration, no RPC, no new dependency.

## Files modified

| File | Net LOC | Pattern | Notes |
|---|---|---|---|
| `apps/mobile/lib/screens/search_screen.dart` | -3 | A (LOW) | Household-id-only lookup |
| `apps/mobile/lib/screens/subscription_screen.dart` | -2 | A (LOW) | Household-id-only |
| `apps/mobile/lib/screens/shopping_category_screen.dart` | -2 | A (LOW) | Household-id-only; latent dispose bug left for 7b |
| `apps/mobile/lib/screens/data_export_screen.dart` | -6 | A (LOW) | Household-id-only; admin-only feature |
| `apps/mobile/lib/screens/household_stats_screen.dart` | -2 | A (LOW) | Household-wide stats |
| `apps/mobile/lib/screens/home_shell_screen.dart` | +2 / -16 net **-14** | B (CLEANUP) | Replaced ~15-LOC manual overlay with helper; preserved profile-switcher members list query |
| `apps/mobile/lib/screens/chore_dashboard_screen.dart` | +2 / -18 net **-16** | B (CLEANUP) | Replaced ~15-LOC manual overlay with helper |
| **Total** | **−17 LOC net** | | |

## Per-screen highlights

### LOW screens (Pattern A — no listener)

All 5 verified: only `household_id` flows downstream from the membership lookup. No `Permissions.isKid` / `isAdmin` calls. No `_myMembership['id']` writes. None had pre-existing realtime listeners or ActiveMember listeners. Migration is purely a 1-call helper swap with a comment explaining why no listener was added.

- **`search_screen.dart`**: just sets `_household = {'id': household_id}`. Uplifted catch-all `catch (_)` to `catch (e) + debugPrint` (Pass 2 pattern).
- **`subscription_screen.dart`**: uses `includeHouseholdJoin: true` because subscription tier lives on the `households` row. Pass 2 uplift on catch.
- **`shopping_category_screen.dart`**: `includeHouseholdJoin: true`. **Latent `TextEditingController` dispose bug elsewhere in this file is left untouched** — deliberately deferred to Batch 7b per the brief.
- **`data_export_screen.dart`**: just needs `household_id` (uses `_supabase` shorthand for the client). Admin-only feature; kid couldn't trigger anyway.
- **`household_stats_screen.dart`**: `includeHouseholdJoin: true` for household-wide aggregate counts. Numbers are the same for any household member.

### CLEANUP screens (Pattern B — preserve existing listeners)

#### `home_shell_screen.dart` (−14 LOC net)

**Before**: 16-LOC manual overlay that:
1. Loaded JWT-holder's row via `.eq('auth_user_id', userId)`.
2. Loaded all household_members for the profile-switcher menu.
3. Found the active member in the loaded list via `firstWhere(..., orElse: adultMembership)`.
4. Called `switchTo(adult.id)` if the active id was null OR stale.

**After**: helper call + the same "load all members for switcher" + a simplified `switchTo(_myMembership.id)` reconciliation.

**Verified all 3 behavioral scenarios match the original**:

| Scenario | Original behavior | New behavior |
|---|---|---|
| `activeId == null` (initial bootstrap) | helper returns adult; `requestedActiveId != _myMembership.id` (null != adult.id) → `switchTo(adult.id)` ✓ | ✓ identical |
| `activeId == kid.id` (valid kid session) | helper returns kid; `requestedActiveId == _myMembership.id` → no switchTo ✓ | ✓ identical |
| `activeId` points to deactivated kid (stale) | helper's kid lookup returns empty → falls back to adult → `switchTo(adult.id)` resets stale id ✓ | ✓ identical |

The `_householdMembers` list query (needed for the profile-switcher menu) stays separate. Could be replaced with a single query that returns both `_myMembership` + `_householdMembers` joined, but that's an optimization out of scope here. Existing realtime + ActiveMember listeners untouched.

#### `chore_dashboard_screen.dart` (−16 LOC net)

**Before**: 16-LOC manual overlay matching home_shell's pattern (load adult, conditionally load active member by id, fallback to adult).

**After**: single helper call. ActiveMemberService listener was already registered (added in Batch 8.1's music FAB work); preserved.

`final myMemberId = _myMembership!['id']` line preserved unchanged — chore filtering downstream works identically.

## Migration totals across all 7a sub-batches

| Sub-batch | Risk | Screens | Net LOC | Status |
|---|---|---|---|---|
| 7a-i | HIGH | 6 + bonus | +91 | Shipped `77d71bb` |
| 7a-ii | MEDIUM | 4 | +76 | Shipped `c645cb0` |
| 7a-iii | LOW + cleanup | 7 | **−17** | This commit |
| **Total** | | **17 screens** | **+150 LOC net** | |

Plus the bonus `chore_dashboard` AppBar title fix in 7a-i.

## What still uses the legacy `.eq('auth_user_id')` pattern (and why)

After 7a-iii lands, the only remaining hits across `apps/mobile/lib/`:

| File | Line | Why it stays |
|---|---|---|
| `lib/main.dart` | 118 | Pre-household auth gate — decides HomeShell vs Onboarding. ActiveMemberService not initialized yet. |
| `lib/screens/household_setup_screen.dart` | 188 | Onboarding/invite-acceptance flow. No "active kid" exists pre-membership. |
| `lib/utils/membership.dart` | 54 | MembershipHelper's *own* JWT-holder lookup. Required for the overlay pattern. |
| `lib/utils/membership.dart` | 15 | Doc comment referring to the pattern. |
| `lib/services/notification_service.dart` | 26, 64, 109 | **Deferred to 6c-i** — bundles with push notification work. |
| `lib/screens/notification_preferences_screen.dart` | 35 | **Deferred to 6c-iii** — bundles with prefs UI/DB schema reconcile. |

All other screens are migrated.

## Analyzer

| | Issues | Errors |
|---|---|---|
| Before | 367 | 1 (pre-existing `MyApp` test) |
| After | **367** | 1 (same) |
| **Net** | **0** | **0** |

Zero new info, warning, or error across all 7 touched files. The cleanup pass reduced overall LOC (less code = fewer potential lint targets) but the lint count happened to stay the same.

## iPhone smoke test checklist (14 paths, lower bar for LOW)

LOW-risk migrations have the same behavior pre- and post-migration (since they only consumed household_id, which kid and admin share). Smoke is spot-check rather than full kid-vs-admin matrix.

1. **Randi, search_screen** → loads; can search across household items.
2. **Randi, subscription_screen** → loads; shows tier info.
3. **Randi, shopping_category_screen** → loads; category list visible. (Latent dispose bug not fixed — Batch 7b.)
4. **Admin, data_export_screen** → can trigger export; JSON/CSV produced.
5. **Admin, household_stats_screen** → stats render.

**CLEANUP regression check** (critical — preserve existing behavior):

6. **Sign in fresh, no active id set yet** → home_shell loads adult member correctly; profile-switcher menu populated.
7. **Switch to Randi via profile-switcher** → home_shell + chore_dashboard reload with Randi's perspective.
8. **Reopen the app** → Randi remains the active profile (persisted state); home_shell + chore_dashboard show Randi.
9. **Stale-id scenario**: manually clear Randi's `is_active` in DB (or delete her), reopen app → home_shell + chore_dashboard fall back to adult, `ActiveMemberService.activeMemberId` resets to adult's id.
10. **Switch back to admin via profile-switcher** → both screens reload with admin perspective.

**Profile-switcher menu** (home_shell-specific):

11. **Open profile-switcher popup** → shows all household members (kid + adult). List query unchanged from before.

**Quick smoke** for the other migrated screens (regression):

12. **Each LOW screen as admin** → unchanged from before. Spot-check one or two; no behavior change expected.
13. **Each LOW screen as Randi** → unchanged (household-id-shared with admin). Spot-check.
14. **`shopping_category_screen` open + dismiss flow** → existing dispose bug may manifest as a controller-already-disposed assertion. If it surfaces, capture for Batch 7b. **Not a 7a-iii bug** — it pre-dates the migration.

## Known followups (carry-forward)

- **Batch 7b**: `shopping_category_screen` dispose bug; `settings_screen` edit-profile sheet race; `chore_templates_screen` menu-entry admin gate; Add Chore FAB admin-gate on `chore_dashboard`; active-member identity indicator in home_shell AppBar; codebase-wide `withOpacity` → `withValues` sweep.
- **Batch 6c-i**: `notification_service.dart` migration + APNs foundation.
- **Batch 6c-iii**: `notification_preferences_screen.dart` migration + schema reconcile.
- **Batch 9** (new from 7a-i smoke): kid redemption requests via Approvals dashboard (the RLS issue surfaced when Randi tried to redeem; architecturally requires admin approval like wishlist).

## What this batch deliberately did NOT include

- No 7a-i or 7a-ii screens (already shipped).
- No `notification_service.dart` (6c-i).
- No `notification_preferences_screen.dart` (6c-iii).
- **No fix to `shopping_category_screen`'s latent dispose bug** (Batch 7b — flagged in code comment).
- No RPC or migration changes.
- No optimization of home_shell's "load all members for switcher" query (orthogonal).
- No new dialog widgets.

## Next steps (for the user)

1. Review the 7 modified files (5 LOW + 2 cleanup).
2. Rebuild iOS on this branch (hot restart suffices; no Info.plist change).
3. Run through the 14 smoke paths above. Particular attention to:
   - Paths 6–10: cleanup regression check (home_shell + chore_dashboard must behave identically to before).
   - Path 11: profile-switcher menu still populated correctly.
   - Path 14: confirm if the latent dispose bug manifests (capture, don't fix).
4. Commit as a single commit on `feat/ui-hardening-batch-7a-iii-2026-05-26`.
5. Push when ready.
6. Optional: tag a milestone (e.g., `v0.5.0-membership-migration-complete`) since this closes the 7a workstream — 17 screens migrated in three sub-batches.
