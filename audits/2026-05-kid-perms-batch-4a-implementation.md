# Kid Permissions Batch 4a — Implementation

Date: 2026-05-24
Branch: `feat/kid-perms-batch-4-kid-photo-flow-2026-05-24` (working-tree only; no commits)
Scope: kid chore-photo upload path — new `pickAndUploadPrivate` helper + replace 2 kid TODO branches
Status: code complete — **not committed**

## Summary

Batch 4a done. Kids can now submit chores with a required photo via the camera. The kid TODO branches in `_completeChore` (chore_dashboard) and `_quickUpdateStatus` (chore_detail) are replaced with a camera-pick → private-bucket upload → `submit_kid_chore_with_photo` RPC pipeline. On RPC failure the orphaned Storage file is removed before the error surfaces to the user.

Analyzer: **333 → 335** (+2 info warnings on the 2 new `submit_kid_chore_with_photo` RPC calls — consistent with the established codebase pattern; 12+ pre-existing identical warnings on other RPC calls, none of which the codebase annotates). **0 new errors.** Half B's pattern of leaving `.rpc()` calls unannotated is preserved.

Batch 4b (Re-do RPC + Re-do button + dashboard rejected UI + admin reject-with-reason dialog + photo viewer) is the natural next step. Until 4b lands, the admin still uses the existing Half B reject path (which passes `p_reason: null` and shows nothing to the kid about the rejection).

## Files modified

| File | Sites | Change |
|---|---|---|
| `apps/mobile/lib/services/image_upload_service.dart` | +57 LOC | New `pickAndUploadPrivate` static method as sibling to existing `pickAndUpload`. Returns storage path (not URL) since the chore-photos bucket is private. |
| `apps/mobile/lib/screens/chore_dashboard_screen.dart` | +43 / −5 LOC | Added imports (`image_picker`, `image_upload_service`). Replaced kid branch of `_completeChore` with the camera+upload+RPC pipeline. |
| `apps/mobile/lib/screens/chore_detail_screen.dart` | +37 / −4 LOC | Same imports added. Replaced kid branch of `_quickUpdateStatus` (the `pending_verification` target) with the same pipeline. |

Net: ~130 LOC across 3 files. No new files. No migration changes. No other Dart touched.

## Per-phase diffs

### Phase 1 — `image_upload_service.dart` new method (~line 67)

Added between existing `pickAndUpload` and `uploadAvatar`:

```dart
/// Pick an image and upload to a PRIVATE Supabase Storage bucket.
/// Returns the storage path (not a public URL — the bucket is private,
/// so callers must use `createSignedUrl` later when displaying the image).
///
/// Use this for private buckets like `chore-photos`. For public buckets
/// (avatars, recipe images), use [pickAndUpload] instead — that helper
/// returns a public URL ready for `Image.network`.
///
/// The full storage object key is `$pathPrefix/${timestamp_ms}.jpg`.
/// The first folder of `pathPrefix` should be the household_id so the
/// chore-photos bucket's RLS policy (which checks
/// `(storage.foldername(name))[1]`) can match.
///
/// On RPC failure after the upload succeeded, the caller is expected
/// to clean up via `Supabase.instance.client.storage.from(bucketId).remove([path])`
/// — this method does not retain enough state to do that cleanup itself.
///
/// Throws on upload failure (no swallow). Returns null if the user
/// cancelled the picker.
static Future<String?> pickAndUploadPrivate({
  required String bucketId,
  required String pathPrefix,
  ImageSource source = ImageSource.camera,
  int maxWidth = 1024,
  int maxHeight = 1024,
  int imageQuality = 80,
}) async {
  final XFile? image = await _imagePicker.pickImage(
    source: source,
    maxWidth: maxWidth.toDouble(),
    maxHeight: maxHeight.toDouble(),
    imageQuality: imageQuality,
  );

  if (image == null) return null; // User cancelled

  final bytes = await image.readAsBytes();
  final fileName = '${DateTime.now().millisecondsSinceEpoch}.jpg';
  final storagePath = '$pathPrefix/$fileName';

  await _supabase.storage.from(bucketId).uploadBinary(
    storagePath,
    bytes,
    fileOptions: const FileOptions(
      contentType: 'image/jpeg',
      upsert: false,
    ),
  );

  return storagePath;
}
```

`upsert: false` chosen intentionally — each chore photo gets a unique timestamp-based filename, so we want collisions to fail loud rather than silently overwrite. Per Q13, defaults match existing `pickAndUpload`: maxWidth/maxHeight 1024, quality 80.

### Phase 2 — `chore_dashboard_screen.dart`

Imports (lines 1-9):
```diff
 import 'package:flutter/material.dart';
 import 'package:supabase_flutter/supabase_flutter.dart';
+import 'package:image_picker/image_picker.dart';
 import '../theme/app_theme.dart';
 import '../services/realtime_service.dart';
 import '../services/active_member_service.dart';
+import '../services/image_upload_service.dart';
 import '../utils/permissions.dart';
 import 'chore_detail_screen.dart';
```

`_completeChore` kid branch (around line 133):
```diff
       if (Permissions.isKid(_myMembership)) {
-        // TODO: Batch 4 — migrate kid path to submit_kid_chore_with_photo RPC.
-        // Today this direct UPDATE works because the underlying JWT is the
-        // parent adult's; RLS sees admin role and allows. Batch 4 replaces
-        // this with photo-required completion.
-        await Supabase.instance.client.from('chores').update({
-          'status': 'pending_verification',
-          'completed_at': DateTime.now().toIso8601String(),
-        }).eq('id', choreId);
+        // Kid path: camera → upload to private chore-photos bucket →
+        // submit_kid_chore_with_photo RPC (atomic status update + photo row).
+        // On RPC failure, the just-uploaded Storage object is removed so we
+        // don't leave orphans (the 30-day cleanup cron from Batch 1 — still
+        // deferred — only catches files referenced by chore_verification_photos).
+        final chore = _myChores.firstWhere(
+          (c) => c['id'] == choreId,
+          orElse: () => <String, dynamic>{},
+        );
+        if (chore.isEmpty) {
+          throw Exception('Chore not found in local cache');
+        }
+        final householdId = chore['household_id'];
+        final memberId = _myMembership!['id'];
+
+        final storagePath = await ImageUploadService.pickAndUploadPrivate(
+          bucketId: 'chore-photos',
+          pathPrefix: '$householdId/$choreId',
+          source: ImageSource.camera,
+        );
+        if (storagePath == null) {
+          // User cancelled the camera; bail without error or status change.
+          return;
+        }
+
+        try {
+          await Supabase.instance.client.rpc('submit_kid_chore_with_photo', params: {
+            'p_chore_id': choreId,
+            'p_member_id': memberId,
+            'p_storage_path': storagePath,
+          });
+        } catch (rpcError) {
+          // RPC rejected — clean up the orphaned Storage file, then
+          // rethrow so the outer catch surfaces the real cause to the kid.
+          try {
+            await Supabase.instance.client.storage
+                .from('chore-photos')
+                .remove([storagePath]);
+          } catch (cleanupError) {
+            debugPrint('storage cleanup failed (continuing): $cleanupError');
+          }
+          rethrow;
+        }
       } else {
```

Adult branch unchanged (still calls `complete_chore_self` per Half B). Outer try/catch with `debugPrint('complete chore failed: $e')` + non-const SnackBar with `$e` interpolation is unchanged.

### Phase 3 — `chore_detail_screen.dart`

Same imports added at top. Same pipeline inside `_quickUpdateStatus` kid branch (around line 884). Difference from chore_dashboard: uses `_chore['household_id']` instead of `_myChores.firstWhere(...)` (chore_detail already has the full chore loaded via `_chore`). The `widget.choreId` is used instead of a local `choreId` parameter.

Adult `complete_chore_self` and admin `approve_chore` branches both unchanged.

## Analyzer deltas

| | Total | Errors | Notes |
|---|---|---|---|
| Baseline | 333 | 1 (`MyApp` test — pre-existing) | — |
| After all edits | 335 | 1 (same) | +2 info-level `inference_failure_on_function_invocation` warnings on the 2 new `submit_kid_chore_with_photo` `.rpc()` calls |

Net delta: **+2 info warnings, 0 new errors**.

Both new warnings match the pre-existing codebase pattern — 12+ existing `.rpc()` calls (e.g., `award_points_to_member`, `check_and_award_achievements`, `complete_chore_self`, `approve_chore`, `get_leaderboard`) all trigger the same inference warning. The codebase convention is to leave `.rpc()` calls unannotated; annotating just these two would be inconsistent. Carried forward as a separate cleanup pass if ever needed (e.g., `.rpc<void>(...)` would silence them).

## Verification checklist for iPhone

1. **Kid Mark complete (happy path)** — adult signs in, switches to kid via profile switcher, opens Chores tab, finds an `'assigned'` chore in My Chores, taps Mark complete.
   - iOS one-time camera permission prompt (if first run since the iOS Info.plist permissions fix landed)
   - Camera opens
   - Take a photo (or Retake then Use Photo)
   - Photo uploads (brief delay; ~100-300KB at quality 80)
   - `submit_kid_chore_with_photo` RPC fires → chore status → `'pending_verification'` server-side
   - Realtime listener bumps `choresVersion` → dashboard refreshes → chore disappears from My Chores (the dashboard query filters to `IN ('assigned', 'in_progress')`)

2. **Kid Mark complete via chore detail screen** — same chore tapped into detail, then tap the Complete chip. Same outcome as #1 from a different entry point.

3. **Cancel the camera** — tap Mark complete, then tap Cancel on the camera or back-button out. Expected: function returns silently, no SnackBar, no status change, no Storage upload. Verified via the `if (storagePath == null) return;` guard.

4. **RPC rejection cleanup** — hard to trigger naturally since validation passes for a normal kid completing an assigned chore. Forced scenarios:
   - Admin marks the chore `verified` from another device between camera-pick and RPC-call: the RPC raises "Chore is not in a submittable state". Expected: orphaned Storage file is `remove()`d, kid sees a SnackBar with the actual exception text via debugPrint + the outer catch.
   - Network blip during RPC call: similar cleanup path.

5. **Admin approves the kid's submission** — admin signs in, sees the chore in Pending Verification, taps Approve. Existing `approve_chore` RPC from Half B fires; status → `'verified'`, points awarded to the kid via `award_points_to_member` (server-side branching). Photo's `delete_after` set to `now() + 30 days` by `approve_chore`. **Note: photo viewer not in scope for 4a** — admin sees the chore card but no thumbnail. Batch 4b adds that.

6. **Admin rejects the kid's submission** — same screen, tap Reject. Existing `approve_chore` RPC from Half B fires with `p_approved=false, p_reason=null` (Half B passes null since admin reject UI isn't in until 4b). Status → `'rejected'`. **Note: kid currently has NO UI to see this** — rejected chores are excluded from My Chores' status filter. Batch 4b broadens the query and adds the Re-do button.

## Known followups (Batch 4b scope, all pending)

1. **`redo_chore` RPC + migration `0019_redo_chore_rpc.sql`** — kid taps Re-do, status reverts to `'assigned'`, `rejected_reason` cleared.
2. **Re-do button on rejected chore cards** in both chore_dashboard (dashboard My Chores section, after broadening the query to include `'rejected'`) and chore_detail.
3. **`'rejected'` status UI mapping in chore_dashboard** — query broadening to include `'rejected'`, status badge ("Rejected" pill, coral background) on chore cards.
4. **Admin reject-with-reason text dialog** — multi-line text field, optional, max ~500 chars, populates `p_reason` on the existing `approve_chore` reject call.
5. **Photo viewer widget** — `chore_photo_viewer.dart` with thumbnail + tap-to-modal `InteractiveViewer`. Used in chore_dashboard Pending Verification cards and chore_detail above the action chips. Loads via `createSignedUrl(storagePath, 3600)`.
6. **Optional: also add Reject chip to chore_detail action chips** — currently only chore_dashboard has the Reject affordance.

Pre-existing carry-forwards (out of Batch 4 scope):
- pg_cron 30-day photo cleanup migration (still deferred — needs pg_cron enabled + Storage cleanup design).
- `'skipped'` status string at `chore_detail_screen.dart:520` not in the `chore_status` enum.

## Git state (uncommitted)

```
$ git status --short
 M apps/mobile/lib/screens/chore_dashboard_screen.dart
 M apps/mobile/lib/screens/chore_detail_screen.dart
 M apps/mobile/lib/services/image_upload_service.dart
?? audits/2026-05-kid-perms-batch-4-investigation.md
?? audits/2026-05-kid-perms-batch-4a-implementation.md
```

3 modified files + 2 new audit docs (investigation from earlier + this implementation report). Branch otherwise clean. Ready for review + iPhone smoke-test, then commit + push with `--set-upstream`.

## Next steps

1. **You review** the diff (`git diff --stat` shows 3 modified files + the line shifts).
2. **iPhone smoke-test** — run the 6-item checklist above. Path #1 is the critical happy path.
3. **Commit** Batch 4a as a single commit on `feat/kid-perms-batch-4-kid-photo-flow-2026-05-24`. Push with `--set-upstream`.
4. **Schedule Batch 4b** — Re-do RPC + Re-do button + dashboard rejected UI + admin reject dialog + photo viewer.

After 4b lands, the kid chore loop is fully closed: submit → review (with photo) → approve OR reject (with reason) → kid sees rejection + can Re-do.
