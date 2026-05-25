# Kid Permissions Batch 4b — Investigation

Date: 2026-05-25
Branch: `feat/kid-perms-batch-4-kid-photo-flow-2026-05-24` (read-only; no code, migrations, or commits)
Base: built on `a496cf4` (spec amendment, photo-optional now canonical). 4a + spec amendment in tree.
Status: investigation complete — **no blockers**; surfaces 11 open questions across 5 in-scope items.

## Summary

Batch 4b closes the kid chore-photo loop with 5 items: (1) Re-do for rejected chores, (2) admin reject-with-reason text dialog, (3) photo viewer widget, (4) dashboard 'rejected' UI mapping, (5) admin delete-photo. Item 5 is new since the original 4-investigation.

Key architectural finding that changes prior design: **`storage.objects` already has a DELETE policy** (migration 0003:144-165) that permits both the uploader and any household admin to delete chore-photo Storage objects via the client SDK. That means **item 5 doesn't strictly require a Storage-side RPC** — admin auth + Storage delete are already permitted by RLS. We can still wrap the row-side delete in an RPC for audit-trail consistency with the other kid-perms RPCs, OR go pure-client. Surfaced as Q3 below.

For item 1 (Re-do), the original Batch 4 investigation's Phase 6 design holds — single new RPC `redo_chore(p_chore_id, p_member_id)`, status flip + clear `rejected_reason` + clear `completed_at`/`verified_at`/`verified_by_member_id`.

Migration plan: **single migration 0020_redo_chore_and_optional_delete_photo.sql** if delete_chore_photo lands as an RPC; **0020_redo_chore.sql alone** if delete is pure-client. Recommend single migration (Q3 + Q9).

**Estimated total scope**: ~400-450 LOC across 1 new migration + 3 modified Dart files + 1 new widget file. Borderline for a single batch — recommend keeping as one 4b, but if user prefers split: 4b-i (Re-do + reject UI + 'rejected' mapping = ~200 LOC) and 4b-ii (photo viewer + delete-photo = ~200 LOC).

11 open questions in Phase 9. The consequential ones: Q3 (RPC vs pure-client for delete-photo), Q5 (reject reason multi-line + 500-char ok), Q7 (multiple photos per chore display), Q9 (single 0020 or two migrations).

## Phase 1 — Scope confirmation

The amended Batch 4 row (spec line 116, verbatim):

> | **4** | Chore submission flow with **optional** photo: kid 3-button choice (Take Photo / Skip / Cancel), conditional storage upload, RPC accepts null path (migration 0019), admin review UI with photo viewer (handles "no photo submitted" state) + reject-with-reason field + Re-do affordance for rejected chores + admin photo-delete button. **Batch 4a ✅ shipped 2026-05-24 (commit ed626bb): photo-optional kid submission + migration 0019.** Batch 4b remaining: Re-do, photo viewer, admin reject UI, dashboard "rejected" mapping, admin delete-photo. | Medium-High | Batches 1+2 (RPCs in place) | `feat/kid-perms-batch-4-kid-photo-flow-2026-05-24` (4a shipped; 4b TBD) |

The 5 in-scope items in the user's brief match the spec exactly. No drift.

Out of scope is confirmed: adult optional photo flow (deferred), pg_cron 30-day cleanup (still deferred), pre-launch legal items (separate workstream at `/audits/2026-05-pre-launch-legal-review-stub.md`), pre-upload content moderation.

## Phase 2 — Migration design

### Two RPCs candidate

| RPC | Purpose | Strictly required? |
|---|---|---|
| `redo_chore(p_chore_id, p_member_id) RETURNS void` | Kid reverts a rejected chore back to 'assigned'; clears rejection metadata | **Yes** — no existing path for this; rejected → assigned is not a valid transition under current RLS UPDATE policies |
| `delete_chore_photo(p_photo_id) RETURNS void` | Admin atomically deletes a photo row + (optionally) Storage object | **Optional** — see Q3; existing RLS already permits both row delete and Storage delete directly via the client SDK |

### redo_chore proposed signature (unchanged from prior investigation Phase 6)

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
  -- 1. Load chore
  SELECT household_id, assigned_to_member_id, status
    INTO v_household_id, v_assigned_member_id, v_current_status
    FROM public.chores
   WHERE id = p_chore_id;

  IF v_household_id IS NULL THEN
    RAISE EXCEPTION 'Chore not found';
  END IF;

  -- 2. Validate kid + household + assignee + status
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
    RAISE EXCEPTION 'Chore is not rejected (current status: %)', v_current_status;
  END IF;

  -- 3. Atomic: reset to 'assigned', clear all rejection/completion metadata.
  --    Prior chore_verification_photos rows are kept for audit; the kid's
  --    next submission will create a new photo row alongside the old one
  --    (Q7 — single vs multiple photo display addressed in viewer).
  UPDATE public.chores
     SET status = 'assigned',
         rejected_reason = NULL,
         completed_at = NULL,
         verified_at = NULL,
         verified_by_member_id = NULL
   WHERE id = p_chore_id;
END;
$$;

REVOKE ALL ON FUNCTION public.redo_chore(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.redo_chore(uuid, uuid) TO authenticated;
```

Patterns applied: SECURITY DEFINER + `SET search_path = public` (1), REVOKE FROM `PUBLIC, anon` then GRANT to `authenticated` (3). No pgcrypto, no `::text` casts needed.

### delete_chore_photo — critical Storage question

**The "IMPORTANT QUESTION" from the brief — answered:**

Postgres RPCs **cannot** call the Supabase Storage HTTP API directly. They CAN execute SQL against the `storage.objects` table because it's just a Postgres table — but Supabase explicitly warns that direct `DELETE FROM storage.objects` doesn't necessarily trigger removal of the underlying file from the S3-compatible backend (file lifecycle is managed by the Storage service, not Postgres). So even if the SQL succeeds, the file may persist.

**The actual answer for our case is simpler**: migration 0003:144-165 already has this Storage DELETE policy:

```sql
CREATE POLICY "Uploader or household admin can delete chore photos"
  ON storage.objects FOR DELETE
  USING (
    bucket_id = 'chore-photos'
    AND (
      EXISTS (
        SELECT 1
        FROM public.chore_verification_photos cvp
        JOIN public.household_members hm ON hm.id = cvp.uploaded_by_member_id
        WHERE cvp.storage_path = storage.objects.name
          AND hm.auth_user_id = auth.uid()
      )
      OR
      (storage.foldername(name))[1] IN (
        SELECT household_id::text
        FROM public.household_members
        WHERE auth_user_id = auth.uid()
          AND is_active = true
          AND role IN ('owner', 'admin')
      )
    )
  );
```

This means **the client can already call `client.storage.from('chore-photos').remove([path])`** from any household admin's session and the RLS layer will permit it. Same for the row delete — migration 0017 has `photos_admin_delete` policy on `chore_verification_photos`. **No new RPC is strictly required.**

Three architectural choices for delete_chore_photo (Q3):

#### Option A — Pure client (no migration)

```dart
Future<void> _deleteChorePhoto(String photoId, String storagePath) async {
  // Confirmation modal first (destructive action)
  final confirmed = await _showDeletePhotoConfirmDialog();
  if (confirmed != true) return;

  try {
    // Row first, Storage second: if row delete fails, we never touched
    // Storage. If Storage delete fails after row delete, we have a Storage
    // orphan — the chore view is correct but the file persists until the
    // pg_cron retention job (deferred) eventually catches it.
    await Supabase.instance.client
        .from('chore_verification_photos')
        .delete()
        .eq('id', photoId);

    try {
      await Supabase.instance.client.storage
          .from('chore-photos')
          .remove([storagePath]);
    } catch (storageError) {
      debugPrint('storage delete failed after row delete (orphan logged): $storageError');
    }

    _loadData();
  } catch (e) {
    debugPrint('delete photo failed: $e');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not delete photo: $e')),
      );
    }
  }
}
```

**Pros:** no migration, smallest scope, fastest to ship, follows the existing pattern in `chore_detail._deleteChore` (direct table delete, no RPC).
**Cons:** no centralized "admin tried to delete" audit point if we want one later; logic split across two table operations + RLS layers.

#### Option B — RPC for row delete; client does Storage delete

```sql
CREATE OR REPLACE FUNCTION public.delete_chore_photo(
  p_photo_id uuid
)
RETURNS text  -- returns the storage_path for the client to remove
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_household_id uuid;
  v_storage_path text;
BEGIN
  SELECT household_id, storage_path
    INTO v_household_id, v_storage_path
    FROM public.chore_verification_photos
   WHERE id = p_photo_id;

  IF v_household_id IS NULL THEN
    RAISE EXCEPTION 'Photo not found';
  END IF;

  IF NOT public.is_household_admin(v_household_id) THEN
    RAISE EXCEPTION 'Only household admins can delete chore photos';
  END IF;

  DELETE FROM public.chore_verification_photos
   WHERE id = p_photo_id;

  RETURN v_storage_path;
END;
$$;

REVOKE ALL ON FUNCTION public.delete_chore_photo(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_chore_photo(uuid) TO authenticated;
```

Client uses the returned path: `final path = await rpc('delete_chore_photo', ...); await client.storage.from('chore-photos').remove([path]);`

**Pros:** centralized admin validation; cleaner error surfacing if not admin; consistent with `approve_chore` / `submit_kid_chore_with_photo` / `redo_chore` pattern; the RPC could later be extended (e.g., to write an audit row).
**Cons:** small added complexity; still requires client to handle Storage delete (no atomicity gain).

#### Option C — Server-side `DELETE FROM storage.objects` inside the RPC

Possible but **NOT recommended.** Supabase docs warn that direct manipulation of `storage.objects` doesn't sync to the underlying file backend. Risk of orphaned files on disk while the row indicates "deleted."

### Recommendation

**Option B** for consistency with the kid-perms RPC pattern. Single migration `0020_redo_chore_and_delete_photo.sql` with both functions, ~140 LOC total. Apply patterns 1 and 3.

If user prefers minimum surface area, Option A is fine — drop delete_chore_photo from the migration, take the row delete + Storage delete directly via client SDK, just like `chore_detail._deleteChore` already does for chore deletion.

### Migration positioning

```
0019_submit_kid_chore_optional_photo.sql   (shipped in 4a)
0020_redo_chore_and_delete_photo.sql       (this batch — Option B)  ← recommended
```

OR

```
0020_redo_chore.sql                        (Option A: no delete_chore_photo migration)
```

OR (Phase 2's Option B from the brief — split migrations)

```
0020_redo_chore.sql
0021_delete_chore_photo.sql
```

Recommend **single 0020** with both RPCs (cleanest pairing) IF delete_chore_photo lives as an RPC.

## Phase 3 — Query broadening for dashboard

### Current state (chore_dashboard_screen.dart:98-105)

```dart
final myChores = await Supabase.instance.client
    .from('chores')
    .select()
    .eq('household_id', householdId)
    .eq('assigned_to_member_id', myMemberId)
    .inFilter('status', ['assigned', 'in_progress'])
    .order('due_at', ascending: true);
```

### Proposed broadening

```dart
final myChores = await Supabase.instance.client
    .from('chores')
    .select()
    .eq('household_id', householdId)
    .eq('assigned_to_member_id', myMemberId)
    .inFilter('status', ['assigned', 'in_progress', 'rejected'])
    .order('due_at', ascending: true);
```

Single status added: `'rejected'`. Order stays by `due_at` ASC — rejected chores will mingle with active ones by their original due date, which is fine UX (kid sees "Feed Pets (rejected) — due today" right alongside other today-due items).

### Privacy note

Kids only see chores **assigned to them** (`assigned_to_member_id = myMemberId`). Admins see all rejected chores via the broader Pending Verification path *if* we choose to surface rejected chores to admins anywhere — but the current Pending Verification section filters strictly on `status='pending_verification'`, not `'rejected'`. Admins viewing chore_detail will see the rejected chore there; that's enough. **No admin-side "Rejected chores" section needed** — admins rejected them; they know they exist; the kid is the one who needs reminded.

Recommend the query change exactly as above.

### Side-effect to be aware of

`_ChoreCard` currently renders Mark Complete via `isActionable = status == 'assigned' || status == 'in_progress'` (line 502). Adding `'rejected'` to the query means `_ChoreCard` will render rejected chores too — and `isActionable` correctly returns false, so Mark Complete is hidden. **But** we need a Re-do button to take its place when `status == 'rejected'`. Tied to Phase 6 below.

## Phase 4 — Reject-with-reason dialog

### Current state

`chore_dashboard_screen.dart:259-288` — `_verifyChore`:

```dart
await Supabase.instance.client.rpc('approve_chore', params: {
  'p_chore_id': choreId,
  'p_approved': approved,
  'p_reason': null,  // Batch 4 adds UI for entering rejection reason
});
```

`approve_chore` (migration 0017:98-198) already accepts `p_reason text DEFAULT NULL` and stores it to `chores.rejected_reason` on the reject path. No migration needed for item 2.

### Proposed dialog (UI-only)

Tap **Reject** on a Pending Verification card → AlertDialog with optional text field → call `approve_chore(p_chore_id, p_approved: false, p_reason: <text or null>)`.

```dart
Future<String?> _showRejectReasonDialog(BuildContext context, String choreName) async {
  final controller = TextEditingController();
  return showDialog<String?>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Reject "$choreName"?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Tell them why (optional):',
              style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          TextField(
            controller: controller,
            maxLines: 3,
            maxLength: 500,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              hintText: 'e.g. "Try again — the room still has clothes on the floor"',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, null),  // sentinel for cancel
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text.trim()),
          style: FilledButton.styleFrom(backgroundColor: AppColors.coral),
          child: const Text('Reject'),
        ),
      ],
    ),
  );
}
```

Then in `_verifyChore`:

```dart
if (!approved) {
  final reason = await _showRejectReasonDialog(context, chore['title']);
  if (reason == null) return;  // user cancelled
  await Supabase.instance.client.rpc('approve_chore', params: {
    'p_chore_id': choreId,
    'p_approved': false,
    'p_reason': reason.isEmpty ? null : reason,
  });
} else {
  await Supabase.instance.client.rpc('approve_chore', params: {
    'p_chore_id': choreId,
    'p_approved': true,
    'p_reason': null,
  });
}
```

### Sentinel pattern

The dialog returns:
- `null` → user cancelled (no submission)
- `''` (empty string) → user pressed Reject with empty field (rejection happens, p_reason stays null)
- `'text'` → rejection with reason

This avoids ambiguity. Convert `''` → `null` before passing to the RPC.

### Same pattern in chore_detail?

The brief's open question: add Reject from chore_detail? Currently chore_detail has no Reject chip (Quick Actions has Verify when status='pending_verification' and admin, but no Reject). Admin can only reject from the chore_dashboard's Pending Verification section. Surfacing as Q6.

Recommend **yes** — admin reviewing a chore in detail (e.g., looking at the photo) should be able to Reject from there too. Add a Reject action chip when `status='pending_verification'` && isAdmin.

## Phase 5 — Photo viewer widget

### New widget — `apps/mobile/lib/widgets/chore_photo_viewer.dart` (~150 LOC)

API outline:

```dart
class ChorePhotoThumbnail extends StatelessWidget {
  final String? storagePath;  // null = no photo submitted
  final double size;           // e.g., 60 for card, 200 for detail
  final VoidCallback? onTap;   // tap → full-screen modal
}

class ChorePhotoFullScreenView extends StatelessWidget {
  final String storagePath;
  final VoidCallback? onDelete; // optional: shows Delete button if non-null
}
```

### Signed URL pattern

Bucket is private (per 0003:35 — `public: false`). Display path:

```dart
Future<String> _signedUrl(String storagePath) async {
  final response = await Supabase.instance.client.storage
      .from('chore-photos')
      .createSignedUrl(storagePath, 3600);  // 1-hour expiry
  return response;  // returns String, not List
}
```

Wrap in a `FutureBuilder<String>` inside the thumbnail. Cache the future for the widget's lifetime to avoid round-trips on rebuild.

### Empty state (4a skip-path)

When the chore has zero `chore_verification_photos` rows (kid chose Skip Photo), render a placeholder instead of an `Image.network`:

```
┌──────────────────────────┐
│         📷               │
│   No photo submitted     │
│   (kid skipped)          │
└──────────────────────────┘
```

`onTap` is disabled (or shows a small toast "No photo to view").

### Loading + error states

```dart
FutureBuilder<String>(
  future: _signedUrlFuture,
  builder: (ctx, snap) {
    if (snap.connectionState == ConnectionState.waiting) {
      return Container(color: Colors.grey.shade100,
        child: const Center(child: CircularProgressIndicator()));
    }
    if (snap.hasError || !snap.hasData) {
      return Container(color: Colors.grey.shade100,
        child: const Center(child: Icon(Icons.broken_image_outlined)));
    }
    return Image.network(snap.data!, fit: BoxFit.cover, ...);
  },
)
```

Surface errors via `debugPrint` inside the FutureBuilder; don't pop a SnackBar (a thumbnail failing isn't worth a user notification — broken-image icon is enough).

### Modal viewer

Tap thumbnail → push a full-screen `Dialog` with `InteractiveViewer` for pinch-to-zoom:

```dart
Navigator.push(context, PageRouteBuilder(
  opaque: false,
  pageBuilder: (_, __, ___) => Dialog(
    backgroundColor: Colors.black,
    child: Stack(
      children: [
        InteractiveViewer(
          minScale: 0.5,
          maxScale: 4.0,
          child: Center(child: Image.network(signedUrl)),
        ),
        Positioned(
          top: 12,
          right: 12,
          child: IconButton.filled(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        if (isAdmin && onDelete != null)
          Positioned(
            bottom: 24,
            left: 24,
            right: 24,
            child: FilledButton.icon(
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete photo'),
              onPressed: onDelete,
              style: FilledButton.styleFrom(backgroundColor: AppColors.coral),
            ),
          ),
      ],
    ),
  ),
));
```

### Where it appears

| Site | Treatment |
|---|---|
| `chore_dashboard` Pending Verification card | Small 60-80px square thumbnail on the right side of the card, between title and Approve/Reject buttons. Tap → modal. Empty state: "No photo" small text instead of camera icon. |
| `chore_detail` view mode | Full-width 200px tall photo above the Quick Actions section. Tap → modal. Visible when status ∈ {pending_verification, rejected, verified}. |

### Multiple photos per chore (post-Re-do)

After 4b ships Re-do, a kid can submit → admin rejects → kid Re-does → kid submits new photo → admin views. The chore now has 2 `chore_verification_photos` rows (the original rejected one with `delete_after = approve_chore_reject_time + 30 days`, and the new one).

**Recommend most-recent-only in 4b** (Q7) — query is `ORDER BY created_at DESC LIMIT 1`. The carousel for all-photos display can ship as a polish followup if user wants the history visible.

The most-recent-only path also avoids a confusing UI where the admin sees an old rejected photo when they're reviewing a freshly-resubmitted chore.

### `cached_network_image` dependency?

Not recommended for 4b (Q8). `Image.network`'s in-memory cache is sufficient; the signed URL has a 1-hour TTL anyway. Only add `cached_network_image` if Storage egress becomes a cost concern.

## Phase 6 — Dashboard 'rejected' UI mapping

### Where status-aware rendering exists today

**`chore_detail_screen.dart`:**
- `_statusColor` (line 307): includes `'rejected' => AppColors.coral` ✅ already maps
- `_statusIcon` (line 319): includes `'rejected' => Icons.cancel_outlined` ✅ already maps
- Quick Actions chips (line 519-528): no current handling for `'rejected'`. Need to add a **Re-do** chip when `status='rejected'` && kid sees own chore. Also surface `rejected_reason` text somewhere in view mode (above Quick Actions, in a coral-tinted callout).

**`chore_dashboard_screen.dart`:**
- No centralized `_statusColor`/`_statusIcon` helpers. `_ChoreCard` (line 487-605) is a `StatelessWidget` that renders the chore with difficulty-based colors, NOT status-based. Status only checked at line 502 (`isActionable`) for the Mark Complete button gating.

### What needs changing in chore_dashboard

For the kid's `_ChoreCard` (the My Chores section) to surface rejected chores:

1. **Add a small status badge** between the chore title row and the room/due row. When `status == 'rejected'`, render a coral chip: `Icon(Icons.cancel_outlined, size:14) + Text('Rejected', color: AppColors.coral)`.
2. **Add a Re-do button** parallel to Mark Complete. Render `FilledButton.icon` with `icon: Icons.refresh_rounded, label: 'Re-do', backgroundColor: AppColors.honeyGold` when `status == 'rejected'`. Hide Mark Complete when status is rejected.
3. **Optional**: surface a truncated `rejected_reason` snippet on the card. E.g., 1 line of italic text below the title: `'Mom: Try again — room still has clothes on the floor'`. Truncate at 80 chars + ellipsis.

Approximately **~30 LOC of card changes** + the query broadening from Phase 3.

The Pending Verification section (admin-side) does NOT need any rejected handling — admins approve/reject, they don't see rejected chores in this section (and that's correct UX).

### What needs changing in chore_detail

1. **Re-do action chip** when `status == 'rejected'` && `Permissions.isKid(_householdMember)` && `_chore['assigned_to_member_id'] == _householdMember['id']`. ~10 LOC inside the Quick Actions wrap (line 515).
2. **Rejection reason callout** above Quick Actions when `status == 'rejected'` && `_chore['rejected_reason'] != null`. Coral-tinted container with the full reason text. ~20 LOC.

Total chore_detail status-aware tweaks: ~30 LOC.

## Phase 7 — Admin delete photo UX

### Where the Delete button lives

Recommend **inside the full-screen photo viewer modal** (per the design in Phase 5):

- Pros: hidden behind a tap on the thumbnail (won't accidentally trigger), large red button at the bottom, modal can show a confirmation before actually deleting
- Cons: small extra step (admin has to tap thumbnail before they can delete)

Alternative: small trash icon on the Pending Verification card next to the thumbnail. Faster but accident-prone. Recommend against.

### Confirmation modal copy

```
Delete this photo?

This will permanently remove the photo from
storage. The chore will still show but with
"No photo submitted" instead.

[Cancel] [Delete]
```

Delete button in coral. Cancel default-styled.

### Delete flow (Option B, recommended; Option A noted)

**Option B flow** (RPC, recommended per Phase 2):

```dart
Future<void> _deleteChorePhoto(String photoId) async {
  final confirmed = await _showDeletePhotoConfirmDialog();
  if (confirmed != true) return;

  try {
    // RPC validates admin + deletes the row + returns storage_path
    final storagePath = await Supabase.instance.client.rpc(
      'delete_chore_photo',
      params: {'p_photo_id': photoId},
    ) as String;

    // Client deletes the Storage object
    try {
      await Supabase.instance.client.storage
          .from('chore-photos')
          .remove([storagePath]);
    } catch (storageError) {
      // Row delete already succeeded; orphan is acceptable
      debugPrint('storage delete failed (orphan logged): $storageError');
    }

    if (mounted) Navigator.pop(context);  // close modal viewer
    _loadData();
  } catch (e) {
    debugPrint('delete photo failed: $e');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not delete photo: $e')),
      );
    }
  }
}
```

**Option A flow** (pure-client, if Q3 picks Option A): identical, but `client.from('chore_verification_photos').delete().eq('id', photoId)` instead of the RPC. Reads `storagePath` from the local data structure that already has it.

### Where the chore appears AFTER delete

The chore row stays; `status` is unchanged (still `pending_verification` or whichever it was). The photo viewer thumbnail switches to the empty state (no row → "No photo submitted"). Admin can still approve/reject the chore based on... well, on what? Without a photo and without admin physically inspecting, this is admin's call. Surface as Q11.

## Phase 8 — Scope estimate + split recommendation

| Item | Files touched | Net LOC est. | Complexity |
|---|---|---|---|
| **1** Re-do | `0020_*.sql` (+70), `chore_dashboard_screen.dart` (+25), `chore_detail_screen.dart` (+15) | +110 | Medium (new RPC + UI in 2 sites) |
| **2** Reject text dialog | `chore_dashboard_screen.dart` (+50), optionally `chore_detail_screen.dart` (+20 Q6) | +50-70 | Low-Medium (new dialog widget + state) |
| **3** Photo viewer widget | new `chore_photo_viewer.dart` (+150), `chore_dashboard_screen.dart` (+30 thumbnail on Pending Verification card), `chore_detail_screen.dart` (+25 inline + integration) | +205 | Medium (new widget, signed URL, FutureBuilder lifecycle) |
| **4** Dashboard 'rejected' UI | `chore_dashboard_screen.dart` (+30 query broadening + badge + reason snippet) | +30 | Low |
| **5** Admin delete photo | `0020_*.sql` (+60 if RPC route) OR 0 LOC migration (Option A), `chore_photo_viewer.dart` (+25 Delete button inside modal), `chore_dashboard_screen.dart` (+25 _deleteChorePhoto handler + dialog), `chore_detail_screen.dart` (+15 wire-up) | +65-125 | Medium |

**Totals:**
- Option B (delete_chore_photo RPC + redo_chore RPC, single migration 0020): **~440 LOC** + 1 migration + 1 new widget.
- Option A (redo_chore RPC only, no delete RPC): **~380 LOC** + 1 migration + 1 new widget.

### Split recommendation

Single 4b is **borderline** — 380-440 LOC is at the upper edge of what fits comfortably in one batch. Two reasonable splits exist:

**Split path A** (recommended if user wants smaller commits):
- **Batch 4b-i** — Re-do + reject reason + 'rejected' UI mapping (items 1, 2, 4). ~210 LOC + migration 0020 (redo_chore only).
- **Batch 4b-ii** — Photo viewer + admin delete-photo (items 3, 5). ~230 LOC + (optional) migration 0021 (delete_chore_photo).

The two halves are independent — 4b-i delivers the rejected-chore UX loop standalone; 4b-ii delivers the photo viewer + delete safety feature.

**Single 4b** (recommended if user wants velocity):
- Ship all 5 items in one batch. ~440 LOC, single migration 0020. iPhone smoke-test covers the full loop.
- The pieces have small natural couplings (the Delete button lives inside the photo viewer; the Re-do button is parallel to the reject-reason path) but they're loose enough to keep together.

Recommend **single 4b** for velocity, with the option to peel off 4b-ii if scope creeps during implementation.

## Phase 9 — Open questions

### Architecture (consequential)

**Q1. Migration count for the two new RPCs.** Single `0020_redo_chore_and_delete_photo.sql` OR `0020_redo_chore.sql` + `0021_delete_chore_photo.sql`. Recommend **single 0020** if delete_chore_photo lives as an RPC.

**Q2. Single-batch 4b or split into 4b-i + 4b-ii?** Recommend **single 4b** for velocity; split is available if scope creeps.

**Q3. delete_chore_photo: RPC (Option B) or pure-client (Option A)?** Existing RLS permits client-side. RPC adds a centralized admin check + extension point for audit logging. Recommend **Option B (RPC)** for consistency with the kid-perms workstream pattern.

### UX (Re-do)

**Q4. Re-do — confirmation modal or one-tap with Undo snackbar?** Recommend **one-tap with 5-second Undo SnackBar** (Material pattern; lighter weight than a modal for a non-destructive state change).

### UX (reject reason)

**Q5. Reject reason field — multi-line (max 3) + 500-char limit ok?** Per brief — confirm.

**Q6. Add Reject chip to chore_detail too?** Currently only chore_dashboard has Reject. Recommend **yes** — admin reviewing a chore via the detail screen (and its photo) should be able to reject from there. Same reason dialog reused.

### UX (photo viewer)

**Q7. Multiple photos per chore (post-Re-do): show most-recent only or all?** Recommend **most-recent only** in 4b; carousel as a polish followup.

**Q8. `cached_network_image` package dependency?** Recommend **skip** for 4b; `Image.network` in-memory cache is sufficient with 1-hour signed URLs.

**Q9. Photo viewer empty state copy.** Brief: "No photo submitted (kid skipped)." Confirm or tweak.

### UX (delete photo)

**Q10. Confirmation modal copy for delete-photo.** Proposed wording above ("Delete this photo? This will permanently remove the photo from storage. The chore will still show but with 'No photo submitted' instead."). Confirm or tweak.

**Q11. After admin deletes a photo, what should the chore look like to admin and kid?** Recommend: chore stays in `pending_verification` (or whatever its status was); thumbnail switches to the empty state; admin can still approve/reject without a photo. No automatic status change on delete.

## Next steps

1. **You answer Q1-Q11.** Q1-Q3 are the architecture choices; Q4-Q11 are UX defaults that I have recommendations for.
2. **You approve single-4b vs split path A**.
3. **I write Batch 4b** — single migration 0020 + the Dart additions + the new `chore_photo_viewer.dart` widget. Analyzer baseline before/after, 0 net new errors expected (likely a couple of new `rpc` inference warnings on the two new RPCs, in line with existing codebase pattern).
4. **Commit + push** with the standard message template.
5. **iPhone smoke-test the full loop**: kid submits with photo → admin sees thumbnail → admin rejects with reason → kid sees rejected card + reason → kid Re-dos → kid submits new photo → admin verifies. Plus: admin deletes a photo → empty state renders → admin can still approve/reject.

After Batch 4b ships, the chore loop is fully closed. Pass 3 remaining work: Batch 5 (wishlist), Batch 6 (meal requests w/ push), Batch 7 (kind-based UI hardening), Batch 8 (music app deep link).

## Note on referenced patterns doc

`/audits/supabase-patterns-learned.md` was referenced in the brief but does not exist at that path. The 3 patterns it presumably documents are observable in migrations 0017 / 0019:
- **Pattern 1**: `SECURITY DEFINER` + `SET search_path = public` on every definer function (0017 lines 76, 105, 220, 312, 414, 533, 612; 0019 line 50-54).
- **Pattern 2**: `extensions.gen_salt`/`extensions.crypt` qualification (Pass 2 PIN work; not relevant to 4b — no pgcrypto used). `::text` casts where needed (also not used in 4b).
- **Pattern 3**: `REVOKE ALL ON FUNCTION ... FROM PUBLIC, anon;` THEN `GRANT EXECUTE ... TO authenticated;` — not just FROM PUBLIC (Supabase grants EXECUTE to anon by default). (0017 lines 719-731; 0019 lines 107-108).

Both `redo_chore` and `delete_chore_photo` (if Option B) apply patterns 1 and 3 in their proposed bodies above.
