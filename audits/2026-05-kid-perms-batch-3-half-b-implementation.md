# Kid Permissions Batch 3 Half B — Implementation

Date: 2026-05-22
Branch: `feat/kid-perms-chore-rpcs-batch-3-half-b-2026-05-22` (working-tree only; no commits)
Scope: 5 code changes across 2 files migrating chore-completion / chore-verification to the Batch 2 RPCs
Status: code complete — **not committed; analyzer delta = 0**

## Summary

Half B done. All chore-completion and chore-verification flows in app code now route through `approve_chore` and `complete_chore_self` RPCs (kid path on `_completeChore` and `_quickUpdateStatus` keeps direct UPDATE temporarily per Q1; replaced in Batch 4 by `submit_kid_chore_with_photo`). `_saveChore` tightened to admin-only per Q4. `'rejected'` status now has explicit color + icon mapping per Q6. Pass-2 error-surfacing pattern (catch-`e` + `debugPrint` + non-const SnackBar with `$e`) applied to all modified catches.

Analyzer: **333 issues before and after — net delta zero, no new errors**.

`_verifyChore` shrank from ~70 lines to ~17 lines (kid/adult points branching is now server-side inside `approve_chore`). 

The non-admin adult chore-completion breakage introduced by Batch 2's RLS lockdown is fixed.

## Files modified

| File | Sites | Change |
|---|---|---|
| `apps/mobile/lib/screens/chore_dashboard_screen.dart` | 2 | `_verifyChore` body → `approve_chore` RPC (server-side handles status update, points branch, achievements, photo cleanup). `_completeChore` body branches on `Permissions.isKid(_myMembership)`: kid keeps direct UPDATE with TODO; adult calls `complete_chore_self` RPC. Both use `debugPrint` + non-const SnackBar with `$e`. |
| `apps/mobile/lib/screens/chore_detail_screen.dart` | 3 | `_quickUpdateStatus` internal status branching: `pending_verification` → kid/adult branch (same as `_completeChore`); `verified` → `approve_chore` RPC (fixes pre-existing missing-points bug); other statuses → direct UPDATE. `_saveChore` `canEdit` dropped `|| isAssignedToMe` (admin-only). `_statusColor` + `_statusIcon` switches gained `'rejected'` entries. |

No new files. No imports added (both screens already imported `Permissions` from Half A).

## Per-phase diffs

### Phase 1 — `chore_dashboard_screen.dart` `_verifyChore` (~70 lines → ~17 lines)

```diff
   Future<void> _verifyChore(String choreId, bool approved) async {
     try {
       final chore = _pendingVerification.firstWhere((c) => c['id'] == choreId);
-      final points = chore['point_value'] ?? 5;
-
-      if (approved) {
-        // Update chore status
-        await Supabase.instance.client.from('chores').update({
-          'status': 'verified',
-          'verified_at': DateTime.now().toIso8601String(),
-          'verified_by_member_id': _myMembership!['id'],
-        }).eq('id', choreId);
-
-        // Award points to the user who completed it.
-        // Adults have a Supabase auth account (kind = 'adult_auth_user');
-        // kids are sub_profiles with auth_user_id = NULL, so for kids we
-        // call the member_id-based RPC variants (see 0011 migration).
-        final assignedMemberId = chore['assigned_to_member_id'] as String;
-        final assignedMember = await Supabase.instance.client
-            .from('household_members')
-            .select('id, kind, auth_user_id')
-            .eq('id', assignedMemberId)
-            .single();
-
-        final totalPoints = points + (chore['bonus_points'] ?? 0);
-        final isSubProfile = assignedMember['kind'] == 'sub_profile';
-
-        if (isSubProfile) {
-          await Supabase.instance.client.rpc('award_points_to_member', params: { /* … */ });
-          await Supabase.instance.client.rpc('check_and_award_achievements_for_member', params: { /* … */ });
-        } else {
-          await Supabase.instance.client.rpc('award_points', params: { /* … */ });
-          await Supabase.instance.client.rpc('check_and_award_achievements', params: { /* … */ });
-        }
-
-        // Create the next occurrence for recurring chores after approval.
+
+      // approve_chore (migration 0017) handles the status update, points
+      // award (with kid/adult branching), achievements check, and photo
+      // delete_after scheduling server-side. Reject sets status='rejected'
+      // (final — kid Re-do affordance lands in Batch 4).
+      await Supabase.instance.client.rpc('approve_chore', params: {
+        'p_chore_id': choreId,
+        'p_approved': approved,
+        'p_reason': null,  // Batch 4 adds UI for entering rejection reason
+      });
+
+      // Recurring chores still need next-occurrence creation app-side;
+      // the RPC doesn't do this.
+      if (approved) {
         await _createNextRecurringChoreIfNeeded(chore);
-      } else {
-        // Reject - put chore back to assigned
-        await Supabase.instance.client.from('chores').update({
-          'status': 'assigned',
-          'completed_at': null,
-        }).eq('id', choreId);
       }
 
       _loadData();
     } catch (e) {
+      debugPrint('approve_chore failed: $e');
       if (mounted) {
         ScaffoldMessenger.of(context).showSnackBar(
           SnackBar(content: Text('Could not update chore status: $e')),
         );
       }
     }
   }
```

### Phase 2 — `chore_dashboard_screen.dart` `_completeChore` (kid/adult branch + error fix)

```diff
   Future<void> _completeChore(String choreId) async {
     try {
-      await Supabase.instance.client.from('chores').update({
-        'status': 'pending_verification',
-        'completed_at': DateTime.now().toIso8601String(),
-      }).eq('id', choreId);
+      if (Permissions.isKid(_myMembership)) {
+        // TODO: Batch 4 — migrate kid path to submit_kid_chore_with_photo RPC.
+        // Today this direct UPDATE works because the underlying JWT is the
+        // parent adult's; RLS sees admin role and allows. Batch 4 replaces
+        // this with photo-required completion.
+        await Supabase.instance.client.from('chores').update({
+          'status': 'pending_verification',
+          'completed_at': DateTime.now().toIso8601String(),
+        }).eq('id', choreId);
+      } else {
+        // Adult path: auto-verifies (per spec Q3, no admin step for adults),
+        // points + achievements awarded immediately inside the RPC.
+        await Supabase.instance.client.rpc('complete_chore_self', params: {
+          'p_chore_id': choreId,
+          'p_member_id': _myMembership!['id'],
+        });
+      }
 
       _loadData();
     } catch (e) {
+      debugPrint('complete chore failed: $e');
       if (mounted) {
         ScaffoldMessenger.of(context).showSnackBar(
-          const SnackBar(content: Text('Could not mark chore as complete. Please try again.')),
+          SnackBar(content: Text('Could not mark chore as complete: $e')),
         );
       }
     }
   }
```

The const-SnackBar / generic-text violation from Pass 2 is fixed.

### Phase 3 — `chore_detail_screen.dart` `_quickUpdateStatus` (multi-branch refactor)

```diff
   Future<void> _quickUpdateStatus(String newStatus) async {
     try {
       final previousChore = _chore == null ? null : Map<String, dynamic>.from(_chore!);
-      final updates = <String, dynamic>{'status': newStatus};
-      if (newStatus == 'pending_verification' || newStatus == 'verified') {
-        updates['completed_at'] = DateTime.now().toIso8601String();
-      }
-      await Supabase.instance.client
-          .from('chores')
-          .update(updates)
-          .eq('id', widget.choreId);
+
+      if (newStatus == 'pending_verification') {
+        // Complete chip — branch on kind, same pattern as
+        // chore_dashboard._completeChore (Batch 3 Half B).
+        if (Permissions.isKid(_householdMember)) {
+          // TODO: Batch 4 — migrate kid path to submit_kid_chore_with_photo RPC.
+          await Supabase.instance.client.from('chores').update({
+            'status': 'pending_verification',
+            'completed_at': DateTime.now().toIso8601String(),
+          }).eq('id', widget.choreId);
+        } else {
+          // Adult path: auto-verifies + awards points via the RPC.
+          await Supabase.instance.client.rpc('complete_chore_self', params: {
+            'p_chore_id': widget.choreId,
+            'p_member_id': _householdMember!['id'],
+          });
+        }
+      } else if (newStatus == 'verified') {
+        // Verify chip — admin-only. approve_chore handles status update,
+        // points award (kid/adult branching server-side), achievements,
+        // and photo delete_after scheduling. Also fixes the missing-points
+        // bug noted in the baseline-merge followups for this chip.
+        await Supabase.instance.client.rpc('approve_chore', params: {
+          'p_chore_id': widget.choreId,
+          'p_approved': true,
+          'p_reason': null,
+        });
+      } else {
+        // Start / Skip / Reassign — direct UPDATE (admin-only via RLS).
+        final updates = <String, dynamic>{'status': newStatus};
+        await Supabase.instance.client
+            .from('chores')
+            .update(updates)
+            .eq('id', widget.choreId);
+      }
 
+      // Recurring chores still need next-occurrence creation app-side.
       if ((newStatus == 'pending_verification' || newStatus == 'verified') && previousChore != null) {
         await _createNextRecurringChoreIfNeeded(previousChore);
       }
 
       await _loadData();
 
       if (mounted) {
         ScaffoldMessenger.of(context).showSnackBar(
           SnackBar(content: Text('Status updated to ${_statuses.firstWhere((s) => s['value'] == newStatus, orElse: () => {'label': newStatus})['label']}')),
         );
       }
     } catch (e) {
+      debugPrint('quick status update failed: $e');
       if (mounted) {
         ScaffoldMessenger.of(context).showSnackBar(
           SnackBar(content: Text('Error updating status: $e')),
         );
       }
     }
   }
```

Side effect: the Verify chip now awards points correctly (it didn't before — known bug from baseline-merge followups).

### Phase 4 — `chore_detail_screen.dart` `_saveChore` `canEdit` tighten

```diff
   final isAdmin = Permissions.canEditAnyChore(_householdMember);
-  final isAssignedToMe = _chore?['assigned_to_member_id'] == _householdMember?['id'];
-  final canEdit = isAdmin || isAssignedToMe;
+  // Edit is admin-only per kid-permissions spec (Batch 3 Half B).
+  // Assignee-self-edit was dropped because Batch 2's chores UPDATE RLS
+  // is admin-only; the previous canEdit included the assignee path
+  // which would have failed at runtime with an RLS error.
+  final canEdit = isAdmin;
```

`isAssignedToMe` was only used in `canEdit` (verified via grep), so removed entirely to avoid an unused-local warning.

### Phase 5 — `chore_detail_screen.dart` `'rejected'` status mapping

```diff
   Color _statusColor(String status) {
     return switch (status) {
       'assigned' => AppColors.skyBlue,
       'in_progress' => AppColors.honeyGold,
       'pending_verification' => AppColors.grassGreen,
       'verified' => const Color(0xFF4CAF50),
+      'rejected' => AppColors.coral,
       'skipped' => Colors.grey,
       _ => Colors.grey,
     };
   }

   IconData _statusIcon(String status) {
     return switch (status) {
       'assigned' => Icons.assignment,
       'in_progress' => Icons.pending,
       'pending_verification' => Icons.check_circle,
       'verified' => Icons.verified,
+      'rejected' => Icons.cancel_outlined,
       'skipped' => Icons.skip_next,
       _ => Icons.help,
     };
   }
```

Matches `search_screen.dart:467`'s color choice (`AppColors.coral`). `chore_dashboard_screen.dart` has no centralized status switch (chores render with their own inline styling), so no map there to update.

## Analyzer deltas

| | Total | Errors |
|---|---|---|
| Baseline (pre-edit) | 333 | 1 (pre-existing `MyApp` test) |
| After all 5 edits | 333 | 1 (same) |

Net delta: **0 issues, 0 new errors**. No new imports were needed (both screens already imported `Permissions` from Half A). `debugPrint` is exported by `package:flutter/material.dart` which both screens already import.

## Verification checklist for iPhone testing

Six paths from the investigation, plus the chip-level paths in chore_detail. Test as the Wrights owner first; if you have a non-admin adult test account or a kid switcher path, run those too.

| # | Path | Expected |
|---|---|---|
| 1 | **Adult admin: tap Complete on own chore** (chore dashboard) | Goes straight to `verified` (skips `pending_verification`). Points awarded immediately. Chore disappears from "My Chores" list. If the chore was recurring, next occurrence appears in `assigned`. |
| 2 | **Adult non-admin: tap Complete on own chore** | Same as #1 — now works (was broken by Batch 2's RLS lockdown; this is the fix). |
| 3 | **Kid: tap Complete on own chore** (via active-member switch into kid) | Status moves to `pending_verification`. **Unchanged behavior** — direct UPDATE still used (kid path migrates to `submit_kid_chore_with_photo` in Batch 4). |
| 4 | **Admin: tap Approve on a pending_verification chore** | Status moves to `verified`. Points awarded (kid or adult, branched server-side). Achievements check fires. Recurring chores spawn next occurrence. |
| 5 | **Admin: tap Reject on a pending_verification chore** | Status moves to `'rejected'` (NOT back to `'assigned'`). The chore now displays with coral color + cancel icon. (Re-do affordance is Batch 4 — admin workaround in the meantime: delete and re-create the chore.) |
| 6 | **Admin: tap Approve on an already-verified chore** | SnackBar shows: `Could not update chore status: PostgrestException(message: Chore is not pending verification (current status: verified), …)`. Q4 idempotency raise. |

Additional tests for chore_detail:

| # | Path | Expected |
|---|---|---|
| 7 | **Open a chore detail. Tap the Verify chip on a pending_verification chore (admin)** | Same effect as #4 — points awarded (this previously didn't award points; known baseline-merge bug now fixed). |
| 8 | **Open a chore detail as a non-admin who's the assignee** | No Edit / Delete buttons in the appbar (`canEdit` is now admin-only per Q4). Previously these icons were shown but tapping them would have hit RLS errors. |
| 9 | **Open a chore detail as admin. Tap Start, Skip, or Reassign chips** | Status changes via direct UPDATE (admin path under Batch 2 RLS works). No regression. |

## Known followups (Batch 4 work)

The Batch 4 spec (kid chore-photo flow) now has a clear remaining surface:

1. **Kid path on `_completeChore` and `_quickUpdateStatus`**: replace the TODO'd direct UPDATE with `submit_kid_chore_with_photo` RPC. Wire up camera (`image_picker`), Storage upload to `chore-photos` bucket, and the RPC call. Photo path becomes the kid's required submission flow.
2. **Re-do affordance for rejected chores**: kid (or admin on kid's behalf) taps "Re-do" on a `'rejected'` chore → clears `rejected_reason`, sets status back to `'assigned'`. Today, admin's only workaround is delete + recreate.
3. **Admin reject UI**: text field for entering `p_reason` when rejecting. Today `_verifyChore` and `_quickUpdateStatus` pass `null`.
4. **Photo viewer for admin reviewing a kid submission**: load chore_verification_photos via signed URL from Storage and render in the chore detail screen. RLS already permits household-scoped SELECT.

Plus the pre-existing carry-forwards (out of any current batch):

- `'skipped'` status string in `chore_detail_screen.dart:520` is not in the `chore_status` enum. Will fail at runtime if anyone hits Skip on a chore.
- pg_cron photo cleanup migration still deferred.
- Spec amendment per Batch 1 followup #3.
- An `edit_chore_self(p_chore_id, p_member_id, p_due_at, p_notes)` RPC if assignee-self-edit ever becomes a feature requirement (per Q4 we dropped the affordance for now).
- The 5 display-only role-reads could be centralized into a `RoleDisplay` helper (carried from Half A).

## Git state (uncommitted)

```
$ git status --short
 M apps/mobile/lib/screens/chore_dashboard_screen.dart
 M apps/mobile/lib/screens/chore_detail_screen.dart
?? audits/2026-05-kid-perms-batch-3-half-b-implementation.md
?? audits/2026-05-kid-perms-batch-3-half-b-investigation.md
```

2 modified screens + 2 new audit docs. Branch otherwise clean. Ready for review + iPhone smoke-test, then commit + push with `--set-upstream`.

## Next steps

1. **You review** the diff (`git diff --stat` shows 2 modified files).
2. **Smoke-test on iPhone** — run the 9-item checklist above. Path #5 (the new `'rejected'` rendering) is the most visible UI change; path #2 (non-admin adult complete) is the most important functional fix.
3. **Commit** as one Half B commit on `feat/kid-perms-chore-rpcs-batch-3-half-b-2026-05-22`. Push with `--set-upstream`.
4. **Schedule Batch 4 investigation** when ready — the kid chore-photo flow is the natural next workstream and closes the last remaining direct-UPDATE in the chore surface.
