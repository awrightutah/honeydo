# Chore Verify Flow — Outcome

Date: 2026-05-21
Branch: `fix/chore-verify-flow-2026-05-21` (off `fix/batch-3-image-and-calendar-2026-05-21`)

## Summary

**Bugs 1-5 listed in the brief are already fixed** on this branch (they landed in `fix/post-iphone-batch-2-2026-05-21` and inherit down to this branch through the in-progress branch chain). The only real outstanding change in `_verifyChore` was the generic SnackBar message — that has been swapped to surface the actual exception text.

## Verification of bugs 1-5 (already fixed)

Read `apps/mobile/lib/screens/chore_dashboard_screen.dart` `_verifyChore` (function spans lines 192-246 on this branch). Per-bug status against current file:

| # | Brief's claim | Current code | Status |
|---|---|---|---|
| 1 | line 133: `status: 'completed'` should be `'verified'` | line 200: `'status': 'verified'` | already fixed ✓ |
| 2 | line 142: `.select('user_id')` should be `.select('auth_user_id')` | line 209: `.select('auth_user_id')` | already fixed ✓ |
| 3 | lines 147-151: RPC param names `p_user_id` → `p_auth_user_id`, `p_reason` → `p_note`, `p_reference_id` → `p_source_id`, add `p_source_table: 'chores'` | lines 213-220: `p_auth_user_id`, `p_household_id`, `p_points`, `p_note: 'chore_completion'`, `p_source_table: 'chores'`, `p_source_id: choreId` | already fixed ✓ |
| 4 | line 156: `check_and_award_achievements` expects `p_auth_user_id`, not `p_user_id` | line 224: `'p_auth_user_id': assignedMember['auth_user_id']` | already fixed ✓ |
| 5 | line 147: `assignedMember['user_id']` → `assignedMember['auth_user_id']` | line 214: `'p_auth_user_id': assignedMember['auth_user_id']` | already fixed ✓ |

Line numbers in the brief assumed an older snapshot of the file. On this branch the function starts at line 192 and ends at line 246; numbers above reflect the current layout. The substantive content matches what the brief asked for.

These fixes were committed in batch 2 (`audits/2026-05-post-iphone-batch-2-outcome.md`). The "bugs to fix" list in this brief overlaps with the work that batch already did. No regression — the branch chain preserved those changes.

## Change actually made: SnackBar error surfacing

`_verifyChore`'s catch block previously hid the exception behind a generic string. Swapped to interpolate the actual error so future failures surface in-app immediately.

**Diff — `apps/mobile/lib/screens/chore_dashboard_screen.dart` (line 242):**

```diff
       _loadData();
     } catch (e) {
       if (mounted) {
         ScaffoldMessenger.of(context).showSnackBar(
-          const SnackBar(content: Text('Could not update chore status. Please try again.')),
+          SnackBar(content: Text('Could not update chore status: $e')),
         );
       }
     }
```

## App-wide sweeps

### Sweep 1 — `p_user_id` / `p_reason` / `p_reference_id` anywhere in `apps/mobile/lib/`

```
grep -rn "p_user_id\|p_reason\|p_reference_id" apps/mobile/lib/ --include="*.dart"
```

**Zero matches.** All RPC parameter names are aligned with the SQL function signatures in `0002_gamification_functions.sql`.

### Sweep 2 — `.select('user_id'...)` on `household_members`

```
grep -rn "\.select('user_id" apps/mobile/lib/ --include="*.dart"
```

**Zero matches.** The only `.select(...)` on `household_members` that involves the auth user field is at `chore_dashboard_screen.dart:209` and uses the correct `auth_user_id` column.

A broader grep — `.select(...user_id...)` against `household_members` anywhere — also returned zero hits.

## Analyzer deltas

| | Total | Errors | Warnings | Infos |
|---|---|---|---|---|
| Before | 327 | 44 | 78 | 205 |
| After  | 327 | 44 | 78 | 205 |
| Delta  | 0 | 0 | 0 | 0 |

## Modified files

- `apps/mobile/lib/screens/chore_dashboard_screen.dart` — SnackBar message swap (1 line changed).

## New files

- `audits/2026-05-chore-verify-fix-outcome.md` — this report.

## Followups

None spotted that aren't already tracked elsewhere. The chore verify flow's correctness depends on the upstream migrations being applied (0002 gamification functions, 0006 RLS policies, 0009 streak signature change). Those have been documented for the user to apply via the consolidated SQL block in `audits/2026-05-post-iphone-batch-2-outcome.md` and the patch in `audits/2026-05-batch-fix-3-outcome.md`. No new findings from this pass.

## Branch & commit state

- Branch: `fix/chore-verify-flow-2026-05-21` (off `fix/batch-3-image-and-calendar-2026-05-21`)
- Nothing committed.
