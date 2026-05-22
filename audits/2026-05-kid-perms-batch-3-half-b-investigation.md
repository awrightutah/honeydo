# Kid Permissions Batch 3 Half B — Investigation

Date: 2026-05-22
Branch: `feat/kid-perms-chore-rpcs-batch-3-half-b-2026-05-22` (read-only investigation; no edits, no commits)
Scope: migrate `_verifyChore` → `approve_chore` RPC; migrate `_completeChore` → `complete_chore_self` RPC; check `_quickUpdateStatus` in chore_detail
Status: investigation complete — **`'rejected'` enum is NOT a blocker**; 6 open questions surfaced

## Summary

Good news up front:

- The `chore_status` enum already includes `'rejected'` (verified at `0001_initial_schema.sql:12`). **Not a blocker.**
- The 0017 RLS lockdown only breaks two specific UX paths in current app code: non-admin adult chore completion via `_completeChore`, and non-admin assignee chore edits via `_saveChore` (chore_detail). Half B fixes the first.
- The Pass 2 PIN-debugging error-surfacing pattern is already followed by 3 of 4 chore-write sites. One site (`_completeChore`) currently uses `const SnackBar` with a generic message — needs fixing as part of the migration.

The migration is more nuanced than just "swap two function bodies for RPC calls." Six considerations to settle before SQL — well, Dart — gets written:

1. Kid-vs-adult branching in `_completeChore`: `complete_chore_self` is adult-only by RPC contract. Kid completions stay on the direct-UPDATE path (works under RLS via admin JWT) until Batch 4 migrates them to `submit_kid_chore_with_photo`.
2. The reject semantic change (kid's "Re-do" affordance lives in Batch 4) is a known UX gap that becomes user-visible after Half B lands.
3. `_quickUpdateStatus` in `chore_detail_screen.dart` is a sister to `_completeChore`/`_verifyChore` — touches the same statuses via chip taps. In-scope vs out-of-scope question.
4. `_saveChore` (chore_detail) non-admin assignee path is broken after Batch 2 RLS. Tighten UI or add an RPC?
5. The recurring-chore creation (`_createNextRecurringChoreIfNeeded`) is currently called inside `_verifyChore` after approval. The new `approve_chore` RPC doesn't do this. Keep app-side or move to RPC?
6. The `'rejected'` status only has explicit UI handling in `search_screen.dart`. Other chore lists may render rejected chores with default styling — needs a quick UI review during Half B testing.

## Phase 1 — chore-table write sites

`grep -rn "from('chores')" apps/mobile/lib/`. SELECT-only sites omitted; only WRITE sites listed:

| File:line | Operation | What it does | RLS-affected? | Half B scope? |
|---|---|---|---|---|
| `chore_dashboard_screen.dart:133` (`_completeChore`) | UPDATE `status='pending_verification'` | Member taps "Complete" on their own chore | **BREAKS** for non-admin adult (today's bug) | **YES** — migrate to `complete_chore_self` |
| `chore_dashboard_screen.dart:190` (`_createNextRecurringChoreIfNeeded`) | INSERT new chore (after approval) | Generates next occurrence of recurring chore | Admin-only OK (called from `_verifyChore` admin context) | NO — stays as-is (called post-RPC) |
| `chore_dashboard_screen.dart:200, 252` (`_verifyChore`) | UPDATE chore status='verified' / 'assigned' | Admin approve/reject from dashboard | Works for admin under Batch 2 RLS | **YES** — migrate to `approve_chore` |
| `chore_dashboard_screen.dart:719` (`_AddChoreSheet`) | INSERT new chore | Admin creates chore from FAB | Admin-only OK | NO — stays direct |
| `chore_detail_screen.dart:197` (`_saveChore`) | UPDATE chore fields | Edit chore details (title, points, recurrence, status, due_at) | **BREAKS** for non-admin assignee | NO (flagged Q4) — see open questions |
| `chore_detail_screen.dart:244` (`_deleteChore`) | DELETE chore | Admin removes chore | Works for admin | NO — stays direct |
| `chore_detail_screen.dart:881` (`_quickUpdateStatus`) | UPDATE chore status | Action chip in chore detail; status varies (`in_progress`, `pending_verification`, `verified`, `assigned`, `skipped`) | Works for admin under Batch 2 RLS; breaks for non-admin paths | **PARTIAL** (flagged Q3) |
| `chore_detail_screen.dart:947` (`_createNextRecurringChoreIfNeeded`) | INSERT next chore | Recurring duplicate; called by `_quickUpdateStatus` post-verify | Admin-only OK | NO — stays as-is |
| `chore_templates_screen.dart:130` (template apply) | INSERT chore | Admin applies a template | Admin-only OK | NO — stays direct |

**11 SELECT-only sites** (data_export, household_stats, member_profile, activity_feed, search, chore_dashboard `_loadData`, chore_detail `_loadChore`) are RLS-untouched and not in scope.

## Phase 2 — current `_verifyChore` body + mapping to `approve_chore` RPC

Full body at `chore_dashboard_screen.dart:193–266`:

```dart
Future<void> _verifyChore(String choreId, bool approved) async {
  try {
    final chore = _pendingVerification.firstWhere((c) => c['id'] == choreId);
    final points = chore['point_value'] ?? 5;

    if (approved) {
      // Update chore status
      await Supabase.instance.client.from('chores').update({
        'status': 'verified',
        'verified_at': DateTime.now().toIso8601String(),
        'verified_by_member_id': _myMembership!['id'],
      }).eq('id', choreId);

      // Award points to the user who completed it.
      // Adults have a Supabase auth account (kind = 'adult_auth_user');
      // kids are sub_profiles with auth_user_id = NULL, so for kids we
      // call the member_id-based RPC variants (see 0011 migration).
      final assignedMemberId = chore['assigned_to_member_id'] as String;
      final assignedMember = await Supabase.instance.client
          .from('household_members')
          .select('id, kind, auth_user_id')
          .eq('id', assignedMemberId)
          .single();

      final totalPoints = points + (chore['bonus_points'] ?? 0);
      final isSubProfile = assignedMember['kind'] == 'sub_profile';

      if (isSubProfile) {
        await Supabase.instance.client.rpc('award_points_to_member', params: {...});
        await Supabase.instance.client.rpc('check_and_award_achievements_for_member', params: {...});
      } else {
        await Supabase.instance.client.rpc('award_points', params: {...});
        await Supabase.instance.client.rpc('check_and_award_achievements', params: {...});
      }

      // Create the next occurrence for recurring chores after approval.
      await _createNextRecurringChoreIfNeeded(chore);
    } else {
      // Reject - put chore back to assigned
      await Supabase.instance.client.from('chores').update({
        'status': 'assigned',
        'completed_at': null,
      }).eq('id', choreId);
    }

    _loadData();
  } catch (e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not update chore status: $e')),
      );
    }
  }
}
```

**Behavior summary:**
- Parameters: `choreId`, `approved` (bool).
- Approve path: 3 sequential operations (status UPDATE, member lookup, branch-on-kind to award_points + achievements), plus `_createNextRecurringChoreIfNeeded`.
- Reject path: status→`'assigned'`, `completed_at`→null (kid retries on the same row; no `rejected_reason` saved).
- Error handling: `catch (e)` + non-const SnackBar with `$e`. ✓ Follows Pass 2 lesson, except missing `debugPrint` (minor).

**Mapping to `approve_chore(p_chore_id, p_approved, p_reason)`:**

The new RPC absorbs almost everything inside its `BEGIN ... END` block (per `0017:91–198`):
- Status UPDATE (verified or rejected) — RPC handles
- Member lookup for kind — RPC handles
- Branch to `award_points_to_member` vs `award_points` — RPC handles
- Branch to `check_and_award_achievements_for_member` vs `check_and_award_achievements` — RPC handles
- Photo `delete_after` scheduling — RPC handles (bonus; current app didn't do this)

**Two things the RPC does NOT handle:**
1. `_createNextRecurringChoreIfNeeded` (recurring-chore next-occurrence creation) — must stay app-side after RPC call.
2. Saving a `rejected_reason` text — `approve_chore` accepts `p_reason` but the current UI has no field for entering rejection text. Pass `null` for now; Batch 4 adds the reject-with-reason UI.

**Semantic differences to call out:**
- Reject sets `status='rejected'` (final) instead of `'assigned'` (retry). Per Q1 from Batch 2. Kid-side Re-do affordance lives in Batch 4.
- RPC raises `'Chore is not pending verification'` on already-verified/rejected (per Q4 from Batch 2). Current `_verifyChore` doesn't check the current state — silently overwrites. The new behavior catches double-taps.

**Proposed migrated body (~17 lines):**

```dart
Future<void> _verifyChore(String choreId, bool approved) async {
  try {
    final chore = _pendingVerification.firstWhere((c) => c['id'] == choreId);

    await Supabase.instance.client.rpc('approve_chore', params: {
      'p_chore_id': choreId,
      'p_approved': approved,
      'p_reason': null,  // Batch 4 adds UI for entering rejection reason
    });

    // Recurring chores still need next-occurrence creation app-side
    // (the RPC doesn't do this).
    if (approved) {
      await _createNextRecurringChoreIfNeeded(chore);
    }

    _loadData();
  } catch (e) {
    debugPrint('approve_chore failed: $e');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not update chore status: $e')),
      );
    }
  }
}
```

~70 lines → ~17 lines. The kid/adult points branching is now server-side. Big simplification.

## Phase 3 — current `_completeChore` body + mapping to `complete_chore_self` RPC

Full body at `chore_dashboard_screen.dart:131–146`:

```dart
Future<void> _completeChore(String choreId) async {
  try {
    await Supabase.instance.client.from('chores').update({
      'status': 'pending_verification',
      'completed_at': DateTime.now().toIso8601String(),
    }).eq('id', choreId);

    _loadData();
  } catch (e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not mark chore as complete. Please try again.')),
      );
    }
  }
}
```

**Behavior:**
- Parameter: `choreId`.
- Single UPDATE: status→`'pending_verification'`, `completed_at`→now.
- Does NOT distinguish kid vs adult — fires for any active member tapping "Complete".
- Does NOT award points (kid+admin verify pathway in `_verifyChore` does that).
- **VIOLATES Pass 2 error-surfacing lesson:** `catch (e)` binds `e` but the SnackBar is `const` with a generic message (no `$e` interpolation, no `debugPrint`). Fix during migration.

**Mapping to `complete_chore_self(p_chore_id, p_member_id)`:**

The new RPC is adult-only (per `0017:212–290`):
- Validates `p_member_id` is in chore's household, is_active, `kind='adult_auth_user'`, matches `auth.uid()`.
- Verifies `chore.assigned_to_member_id = p_member_id` (only complete your own).
- Verifies status in `('assigned','in_progress')`.
- Sets status→`'verified'` directly (no admin step — per spec Q3 decision).
- Awards points via `award_points` (adult path) + `check_and_award_achievements`.

**This is a semantic change**: adults no longer go through `pending_verification`. Adult tap "Complete" → chore auto-verifies, points awarded immediately. The admin verify step is bypassed for adults.

**Adult vs kid routing question (Q1 in open questions):**

Kid completions today work via direct UPDATE (kid sets status to `'pending_verification'`; admin verifies later). After Batch 2 RLS, this *only works* because the underlying JWT is the adult's — RLS sees admin role, allows UPDATE. The user experience is unchanged.

If we migrate the kid path to `complete_chore_self`, the RPC will raise `'Only the assigned adult can self-complete this chore'` (it checks kind=adult). Kids would be blocked.

The right place for kid completions is `submit_kid_chore_with_photo` — but that's Batch 4 (photo flow, UI, Storage upload). For Half B, the cleanest move is:

```dart
Future<void> _completeChore(String choreId) async {
  try {
    if (Permissions.isKid(_myMembership)) {
      // Kid path: temporarily keep the direct UPDATE. Works under
      // current RLS because the JWT is the parent adult's. Batch 4
      // replaces this with submit_kid_chore_with_photo (photo required).
      await Supabase.instance.client.from('chores').update({
        'status': 'pending_verification',
        'completed_at': DateTime.now().toIso8601String(),
      }).eq('id', choreId);
    } else {
      // Adult path: use the RPC. Per spec Q3, adults auto-verify
      // (status → 'verified' directly, points awarded immediately).
      await Supabase.instance.client.rpc('complete_chore_self', params: {
        'p_chore_id': choreId,
        'p_member_id': _myMembership!['id'],
      });
    }

    _loadData();
  } catch (e) {
    debugPrint('complete chore failed: $e');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not mark chore as complete: $e')),
      );
    }
  }
}
```

This:
- Fixes non-admin adult completion (the Batch 2 breakage).
- Preserves kid behavior unchanged for now.
- Fixes the error-surfacing violation.
- Sets up the kid path for clean replacement in Batch 4.

## Phase 4 — error surfacing audit

For each chore-write site, status against Pass 2 PIN-debugging lessons:

| Site | catch pattern | const SnackBar? | $e interpolation? | debugPrint? | Status |
|---|---|---|---|---|---|
| `chore_dashboard:_completeChore` | `catch (e)` | **YES (violation)** | NO | NO | **FIX in Half B** |
| `chore_dashboard:_verifyChore` | `catch (e)` | NO | YES (`'$e'`) | NO | OK; add `debugPrint` during migration for symmetry |
| `chore_detail:_saveChore` | `catch (e)` | NO | YES | NO | OK |
| `chore_detail:_deleteChore` | (haven't read full catch but pattern is consistent across screen) | TBD | TBD | TBD | NOT in Half B scope |
| `chore_detail:_quickUpdateStatus` | `catch (e)` | NO | YES (`'$e'`) | NO | OK; add `debugPrint` if migrated |

Only `_completeChore` violates. The migration fixes it.

The other sites already comply with the visual-surface part of the pattern (`$e` in SnackBar). Adding `debugPrint('action_name failed: $e')` to all of them is a clean win — terminal output for development, SnackBar text for the user. Half B should adopt this on the two migrated functions.

## Phase 5 — chore_detail_screen direct UPDATEs

Three direct UPDATEs in chore_detail_screen, two of which are partial-fit for Half B scope:

### `_saveChore` (lines 195–198) — admin chore-edit

```dart
await Supabase.instance.client
    .from('chores')
    .update(updates)
    .eq('id', widget.choreId);
```

`updates` is a Map of title, description, point_value, recurrence_rule, status, assigned_to_member_id, due_at — anything from the Edit form.

UI gate at line 347: `final canEdit = isAdmin || isAssignedToMe;` (now refactored to `Permissions.canEditAnyChore(_householdMember) || isAssignedToMe` via Half A). Non-admin assignee passes the UI gate and lands in `_saveChore`, where Batch 2's admin-only UPDATE RLS rejects.

**Broken right now for assignees.** Half B options (see Q4):

- (A) Tighten UI to admin-only: drop `|| isAssignedToMe`. Assignee loses ability to edit own due-date or set status from this screen. Quick fix; loss of feature.
- (B) Add `edit_chore_self(p_chore_id, p_member_id, p_due_at, p_notes)` RPC for the assignee subset. More work; preserves feature.
- (C) Accept the break; ship a UI message ("Only admins can edit chores"). Half-measure.

Recommend either A (quick, ship now) or B (right answer for kid permissions later — kids may legitimately need to edit their own chore notes). Decide before Half B writes.

### `_quickUpdateStatus` (lines 872–902) — action-chip status updates

```dart
Future<void> _quickUpdateStatus(String newStatus) async {
  try {
    final previousChore = _chore == null ? null : Map<String, dynamic>.from(_chore!);
    final updates = <String, dynamic>{'status': newStatus};
    if (newStatus == 'pending_verification' || newStatus == 'verified') {
      updates['completed_at'] = DateTime.now().toIso8601String();
    }
    await Supabase.instance.client.from('chores').update(updates).eq('id', widget.choreId);

    if ((newStatus == 'pending_verification' || newStatus == 'verified') && previousChore != null) {
      await _createNextRecurringChoreIfNeeded(previousChore);
    }

    await _loadData();
    // ... success SnackBar ...
  } catch (e) {
    // ... non-const SnackBar with $e ...
  }
}
```

Called from action chips at line 514:
- `'Complete'` → `_quickUpdateStatus('pending_verification')` — equivalent to `_completeChore` in chore_dashboard. **Same migration treatment.**
- `'Verify'` → `_quickUpdateStatus('verified')` (admin only, gated by UI) — same effect as `_verifyChore`'s approve path BUT without awarding points (known bug from baseline-merge followups). **Migrating to `approve_chore` fixes the missing-points bug as a side effect.**
- `'Start'` → `_quickUpdateStatus('in_progress')` — non-completion path; works under admin RLS today but breaks for non-admin assignee.
- `'Skip'` → `_quickUpdateStatus('skipped')` — **`'skipped'` is not in the `chore_status` enum** (known pre-existing bug). Out of Half B scope.
- `'Reassign'` → `_quickUpdateStatus('assigned')` — admin chore-edit; same as `_saveChore` issue.

Half B scope (recommended): migrate `_quickUpdateStatus` to **branch internally** on `newStatus`:

```dart
if (newStatus == 'pending_verification') {
  // Same kid/adult branching as _completeChore
} else if (newStatus == 'verified') {
  // Call approve_chore RPC (also fixes the missing-points bug)
} else {
  // Direct UPDATE (admin status-edit affordance); works under Batch 2 RLS
}
```

This is more code than the dashboard's `_completeChore`/`_verifyChore` migration but cleaner than duplicating logic.

### `_deleteChore` (lines 242–245) — admin chore deletion

Works under Batch 2 RLS (admin-only DELETE policy on chores). Not in Half B scope.

## Phase 6 — `'rejected'` status enum check

```
$ grep "create type chore_status" supabase/migrations/0001_initial_schema.sql
12:create type chore_status as enum ('assigned', 'in_progress', 'pending_verification', 'verified', 'rejected', 'overdue', 'cancelled');
```

`'rejected'` is in the enum. The `approve_chore` RPC's reject path (which sets `status='rejected'`) will work without any schema change.

**UI rendering of rejected chores:**

```
$ grep -rn "'rejected'" apps/mobile/lib/screens/ --include="*.dart"
apps/mobile/lib/screens/search_screen.dart:467:    'rejected': AppColors.coral,
```

Only `search_screen.dart` explicitly maps `'rejected'` to a color. Other status-styled screens (`chore_detail_screen.dart:308`, `chore_dashboard_screen.dart`) don't list `'rejected'` in their status-to-color maps and presumably fall through to a default.

**Implication:** after Half B lands, an admin clicking Reject will produce a chore with `status='rejected'`. This chore will show up in the chore lists with whatever default styling. Worth a quick visual review during Half B testing — particularly:
- Does the kid's "My Chores" tab still show the rejected chore?
- Does it look different from `'assigned'`?
- Is there any user-facing indication that it was rejected, or does it just look like another active chore?

If the answer is "rejected chores look identical to assigned chores," that's a UX bug that should be fixed in Half B or punted to Batch 4 along with the Re-do affordance.

## Phase 7 — files touched in Half B

| File | Sites | Change |
|---|---|---|
| `apps/mobile/lib/screens/chore_dashboard_screen.dart` | 2 | `_verifyChore` body (~70 → ~17 lines) calls `approve_chore` RPC. `_completeChore` body branches on `Permissions.isKid(_myMembership)`: kid path keeps direct UPDATE temporarily; adult path calls `complete_chore_self` RPC. Both add `debugPrint`. `_completeChore` SnackBar dropped from `const` to non-const with `$e`. |
| `apps/mobile/lib/screens/chore_detail_screen.dart` | 1 | `_quickUpdateStatus` internal branching: `pending_verification` → same as `_completeChore`; `verified` → `approve_chore` RPC (also fixes the missing-points bug noted in baseline-merge followups); other statuses → direct UPDATE. |
| (optional) `_saveChore` non-admin assignee path | 1 | Depends on Q4 — either tighten UI to admin-only OR add `edit_chore_self` RPC. Not strictly required for Half B if we decide to leave the break as known-issue. |

Estimated diff: ~50–100 lines net (mostly deletions in `_verifyChore`).

Files NOT touched in Half B:
- Other chore-write sites listed in Phase 1 are admin-only and work fine under Batch 2 RLS.
- `_createNextRecurringChoreIfNeeded` (in both chore_dashboard and chore_detail) — stays as-is; called post-RPC from app side.
- chore_templates_screen, search_screen, member_profile_screen — read-only or admin-write, no changes needed.

## Phase 8 — open questions for user

**Q1. Kid completion path during Half B.** `complete_chore_self` is adult-only by RPC contract. Options:
- (A) Branch in `_completeChore` on `Permissions.isKid(_myMembership)`. Adults → RPC; kids → keep direct UPDATE temporarily. (Recommend.)
- (B) Block kid completions in Half B (show "coming in Batch 4" snackbar). Cleaner but degrades UX for kids during the gap.
- (C) Wait until Batch 4 lands before merging Half B. Doesn't unblock the Batch 2 non-admin-adult breakage; not recommended.

**Recommendation: A.** Smallest change, fixes the immediate breakage, doesn't introduce new bugs. Batch 4 cleanly replaces the kid branch with `submit_kid_chore_with_photo`.

**Q2. Reject semantic change ('assigned' → 'rejected').** Today's `_verifyChore` reject sets status='assigned' so the kid retries on the same row. After migration via `approve_chore`, reject sets status='rejected' (final) per spec Q1. The kid can't retry until Batch 4 ships the "Re-do" button.

- Acceptable trade-off for the Half-B-to-Batch-4 gap? (Recommend yes — admins can also delete + recreate as a workaround.)
- Or punt the reject path entirely from Half B (admin can't reject until Batch 4 ships the Re-do)? (Doesn't really help; the approve path is the more important one.)

**Recommendation: ship Half B with reject going to 'rejected'.** Add a known-issue line to the implementation report saying "kid Re-do not available until Batch 4."

**Q3. `_quickUpdateStatus` migration scope.** Three paths to consider:
- `pending_verification`: migrate per `_completeChore` (kid/adult branch).
- `verified`: migrate to `approve_chore` (fixes missing-points bug as a side-effect).
- Other (`assigned`, `in_progress`, `skipped`, etc.): leave as direct UPDATE.

Migrate just the two (pending_verification, verified) or migrate the whole function with a status-switch? Recommend the two-path migration — minimal change, fixes the immediate problems, leaves admin status-edit affordances untouched.

**Q4. `_saveChore` non-admin assignee.** Today's UI lets a non-admin assignee enter Edit mode (`canEdit = isAdmin || isAssignedToMe`) and try to save — they'll hit an RLS error under Batch 2. Options:
- (A) Tighten UI: drop `|| isAssignedToMe`. Quick fix; assignee loses self-edit feature.
- (B) Add `edit_chore_self` RPC for the assignee subset (due_at, notes). Right answer eventually for kid notes, etc. More work.
- (C) Leave broken; ship a UI warning. Half-measure.

Recommend **A for now**, **B later** (in or after Batch 4). The assignee-edit affordance is rarely used today and gives a confusing RLS error instead of a clean denial.

**Q5. Recurring chore creation.** `_createNextRecurringChoreIfNeeded` currently runs inside `_verifyChore` after admin approval. The `approve_chore` RPC doesn't do this. Options:
- (A) Keep app-side post-RPC call (as proposed in Phase 2). (Recommend.)
- (B) Move next-occurrence creation server-side into `approve_chore`. More invasive; would be a follow-up migration; not strictly in Half B scope.

**Recommendation: A.** Keep app-side; flag B as a Pass-2.x followup.

**Q6. Rejected chore UI rendering.** `'rejected'` status only has explicit handling in `search_screen.dart`. Other screens (chore_dashboard, chore_detail) fall through to defaults. After Half B lands, rejected chores will start appearing. Half B should either:
- Add explicit 'rejected' status styling (color + label) to chore_dashboard and chore_detail status maps. ~5 lines of UI tweaks. Small bug fix, reasonable in scope.
- Leave it for Batch 4 (which adds the Re-do affordance, naturally surfaces rejected chores). Punts a visual gap.

**Recommendation: include the small UI tweak in Half B.** Five lines, no risk, makes the new state legible immediately. Add `'rejected': AppColors.coral` and an icon/label mapping in the chore dashboard and chore detail status maps.

## Next steps

1. **You answer Q1–Q6.** Q1 and Q2 are the consequential ones; Q3–Q6 have clear recommendations.
2. **I write the migration** — likely ~50–100 lines of net diff across `chore_dashboard_screen.dart` and `chore_detail_screen.dart`, plus the small 'rejected' UI mapping if Q6 includes it.
3. **Analyzer baseline** before and after. Expect 0 net new issues (RPC calls follow the existing `await client.rpc(...)` pattern; no new imports beyond `Permissions` which Half A already established).
4. **iPhone smoke test:**
   - Adult admin: tap Complete on own chore → goes straight to verified (status change), points awarded.
   - Adult non-admin (if any): same path; was broken before, now works.
   - Kid: tap Complete on own chore → status='pending_verification' (unchanged, direct UPDATE still works).
   - Admin: tap Approve on a pending_verification chore → status='verified', points awarded (via RPC). Recurring chores spawn next occurrence.
   - Admin: tap Reject on a pending_verification chore → status='rejected'. Verify the chore appears in lists (UI check).
   - Admin: tap Approve on an already-verified chore → see "Chore is not pending verification" SnackBar with the exception text visible.
5. **Commit** as one Half B commit on `feat/kid-perms-chore-rpcs-batch-3-half-b-2026-05-22`. Push with `--set-upstream`.
6. **Schedule Batch 4** — kid chore-photo flow + Re-do affordance for rejected chores + the assignee-edit RPC if we picked Q4-B.

After Half B, the chore mutation surface in app code is fully RPC-aligned: no more direct chore UPDATEs in the completion/verification flow. The remaining direct UPDATEs (`_saveChore`, `_quickUpdateStatus` for non-completion statuses, `_deleteChore`, `_createNextRecurringChoreIfNeeded` INSERT) are all admin-only and work under Batch 2's RLS.
