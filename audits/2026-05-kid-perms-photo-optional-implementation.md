# Kid permissions — photo-optional revision (Batch 4a) — implementation report

Date: 2026-05-24
Branch: `feat/kid-perms-batch-4-kid-photo-flow-2026-05-24`
Status: **changes uncommitted** — user reviews then commits

## Summary

Implements the photo-optional revision to Batch 4a per the locked decisions in `/audits/2026-05-kid-perms-photo-optional-investigation.md`:

- **RPC (Option A)**: new migration `0019_submit_kid_chore_optional_photo.sql` CREATE-OR-REPLACEs `submit_kid_chore_with_photo` to accept a nullable `p_storage_path`. The "Photo storage path is required" early raise from 0017 is gone; the `chore_verification_photos` INSERT is now inside `IF v_has_photo THEN ... END IF`. Function name preserved (acceptable wart per investigation Q5).
- **UI (Option 1)**: new `showPhotoChoiceDialog` static on `ImageUploadService` — AlertDialog with `📷 Take Photo` (bolded) / `✏️ Skip Photo` / `Cancel`. Symmetric tap counts.
- **4a Dart (Option 2)**: kid branches in `chore_dashboard_screen.dart` (`_completeChore`) and `chore_detail_screen.dart` (`_quickUpdateStatus`) modified in place. `pickAndUploadPrivate`, imports, cleanup-on-failure pattern preserved. Storage path is now nullable; cleanup only fires when a path was actually uploaded.
- **Spec amendment**: deferred to a follow-up commit on this same branch (per Q4).

Net additions: **1 new migration + 1 new method on ImageUploadService + 2 kid-branch revisions**.

## Files modified

| File | Type | Net LOC change |
|---|---|---|
| `supabase/migrations/0019_submit_kid_chore_optional_photo.sql` | **new** | +160 |
| `apps/mobile/lib/services/image_upload_service.dart` | modified | +39 (new `showPhotoChoiceDialog`) |
| `apps/mobile/lib/screens/chore_dashboard_screen.dart` | modified | +21 (kid branch revision in `_completeChore`) |
| `apps/mobile/lib/screens/chore_detail_screen.dart` | modified | +21 (kid branch revision in `_quickUpdateStatus`) |

The two screen edits replace existing camera-first code with the new choice-first flow. Comments updated to reference migration 0019.

## Phase 1 — Migration 0019

**File**: `supabase/migrations/0019_submit_kid_chore_optional_photo.sql` (160 lines)

**Structure**:
- Lines 1-35: Header block — explains it's a behavior change to an existing RPC; references investigation + spec amendment; lists what changed vs 0017 Section 4.
- Lines 38-103: **SECTION 1** — `CREATE OR REPLACE FUNCTION public.submit_kid_chore_with_photo(...)`.
- Lines 106-110: **SECTION 2** — re-stated `REVOKE FROM PUBLIC, anon` + `GRANT EXECUTE TO authenticated`.
- Lines 113-160: **VERIFICATION QUERIES** — A) function exists + SECURITY DEFINER, B) `p_storage_path` has default (proves nullability via `pronargdefaults`), C) `has_function_privilege` for authenticated/anon/service_role, D) functional smoke (photo + photo-less), E) confirm 0017's raise is gone (empty-string call must succeed).

**What changed vs 0017 Section 4** (lines 306-387 of `0017_kid_perms_rls_rpcs.sql`):

```diff
 CREATE OR REPLACE FUNCTION public.submit_kid_chore_with_photo(
   p_chore_id     uuid,
   p_member_id    uuid,
-  p_storage_path text
+  p_storage_path text DEFAULT NULL
 )
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public
 AS $$
 DECLARE
   v_household_id       uuid;
   v_assigned_member_id uuid;
   v_current_status     chore_status;
   v_kid_household_id   uuid;
   v_new_photo_id       uuid;
+  v_has_photo          boolean;
 BEGIN
-  -- 1. Validate inputs
-  IF p_storage_path IS NULL OR length(p_storage_path) = 0 THEN
-    RAISE EXCEPTION 'Photo storage path is required';
-  END IF;
+  -- 1. Compute photo presence (no longer required, just informational)
+  v_has_photo := p_storage_path IS NOT NULL AND length(p_storage_path) > 0;

   -- 2. Member must be an active sub_profile
   IF NOT public.is_member_kid(p_member_id) THEN
-    RAISE EXCEPTION 'Only sub_profiles can submit chores with photos';
+    RAISE EXCEPTION 'Only sub_profiles can submit chores via this RPC';
   END IF;

   -- ... (validation 3-6 unchanged: household match, JWT in household,
   --      assignee match, status in ['assigned','in_progress']) ...

   -- 7. Atomic: update chore + conditionally insert photo row
   UPDATE public.chores
      SET status = 'pending_verification',
          completed_at = now()
    WHERE id = p_chore_id;

-  INSERT INTO public.chore_verification_photos (
-    chore_id, household_id, uploaded_by_member_id, storage_path
-  ) VALUES (
-    p_chore_id, v_household_id, p_member_id, p_storage_path
-  )
-  RETURNING id INTO v_new_photo_id;
+  IF v_has_photo THEN
+    INSERT INTO public.chore_verification_photos (
+      chore_id, household_id, uploaded_by_member_id, storage_path
+    ) VALUES (
+      p_chore_id, v_household_id, p_member_id, p_storage_path
+    )
+    RETURNING id INTO v_new_photo_id;
+  END IF;

-  RETURN v_new_photo_id;
+  RETURN v_new_photo_id;  -- NULL when no photo was submitted
 END;
 $$;

 REVOKE ALL ON FUNCTION public.submit_kid_chore_with_photo(uuid, uuid, text) FROM PUBLIC, anon;
 GRANT EXECUTE ON FUNCTION public.submit_kid_chore_with_photo(uuid, uuid, text) TO authenticated;
```

Also tweaked the kid-membership raise message from "submit chores with photos" → "submit chores via this RPC" since the RPC no longer requires a photo.

**Supabase patterns observed** (per `/audits/supabase-patterns-learned.md`):
- `SECURITY DEFINER` + `SET search_path = public` (pattern 1).
- `REVOKE ALL FROM PUBLIC, anon` not just `PUBLIC` (pattern 3 — Supabase grants EXECUTE to anon by default).
- `GRANT EXECUTE TO authenticated` only.
- All raises use `RAISE EXCEPTION` (consistent with 0017).

## Phase 2 — `showPhotoChoiceDialog` on `ImageUploadService`

**File**: `apps/mobile/lib/services/image_upload_service.dart`, +39 LOC, inserted directly above `showImageSourceDialog`.

```dart
/// Show a 3-button modal asking the user to choose between taking a photo,
/// skipping the photo, or cancelling entirely. Used by the kid chore-
/// completion flow (Batch 4a revised) where photo evidence is optional.
///
/// Returns:
///   'photo' — user wants to take a photo
///   'skip'  — user wants to submit without a photo
///   null    — user cancelled (no submission should occur)
///
/// Symmetric tap counts: 2 to photo (this dialog + camera), 2 to skip
/// (this dialog + nothing else), 1 to cancel.
static Future<String?> showPhotoChoiceDialog(
  BuildContext context, {
  String title = 'Submit chore as complete?',
}) async {
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: const Text('Would you like to include a photo?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, 'photo'),
          child: const Text(
            '📷  Take Photo',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, 'skip'),
          child: const Text('✏️  Skip Photo'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, null),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
}
```

**Styling rationale**: AlertDialog actions slot expects TextButton (Material spec). The codebase's other AlertDialog patterns — e.g., `_deleteChore` at `chore_detail_screen.dart:220-240` — use TextButton + ElevatedButton mix only for *destructive* paths (delete chore). For this non-destructive choice modal, three TextButtons with bold weight on the recommended action match the platform default and avoid mixed-style buttons inside actions.

## Phase 3 — `chore_dashboard_screen.dart` kid branch

**File**: `apps/mobile/lib/screens/chore_dashboard_screen.dart`, lines ~135-184 (was ~135-178; +21 LOC after edit).

**Flow** (replaces previous camera-first flow):

1. Look up chore from `_myChores` local cache → extract `household_id`.
2. `final choice = await ImageUploadService.showPhotoChoiceDialog(context);`
3. If `choice == null` → `return` (cancel).
4. If `choice == 'photo'` → call `pickAndUploadPrivate(...)`. If that returns null (user cancelled camera) → `return`. Otherwise `storagePath` is set.
5. If `choice == 'skip'` → `storagePath` stays `null`.
6. Call `submit_kid_chore_with_photo` RPC with `'p_storage_path': storagePath` (nullable).
7. On RPC failure: clean up Storage only if `storagePath != null`. Then `rethrow`.

The adult branch (`complete_chore_self`) is unchanged. The outer `catch (e)` + `debugPrint` + non-const SnackBar with `$e` interpolation remains intact.

## Phase 4 — `chore_detail_screen.dart` kid branch

**File**: `apps/mobile/lib/screens/chore_detail_screen.dart`, lines ~886-940 (+21 LOC after edit).

Identical pattern to Phase 3, with these differences:
- Uses `_chore!['household_id']` (already loaded into state).
- Uses `widget.choreId` instead of the parameter `choreId`.
- Uses `_householdMember` instead of `_myMembership`.

`null` check on `_chore` preserved as the existing "Chore not loaded" guard. Outer try/catch with `debugPrint('quick status update failed: $e')` + SnackBar unchanged.

## Phase 5 — Analyzer deltas

| Scope | Before | After | Delta |
|---|---|---|---|
| `flutter analyze apps/mobile/` | 335 issues | 335 issues | **0 net new** |
| Touched-files scoped | n/a | 31 issues | all pre-existing |

**The one pre-existing `error`** (`The name 'MyApp' isn't a class • test/widget_test.dart:16:35`) is unrelated to this work and present in the baseline.

**Touched-files breakdown** (all pre-existing patterns; same count as before edits):
- `withOpacity` deprecations on `chore_detail_screen.dart` (6) — pre-existing styling.
- `value` form-field deprecations in dropdowns (5) — pre-existing.
- `inference_failure_on_function_invocation` on `rpc` calls (3 in chore_detail) — known existing Supabase SDK type-inference pattern.
- `dart:io` unused import on `image_upload_service.dart` — pre-existing (was already in the file before our Phase 2 addition).
- `prefer_const_constructors` (1) — pre-existing.
- `unused_local_variable 'user'` in `_addComment` — pre-existing.

**No new lint** introduced by `showPhotoChoiceDialog(context)` calls because both call sites have the dialog as the *first* `await` in their respective methods, so the `use_build_context_synchronously` lint does not apply.

## iPhone smoke-test checklist (5 paths)

Run after applying migration 0019 (push to remote Supabase or run via SQL editor) and rebuilding the iOS app.

| # | Path | Expected outcome |
|---|---|---|
| 1 | Kid taps Mark complete → modal → **Take Photo** → camera → photo → upload → RPC | Status flips `assigned` → `pending_verification`; new `chore_verification_photos` row with `storage_path`; chore appears in admin Pending Verification list with photo. |
| 2 | Kid taps Mark complete → modal → **Skip Photo** → RPC with null path | Status flips `assigned` → `pending_verification`; **no** new `chore_verification_photos` row; chore appears in admin Pending Verification list with "No photo submitted" (handled in Batch 4b photo viewer). |
| 3 | Kid taps Mark complete → modal → **Cancel** | No submission; chore stays `assigned`; no Storage write; no RPC call. |
| 4 | Kid taps Mark complete → modal → **Take Photo** → cancels camera | No submission; chore stays `assigned`; no RPC call. (To re-try, kid taps Mark complete again — gets a fresh choice modal.) |
| 5 | Admin verifies a photo-less submission (from path 2) | Status `pending_verification` → `verified`; points awarded to kid; `approve_chore`'s `UPDATE chore_verification_photos SET delete_after = ...` is a no-op (zero matching rows; Postgres handles gracefully — confirmed in investigation Q7). |

**Run both screens** (chore_dashboard's _ChoreCard "Mark complete" button AND chore_detail's "Complete" action chip) since the same flow exists in both — verify both produce the same UX.

**iOS prereq**: This branch requires the camera + photo library `Info.plist` keys from `fix/ios-image-picker-permissions-2026-05-24` to be merged or stacked. Without them, paths 1 and 4 will crash on iOS pre-permission grant.

## Known followups

### For the spec amendment commit (next on this branch)

Per Q4, the spec edits land in a separate follow-up commit. Files/locations to amend:

| File | Line(s) | Change |
|---|---|---|
| `/audits/2026-05-kid-profile-permissions-spec.md` | 18 (Q-A row) | "Optional for adults, **required for kids**" → "Optional for everyone; kid chooses each submission." |
| `/audits/2026-05-kid-profile-permissions-spec.md` | 38 (Allowed Action #2) | Rewrite "camera opens → photo uploaded" to "choose Take Photo or Skip → photo (if any) uploaded → row added (if photo)." |
| `/audits/2026-05-kid-profile-permissions-spec.md` | 96 (Implementation Notes "Kid chore completion") | Rewrite to describe the optional path. |
| `/audits/2026-05-kid-profile-permissions-spec.md` | 116 (Batch plan row 4) | Mention photo-optional UI explicitly. |
| `/audits/2026-05-kid-profile-permissions-spec.md` | 143 (Resolved Questions #6) | Mirror line-18 update. |
| `/audits/2026-05-kid-profile-permissions-spec.md` | "Kid chore completion (Batch 3 Half B + Batch 4)" sub-bullets | "opens the camera" → "kid chooses Take Photo or Skip." |

Plus a small implementation report: `/audits/2026-05-kid-perms-spec-amendment-photo-optional.md`.

### For Batch 4b

Per investigation Phase 6: the photo viewer widget must handle "no photo submitted" gracefully. ~10 LOC empty-state placeholder when `chore_verification_photos` has zero rows for the chore. Everything else in Batch 4b (Re-do, admin reject UI, rejected dashboard mapping) is unaffected.

### Flagged for later (not now)

- **Q5 (function name)**: `submit_kid_chore_with_photo` is now slightly misleading ("with_photo" but optional). Defer rename to a Pass-3.x cleanup pass; cost of breaking the RPC contract today is higher than the naming benefit.
- **Q6 (adult symmetry)**: `complete_chore_self` could also gain an optional photo path for full UX symmetry. Out of scope here — adults currently auto-verify without photo storage at all; that's a separate behavior change.
- **Q7 (approve_chore no-op)**: confirmed in investigation — Postgres `UPDATE` with zero matching rows is a no-op, so `approve_chore`'s photo-cleanup-scheduling step is safe for photo-less submissions. No code change needed.

## What was NOT touched

- Spec file (per Q4 — separate commit).
- Adult path `complete_chore_self` RPC + adult Dart branches.
- Any Batch 4b items (Re-do, photo viewer, admin reject UI).
- Other RPCs (Options B and C rejected).
- Function name `submit_kid_chore_with_photo` (Option C rejected).
- ImageUploadService's existing `pickAndUpload`, `pickAndUploadPrivate`, `uploadAvatar`, `uploadRecipeImage`, `deleteImage`, `showImageSourceDialog` — all unchanged.

## Next steps for the user

1. Review the diffs in:
   - `supabase/migrations/0019_submit_kid_chore_optional_photo.sql`
   - `apps/mobile/lib/services/image_upload_service.dart`
   - `apps/mobile/lib/screens/chore_dashboard_screen.dart`
   - `apps/mobile/lib/screens/chore_detail_screen.dart`
2. Apply migration 0019 to remote Supabase (or local dev DB).
3. Rebuild iOS app on `feat/kid-perms-batch-4-kid-photo-flow-2026-05-24` (assuming iOS Info.plist permissions branch is stacked or merged).
4. Smoke-test the 5 paths above.
5. Commit the four files as one Batch 4a (revised) commit.
6. Author the spec amendment as a follow-up docs commit on the same branch.
