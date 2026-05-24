# Verified chores stale in "My Chores" — Investigation

Date: 2026-05-24
Branch: `fix/verified-chores-stale-in-my-chores-2026-05-23` (off main at `cadc09b`; pre-Half-A/B state)
Status: read-only investigation; no edits, no commits

## Summary

The query that builds the "My Chores" list at `chore_dashboard_screen.dart:96-102` is **already filtered** to `status IN ('assigned', 'in_progress')`. A `'verified'` chore should not appear in `_myChores` via this query path.

The actual surfaced bug is that a stale `_myChores` snapshot is being **rendered** even when the underlying chore has moved on. Three things make this possible:

1. **The widget uses `AutomaticKeepAliveClientMixin`** — the dashboard's state persists across navigation. After a navigate-out / change-elsewhere / navigate-back, the cached `_myChores` is rendered immediately on rebuild while a fresh `_loadData` may not have fired yet.
2. **There is no UI-side status gate on the Mark complete button.** `_ChoreCard` (lines 558-568) unconditionally renders the Mark complete button for every chore in `_myChores`, regardless of `chore['status']`. So if a stale `'verified'` chore ever sneaks into the list (via cache, race, or a future query broadening), the button still appears and the user can tap it.
3. **Realtime + listener gaps**: if the realtime subscription isn't active when an external status change happens (different device, Supabase Studio, admin's chore_detail approve race), the listener never fires, and the dashboard never refreshes.

The minimal fix is a UI-side gate inside `_ChoreCard`: render Mark complete only when status is `'assigned'` or `'in_progress'`. ~5 lines, defense in depth.

A separate, slightly broader fix is to **broaden the query** to include `'pending_verification'` (and after Batch 4, `'rejected'`) so the kid can see chores they've completed but not yet verified — currently those just vanish, which is its own confusing UX. This would also need the UI to show the right affordance for each status. ~15-20 lines.

Three open questions for the user about which approach to pick (see Phase 6).

## Phase 1 — where the My Chores list lives

Single owner: `chore_dashboard_screen.dart`. Relevant references:

```
20:  List<Map<String, dynamic>> _myChores = [];
96:      final myChores = await Supabase.instance.client
117:        _myChores = List<Map<String, dynamic>>.from(myChores);
282:    final totalPending = _myChores.length;
361:    if (_myChores.isEmpty)
377:      ..._myChores.map((chore) => _ChoreCard(
```

The query at line 96 populates `_myChores`. The render at line 377 iterates it and constructs `_ChoreCard` per chore, which renders the Mark complete button (line 561) without any status check.

The widget has `AutomaticKeepAliveClientMixin` (line 16) — state survives across tab switches and Navigator push/pop.

Listeners that should keep the list fresh:
```
31:    RealtimeService.instance.choresVersion.addListener(_onRealtimeUpdate);
32:    ActiveMemberService.instance.activeMemberId.addListener(_onActiveMemberChanged);
```

Both call `_loadData()` when fired. So in the happy path the list refreshes on any chore change.

## Phase 2 — current query verbatim

`chore_dashboard_screen.dart:93-102`:

```dart
final myMemberId = _myMembership!['id'];

// Load chores assigned to me that are assigned/pending
final myChores = await Supabase.instance.client
    .from('chores')
    .select()
    .eq('household_id', householdId)
    .eq('assigned_to_member_id', myMemberId)
    .inFilter('status', ['assigned', 'in_progress'])
    .order('due_at', ascending: true);
```

The filter `inFilter('status', ['assigned', 'in_progress'])` corresponds to Postgres `status IN ('assigned','in_progress')`. **Excludes** `'pending_verification'`, `'verified'`, `'rejected'`, `'overdue'`, `'cancelled'`. Verified chores should never be returned by this query.

The render that consumes the result, `_ChoreCard.build`, lines 556-569:

```dart
const SizedBox(height: 12),
SizedBox(
  width: double.infinity,
  child: FilledButton.icon(
    onPressed: onComplete,
    icon: const Icon(Icons.check_rounded, size: 18),
    label: const Text('Mark complete'),
    style: FilledButton.styleFrom(
      minimumSize: const Size.fromHeight(40),
      backgroundColor: AppColors.grassGreen,
    ),
  ),
),
```

No `if (status == ...)` guard. The button always renders for every card.

Side observation: `_ChoreCard.onTap` at line 489-495 has a latent bug — `Navigator.push(...).then((_) => onComplete)` returns `onComplete` (a `VoidCallback`) from the `.then` callback but never invokes it. To actually trigger a callback after returning from chore detail it would need `.then((_) => onComplete())` with parentheses. Out of scope for this fix; flagging.

## Phase 3 — what should be included

The `chore_status` enum (from `0001_initial_schema.sql:12`): `'assigned'`, `'in_progress'`, `'pending_verification'`, `'verified'`, `'rejected'`, `'overdue'`, `'cancelled'`. Per-status disposition for the kid's "My Chores" view:

| Status | Include? | Affordance |
|---|---|---|
| `assigned` | ✓ | Mark complete |
| `in_progress` | ✓ | Mark complete |
| `pending_verification` | ✓ (recommend) | "Awaiting verification" label; no Mark complete button. Currently EXCLUDED — chores vanish after the kid taps Complete, which is confusing |
| `verified` | ✗ | n/a — done; gone |
| `rejected` | ✓ (after Batch 4 ships Re-do) | "Rejected — tap to re-do" button. Before Batch 4: include with "Rejected — ask admin to redo" label only |
| `overdue` | maybe (out of scope here) | Mark complete + late badge — but the schema's `overdue` is a stale status; nothing in the codebase transitions to it. Probably dead enum value. |
| `cancelled` | ✗ | n/a |

Today the query only includes `'assigned'` and `'in_progress'`. So `pending_verification` chores are invisible to the kid (and assigned adult) on the dashboard. The chore_detail screen still shows them via its independent query. This is a real UX gap, separate from the verified-stale bug.

## Phase 4 — proposed fix

Two options. The bug surface lives in BOTH the data layer (race-condition stale data) and the UI layer (no status guard). The fixes can be applied independently or together.

### Option A — Minimal: UI-side gate (5 lines)

Defense in depth. Even if stale data sneaks through, the button only renders when the status is actionable.

In `_ChoreCard.build` (around line 470), compute a local from `chore['status']`. In the button section (around line 558), wrap the button in a conditional:

```dart
// In build(), top:
final status = chore['status'] ?? 'assigned';
final isActionable = status == 'assigned' || status == 'in_progress';

// Replace the unconditional FilledButton with:
if (isActionable)
  SizedBox(
    width: double.infinity,
    child: FilledButton.icon(
      onPressed: onComplete,
      // ... unchanged ...
    ),
  ),
```

Pros:
- 1 file changed, ~5 lines net (1 local, 1 `if` wrapper)
- Defends against any future stale-cache or race-condition scenario
- No data-fetch change; minimal risk

Cons:
- Doesn't address the broader UX gap (pending_verification chores still disappear from the dashboard after the kid taps Complete)
- Doesn't address the "where do rejected chores live" question

### Option B — UI gate + query broadening (15-20 lines)

Include more statuses in the query, then render status-appropriate UI per card.

```dart
// chore_dashboard_screen.dart:101 — broaden the filter
.inFilter('status', ['assigned', 'in_progress', 'pending_verification', 'rejected'])
```

Then in `_ChoreCard.build`:

```dart
final status = chore['status'] ?? 'assigned';

// Replace the unconditional Mark complete button with a switch:
switch (status) {
  case 'assigned':
  case 'in_progress':
    return FilledButton.icon(onPressed: onComplete, icon: Icons.check_rounded, label: 'Mark complete', ...);
  case 'pending_verification':
    return Chip(label: 'Awaiting verification', backgroundColor: AppColors.honeyGold.withOpacity(0.15));
  case 'rejected':
    return Chip(label: 'Rejected — ask admin to redo', backgroundColor: AppColors.coral.withOpacity(0.15));
}
```

Pros:
- Closes the disappearing-chore UX gap for pending_verification
- Surfaces rejected chores to the kid (so they know to ask for re-do)
- Sets up cleanly for Batch 4's Re-do affordance (just swap `Chip` for an actionable button in the `'rejected'` case)

Cons:
- Bigger change (~15-20 lines)
- Requires UI design choices (badge style, color, copy)
- Includes some Batch 4-adjacent work

### Recommendation

Ship Option A as the immediate fix. Option B is a UX improvement that could either go in this branch (Phase 6 Q1-Q3 dependent) or land alongside Batch 4 when the Re-do affordance arrives — which would be a natural moment to broaden the dashboard query.

## Phase 5 — related queries audit

`grep -rn "assigned_to_member_id"` across `lib/`:

| Site | What | Status filter? | Issue? |
|---|---|---|---|
| `chore_dashboard_screen.dart:96-102` | My Chores list | `IN ('assigned','in_progress')` | The bug under investigation — query is correct, but UI doesn't double-check |
| `chore_dashboard_screen.dart:107-113` | Pending Verification list (admin) | `= 'pending_verification'` | Correct |
| `chore_dashboard_screen.dart:173` | `_createNextRecurringChoreIfNeeded` duplicate-check SELECT | n/a (write path) | Correct |
| `chore_detail_screen.dart:91` | Single chore load | n/a (by id) | Correct |
| `member_profile_screen.dart:48-52` | "Completed chores" stat count | `IN ('verified','pending_verification')` | **Correct for this purpose** — wants completed history |
| `member_profile_screen.dart:65-70` | "Recent chores" list (history view) | none (all statuses) | **Correct** — history view, wants everything |
| `activity_feed_screen.dart:52` | Activity feed chore items | (via activity feed logic) | Correct |

Only the My Chores query at line 96-102 has the actionable-list semantic. No other sibling queries are affected by this bug.

## Phase 6 — open questions

**Q1. Should `'pending_verification'` chores appear in "My Chores"?**

Today: excluded. Kid taps Complete → chore vanishes from list. Slightly confusing — kid doesn't know whether their tap "worked" until they check the chore detail screen.

Recommendation: **yes**, include them, with an "Awaiting verification" label instead of the Mark complete button. Option B above.

**Q2. Should `'rejected'` chores appear, given Batch 4's Re-do affordance hasn't shipped?**

Today: excluded by the query. After Batch 4: should appear with a Re-do button. In the Half B → Batch 4 gap: should appear with a "Rejected — ask admin to redo" label (no button).

Recommendation: **yes** for both phases. The kid needs to know their chore was rejected; they shouldn't have to navigate to chore detail to find out.

**Q3. How big a fix to ship now?**

- Option A only: 5-line defense-in-depth UI gate. Doesn't change query or surface new chores. **Lowest risk.** Recommend if you want a fast cleanup that just stops the immediate symptom.
- Option B: query broadening + status-aware UI. Includes pending_verification + rejected surfacing. Bigger UX improvement but more lines, more UI design calls. **Recommend if** you want to close the broader "My Chores never shows pending/rejected" UX gap in the same pass.
- Option A now + Option B alongside Batch 4: defer the broader UX work until Re-do lands, so both ship together.

The user's framing ("small cleanup") suggests Option A.

## Next steps

1. **You pick** Option A (~5 lines, ship now), Option B (~15-20 lines, also ship now), or Option A now + B alongside Batch 4.
2. **I write the chosen fix** with analyzer baseline before/after; expect 0 net new issues either way.
3. **iPhone smoke-test**: navigate to dashboard with a recurring verified chore in the database; verify Mark complete button no longer appears for the verified instance (Option A) or that the broader status-aware UI renders correctly (Option B).
4. **Commit** on `fix/verified-chores-stale-in-my-chores-2026-05-23`. Push with `--set-upstream`.

The latent `Navigator.push(...).then((_) => onComplete)` bug at `_ChoreCard.dart:494` is out of scope but worth a followup ticket — it looks like the intent was to refresh the list after returning from chore detail, but the syntax is wrong and the callback never fires. Either fix to `.then((_) => onComplete())` or rip out the `.then` entirely (the parent's realtime listener should handle the refresh).
