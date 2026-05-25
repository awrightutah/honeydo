# Kid Permissions Batch 4b — Implementation Report

Date: 2026-05-25
Branch: `feat/kid-perms-batch-4-kid-photo-flow-2026-05-24`
Status: **changes uncommitted** — user reviews then commits

## Summary

Closes the kid chore-photo loop with all 5 in-scope items: (1) Re-do for rejected chores, (2) admin reject-with-reason text dialog, (3) photo viewer widget, (4) dashboard 'rejected' UI mapping, (5) admin delete-photo (new in 4b). Migration 0020 adds two RPCs: `redo_chore` (status flip back to 'assigned' + clear rejection metadata) and `delete_chore_photo` (admin deletes row, returns storage_path so client can finalize the Storage removal). A new `ChorePhotoThumbnail` widget handles signed URL generation + empty state + tap-to-zoom modal, used on the dashboard Pending Verification cards and on the chore detail view.

All 11 locked decisions implemented as specified.

## Files modified / created

| File | Type | Net LOC | Purpose |
|---|---|---|---|
| `supabase/migrations/0020_redo_chore_and_delete_photo.sql` | **new** | +233 | Both RPCs + REVOKE/GRANT + verification queries |
| `apps/mobile/lib/widgets/chore_photo_viewer.dart` | **new** | +295 | `ChorePhotoThumbnail` + `ChorePhotoFullScreenView` + delete flow |
| `apps/mobile/lib/screens/chore_dashboard_screen.dart` | modified | +163 | Query broadening, _redoChore + _showRejectReasonDialog handlers, _ChoreCard rejected state, _VerificationCard photo thumbnail integration |
| `apps/mobile/lib/screens/chore_detail_screen.dart` | modified | +211 | Photo loading in _loadData, photo section + rejection callout in _buildViewMode, Reject + Re-do chips in Quick Actions, _redoFromDetail + _rejectFromDetail + _showRejectReasonDialog handlers |

## Phase 1 — Migration 0020 structure

**File**: `supabase/migrations/0020_redo_chore_and_delete_photo.sql` (233 lines)

Layout:
- Lines 1-58: Header — references investigation/spec/4a; explains why each RPC exists; explains why we don't `DELETE FROM storage.objects` server-side (Supabase Storage backend doesn't reliably sync to file removal — see Q3 of the investigation).
- Lines 61-130: **Section 1** — `CREATE OR REPLACE FUNCTION public.redo_chore(p_chore_id uuid, p_member_id uuid) RETURNS void`. Six validations (chore exists; member is active sub_profile via `is_member_kid`; household match; calling JWT in household via `is_household_member`; chore assigned to member; current status='rejected'). Atomic UPDATE: status='assigned', clears `rejected_reason`, `completed_at`, `verified_at`, `verified_by_member_id`. `chore_verification_photos` rows untouched (audit trail; their `delete_after` was set by approve_chore's reject path).
- Lines 133-176: **Section 2** — `CREATE OR REPLACE FUNCTION public.delete_chore_photo(p_photo_id uuid) RETURNS text`. Validates photo exists; caller is admin via `is_household_admin`. Deletes the chore_verification_photos row. Returns the `storage_path` so the client can call `storage.from('chore-photos').remove([path])`.
- Lines 179-194: **Section 3** — REVOKE FROM PUBLIC, anon + GRANT EXECUTE TO authenticated for both RPCs. Applies Pattern 3 from `/audits/supabase-patterns-learned.md`.
- Lines 197-233: Verification queries (commented) — function existence + SECURITY DEFINER + pronargs check; `has_function_privilege` matrix for authenticated/anon/service_role; functional smokes for both RPCs (including error-path expectations).

Patterns applied (per `/audits/supabase-patterns-learned.md`):
- **Pattern 1** — `SECURITY DEFINER` + `SET search_path = public` on both functions.
- **Pattern 3** — `REVOKE ALL ... FROM PUBLIC, anon` then `GRANT EXECUTE ... TO authenticated`. (Pattern 2 doesn't apply: no pgcrypto, no `::text` casts.)

## Phase 2 — `chore_photo_viewer.dart` structure

**File**: `apps/mobile/lib/widgets/chore_photo_viewer.dart` (295 lines)

Two public widgets:

### `ChorePhotoThumbnail` (lines 21-184)

- Props: `storagePath` (nullable — null = empty state), `size` (default 64), `photoId`, `canDelete` (default false), `onDeleted` callback.
- State: caches the signed-URL future for the widget's lifetime; re-generates only when `storagePath` changes (so an admin deleting a photo and a new submission landing both refresh cleanly).
- Empty state (storagePath == null): grey rounded container with `Icons.no_photography_outlined` + "No photo submitted" label (label only shown when size ≥ 100).
- Loading state: `CircularProgressIndicator` sized to ~40% of widget size.
- Error state: `Icons.broken_image_outlined` (debugPrint only, no SnackBar — thumbnail failures aren't user-actionable).
- Loaded: `ClipRRect` + `Image.network(signedUrl, fit: BoxFit.cover)`.
- Tap: pushes `ChorePhotoFullScreenView` via `PageRouteBuilder(opaque: false, barrierColor: Colors.black87)`.

### `ChorePhotoFullScreenView` (lines 188-295)

- Props: `storagePath` (required), `photoId`, `canDelete`, `onDeleted`.
- `Scaffold(backgroundColor: Colors.black)` + `Stack` layout.
- `InteractiveViewer(minScale: 0.5, maxScale: 4.0)` wrapping centered `Image.network`.
- Close `IconButton.filled` top-right (respects safe-area top inset).
- Conditional Delete `FilledButton.icon` bottom (respects safe-area bottom inset), `AppColors.coral`, `minimumSize: Size.fromHeight(48)`. Shown only when `canDelete && photoId != null`.
- Delete flow (`_confirmAndDelete`, lines 211-263):
  - Q10 confirmation modal: title "Delete this photo?", body "This can't be undone. The chore will show 'No photo submitted' instead.", Cancel + Delete buttons (Delete in coral).
  - On confirm: call `delete_chore_photo` RPC → returns path → call `storage.from('chore-photos').remove([returnedPath])`. If Storage removal fails after row delete succeeds, log debugPrint (orphan acceptable; row is already gone so UI is correct).
  - On RPC failure: stay in viewer, SnackBar with `$e` interpolation.
  - On success: pop the viewer, call `onDeleted` so the parent reloads.

Signed URL pattern (lines 70-74, 200-202): `Supabase.instance.client.storage.from('chore-photos').createSignedUrl(storagePath, 3600)` — 1-hour TTL.

## Phase 3 — `chore_dashboard_screen.dart` changes

### 3a. Query broadening (lines 102-107)
```dart
.inFilter('status', ['assigned', 'in_progress', 'rejected'])
```
Adds `'rejected'` so kids see rejected chores in their My Chores section with the Re-do affordance.

### 3b. New state field (line 26)
```dart
Map<String, Map<String, dynamic>?> _latestPhotoByChoreId = {};
```
Most-recent photo per pending-verification chore. `null` value = kid skipped (4a Skip Photo branch).

### 3c. Photo side-query in `_loadData` (lines 113-140)
After loading pending-verification chores, fetch `chore_verification_photos` for those chore_ids, ordered by `created_at DESC`. Group by `chore_id`, keep first per group (most-recent). Q7 — most-recent only; carousel deferred.

### 3d. `_verifyChore` reject branch (lines 268-281)
When `approved == false`, opens `_showRejectReasonDialog` first. Cancelled dialog → `return` (no submission). Empty reason → pass `null` to RPC. Otherwise pass the typed text. Approve path unchanged.

### 3e. `_redoChore` method (lines 306-352)
Calls `redo_chore` RPC then reloads. Shows a 5-second SnackBar with an Undo `SnackBarAction` that reverts via direct UPDATE (`status = 'rejected'`). After 5s, the Re-do is final (Q4). Surfacing pattern: try/catch + debugPrint + non-const SnackBar with `$e`.

### 3f. `_showRejectReasonDialog` method (lines 354-393)
AlertDialog with title `Reject "$choreName"?`, multiline TextField (Q5: maxLines:3, maxLength:500), Cancel + Reject buttons (Reject in coral). Returns `null` (cancel), `''` (Reject with empty), or `'text'` (Reject with reason). Caller converts `''` → `null` before passing to `approve_chore`.

### 3g. `_ChoreCard` rejected state (lines 685-732)
- New `onRedo` parameter.
- When `status == 'rejected'`: render a coral "Rejected" badge row (`Icons.cancel_outlined` + "Rejected" text).
- When `rejected_reason` non-empty: italic 1-line snippet `"$rejectedReason"` with ellipsis overflow.
- Action button switches: `isActionable` → Mark complete (existing); `isRejected` → Re-do (`FilledButton.icon(Icons.refresh_rounded, label:'Re-do', AppColors.honeyGold)`).

### 3h. `_VerificationCard` photo integration (lines 821-895)
- New `latestPhoto` + `onPhotoDeleted` parameters.
- Layout reshaped: top row is `Expanded(Column([title+points row, completedBy]))` + `ChorePhotoThumbnail(size:64, canDelete:true, photoId, onDeleted: onPhotoDeleted)` on the right. Empty state renders when `storagePath == null` (kid skipped).
- Tap thumbnail → full-screen with Delete button; on delete → `onPhotoDeleted` → `_loadData()`.

## Phase 4 — `chore_detail_screen.dart` changes

### 4a. State field (line 25)
```dart
Map<String, dynamic>? _latestPhoto;
```

### 4b. Photo load in `_loadData` (lines 156-171)
After comments load, fetch `chore_verification_photos` for this chore, `ORDER BY created_at DESC LIMIT 1`. Try/catch wraps as `null` on error (same pattern as the existing `_activityLog`/`_comments` loads).

### 4c. Submitted photo section in `_buildViewMode` (lines 492-516)
Visible when `status ∈ {pending_verification, verified, rejected}`. Centered `ChorePhotoThumbnail(size:200)` with the most-recent photo. `canDelete: isAdmin` so admin gets the Delete button in the modal. `onDeleted`: `setState(_latestPhoto = null)` + `_loadData()` — thumbnail switches to empty state per Q11.

### 4d. Rejection callout in `_buildViewMode` (lines 518-560)
Visible when `status == 'rejected'`. Coral-bordered Container with `Icons.cancel_outlined` + "Rejected" header + full `rejected_reason` text (or italic "No reason provided" when null/empty).

### 4e. Quick Actions visibility + chips (lines 575-617)
- Wrap visible if `(canEdit && status != 'verified') || (status == 'rejected' && Permissions.isKid(_householdMember) && _chore?['assigned_to_member_id'] == _householdMember?['id'])` — so kids see Quick Actions just for the Re-do entry point on their own rejected chores.
- New chips (4b):
  - **Reject** (`Icons.close_rounded`, coral) — when `status == 'pending_verification' && isAdmin`. Calls `_rejectFromDetail`. Per Q6.
  - **Re-do** (`Icons.refresh_rounded`, honeyGold) — when `status == 'rejected'` && kid is the assignee. Calls `_redoFromDetail`.
- Existing chips (Start/Complete/Verify/Skip/Reassign) are now explicitly gated on `canEdit` so kids visiting a rejected chore see ONLY Re-do (not Skip/Reassign).

### 4f. `_redoFromDetail` (lines 990-1037)
Same shape as dashboard's `_redoChore`. RPC → `_loadData()` → SnackBar with 5s Undo `SnackBarAction` (reverts via direct UPDATE).

### 4g. `_rejectFromDetail` (lines 1040-1063)
Opens `_showRejectReasonDialog`, passes the trimmed reason (or null if empty) to `approve_chore` RPC.

### 4h. `_showRejectReasonDialog` (lines 1067-1106)
Duplicated inline from chore_dashboard (per brief's recommendation: "duplicate inline for now; extract to utility if it grows"). Same body.

## Phase 5 — Status maps confirmation

`_statusColor` (line 307) and `_statusIcon` (line 319) in chore_detail already include `'rejected'` (added in Half B). No change needed.

## Phase 6 — Analyzer deltas

| Scope | Before | After | Net new errors | Net new info/warnings |
|---|---|---|---|---|
| `flutter analyze apps/mobile/` | 335 | 353 | **0** | +18 |

The single `error` in both outputs is the pre-existing `MyApp` issue at `test/widget_test.dart:16:35` (creation_with_non_type) — present in the baseline, unchanged.

**One issue I caught and fixed mid-implementation**: `unawaited_futures` at `chore_detail_screen.dart:1013` (`_loadData()` inside `_redoFromDetail`'s SnackBarAction.onPressed). Fixed by changing to `await _loadData()` (the closure is already `async`). Applied the same fix to chore_dashboard's `_redoChore` for consistency (the analyzer didn't flag that one — apparently a closure-scope inference quirk — but the awaited form is the correct shape).

**All +18 issues are routine codebase-pattern items** (mirroring what `chore_dashboard_screen.dart` and `chore_detail_screen.dart` had before this batch):
- `prefer_const_constructors` / `prefer_const_literals_to_create_immutables` on new Widget constructor calls — ~8 hits.
- `withOpacity` deprecation on new `AppColors.coral.withOpacity(0.08)` / `0.4` usages — ~2 hits.
- `inference_failure_on_function_invocation` on the new `.rpc('redo_chore', ...)`, `.rpc('approve_chore', ...)`, `.rpc('delete_chore_photo', ...)` calls — ~5 hits (matches existing pattern across the codebase per the brief).
- `inference_failure_on_instance_creation` on the new `PageRouteBuilder` and `MaterialPageRoute` in chore_photo_viewer + chore_dashboard — 2 hits.
- 1 misc.

No security-relevant or correctness-relevant warnings.

## Verification checklist for iPhone testing

After applying migration 0020 to Supabase (or local dev DB) and rebuilding:

| # | Path | Expected |
|---|---|---|
| 1 | Kid taps Mark complete → modal → Take Photo → submits | Status → `pending_verification`; admin sees the chore in Pending Verification with the thumbnail rendered |
| 2 | Admin taps thumbnail | Full-screen viewer opens; pinch-to-zoom works; close button returns to dashboard |
| 3 | Admin taps Reject → reason dialog → types text → Reject | Reason dialog appears; on Reject, chore moves to kid's My Chores as rejected with red badge + truncated reason snippet |
| 4 | Kid taps Re-do → SnackBar with Undo within 5s | Status briefly assigned → Undo reverts to rejected; chore is back to rejected state |
| 5 | Kid taps Re-do → waits 5s → submits again with new photo | Re-do final; chore goes 'assigned'; kid submits; admin sees the **most-recent** photo as thumbnail (prior rejected photo not shown — Q7) |
| 6 | Admin verifies the new submission | Status → `verified`; points awarded; chore disappears from Pending Verification |
| 7 | Admin taps thumbnail → Delete photo → confirm | Confirmation modal appears with Q10 copy; on Delete: row gone + Storage object removed; thumbnail switches to "No photo submitted" empty state; chore stays in current status (Q11) |
| 8 | Kid completes a chore with Skip Photo → admin sees empty state | Pending Verification card shows the no-photo placeholder thumbnail; Approve/Reject still work |
| 9 | Same flows from chore_detail | Re-do chip works (kid + rejected); Reject chip works (admin + pending_verification); Submitted photo section renders; rejection callout shows full reason |
| 10 | Verify migration 0020 functional | Run sections A/B/C/D verification queries from the migration file's bottom comment block |

## Known followups (not blocking 4b)

- **Multiple photos carousel**: Q7 picked most-recent only for 4b. If user wants the full history visible (especially post-Re-do showing the rejected photo + new photo), a horizontal carousel inside the full-screen viewer is the natural place. Roughly +60 LOC inside chore_photo_viewer.
- **Audit logging on delete_chore_photo**: extension point reserved in the RPC. If we want a `chore_photo_deletions` table, that's a future migration.
- **Storage orphan tracking**: if the client's `.remove([path])` fails after the row delete succeeds, we log debugPrint but don't queue a retry. The pg_cron 30-day retention job (still deferred) would NOT catch these (no `chore_verification_photos` row to scan). Worth flagging if Storage egress becomes a concern.
- **Spec amendment**: none needed. The spec's amended Batch 4 row already names all 5 items; just the implementation status flips from "remaining" to "shipped" once this commits.
- **Investigation `/audits/2026-05-kid-perms-batch-4-investigation.md`**: Phase 6 originally proposed migration `0019_redo_chore_rpc.sql` (a single function). That slot was used by the photo-optional fix; we landed both new RPCs together in `0020_redo_chore_and_delete_photo.sql`. The investigation reference still works (it's the design rationale; the slot number diverged).
- **Batch 5+ on deck**: wishlist (Batch 5), meal requests w/ push (Batch 6), kind-based UI hardening (Batch 7), music app deep link (Batch 8).

## Next steps for the user

1. Review diffs across the 4 files (1 new migration + 1 new widget + 2 modified screens).
2. Apply migration 0020 to remote Supabase (or local dev DB).
3. Rebuild iOS app on `feat/kid-perms-batch-4-kid-photo-flow-2026-05-24`.
4. Smoke-test the 10 paths above.
5. Commit + push.

After 4b ships, the kid chore-photo loop is fully closed.
