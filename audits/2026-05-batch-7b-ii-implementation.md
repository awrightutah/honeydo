# Batch 7b-ii — `withOpacity` → `withValues` Deprecation Sweep

Date: 2026-05-26
Branch: `feat/ui-hardening-batch-7b-2026-05-26`
Status: **changes uncommitted** — user reviews then commits

## Summary

Mechanical replacement of all 138 `Color.withOpacity(x)` callsites across 35 files with the canonical Flutter replacement `Color.withValues(alpha: x)`. Single per-file pass using `Edit` with `replace_all: true` — no manual per-site editing needed since every callsite (per the 7b-ii investigation) was a clean 1:1 substitution with no edge cases. **Analyzer issue count dropped from 367 → 229 (−138 exactly matching site count)** — every withOpacity deprecation info eliminated, zero new issues introduced.

Stacks on top of the uncommitted 7b-i polish bundle on the same branch.

## Phase 1 — Setup

```
$ grep -rln "\.withOpacity(" apps/mobile/lib/ | wc -l
35 files

$ flutter analyze apps/mobile/ | tail -3
367 issues found.    (baseline, after 7b-i)
```

35 files confirmed exactly matching the investigation's count.

## Phase 2 — Mechanical replacement

For each of the 35 files, executed `Edit` with `replace_all: true`:
- `old_string`: `.withOpacity(`
- `new_string`: `.withValues(alpha:`

The leading `.` and the closing `)` of each callsite stayed untouched. Result: every `someColor.withOpacity(0.5)` became `someColor.withValues(alpha: 0.5)` etc.

### Files touched (35 total)

| Path | Hits |
|---|---|
| `screens/member_profile_screen.dart` | 8 |
| `screens/chore_detail_screen.dart` | 8 |
| `screens/search_screen.dart` | 7 |
| `screens/meal_planner_screen.dart` | 7 |
| `screens/activity_feed_screen.dart` | 7 |
| `screens/rewards_screen.dart` | 6 |
| `screens/onboarding_screen.dart` | 6 |
| `screens/members_screen.dart` | 6 |
| `screens/chore_templates_screen.dart` | 6 |
| `screens/shopping_list_screen.dart` | 5 |
| `screens/recipe_detail_screen.dart` | 5 |
| `screens/subscription_screen.dart` | 4 |
| `screens/point_history_screen.dart` | 4 |
| `screens/invite_management_screen.dart` | 4 |
| `screens/household_stats_screen.dart` | 4 |
| `screens/home_shell_screen.dart` | 4 |
| `screens/calendar_screen.dart` | 4 |
| `screens/announcements_screen.dart` | 4 |
| `screens/achievements_screen.dart` | 4 |
| `screens/recipe_library_screen.dart` | 3 |
| `screens/notification_preferences_screen.dart` | 3 |
| `screens/household_setup_screen.dart` | 3 |
| `screens/feedback_screen.dart` | 3 |
| `screens/chore_dashboard_screen.dart` | 3 |
| `widgets/offline_banner.dart` | 2 |
| `services/feature_tour_service.dart` | 2 |
| `screens/splash_screen.dart` | 2 |
| `screens/approvals_screen.dart` | 2 |
| `widgets/app_error.dart` | 1 |
| `widgets/app_a11y.dart` | 1 |
| `screens/shopping_category_screen.dart` | 1 |
| `screens/settings_screen.dart` | 1 |
| `screens/profile_screen.dart` | 1 |
| `screens/necessity_categories_screen.dart` | 1 |
| `screens/auth_screen.dart` | 1 |
| **Total** | **138** |

All 35 `Edit` calls returned "All occurrences were successfully replaced" — no partial-match failures.

## Phase 3 — Verification

```
$ grep -rn "\.withOpacity(" apps/mobile/lib/ | wc -l
0    ← zero withOpacity remain

$ grep -roh "\.withValues(alpha:" apps/mobile/lib/ | wc -l
138  ← exact match to original count
```

138 sites converted, 0 missed.

## Phase 4 — Analyzer delta

| | Issues | Errors |
|---|---|---|
| Before (7b-i baseline) | 367 | 1 (pre-existing `MyApp` test) |
| After (this sweep) | **229** | 1 (same) |
| **Net** | **−138** | **0** |

The 138-issue drop is **exactly** the site count converted — every withOpacity deprecation info was eliminated, and zero new issues were introduced. Remaining issues are unrelated pre-existing pile:
- `unused_import` warnings (`flutter_dotenv` in supabase_client.dart, `app_theme.dart` in app_a11y.dart and offline_banner.dart)
- `inference_failure` warnings on untyped `.rpc()` and `PageRouteBuilder` calls
- The pre-existing `MyApp` test error

None of these are related to the sweep.

## Smoke test recommendation

Per investigation Phase 5, 5-minute visual spot-check on the 5 heaviest screens (where any unintended shift would be most visible):

| Priority | Screen | Hits | What to verify |
|---|---|---|---|
| 1 | `member_profile_screen.dart` | 8 | Tinted avatar background, stat cards |
| 2 | `chore_detail_screen.dart` | 8 | Status-pill backgrounds + borders |
| 3 | `activity_feed_screen.dart` | 7 | 6 icon-circle tints |
| 4 | `meal_planner_screen.dart` | 7 | Meal-type pills |
| 5 | `onboarding_screen.dart` | 6 | Gradients (biggest potential drift, if any) |

Plus `services/feature_tour_service.dart` (2 sites) if the first-launch tour is reachable.

**Expected outcome: zero visible difference.** `Color.withValues(alpha:)` is documented as the exact 1:1 replacement for `.withOpacity()` — designed to avoid precision quirks in the deprecated API, not to change visual output for normal opacity values.

## Known followups (carried forward, unchanged)

- **Batch 7b-iii**: active-member identity indicator in home_shell AppBar (parent helping kid could miss they're operating in kid context).
- **NEW from 7b-i**: settings_screen `nameController` lifecycle (leak per sheet open; not crashing today).
- **Batch 6c-i**: `notification_service.dart` migration + APNs foundation.
- **Batch 6c-iii**: `notification_preferences_screen.dart` migration + schema reconcile.
- **Batch 9** (new from 7a-i smoke): kid redemption requests via Approvals.

## What this batch deliberately did NOT include

- No semantic changes — pure mechanical deprecation cleanup.
- No `unused_import` cleanups (orthogonal lint targets; defer to a future tidy-up pass).
- No active-member identity indicator work (7b-iii territory).
- No new dialog widgets.
- No `withRed`/`withGreen`/`withBlue`/`withAlpha` migration (grep confirms none exist in the codebase).

## Next steps (for the user)

1. Review the diff. The change is uniformly `.withOpacity(` → `.withValues(alpha:` across 35 files; spot-check a few to confirm.
2. Rebuild iOS on this branch (hot restart suffices).
3. Spot-check the 5 priority screens above for any unexpected visual shift.
4. Commit on top of the uncommitted 7b-i polish bundle (either as a separate commit on `feat/ui-hardening-batch-7b-2026-05-26` for cleaner history, or folded into a combined 7b commit — user's choice).
5. Push when ready.
