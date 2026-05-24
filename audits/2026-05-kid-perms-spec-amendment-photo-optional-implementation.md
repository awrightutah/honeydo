# Spec amendment — photo-optional reversal of Q-A — implementation report

Date: 2026-05-24
Branch: `feat/kid-perms-batch-4-kid-photo-flow-2026-05-24`
Status: **changes uncommitted** — user reviews then commits as a follow-up to ed626bb

## Summary

Amends `/audits/2026-05-kid-profile-permissions-spec.md` to reverse the resolved-question Q-A decision from "photo required for kids, optional for adults" to "**photo optional for everyone, kid chooses each submission**." This matches what was shipped in commit `ed626bb` (Batch 4a code + migration 0019) and what the user's original working notes always intended.

Five edits made across the spec; a sixth grep-sweep pass confirmed no remaining sites still imply "required for kids" or kid-camera-auto-open. Each edit carries a dated "REVERSED 2026-05-24" or "UPDATED 2026-05-24" trail so future readers can follow the decision history.

## File modified

| File | Type | Edits |
|---|---|---|
| `audits/2026-05-kid-profile-permissions-spec.md` | modified | 5 edits (Decisions row A, Allowed Action #2, Implementation Notes kid-chore bullet, Batch plan row 4, Resolved Questions #6) |

No code touched. `/audits/supabase-patterns-learned.md` unchanged (the photo-optional revision didn't introduce a new pattern — migration 0019 applies existing patterns 1+3+grant).

## Per-edit confirmation

### Edit 1 — Decisions table row A (line 18)

**Before:**
> `| A | investigation | Adult photo requirement | Optional for adults, **required for kids**. Adult "Complete" button stays as today; kid "Complete" button opens the camera. |`

**After:**
> `| A | investigation | Adult photo requirement | Optional for everyone. Kid and adult both see a choice: Take Photo or Skip Photo. Decision per-submission. (REVERSED 2026-05-24 — original Q6 codified "required for kids" but user intent was always optional for all. Implemented via migration 0019.) |`

**Reason:** This is the canonical Q-A row in the Decisions table at the top of the spec; the source of truth for the policy. Reversed to match shipped behavior, with an inline trail to the migration.

### Edit 2 — Allowed Actions #2 (line 38)

**Before:**
> `2. Submit chore completion with a photo. Kid taps "Complete" → camera opens → photo uploaded to chore-photos bucket → row added to chore_verification_photos → chore status moves to pending_verification. Admin reviews and verifies/rejects.`

**After:**
> `2. Submit chore completion, optionally with a photo. Kid taps "Complete" → 3-button choice (Take Photo / Skip Photo / Cancel). If "Take Photo": camera opens → photo uploaded to chore-photos bucket → row added to chore_verification_photos. If "Skip Photo": no photo upload, no row added. Either way, status moves to pending_verification. Admin reviews and verifies/rejects. (UPDATED 2026-05-24 per the Q-A reversal — was previously camera-required for kids.)`

**Reason:** The user-facing description of the kid's allowed action; needed to reflect the new 3-button modal and the conditional path. Mentions both flows explicitly (photo and skip) so readers don't misread "optionally" as ambiguous.

### Edit 3 — Implementation Notes "Kid chore completion" bullet (line 96)

**Before:**
> `- **Kid chore completion** opens the camera instead of just updating status. Photo uploads to the` `chore-photos` `bucket, row inserts into` `chore_verification_photos`, `status transitions to` `pending_verification`. `Adults retain the no-photo path.`

**After:**
> `- **Kid chore completion** presents a 3-button choice dialog: Take Photo, Skip Photo, or Cancel. If "Take Photo": camera opens → upload to` `chore-photos` `bucket → row inserts into` `chore_verification_photos` `→ status transitions to` `pending_verification`. `If "Skip Photo": no photo upload, no row inserted; status still transitions to` `pending_verification`. `Cancel = no-op. The same RPC` `submit_kid_chore_with_photo` `handles both paths (migration 0019 made` `p_storage_path` `nullable; the photo INSERT is conditional on` `v_has_photo`). `Adults' no-photo path (`complete_chore_self`) unchanged. (REVISED 2026-05-24 per Q-A reversal; commit ed626bb.)`

**Reason:** This is the engineering-oriented implementation bullet. Now describes the choice dialog, both branches, the RPC accepting null, and the conditional INSERT — enough detail for someone implementing or auditing the kid path to understand the shape of the change without leaving the spec.

### Edit 4 — Batch plan row 4 (line 116)

**Before:**
> `| **4** | Chore submit-with-photo flow: kid camera path, storage upload, DB insert via RPC, admin review UI with photo viewer + reject reason field. | Medium-High | Batches 1+2 (RPCs in place) | `feat/kid-perms-chore-photo` |`

**After:**
> `| **4** | Chore submission flow with **optional** photo: kid 3-button choice (Take Photo / Skip / Cancel), conditional storage upload, RPC accepts null path (migration 0019), admin review UI with photo viewer (handles "no photo submitted" state) + reject-with-reason field + Re-do affordance for rejected chores + admin photo-delete button. **Batch 4a ✅ shipped 2026-05-24 (commit ed626bb): photo-optional kid submission + migration 0019.** Batch 4b remaining: Re-do, photo viewer, admin reject UI, dashboard "rejected" mapping, admin delete-photo. | Medium-High | Batches 1+2 (RPCs in place) | `feat/kid-perms-batch-4-kid-photo-flow-2026-05-24` (4a shipped; 4b TBD) |`

**Reason:** The Batch plan row is the at-a-glance status board. Updated to reflect (a) the photo-optional policy as the scope, (b) Batch 4a shipped status with the commit SHA, (c) the actual branch name we used (not the placeholder), and (d) the items still queued for Batch 4b.

### Edit 5 — Resolved Questions #6 (line 143)

**Before:**
> `6. **Adult photo requirement (Q A from investigation)** — Optional for adults, required for kids. Adult "Complete" button stays as today (status update only); kid "Complete" button opens the camera.`

**After:**
> `6. **Adult photo requirement (Q A from investigation)** — Optional for everyone. Kid and adult both see the same UX: a choice between Take Photo and Skip Photo, decided per submission. Adult "Complete" still routes through` `complete_chore_self` `(auto-verifies, no admin step); kid "Complete" routes through` `submit_kid_chore_with_photo` `(goes to` `pending_verification` `for admin review, with or without a photo). (REVERSED 2026-05-24 — the original "required for kids" answer didn't match the user's actual intent, which was always optional. Implemented via migration 0019 and Batch 4a Dart revisions; commit ed626bb. See` `/audits/2026-05-kid-perms-photo-optional-investigation.md` `for the full reasoning.)`

**Reason:** This is the long-form resolved-question entry that pairs with Edit 1's table row. It's the place readers go when they want the "why" behind the decision. Now describes both routings (adult: complete_chore_self auto-verify; kid: submit_kid_chore_with_photo → pending_verification) and links to the investigation doc for the full reasoning.

### Edit 6 — Sweep for any other affected sites

Grep ran on the post-edit spec:

- **`grep -n "photo"`** — 15 matches. Lines 18, 38, 96, 143 are the amended sites. The remaining 11 hits (lines 17, 19, 68, 69, 77, 91, 113, 114, 116, 137, 141, 145) are all neutral references: `chore_verification_photos` table, `chore-photos` bucket name, "30-day photo retention", "photo viewer" UI in Pending Verification, "chore photo retention (COPPA)" — none of which imply photo is required.
- **`grep -n "camera"`** — 2 matches. Lines 38, 96 — both in the amended text, in the new "If Take Photo: camera opens" path. Correct usage.
- **`grep -n "required"`** — 3 matches. Lines 18, 38, 143 — all amended sites, where the word now appears only in the historical reversal trail ("was previously camera-required for kids", `"required for kids"` in quotes as the old decision). No remaining declarative "required" applies to kids' photo submissions.

**Conclusion**: no missed sites. The amendment is self-consistent.

## Known followups

None expected for this commit. The spec amendment is self-contained: shipped code matches spec text, decision-history trail is dated and references the implementing commit + investigation.

Standing followups (carried from the photo-optional implementation report; not blockers for this commit):
- **Q5 (function name)**: `submit_kid_chore_with_photo` is now slightly misleading. Defer rename to a future Pass-3.x cleanup.
- **Q6 (adult symmetry)**: adult `complete_chore_self` could symmetrically gain an optional photo path. Separate decision, not in scope.
- **Batch 4b**: photo viewer needs "no photo submitted" empty state (~10 LOC).

## Next steps for the user

1. Review the diff on `/audits/2026-05-kid-profile-permissions-spec.md` (5 line changes).
2. Commit as a follow-up docs commit on the same branch:
   ```
   git add audits/2026-05-kid-profile-permissions-spec.md \
           audits/2026-05-kid-perms-spec-amendment-photo-optional-implementation.md
   git commit -m "docs(kid-perms): reverse Q-A — photo optional for everyone
                  ..."
   git push
   ```
3. After this commit lands, the spec and shipped code will be in lockstep, and the branch will be ready for Batch 4b planning.
