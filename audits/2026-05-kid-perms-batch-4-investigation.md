# Kid Permissions Batch 4 — Investigation

Date: 2026-05-24
Branch: `feat/kid-perms-batch-4-kid-photo-flow-2026-05-24` (read-only investigation; no edits, no commits)
Base: built on `34d9079` (Half B); Half A + Half B + Batches 1-2 all in tree
Status: investigation complete — **no blockers**; **recommend splitting into 4a + 4b** due to scope

## Summary

Surprisingly good news on infrastructure: **no blockers**. The `chore-photos` Storage bucket exists (created migration 0003 line 35, private 10MB jpeg/png/webp/heic), and Storage policies for household-scoped access are in place. `image_picker: ^1.1.2` is in pubspec + already used in 2 existing screens. An `ImageUploadService` exists at `apps/mobile/lib/services/image_upload_service.dart` but only handles **public** buckets via `getPublicUrl` — needs a new method for **private** chore-photos that returns the storage path instead of a URL.

Six in-scope items break into two natural sub-batches:

- **Batch 4a — kid photo upload path** (items 1, 2). ~200 LOC. Adds private-bucket method to `ImageUploadService`, replaces the kid TODO paths in `_completeChore` and `_quickUpdateStatus` with camera-pick → Storage upload → `submit_kid_chore_with_photo` RPC.
- **Batch 4b — close the loop** (items 3, 4, 5, 6). ~300 LOC. Migration `0019_redo_chore_rpc.sql` + Re-do button + dashboard query broadening for rejected chores + `'rejected'` status mapping in chore_dashboard + admin reject-with-reason text dialog + photo viewer widget.

Splitting is recommended because the two halves are independent — 4a delivers usable kid functionality even before 4b lands (kid can submit; admin can still verify/reject from the existing UI, the only loss is the in-dialog reason field and the kid seeing rejected chores).

Open questions across both halves are at Phase 11. The big ones: reject-reason field UX (required vs optional, multi-line), photo viewer style (thumbnail + tap-modal vs inline), and how to handle a Storage-upload-succeeds-but-RPC-fails race (orphaned file).

## Phase 1 — Scope confirmation

The working tree's spec on this branch is **pre-amendment** (this branch was cut off Half B before the docs amendment commit landed). The current Batch 4 row in the on-branch spec is the single-sentence version. The **amended** 6-item scope from the previous session's docs commit `4d74c87` is:

1. **Original** — kid camera path via `image_picker` + `chore-photos` Storage upload + `submit_kid_chore_with_photo` RPC.
2. **Carry-from-Half-B** — replace the kid TODO'd direct-UPDATE paths in `chore_dashboard_screen.dart:_completeChore` and `chore_detail_screen.dart:_quickUpdateStatus` with the new path.
3. **New** — Re-do affordance for rejected chores (kid taps Re-do, status reverts to `'assigned'`, `chores.rejected_reason` cleared).
4. **New** — `'rejected'` status UI mapping in `chore_dashboard_screen.dart` (Half B added it to chore_detail only).
5. **Original** — admin reject-with-reason text field (Half B passes `p_reason=null`).
6. **Original** — photo viewer for admin reviewing kid submission.

Investigation proceeds against these 6 items.

## Phase 2 — Supabase Storage prerequisites

**No blocker.**

- **Bucket exists** at migration 0003:31-43:
  ```sql
  INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  VALUES (
    'chore-photos',
    'chore-photos',
    false,  -- private; access via signed URLs only
    10485760,  -- 10MB limit
    ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/heic']
  )
  ```
  Private, 10MB cap, common image types. `'image/heic'` is iOS-native, which matters since iPhone is the primary test target.

- **Policies exist** at migration 0003:117-160:
  - SELECT: household members can view photos in their household (path's first folder = household_id).
  - INSERT: household members can upload photos to their household.
  - DELETE: uploader (via `chore_verification_photos.uploaded_by_member_id`) OR household admin.

- **App already uses Storage** via `apps/mobile/lib/services/image_upload_service.dart`. Today's API is public-bucket-only:
  ```dart
  static Future<String?> pickAndUpload({
    required String bucketId,
    required String pathPrefix,
    int maxSizeBytes = 2097152,
    ImageSource source = ImageSource.gallery,
  }) async {
    // ... picks image, uploads, then:
    final publicUrl = _supabase.storage.from(bucketId).getPublicUrl(filePath);
    return publicUrl;  // ← Wrong for private buckets
  }
  ```
  For `chore-photos` we don't want a public URL (it'd 404 anyway since bucket is private). We want to return the **storage path** so we can pass it to `submit_kid_chore_with_photo(p_storage_path)`. Admin viewing later uses `createSignedUrl` to render.

  **Required change in Batch 4a**: add a sibling method to `ImageUploadService`:
  ```dart
  /// Pick and upload to a PRIVATE bucket; returns the storage path
  /// (not a URL — caller uses createSignedUrl when displaying).
  static Future<String?> pickAndUploadPrivate({
    required String bucketId,
    required String pathPrefix,
    int maxSizeBytes = 10485760,
    ImageSource source = ImageSource.gallery,
  }) async {
    // Same picker + upload as pickAndUpload, but return filePath instead of URL
  }
  ```

- **Path convention** per 0003 line 32 comment: `{household_id}/{chore_id}/{filename}`. Storage policies enforce the `{household_id}` first-folder check.

## Phase 3 — image_picker prerequisites

**No blocker.**

- `image_picker: ^1.1.2` in `apps/mobile/pubspec.yaml:21`.
- Already imported in `profile_screen.dart` (avatar upload), `recipe_detail_screen.dart` (recipe photo), and the `image_upload_service.dart` wrapper.
- Existing usage pattern at `image_upload_service.dart:29`:
  ```dart
  final XFile? image = await _imagePicker.pickImage(
    source: source,
    maxWidth: 1024,
    maxHeight: 1024,
    imageQuality: 80,
  );
  ```
  1024x1024 cap + quality 80. Good defaults — typical chore photo would compress to ~100-200KB at this size. No additional processing needed.
- iOS permissions: `NSCameraUsageDescription` and `NSPhotoLibraryUsageDescription` must already be configured (profile_screen uses both via camera path); confirming via `apps/mobile/ios/Runner/Info.plist` is a 1-line verification before Batch 4a code lands.

## Phase 4 — Current TODO paths

### `chore_dashboard_screen.dart:131-160` — `_completeChore`

```dart
Future<void> _completeChore(String choreId) async {
  try {
    if (Permissions.isKid(_myMembership)) {
      // TODO: Batch 4 — migrate kid path to submit_kid_chore_with_photo RPC.
      // Today this direct UPDATE works because the underlying JWT is the
      // parent adult's; RLS sees admin role and allows. Batch 4 replaces
      // this with photo-required completion.
      await Supabase.instance.client.from('chores').update({
        'status': 'pending_verification',
        'completed_at': DateTime.now().toIso8601String(),
      }).eq('id', choreId);
    } else {
      // Adult path: ...
    }
    _loadData();
  } catch (e) {
    debugPrint('complete chore failed: $e');
    // ... non-const SnackBar with $e
  }
}
```

**Replace kid branch** with: camera prompt → upload → RPC call. Pseudocode:
```dart
if (Permissions.isKid(_myMembership)) {
  // 1. Resolve chore to get household_id for the Storage path
  final chore = _myChores.firstWhere((c) => c['id'] == choreId);
  final householdId = chore['household_id'];

  // 2. Pick image (gallery or camera dialog)
  final source = await ImageUploadService.showImageSourceDialog(context);
  if (source == null) return;  // User cancelled
  final imageSource = source == 'camera' ? ImageSource.camera : ImageSource.gallery;

  // 3. Upload to chore-photos bucket; get path back
  final storagePath = await ImageUploadService.pickAndUploadPrivate(
    bucketId: 'chore-photos',
    pathPrefix: '$householdId/$choreId',
    source: imageSource,
  );
  if (storagePath == null) return;  // User cancelled at picker

  // 4. Submit via RPC
  await Supabase.instance.client.rpc('submit_kid_chore_with_photo', params: {
    'p_chore_id': choreId,
    'p_member_id': _myMembership!['id'],
    'p_storage_path': storagePath,
  });
} else {
  // Adult path unchanged
}
```

Error handling: existing `catch (e)` with `debugPrint` + non-const SnackBar with `$e` is correct.

### `chore_detail_screen.dart:884-896` — `_quickUpdateStatus` (kid pending_verification branch)

Same pattern. The kid branch inside the `if (newStatus == 'pending_verification')` block needs the same camera → upload → RPC replacement.

Both sites are nearly identical; consider extracting a `Future<void> _submitKidChoreWithPhoto(choreId, householdId, memberId)` helper somewhere shared (or just inline at both sites; both are 15-20 lines).

## Phase 5 — `submit_kid_chore_with_photo` RPC review

Signature at `0017:306-310`:
```sql
CREATE OR REPLACE FUNCTION public.submit_kid_chore_with_photo(
  p_chore_id     uuid,
  p_member_id    uuid,
  p_storage_path text
) RETURNS uuid
```

Validations (all raise `EXCEPTION` on failure):
- `p_storage_path` non-null + non-empty
- `p_member_id` is active sub_profile (via `is_member_kid`)
- chore exists; loads `household_id, assigned_to_member_id, status`
- kid's `household_id` matches chore's
- calling JWT is in the household (via `is_household_member`)
- chore is assigned to this kid
- status is `'assigned'` or `'in_progress'`

Then atomic:
- `UPDATE chores SET status='pending_verification', completed_at=now()`
- `INSERT INTO chore_verification_photos (chore_id, household_id, uploaded_by_member_id, storage_path)`

Returns new `chore_verification_photos.id`.

**`p_storage_path` confirmation**: per the RPC body line 376 `storage_path = p_storage_path` — it's stored directly as text. Caller should pass the Storage object path (e.g., `7a3f...household-uuid/9c5b...chore-uuid/1716583200000.jpg`), NOT a full URL. The bucket name isn't part of the path — it's implicit (always `chore-photos`).

**Race condition flag**: if Storage upload succeeds but the RPC call fails, the Storage object is orphaned. The 30-day `delete_after` cron (deferred per Batch 1) won't catch orphaned files because there's no `chore_verification_photos` row referencing them. Mitigation options:
- Accept the orphans (small footprint; will get cleaned manually later)
- Wrap upload in a try/catch; on RPC failure, delete the just-uploaded Storage object
- Reorder: insert the DB row first (via a different RPC), upload Storage second, finalize via a third RPC

The third option is overengineered. Recommend **option 2 (delete on RPC failure)** for Batch 4a.

## Phase 6 — Re-do affordance design

**Recommend Option A: new RPC.** Distinct operation, deserves its own RPC for clarity and audit trail. Migration `0019_redo_chore_rpc.sql`.

### Proposed signature

```sql
CREATE OR REPLACE FUNCTION public.redo_chore(
  p_chore_id  uuid,
  p_member_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_household_id       uuid;
  v_assigned_member_id uuid;
  v_current_status     chore_status;
BEGIN
  SELECT household_id, assigned_to_member_id, status
    INTO v_household_id, v_assigned_member_id, v_current_status
    FROM public.chores
   WHERE id = p_chore_id;

  IF v_household_id IS NULL THEN
    RAISE EXCEPTION 'Chore not found';
  END IF;

  IF NOT public.is_member_kid(p_member_id) THEN
    RAISE EXCEPTION 'Only sub_profiles can re-do chores';
  END IF;

  IF NOT public.is_household_member(v_household_id) THEN
    RAISE EXCEPTION 'Caller is not a member of this household';
  END IF;

  IF v_assigned_member_id IS NULL OR v_assigned_member_id <> p_member_id THEN
    RAISE EXCEPTION 'You can only re-do chores assigned to you';
  END IF;

  IF v_current_status <> 'rejected' THEN
    RAISE EXCEPTION 'Chore is not in a rejected state (current status: %)', v_current_status;
  END IF;

  -- Reset status to 'assigned'; clear rejection metadata
  UPDATE public.chores
     SET status = 'assigned',
         rejected_reason = NULL,
         completed_at = NULL,
         verified_at = NULL,
         verified_by_member_id = NULL
   WHERE id = p_chore_id;

  -- Note: prior chore_verification_photos rows are NOT deleted.
  -- They keep delete_after = now() + 30 days from approve_chore's reject path.
  -- The kid will create a new photo when they re-submit.
END;
$$;

REVOKE ALL ON FUNCTION public.redo_chore(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.redo_chore(uuid, uuid) TO authenticated;
```

Apply the 3 Supabase patterns (REVOKE FROM PUBLIC, anon — per `/audits/supabase-patterns-learned.md` pattern 3). pgcrypto not used; `::text` cast not needed.

### Migration positioning

`0019_redo_chore_rpc.sql` — single new function + REVOKE/GRANT. ~70 lines including header comment + verification query. Idempotent via `CREATE OR REPLACE`.

### App-side Re-do button

UI question: where does Re-do appear? Two options:

- **Chore card on the dashboard**: but the dashboard query currently excludes `'rejected'` (filter is `IN ('assigned', 'in_progress')`). Adding `'rejected'` to the query broadens what shows in My Chores — which is also scope item 4.
- **Chore detail screen**: the kid taps the chore (somehow finding the rejected one — via search or notification?). Detail screen shows rejection reason + Re-do button.

**Recommend both**: dashboard shows rejected chores with a "Rejected — tap to redo" badge + button; chore detail shows the rejection reason text + Re-do button. The kid never has to hunt.

This means **scope item 3 implies scope item 4** (broadening dashboard query + UI mapping). They're tightly coupled.

## Phase 7 — chore_dashboard rejected UI mapping

The chore_dashboard doesn't have a centralized status → color/icon map like chore_detail does. The reason: `_myChores` only contains `'assigned'`/`'in_progress'` chores today (per the filter), so chore cards don't need to render status visually.

**For Batch 4 to surface rejected chores**, either:

- **Option A (small)**: Broaden the query to `IN ('assigned', 'in_progress', 'rejected')` and gate the Mark complete button by `isActionable` (already done in the verified-chores-fix branch). Add a small "Rejected" badge + Re-do button on the card when `status='rejected'`. The rest of the card looks the same.
- **Option B (separate section)**: Keep the My Chores query narrow; add a new "Rejected chores" section above or below My Chores; show only rejected chores there with the Re-do button.

Recommend **Option A** — simpler, fewer sections, and the small UI tweak (status-aware rendering on the card) generalizes for future statuses.

The kid sees: "Feed Pets — Rejected" with a red badge and a "Re-do" button. Tap Re-do → confirmation dialog (optional) → call `redo_chore` RPC → list refreshes; chore returns to its normal active state.

Question for user: confirmation dialog before Re-do, or one-tap? Recommend one-tap with an "Undo" snackbar option for 5 seconds (Material design pattern). Out of scope to debate; flag.

## Phase 8 — Admin reject UI design

Currently in `chore_dashboard:_verifyChore` line 207-228 the reject path calls `approve_chore(..., p_approved: false, p_reason: null)`. Same in `chore_detail:_quickUpdateStatus` for the `verified=false` branch (it's actually called via approve_chore when the chip is "Verify" but there's no "Reject" chip there; rejection only happens from the dashboard's Pending Verification section).

**Required for Batch 4b:**

1. **Dialog flow**: when admin taps the Reject button on a pending-verification chore card, show a confirmation dialog with a text input.
   - Dialog title: "Reject this chore?"
   - Subtitle: "Tell {kid name} why" (or "Add a note (optional)" — see open questions)
   - Single `TextField` (or `TextField(maxLines: 3)`) with hint "Reason"
   - 500-char limit (UI counter at the bottom)
   - "Cancel" button (default) + "Reject" button (destructive, red)
2. On Reject: call `approve_chore(p_chore_id, p_approved: false, p_reason: <typed text or null if empty>)`.
3. Error surfacing: same pattern as the rest (catch (e) + debugPrint + non-const SnackBar with `$e`).

**UX questions**:
- Required field, or optional? Recommend **optional** — many rejections are obvious to the kid ("I told you to redo it earlier")
- Single-line vs multi-line? Recommend **multi-line, 3 max** (e.g., "Wait, your room still has clothes on the floor — try again")
- Max length: 500 chars recommended
- Confirmation on empty submit? No — if blank, just proceed
- Reject from chore_detail too? Currently chore_detail has no Reject chip; only chore_dashboard's Pending Verification section. Worth flagging whether to add reject to chore_detail's action chips.

## Phase 9 — Photo viewer design

When admin reviews a chore in `pending_verification` state, they need to see the kid's photo. The photo lives in `chore_verification_photos.storage_path`; bucket is private, so display needs a signed URL.

**Where it appears** (recommend all 3):

1. **Pending Verification card in chore_dashboard**: small thumbnail (60-80px square) on the right side of the card, between the chore title and the Approve/Reject buttons. Tap thumbnail → modal viewer.
2. **chore_detail screen when status=pending_verification or rejected or verified**: a "Submitted photo" section above the action chips, full-width thumbnail (maybe 200px tall), tap to expand.
3. **Modal full-screen viewer**: tap any thumbnail → opens `Hero`-animated full-screen modal with pinch-to-zoom (use `InteractiveViewer`).

**Loading the photo**:
```dart
final signedUrlResponse = await Supabase.instance.client.storage
    .from('chore-photos')
    .createSignedUrl(storagePath, 3600);  // 1 hour
// signedUrlResponse is a String (the URL)
```
Render via `Image.network(signedUrl)`.

**Caching**: `Image.network` caches in memory by default. For the modal viewer it's worth using `cached_network_image` package to also cache on disk — but that's a new dependency. For Batch 4b minimal scope, `Image.network` is fine.

**Multiple photos**: the schema allows multiple `chore_verification_photos` rows per chore. After Batch 4b's Re-do flow, a chore could have multiple photos (one per submission cycle). Viewer should handle a list:
- Card thumbnail: show the most recent only (`ORDER BY created_at DESC LIMIT 1`)
- chore_detail: show all in a horizontal scroll row
- Modal: swipe between photos

For Batch 4b minimal scope, show only the most-recent. Multiple-photo carousel can be a polish followup.

**New widget**: `apps/mobile/lib/widgets/chore_photo_viewer.dart` (~100 lines) with a `ChorePhotoThumbnail` and `ChorePhotoFullScreen` stateless widget pair. Or inline at both sites; the duplication is small.

## Phase 10 — Scope estimate + split recommendation

| Item | Files touched | Net LOC est. | Complexity |
|---|---|---|---|
| **1** kid camera path | `image_upload_service.dart` (+30) | +30 | Low (extends existing service) |
| **2** kid TODO replacement | `chore_dashboard_screen.dart` (+50), `chore_detail_screen.dart` (+50) | +100 | Low-Medium (just call out to new path) |
| **3** Re-do RPC + UI | `supabase/migrations/0019_redo_chore_rpc.sql` (+70), `chore_dashboard_screen.dart` (+40), `chore_detail_screen.dart` (+40) | +150 | Medium |
| **4** dashboard rejected UI | `chore_dashboard_screen.dart` (+30 — query broadening + status badge) | +30 | Low |
| **5** admin reject text dialog | `chore_dashboard_screen.dart` (+50), `chore_detail_screen.dart` (+10 optional Reject chip) | +60 | Medium (new dialog + state) |
| **6** photo viewer | new `chore_photo_viewer.dart` (+100), `chore_dashboard_screen.dart` (+30), `chore_detail_screen.dart` (+30) | +160 | Medium (new widget + signed URL handling) |

**Total: ~530 LOC, 5 files modified + 1 new widget + 1 new migration.**

**Split recommendation:**

- **Batch 4a — kid photo upload** (items 1, 2). ~130 LOC across `image_upload_service.dart` + `chore_dashboard_screen.dart` + `chore_detail_screen.dart`. Migration: none (uses existing `submit_kid_chore_with_photo`). Outcome: kids can submit chores with photos; admins can still verify/reject via the existing UI; the loop has a half-closed UX gap (admin can reject but no reason field, kid can't see rejected chores yet).
- **Batch 4b — close the loop** (items 3, 4, 5, 6). ~400 LOC + migration 0019. Outcome: full kid lifecycle (submit photo → admin reviews with text reason → kid sees rejected with reason → taps Re-do → re-submits with new photo).

**Why split**: 530 LOC in one batch is at the upper edge of what I'd consider safe. The two halves are independent — 4a ships usable kid functionality alone. 4b naturally couples 3/4/5/6 because rejected chores have to be visible (4) before Re-do (3) is useful, and reject reason (5) is what admin writes that the kid reads when deciding to Re-do.

## Phase 11 — Open questions

**Reject UX (Phase 8 details):**
1. **Reject reason — required or optional?** Recommend optional.
2. **Single-line or multi-line text field?** Recommend multi-line, 3 max.
3. **Char limit?** Recommend 500.
4. **Add Reject chip to `chore_detail`?** Currently only `chore_dashboard` has it. Recommend yes — admin reviewing a chore detail should be able to act from there.

**Photo viewer (Phase 9):**
5. **Thumbnail vs inline full-width?** Recommend both (small thumbnail on dashboard cards, inline 200px in chore_detail).
6. **Multiple photos display** (post-Re-do): show most-recent only in Batch 4b; carousel a followup. Confirm.
7. **`cached_network_image` package dep?** Recommend skip for 4b; `Image.network` is fine. Add only if Storage egress becomes a cost concern.
8. **Should the kid see their own submitted photo?** Currently only the admin's view shows it. Recommend yes — show the kid the photo they submitted as confirmation. Add to chore_detail when kid is the assignee.

**Re-do affordance (Phase 6):**
9. **Confirmation dialog before Re-do?** Recommend one-tap with Undo snackbar (Material pattern). Lighter weight.
10. **Re-do button placement**: dashboard card + chore_detail both — confirmed.
11. **Should kid see the admin's rejection reason somewhere prominent?** Recommend yes — render `chores.rejected_reason` on the dashboard card (truncated) AND in chore_detail (full).

**Race condition (Phase 5):**
12. **Storage-upload-succeeds-but-RPC-fails handling?** Recommend option 2 (delete Storage object on RPC failure). Try/catch around the RPC; on catch, delete the just-uploaded file.

**Image processing (Phase 3):**
13. **Existing 1024x1024 / quality 80 sufficient?** Per existing `pickAndUpload` defaults. Yes — typical 1024px image at quality 80 is 100-300KB; well under the 10MB bucket cap. Confirm.

**Recurring chores + photos:**
14. **When admin approves and `_createNextRecurringChoreIfNeeded` creates a new chore row, do photos copy?** No — the new chore has its own id and no photo rows. Photos belong to the original chore. Confirm.

**iOS permissions (Phase 3):**
15. **Confirm `NSCameraUsageDescription` and `NSPhotoLibraryUsageDescription` in `Info.plist`.** Should already be there (profile_screen uses camera). 1-line check before Batch 4a starts.

## Next steps

1. **You answer the 15 open questions** — most have clear recommendations; #1-3 (reject reason UX), #9 (Re-do confirmation), and #12 (orphan-file handling) are the consequential ones.
2. **You approve the 4a/4b split** (or pick a different scope grouping).
3. **I write Batch 4a** — kid photo upload path. ~130 LOC. Analyzer baseline before/after.
4. **Commit + push 4a** with `--set-upstream`. iPhone smoke-test the kid submission flow.
5. **You give the go-ahead for 4b** — Re-do + admin reject UI + photo viewer. ~400 LOC + migration 0019.
6. **Commit + push 4b**. iPhone smoke-test the full loop.

After 4a + 4b ship, Batches 5 (wishlist) + 6 (meal requests) become the natural next workstreams. Pre-existing pg_cron photo cleanup migration is still deferred.

The kid permissions workstream is now ~80% complete by scope: schema + RLS + RPCs (Batches 1-2) + Permissions helper + chore RPC migration (Batches 3a-3b) all shipped. Batch 4 closes the chore loop. Batches 5, 6, 7, 8 are the remaining feature work (wishlist UI, meal requests with push, kind-based UI hardening, music app deep link).
