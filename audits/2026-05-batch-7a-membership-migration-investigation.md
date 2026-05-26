# Batch 7a — MembershipHelper Migration of Remaining Legacy Screens (Investigation)

Date: 2026-05-26
Branch: `feat/ui-hardening-batch-7a-2026-05-26`
Status: **READ-ONLY investigation** — no code, no migrations, no commits

## TL;DR

**Bigger than "9 screens" suggested.** A fresh `grep -rln "\.eq('auth_user_id'" apps/mobile/lib/` returns **22 hits across 22 files** — but 3 are legitimate (auth bootstrap), 1 is `MembershipHelper` itself (by design), and 3 are in `notification_service.dart` (already in 6c-i scope). That leaves **17 screens** still needing the migration, plus 2 that already work via a verbose manual overlay and could be cleaned up.

**Honest classification of the 17:**
- **6 HIGH-risk** (write attribution + permission gating — same class of bug as Batch 5a)
- **5 MEDIUM-risk** (display bug or gating UI; kid sees admin's data)
- **5 LOW-risk** (household-id-only lookups — legacy pattern is *functionally* fine because the household is shared between kid sub_profile and parent admin; migration is for consistency, not correctness)
- **1 OPTIONAL** (`household_stats_screen` — household-id-only like the LOW set; classified separately because it's a kid-facing screen and migrating is cheap)

**Recommendation: split into 7a-i (HIGH-risk, 6 screens) + 7a-ii (MEDIUM-risk, 5 screens) + 7a-iii (LOW + cleanup, ~7 screens) instead of one batch.** Total LOC ~250–350 across 17–19 files; touch surface is too wide for a single safe batch. HIGH-risk subset is the priority — these have real write-attribution bugs that mirror the Batch 5a class.

---

## Phase 1 — Inventory (fresh grep)

```
$ grep -rn "\.eq('auth_user_id'" apps/mobile/lib/ | wc -l
22 hits across 21 files
```

### Legitimate / out of scope (4 hits, 3 files)

| File | Line | Why it's legitimate |
|---|---|---|
| `lib/main.dart` | 118 | Pre-household auth gate. Decides HomeShell vs Onboarding based on whether the JWT holder is in *any* household. ActiveMemberService isn't even initialized at this stage. **Keep as-is.** |
| `lib/screens/household_setup_screen.dart` | 188 | Onboarding/invite-acceptance flow. Inserts the JWT holder as a new member. There's no "active kid" at this point — they don't exist yet. **Keep as-is.** |
| `lib/utils/membership.dart` | 54 | The MembershipHelper's *own* JWT-holder lookup. This is step 1 of the documented overlay pattern. **Keep as-is** — fixing this would break the helper. |
| `lib/utils/membership.dart` | 15 | Doc comment referring to the broken pattern. Not code. |

### Service-side (3 hits, 1 file — owned by Batch 6c-i)

| File | Lines | Status |
|---|---|---|
| `lib/services/notification_service.dart` | 26, 64, 109 | Flagged in 6c investigation. `registerDeviceToken`, `loadPreferences`, `updatePreferences` all use the legacy pattern. **Owned by 6c-i — do not migrate in 7a** (avoid merge conflict with the push-notifications work). |

### Already-functional with manual overlay (2 hits, 2 files — refactor opportunity)

| File | Line | Current behavior |
|---|---|---|
| `lib/screens/home_shell_screen.dart` | 156 | Lines 156–179 manually do the same overlay MembershipHelper does — load adult, then re-query active kid if `activeMemberId != adultMembership['id']`. **Functional, not buggy**, but redundant code that pre-dates the helper. ~25 LOC could shrink to 5. |
| `lib/screens/chore_dashboard_screen.dart` | 70 | Lines 70–96 do the same manual overlay. **Functional**, again predates the helper. The user noted this was "fixed in commit 0a9684a" — the fix was the manual overlay; refactoring to the helper was deferred. ~25 LOC could shrink to 5. |

These are NOT broken. Migration is for code reuse / future-proofing only.

### Legacy bug screens (17 hits across 17 files — the actual 7a work list)

See Phase 4 table.

---

## Phase 2 — Risk classification

### HIGH risk (6 screens) — write attribution + permission gating

Same class of bug as Batch 5a. Kid actions get attributed to admin's member_id, OR kid sees write-affordances they shouldn't (RLS catches the actual write, but the UI is wrong).

| File | Line | Specific bug |
|---|---|---|
| `announcements_screen.dart` | 37 | `_isAdmin = Permissions.canManageAnnouncements(_myMembership)` (line 43) controls FAB visibility. `created_by_member_id: _myMembership!['id']` (line 142) writes admin's id even when kid is "active" creator. Today kid can't actually trigger the create flow because RLS rejects, but the UI shows the affordance. |
| `members_screen.dart` | 39 | `_isAdmin = Permissions.canManageMembers(_myMembership)` (line 128) gates the admin UI section + add-member dialog. `adminMemberId: _myMembership!['id']` (line 121) passed to write paths. |
| `rewards_screen.dart` | 44 | `_myMembership['id']` used for `memberId` in redemption writes (lines 200, 251). **Critical**: kid's reward redemption could deduct from admin's points balance because membership resolves to admin. `points_balance` for the affordability check (line 85) also pulls admin's number, not kid's. |
| `settings_screen.dart` | 47 | Filters notification_preferences and updates via `_myMembership!['id']` (lines 73, 100). Display name edit (line 129) writes to admin's row even when kid is "editing my profile" from a kid session. Each member's settings should be their own. |
| `calendar_screen.dart` | 57 | `myMemberId: _myMembership!['id']` (line 135) passed to event creation — events get attributed to admin even when kid creates. |
| `chore_templates_screen.dart` | 41 | `created_by_member_id: _myMembership!['id']` (line 135) writes admin's id on template creation. Admin-only feature in practice (kid can't reach it via UI), but RLS doesn't enforce attribution. |

### MEDIUM risk (5 screens) — display bugs + gating UI

Kid sees admin's data because membership resolves to admin's row.

| File | Line | Specific bug |
|---|---|---|
| `achievements_screen.dart` | 45 | Loads achievements filtered by `_myMembership['id']` (line 56). Kid currently sees admin's badges, not their own. |
| `point_history_screen.dart` | 34 | Filters point_transactions by `_myMembership!['id']` (line 45). `_myPoints` getter (line 73) returns admin's balance. **Kid sees admin's whole points world.** |
| `feedback_screen.dart` | 41, 78 | Line 78's lookup writes `submitted_by_member_id: memberId` (line 89). Kid feedback gets attributed to admin. No permission gate (any member can submit feedback), so the bug is display/attribution only. |
| `invite_management_screen.dart` | 35 | `_isAdmin = Permissions.canInviteMembers(_myMembership)` (line 63) gates the FAB. Kid currently sees the FAB because membership resolves to admin. RLS catches actual write, so UI-only bug. |
| `notification_preferences_screen.dart` | 35 | Each member should have their own prefs row. Currently kid is reading/writing admin's prefs. Compounds with the pre-existing UI↔DB schema mismatch documented in 6c-i investigation. **Should ship together with 6c-iii** (prefs reconcile), not in 7a. |

### LOW risk (5 screens) — household-id-only lookups

These screens only pull `household_id` from the membership row. **Functionally correct as-is** because kid sub_profiles and parent admins share the same household — `auth_user_id` lookup returns the admin's row, which has the correct `household_id`. Migration is for consistency, not correctness.

| File | Line | What it actually uses |
|---|---|---|
| `search_screen.dart` | 48 | Just `memberships[0]['household_id']` to scope search queries. |
| `subscription_screen.dart` | 32 | Just `households(*)` for subscription tier display. |
| `shopping_category_screen.dart` | 47 | Just `households(*)` for category list — admin-only feature in practice. |
| `data_export_screen.dart` | 138 | Just `household_id` for export queries — admin-only feature in practice. |
| `household_stats_screen.dart` | 51 | Just `household_id` for stats queries. Kid-visible screen. |

**Recommendation: defer these to 7a-iii or just batch them all together as a quick mechanical commit.** No behavior change.

---

## Phase 3 — Scope estimate

### Per-screen LOC

| Risk | Screens | LOC each | Subtotal |
|---|---|---|---|
| HIGH | 6 | 12–18 (import + listener + _loadData refactor + ensure setState in _onActiveMemberChanged) | ~85–110 |
| MEDIUM | 5 | 10–15 (same migration; sometimes less listener work if no realtime ticking needed) | ~55–75 |
| LOW | 5 | 8–10 (just the .eq replacement + import) | ~45–50 |
| Cleanup (home_shell + chore_dashboard) | 2 | -20 (net reduction since manual overlay disappears) | -40 |
| **Total** | **18** | | **~145–195 LOC net** |

### Per-screen smoke paths

Each screen needs at least 2 paths:
1. Adult session: feature works as before, no regressions.
2. Kid session: kid sees their own data / write attribution lands on kid's id.

That's ~36 smoke paths across the full work list. **Too many to test in one sitting.** Splitting into sub-batches lets us smoke-test each sub-batch independently before moving on.

### Risk: merge conflicts

If 6c (push notifications) lands while 7a is in progress, `notification_service.dart` migration will conflict between 6c-i and 7a. **Recommendation**: do 7a HIGH-risk first, then pause, then 6c-i+ii, then resume 7a MEDIUM + LOW. Don't run both in parallel.

---

## Phase 4 — Consolidated work list

| File | Line | Risk | `includeHouseholdJoin`? | Listener? | Notes |
|---|---|---|---|---|---|
| `announcements_screen.dart` | 37 | **HIGH** | No (already separately queried) | Yes | Permissions gate + write attribution; admin FAB visible to kids today |
| `members_screen.dart` | 39 | **HIGH** | No | Yes | Permissions gate + write attribution; admin sections visible to kids today |
| `rewards_screen.dart` | 44 | **HIGH** | No | Yes | Redemption attribution + `points_balance` display both wrong for kids |
| `settings_screen.dart` | 47 | **HIGH** | No | Yes | Settings write to admin's row from kid session; display name edit affects admin |
| `calendar_screen.dart` | 57 | **HIGH** | No | Yes | Event creation attribution to admin even when kid creates |
| `chore_templates_screen.dart` | 41 | **HIGH** | No | Yes | Template `created_by` attribution; admin-only in UI but lacks server enforcement |
| `achievements_screen.dart` | 45 | **MEDIUM** | No | Yes | Kid sees admin's badges (display bug) |
| `point_history_screen.dart` | 34 | **MEDIUM** | No | Yes | Kid sees admin's transactions + balance |
| `feedback_screen.dart` | 41, 78 | **MEDIUM** | No | Maybe | Kid feedback attributed to admin; TWO lookups need migration |
| `invite_management_screen.dart` | 35 | **MEDIUM** | No | Yes | Kid sees admin "Generate Invite" FAB (UI-only bug, RLS catches writes) |
| `notification_preferences_screen.dart` | 35 | **MEDIUM** | No | Yes | **Defer to 6c-iii** — bundles with the UI↔DB schema reconcile work |
| `search_screen.dart` | 48 | **LOW** | Yes (uses households(*)) | No | Just household_id — already functionally correct |
| `subscription_screen.dart` | 32 | **LOW** | Yes | No | Just household_id |
| `shopping_category_screen.dart` | 47 | **LOW** | Yes | No | Just household_id; admin-only feature |
| `data_export_screen.dart` | 138 | **LOW** | No | No | Just household_id; admin-only feature |
| `household_stats_screen.dart` | 51 | **LOW** | No | No | Just household_id; kid-visible read-only stats |
| `home_shell_screen.dart` | 156 | **CLEANUP** | Yes | Already has listener | Replace manual overlay with helper call; -20 LOC |
| `chore_dashboard_screen.dart` | 70 | **CLEANUP** | Yes | Already has listener | Same — replace manual overlay |

**18 screens. Plus 3 in `notification_service.dart` that are 6c-i's job.**

---

## Phase 5 — Open questions

1. **Split into sub-batches?** Recommend yes — **7a-i (HIGH × 6), 7a-ii (MEDIUM × 4, excluding notification_preferences which belongs to 6c-iii), 7a-iii (LOW × 5 + CLEANUP × 2)**. Each sub-batch is ~2 hours including smoke. Single-batch is doable but the smoke surface is wide.

2. **Listener wiring**: should LOW-risk screens also get `ActiveMemberService.addListener`? They don't have a behavior reason to react to profile switches (household_id doesn't change when active member changes within the same household), but adding the listener costs ~5 LOC and keeps the migration pattern uniform. **Recommend: no listener on LOW screens** — they don't need to react, and adding listeners costs 5 LOC × 5 screens for no UX benefit.

3. **Intentional legacy uses to flag**: nothing surfaced that should *stay* on the legacy pattern besides the 4 already documented (main.dart, household_setup, MembershipHelper itself, MembershipHelper doc comment).

4. **Extract a common helper for the migration?** The `initState` + `dispose` + `_onActiveMemberChanged` boilerplate is identical across screens. Could be extracted as a mixin (`MembershipAwareMixin`) but each State has slightly different concerns (some need `setState`, some need to reload other data, some have additional listeners to manage). **Recommend: leave inline.** The pattern is so repetitive that a future maintainer will recognize it; a mixin adds magic without saving meaningful LOC.

5. **`feedback_screen.dart` TWO lookups**: lines 41 (read) and 78 (write attribution). Should migrate both. The two lookups are in different methods — could be consolidated into one `_loadData` call, but that's a refactor beyond the migration scope. Recommend just migrate both in place.

6. **`notification_preferences_screen` placement**: I recommend deferring to **6c-iii** (prefs reconcile) since 6c-iii will rewrite the UI to match the actual DB schema and has to touch the same file. Migrating it in 7a only to have 6c-iii rewrite it is wasted effort and conflict risk.

7. **`chore_templates_screen` admin-gate**: this screen is reachable from home_shell's popup menu without a kid gate. Even after MembershipHelper migration, kid will still see "Chore Templates" in the menu but the screen will then know it's a kid. Should we also gate the menu item? Out of scope for 7a but worth a followup ticket.

8. **`home_shell` + `chore_dashboard` cleanup**: include in 7a-iii, or skip entirely? They're not buggy — the manual overlay produces the same result as MembershipHelper. **Recommend: include in 7a-iii for code uniformity** — once the codebase has only one membership-resolution pattern, future contributors won't be tempted to write a third variant.

---

## Phase 6 — Recommended sub-batch split

### 7a-i — HIGH-risk write attribution (6 screens, ~2 hours)
- `announcements_screen.dart`
- `members_screen.dart`
- `rewards_screen.dart`
- `settings_screen.dart`
- `calendar_screen.dart`
- `chore_templates_screen.dart`

Each ~15 LOC. Total ~90 LOC. Smoke each: 2 paths × 6 = 12 paths. Single commit.

### 7a-ii — MEDIUM display + gating (4 screens, ~1 hour)
- `achievements_screen.dart`
- `point_history_screen.dart`
- `feedback_screen.dart` (two lookups)
- `invite_management_screen.dart`

(`notification_preferences_screen.dart` goes to 6c-iii instead.)

Each ~12 LOC. Total ~50 LOC. Smoke each: 2 paths × 4 = 8 paths. Single commit.

### 7a-iii — LOW household-id + cleanup (7 screens, ~1 hour)
- `search_screen.dart`
- `subscription_screen.dart`
- `shopping_category_screen.dart`
- `data_export_screen.dart`
- `household_stats_screen.dart`
- `home_shell_screen.dart` (cleanup — replace manual overlay)
- `chore_dashboard_screen.dart` (cleanup — replace manual overlay)

Each ~8 LOC (LOW screens) or -20 LOC (cleanup). Total ~+30 net. Smoke: 2 paths × 7 = 14 paths, but most are "did anything obviously break" rather than kid-vs-admin behavior verification. Single commit.

### Total
- ~170 LOC across 3 commits / 3 sessions
- ~34 smoke paths
- Cleaner risk surface than one mega-batch

---

## Phase 7 — Risk surface for execution

1. **Merge conflict with 6c-i** on `notification_service.dart` — mitigated by deferring those 3 hits to 6c-i.
2. **Merge conflict with 6c-iii** on `notification_preferences_screen.dart` — mitigated by deferring to 6c-iii.
3. **Subtle state-loading order on cleanup screens** — `home_shell_screen.dart` does a lot in `_loadHouseholdInfo` after the membership lookup (loads household_members list, sets active member, etc.). The MembershipHelper migration is mechanically simpler but the surrounding code needs to keep working. Test thoroughly.
4. **Realtime listener interactions**: screens that already have realtime listeners (chore_dashboard, recipe_library, activity_feed) need to make sure adding `ActiveMemberService.addListener` doesn't double-trigger `_loadData`. None of the 7a screens currently have realtime listeners that would conflict, but worth checking per-screen.
5. **TextEditingController in `settings_screen.dart:129`**: settings has form fields with controllers. `_onActiveMemberChanged` reloading membership mid-edit could clobber unsaved input. **Need to test**: switch profile mid-edit, verify input isn't lost or that the user gets a clear "discard?" prompt. Could be a polish item if it surfaces.

---

## What this investigation deliberately did NOT do

- Did not write any code or migration.
- Did not modify any files.
- Did not commit anything.
- Did not migrate `notification_preferences_screen.dart` or `notification_service.dart` (owned by 6c-i / 6c-iii).
- Did not refactor `home_shell` or `chore_dashboard` manual overlays (deferred to 7a-iii).

All implementation work awaits user kickoff with sub-batch decisions answered.

---

## Recommended next step

Lock these with user:
- Confirm 3-sub-batch split (7a-i HIGH, 7a-ii MEDIUM, 7a-iii LOW + cleanup).
- Confirm `notification_preferences_screen` and `notification_service` are deferred to 6c-i/6c-iii.
- Confirm we proceed with 7a-i first (highest impact).

Then a single implementation pass on 7a-i. Expect ~2 hours including smoke + commit.
