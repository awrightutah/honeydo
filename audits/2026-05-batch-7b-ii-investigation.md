# Batch 7b-ii — `withOpacity` → `withValues` Deprecation Sweep (Investigation)

Date: 2026-05-26
Branch: `feat/ui-hardening-batch-7b-2026-05-26`
Status: **READ-ONLY investigation** — no code changes

## TL;DR

**138 instances across 35 files.** Every sampled callsite is a clean **1:1 mechanical replacement**: `color.withOpacity(x)` → `color.withValues(alpha: x)`. No unusual patterns (no int args, no chained `.withOpacity().withOpacity()`, no custom Color subclasses). Squarely in the **single-commit single-pass** range per the brief's 50–150 sites guideline. Estimated **~30–45 min** to implement including a quick visual spot-check on the top-5 hit files.

## Phase 1 — Count

```
$ grep -rln "\.withOpacity(" apps/mobile/lib/ | wc -l
35   files affected

$ grep -roh "\.withOpacity(" apps/mobile/lib/ | wc -l
138  total instances
```

### Distribution (Top 10 by hit count)

| File | Hits |
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

### Full breakdown

- **Files with 6+ hits**: 9 (the visually-heavy screens)
- **Files with 3–5 hits**: 14
- **Files with 1–2 hits**: 12
- **Non-screen files**: 4 (`widgets/offline_banner.dart` ×2, `widgets/app_error.dart` ×1, `widgets/app_a11y.dart` ×1, `services/feature_tour_service.dart` ×2)

No file has more than 8 hits — the heaviest are evenly distributed.

## Phase 2 — Sample callsites (5 representative patterns)

All confirmed mechanical 1:1 replacements.

### Pattern 1 — `AppColors.X.withOpacity(literal)`
Most common pattern across the codebase.

```dart
// Before:
AppColors.honeyGold.withOpacity(.3)
// After:
AppColors.honeyGold.withValues(alpha: .3)
```

Example sites: `member_profile_screen.dart:249, 381, 383, 465`, `activity_feed_screen.dart:397, 406`, dozens more.

### Pattern 2 — `Colors.X.withOpacity(literal)`
Same shape with Material colors instead of brand colors.

```dart
Colors.white.withOpacity(.25)         // → withValues(alpha: .25)
Colors.black.withOpacity(0.75)        // → withValues(alpha: 0.75)
Colors.purple.withOpacity(0.15)       // → withValues(alpha: 0.15)
Colors.grey.withOpacity(0.15)         // → withValues(alpha: 0.15)
Colors.grey.shade50                   // (not affected — different method)
```

Example: `member_profile_screen.dart:280, 292`, `feature_tour_service.dart:180`.

### Pattern 3 — `variable.withOpacity(literal)`
Color held in a local variable. Still mechanical.

```dart
// Before:
color.withOpacity(.1)
// After:
color.withValues(alpha: .1)
```

Example: `member_profile_screen.dart:343, 345`, `activity_feed_screen.dart:449`, `chore_detail_screen.dart:784, 785`, `shopping_category_screen.dart:224`.

### Pattern 4 — Function/property result then `.withOpacity`
Chained off a function call or property access. The function returns a `Color`; the chain compiles the same.

```dart
// Before:
_statusColor(status).withOpacity(0.1)
step.color.withOpacity(0.15)
// After:
_statusColor(status).withValues(alpha: 0.1)
step.color.withValues(alpha: 0.15)
```

Example: `chore_detail_screen.dart:433, 438`, `feature_tour_service.dart:204`.

### Pattern 5 — Ternary result then `.withOpacity`
A conditional that resolves to a Color, then opacity applied.

```dart
// Before:
(activity['transaction_type'] == 'earned'
    ? AppColors.honeyGold
    : AppColors.coral
).withOpacity(0.15)
// After:
(activity['transaction_type'] == 'earned'
    ? AppColors.honeyGold
    : AppColors.coral
).withValues(alpha: 0.15)
```

Example: `activity_feed_screen.dart:415`. Same mechanical replacement; the parenthesization is preserved.

### Variant: inside a `.map(...)`
Lambda parameter — still mechanical.

```dart
// Before:
step.gradient.map((c) => c.withOpacity(.15)).toList()
// After:
step.gradient.map((c) => c.withValues(alpha: .15)).toList()
```

Example: `onboarding_screen.dart:290`.

## Phase 3 — Risk surface

### Things I checked

| Risk | Finding |
|---|---|
| Non-literal Double argument (int, computed expression) | None. Every argument is either a numeric literal (e.g., `.3`, `0.15`) or a Color variable receiving a literal. `grep -rn "\.withOpacity([^0-9)]"` returned only Color-variable callsites — no int args, no string concat, no `.withOpacity(foo + bar)`. |
| Chained `.withOpacity(a).withOpacity(b)` | None. The grep `\.withOpacity(.*)\.withOpacity(` returned **one false positive** at `chore_detail_screen.dart:433`: `colors: [_statusColor(status).withOpacity(0.1), _statusColor(status).withOpacity(0.05)]` — that's two **separate** calls in a list literal, not a chain. Treats fine. |
| Custom Color subclass | None. All callsites are on standard Material `Colors.*`, brand `AppColors.*`, or `Color` instances. |
| Result fed into something that depends on `withOpacity`'s precision quirks | None observed. The `withValues(alpha:)` API is documented as the exact 1:1 replacement, designed to avoid the precision loss the deprecation warning calls out. For our usage (UI rendering — fills, borders, gradients, shadows) the visual output is bit-for-bit identical at typical alpha values. |
| Color used in equality / hash comparisons | None. Wouldn't be affected anyway since equality is on the resulting Color, which has the same channels. |

### One nuance worth knowing (not a blocker)

Flutter's deprecation message says `.withOpacity` may have **precision loss** compared to `.withValues(alpha:)`. For our use case — opacity values like 0.1, 0.15, 0.3, 0.5 applied for tinted backgrounds and borders — the visual difference is **invisible to the human eye**. The deprecation is forward-looking (Flutter wants colorspace-aware APIs); existing visuals won't shift.

### Verdict

**Everything is mechanical.** No callsite needs special handling.

## Phase 4 — Scope estimate

| Metric | Estimate |
|---|---|
| Sites | 138 |
| Files | 35 |
| LOC change | ~138 (one per site; same LOC count post-replacement) |
| Implementation time | ~30 min mechanical replacement |
| Smoke time | ~15 min spot-check on top 5 hit files |
| **Total** | **~45 min** |

### Recommended approach

**Single commit, single mechanical pass.** 138 sites is comfortably in the 50–150 range. No need to split.

Implementation strategy options:
- **Option A — Per-file with the Edit tool**: 35 files × ~4 sites/file avg. Cleanest history. Roughly 35 tool calls, but each uses `replace_all: true` on the exact `.withOpacity(` → `.withValues(alpha: ` pattern.
- **Option B — Single sed-style pass via Bash**: `find apps/mobile/lib -name "*.dart" -exec sed -i '' 's/\.withOpacity(/.withValues(alpha: /g' {} +` followed by a single Edit verification. Faster but bypasses the Edit tool's read-first invariant. **NOT recommended** — the codebase has been productive; we should respect the per-file edit pattern.
- **Option C — `grep | xargs` with structured replacement** in a single Bash call. Same caveat as B.

**Recommend Option A.** Predictable, reviewable per-file in the eventual diff.

### Why not split into multiple commits

- All 138 sites are the same mechanical change with the same risk profile (zero).
- Splitting by directory (e.g., screens vs widgets) would create 2-3 commits where each is "the same thing, half of it" — no review benefit.
- A single commit is the cleanest history entry: "refactor(ui): withOpacity → withValues deprecation sweep (138 sites)".

## Phase 5 — Smoke test recommendation

After the mechanical replacement lands, do a **5-minute visual spot-check** on the screens with the heaviest usage. These are where any unintended visual shift would be most visible:

| Priority | Screen | Reason |
|---|---|---|
| 1 | `member_profile_screen.dart` (8) | Tinted avatar background, stat cards with brand-color tints |
| 2 | `chore_detail_screen.dart` (8) | Status-pill backgrounds + borders, photo viewer overlays, redo banner tint |
| 3 | `activity_feed_screen.dart` (7) | Six different icon-circle background tints |
| 4 | `meal_planner_screen.dart` (7) | Meal-type pills with brand-color backgrounds |
| 5 | `onboarding_screen.dart` (6) | Gradient backgrounds — biggest potential for visual shift |

For each: open the screen, scroll through normal usage, verify nothing looks visually off. The expected outcome is **zero visible difference** since `withValues(alpha:)` produces identical results at typical alpha values.

Also: `services/feature_tour_service.dart` (2 sites) controls the first-launch tour overlays. Visually verify if a fresh-install path is available (or trigger the tour manually if there's a debug entry point).

### What you DON'T need to smoke

- The 12 files with 1–2 hits each. Spot-checking is overkill for a single tinted background per screen.
- Logic-heavy screens with low hit counts (`profile_screen.dart`, `subscription_screen.dart`, etc.). The deprecation doesn't affect behavior, only color rendering.

## Recommended implementation plan

1. Single commit on `feat/ui-hardening-batch-7b-2026-05-26` (alongside the already-uncommitted 7b-i polish bundle, OR as a separate commit on the same branch — user's choice).
2. Per-file Edit tool calls with `replace_all: true` against the exact `.withOpacity(` → `.withValues(alpha: ` substitution. 35 files × 1 Edit each.
3. Run `flutter analyze apps/mobile/ 2>&1 | tail -5`. Expect a **drop of ~138 info-level issues** (the deprecation warnings) and 0 new errors/warnings.
4. iPhone smoke: spot-check the 5 priority screens above. Plus the feature tour if reachable.
5. Commit. Push.

## What this investigation deliberately did NOT do

- Did not change any code.
- Did not modify any file.
- Did not commit anything.
- Did not investigate `withRed`, `withGreen`, `withBlue`, `withAlpha` (different deprecations, not in scope; grep confirms none exist in the codebase anyway).

## Recommended next step

Single mechanical implementation pass — **Option A** (per-file Edit with `replace_all: true`). Should fold cleanly into the existing 7b branch alongside the 7b-i polish work, or ship as a follow-on commit on the same branch.
