# Verified chores stale in "My Chores" — Implementation

Date: 2026-05-24
Branch: `fix/verified-chores-stale-in-my-chores-2026-05-23` (working-tree only; no commits)
Scope: Option A (UI gate) + Navigator.push callback fix in `chore_dashboard_screen.dart`
Status: code complete — **not committed; analyzer delta = 0**

## Summary

Two surgical edits to one file. The "Mark complete" button is now gated on `chore['status']` so a stale-cached `'verified'` or `'pending_verification'` chore can't render an actionable button that would just error. The latent `Navigator.push(...).then((_) => onComplete)` no-op was removed entirely (Option 2A) rather than "fixed" — the parent dashboard's realtime listener (`RealtimeService.instance.choresVersion`) and `ActiveMemberService.instance.activeMemberId` listener already refresh the chore list on any mutation, so the `.then` was redundant. "Fixing" it to fire would have called `_completeChore` on every back-navigation, which is the wrong behavior.

Both fixes are defensive — they don't change the query, the data flow, or any other screen's behavior. The Option B query-broadening (so `'pending_verification'` and `'rejected'` chores surface with status-appropriate UI) is deferred to Batch 4 alongside the Re-do affordance.

Analyzer: **333 issues before and after — net delta zero, no new errors**.

## Files modified

| File | Sites | Change |
|---|---|---|
| `apps/mobile/lib/screens/chore_dashboard_screen.dart` | 3 | Added `status` + `isActionable` locals at top of `_ChoreCard.build`. Wrapped the Mark complete `SizedBox` in `if (isActionable)`. Removed the redundant `.then((_) => onComplete)` no-op from the chore-card `onTap` (Option 2A — parent listeners handle refresh). |

No other files touched. The query in `_loadData` at line 96-102 is unchanged.

## Per-phase diffs

### Phase 1a — add `status` + `isActionable` locals near top of `_ChoreCard.build` (around line 478)

```diff
   @override
   Widget build(BuildContext context) {
     final name = chore['title'] ?? 'Untitled Chore';
     final room = chore['room_or_category'] ?? '';
     final points = chore['point_value'] ?? 5;
     final bonus = chore['bonus_points'] ?? 0;
     final difficulty = chore['difficulty'] ?? 'easy';
     final dueAt = chore['due_at'] != null ? DateTime.tryParse(chore['due_at']) : null;
     final isChoreOfDay = chore['chore_of_day_date'] != null;
+    final status = chore['status'] ?? 'assigned';
+    final isActionable = status == 'assigned' || status == 'in_progress';
```

### Phase 1b — gate the Mark complete button (around line 557-568)

```diff
               const SizedBox(height: 12),
-              SizedBox(
-                width: double.infinity,
-                child: FilledButton.icon(
-                  onPressed: onComplete,
-                  icon: const Icon(Icons.check_rounded, size: 18),
-                  label: const Text('Mark complete'),
-                  style: FilledButton.styleFrom(
-                    minimumSize: const Size.fromHeight(40),
-                    backgroundColor: AppColors.grassGreen,
+              // Defense in depth: only render Mark complete for chores
+              // that are actually completable. Stops a stale 'verified'
+              // or 'pending_verification' chore (e.g., from a missed
+              // realtime refresh) from showing a button that would error.
+              if (isActionable)
+                SizedBox(
+                  width: double.infinity,
+                  child: FilledButton.icon(
+                    onPressed: onComplete,
+                    icon: const Icon(Icons.check_rounded, size: 18),
+                    label: const Text('Mark complete'),
+                    style: FilledButton.styleFrom(
+                      minimumSize: const Size.fromHeight(40),
+                      backgroundColor: AppColors.grassGreen,
+                    ),
                   ),
                 ),
-              ),
             ],
```

Uses the codebase's existing "if inside a list literal" pattern (e.g., the `if (isChoreOfDay) ...[` at line 506 in the same widget). The preceding `const SizedBox(height: 12)` spacer stays unconditional — it leaves a small visual gap below the card body when the button is hidden, which is acceptable for the defense-in-depth path (rare).

### Phase 2 — drop the redundant `.then` (line 494, Option 2A)

```diff
         onTap: () {
           Navigator.of(context).push(
             MaterialPageRoute(
               builder: (_) => ChoreDetailScreen(choreId: chore['id']),
             ),
-          ).then((_) => onComplete);
+          );
         },
```

The original `.then((_) => onComplete)` was a no-op (it returned `onComplete` from the callback body but never invoked it, so the callback never fired). "Fixing" the syntax to `.then((_) => onComplete())` would actually invoke `onComplete` — but `onComplete` is wired by the parent (line 379) as `() => _completeChore(chore['id'])`, so every back-navigation from chore detail would mark the chore complete. That's not the intent.

Removed entirely (Option 2A) because the parent dashboard's existing listeners already handle refresh after any chore mutation:
- `RealtimeService.instance.choresVersion` listener at line 31 fires on Postgres CDC events for the chores table.
- `ActiveMemberService.instance.activeMemberId` listener at line 32 fires on member switches.

Both call `_loadData()`, so the dashboard auto-refreshes without needing a `.then` callback on the chore-card navigation. The `.then` was redundant scaffolding from an earlier iteration.

## Analyzer deltas

| | Total | Errors |
|---|---|---|
| Baseline (pre-edit) | 333 | 1 (pre-existing `MyApp` test) |
| After all edits | 333 | 1 (same) |

Net delta: **0 issues, 0 new errors**.

## Verification checklist for iPhone

1. **Stale verified chore doesn't show Mark complete.** Manually create the bug state: with a recurring chore, complete + verify it, then quickly switch to the dashboard tab before realtime refresh (or use Supabase Studio to set status='verified' on a chore assigned to you while the iPhone is on a different tab). Switch to the Chores tab. The chore card should appear (it's cached) but **without** the Mark complete button.
   - **Note:** with the existing query filter excluding `'verified'`, this scenario is hard to reproduce in normal app flow. The realistic test is to verify the button doesn't show for any chore whose status isn't `'assigned'` or `'in_progress'`.

2. **Returning from chore detail.** Tap any chore in the My Chores list → opens chore detail → tap back. The chore list refreshes automatically via the parent's realtime + active-member listeners — no incidental `_completeChore` fire on back-navigation. (Previously the `.then` was a no-op anyway; now it's gone entirely.)

3. **Mark complete still works on assigned/in_progress chores.** Tap Mark complete on an `'assigned'` chore. Status moves to `'pending_verification'`, chore disappears from My Chores (excluded by query), no regression.

## Known followups

**Batch 4 (kid chore-photo flow):**
- Option B query broadening lands alongside Re-do affordance. After Batch 4, the dashboard query expands to include `'pending_verification'` and `'rejected'`; `_ChoreCard` renders status-appropriate UI per status (Awaiting verification label, Re-do button). This closes the broader "chore vanishes after kid taps Complete" UX gap.

**Pre-existing carry-forwards (out of any current batch):**
- `'skipped'` status string at `chore_detail_screen.dart:520` is not in the `chore_status` enum.
- pg_cron photo cleanup migration deferred.
- Spec amendment per Batch 1 followup #3.
- 5 display-only role-reads could centralize into a `RoleDisplay` helper (Half A carry-forward).

## Git state (uncommitted)

```
$ git status --short
 M apps/mobile/lib/screens/chore_dashboard_screen.dart
?? audits/2026-05-verified-chores-stale-implementation.md
?? audits/2026-05-verified-chores-stale-investigation.md
```

1 modified screen + 2 new audit docs. Branch otherwise clean. Ready for review + iPhone smoke-test, then commit + push with `--set-upstream`.
