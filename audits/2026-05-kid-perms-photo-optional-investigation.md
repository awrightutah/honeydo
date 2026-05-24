# Kid permissions — photo-optional discovery investigation

Date: 2026-05-24
Branch: `feat/kid-perms-batch-4-kid-photo-flow-2026-05-24` (read-only investigation; no edits, no commits)
Status: investigation complete — **4 decisions needed before code lands**

## Summary

During Batch 4a iPhone smoke-testing, the user surfaced that the kid chore-photo policy as written in the spec (Q6/A: "required for kids, optional for adults") doesn't match the user's actual intent: **photo is optional for everyone; the kid decides each submission.** This is documented in pre-spec working notes but the formal spec amendment locked in the wrong default.

The discovery affects three layers, in order of impact:

1. **Migration 0017's `submit_kid_chore_with_photo` RPC** — currently raises if `p_storage_path` is null/empty. Needs to accept no-photo submissions.
2. **Batch 4a's just-implemented Dart** — currently opens the camera automatically and treats cancel as a silent no-op. Needs a choice flow (take photo OR skip) and a way to call the RPC without a photo.
3. **The spec's Q6/A decision + several supporting bullets** — currently codify "required for kids."

Batch 4b's planned scope (Re-do, photo viewer, admin reject UI, dashboard rejected UI) is **mostly unaffected**; only the photo viewer needs to handle the "no photo submitted" case.

**Recommended path** (all decisions justified in phases 2-5 below):
- **RPC Option A**: `CREATE OR REPLACE` the existing function in migration 0019; remove the null-path raise; conditionally INSERT only when a path is provided.
- **UI Option 1**: upfront 3-button modal — `Take Photo` / `Skip Photo` / `Cancel`.
- **4a handling Option 2**: modify the uncommitted 4a Dart in place; `pickAndUploadPrivate` is universally useful and stays.
- **Spec amendment** in a follow-up docs commit on this same branch (after the code lands), so the spec change trails the code 1:1.

Estimated total scope at the recommended path: ~150 LOC net (migration 0019 + Dart kid-branch revision + spec amendment).

## Phase 1 — Discovery confirmation

### Current spec Q6/A (line 18 + line 143)

> | A | investigation | Adult photo requirement | Optional for adults, **required for kids**. Adult "Complete" button stays as today; kid "Complete" button opens the camera. |
>
> **6. Adult photo requirement (Q A from investigation)** — Optional for adults, required for kids. Adult "Complete" button stays as today (status update only); kid "Complete" button opens the camera.

### Original kid-permissions investigation, Phase 6 / Q-A

The very investigation that surfaced Q-A explicitly flagged the ambiguity (`/audits/2026-05-kid-permissions-investigation.md:378`):

> A. Does the spec apply photo-requirement to adults as well, or kids only? (Adults today don't submit photos.)

And the Phase 2 capability table at line 164 said:

> Plus gating — adults can still submit without photo (spec is ambiguous about this; see open question).

So the question was open going into the resolved-questions pass. The eventual resolution (Q-A) picked "required for kids, optional for adults" but the user's actual intent was the symmetric option (optional for both). The spec amendment locked in the wrong default.

### What Q6/A should become

Proposed replacement text:

> **Photo is optional for every submission, regardless of member kind.** Kids and adults both see the same flow: tap Complete → choose Take Photo or Skip Photo. The kid's choice happens per-submission (not a global preference). Skipping just submits the status change without a photo row.

This makes adult and kid completion paths converge UX-wise. Server-side they still differ (adults via `complete_chore_self` auto-verifies; kids via `submit_kid_chore_with_photo` goes to `pending_verification` for admin review) — but the photo choice is parallel.

## Phase 2 — RPC change options (A / B / C)

### Current state — migration 0017:323-326

```sql
-- 1. Validate inputs
IF p_storage_path IS NULL OR length(p_storage_path) = 0 THEN
  RAISE EXCEPTION 'Photo storage path is required';
END IF;
```

Plus the body unconditionally inserts a `chore_verification_photos` row referencing `p_storage_path`.

### Option A — `CREATE OR REPLACE` in migration 0019 (recommended)

```sql
-- 0019_submit_kid_chore_optional_photo.sql
CREATE OR REPLACE FUNCTION public.submit_kid_chore_with_photo(
  p_chore_id     uuid,
  p_member_id    uuid,
  p_storage_path text DEFAULT NULL  -- now optional
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  -- ... same vars ...
  v_has_photo boolean;
BEGIN
  -- Removed: the "Photo storage path is required" early raise.
  v_has_photo := p_storage_path IS NOT NULL AND length(p_storage_path) > 0;

  -- All other validations (is_member_kid, household check, assignee check,
  -- status check) unchanged.

  -- ... unchanged validation block ...

  -- 7. Atomic: update chore + optionally insert photo row
  UPDATE public.chores
     SET status = 'pending_verification',
         completed_at = now()
   WHERE id = p_chore_id;

  IF v_has_photo THEN
    INSERT INTO public.chore_verification_photos (
      chore_id, household_id, uploaded_by_member_id, storage_path
    ) VALUES (p_chore_id, v_household_id, p_member_id, p_storage_path)
    RETURNING id INTO v_new_photo_id;
  END IF;

  RETURN v_new_photo_id;  -- NULL when no photo was submitted
END;
$$;

-- Re-state grants (idempotent; matches Supabase patterns 0017/0018 pattern)
REVOKE ALL ON FUNCTION public.submit_kid_chore_with_photo(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.submit_kid_chore_with_photo(uuid, uuid, text) TO authenticated;
```

**Pros:**
- Single RPC; no surface-area growth
- Migration 0019 is small (~30 LOC including header + grants)
- Existing app callers still work (path is just optional now)
- Per `/audits/supabase-patterns-learned.md` pattern 3: REVOKE FROM PUBLIC, anon (not just PUBLIC) is re-stated

**Cons:**
- Function name now slightly misleading: "submit_kid_chore_**with_photo**" but accepts no photo. Wart but acceptable; the function still ships the photo path correctly when one is provided.

### Option B — Add a separate `submit_kid_chore` RPC

Keep `submit_kid_chore_with_photo` exactly as-is; add a sibling `submit_kid_chore(p_chore_id, p_member_id)` that does the status update without a photo row.

**Pros:**
- Clear naming (each function does exactly what its name says)
- No behavior change to the existing RPC

**Cons:**
- Two RPCs to maintain with nearly-identical validation logic (member kind, household match, assignee match, status check)
- Two grants to keep in sync (REVOKE/GRANT for both)
- App layer must branch: photo present → `_with_photo` RPC; no photo → no-photo RPC
- Doubles the test surface

### Option C — Rename to `submit_kid_chore` (drop the suffix)

Migration 0019 `DROP FUNCTION submit_kid_chore_with_photo(uuid, uuid, text)` + `CREATE FUNCTION submit_kid_chore(uuid, uuid, text DEFAULT NULL)`.

**Pros:**
- Cleanest naming long-term

**Cons:**
- Breaking change to a recently-shipped RPC contract
- We just landed `submit_kid_chore_with_photo` in migration 0017 (committed Batch 2). Renaming undoes our own work
- Any external integration (none today, but principle) breaks
- App callers in 4a must rename too

### Recommendation: Option A

Option A wins on engineering economy. The naming wart is real but small; the alternative (B) doubles surface area, and the alternative (C) is invasive renaming for a marginal improvement.

If naming bothers us long-term, capture as a future cleanup: rename to `submit_kid_chore` in a Pass-3.x or post-feature-freeze tidy pass when the cost of breaking the RPC contract is lower.

## Phase 3 — UI flow options (1 / 2 / 3)

### Current Batch 4a UI

Kid taps Mark complete → camera opens immediately → take photo OR cancel (cancel = silent return; chore stays `'assigned'`).

### UI Option 1 — Upfront choice modal (recommended)

```
[Mark Complete] tap
       ↓
┌──────────────────────────────────────┐
│ Submit "Feed Pets" as complete?      │
│                                      │
│   📷  Take Photo                     │
│   ✏️  Skip Photo                     │
│       Cancel                         │
└──────────────────────────────────────┘
```

- "Take Photo" → camera → upload → RPC with `p_storage_path`
- "Skip Photo" → RPC with `p_storage_path: null`
- "Cancel" → return; no change

**Pros:**
- Explicit choice; kid knows exactly what's happening
- Symmetric tap counts (2 for photo, 2 for skip, 1 for cancel)
- Discoverability: kid sees both options first time and learns the affordance
- No overloaded interactions (cancel always means cancel)

**Cons:**
- One extra tap compared to today's 4a camera-first flow for the photo case

### UI Option 2 — Camera first, skip fallback on cancel

```
[Mark Complete] tap
       ↓
Camera opens
       ↓
   Take photo OR Cancel
       ↓ (if cancel)
┌──────────────────────────────────────┐
│ Mark "Feed Pets" complete without    │
│ a photo?                             │
│                                      │
│   No, take a photo                   │
│   Yes, skip photo                    │
└──────────────────────────────────────┘
```

**Pros:**
- Photo case is one tap (just tap Mark complete and shoot)
- Skip case is two taps

**Cons:**
- Overloads the camera Cancel button (sometimes means "back out", sometimes means "skip photo")
- Confusing if the kid cancels the camera because they wanted to back out entirely
- A second dialog after a cancel feels intrusive

### UI Option 3 — Separate Photo + Complete buttons

Each kid chore card has an `[Add Photo]` icon and a `[Mark Complete]` button.

**Pros:**
- Separates concerns clearly

**Cons:**
- More controls per card (visual clutter, harder for kids to parse)
- Two-tap flow even for the photo case (add photo first, then complete)
- Photo lifecycle confusion (kid adds photo, doesn't complete — orphan)
- Not recommended for kid UX

### Recommendation: UI Option 1

Option 1 is the cleanest for kid UX. Two taps for both paths means the kid doesn't feel one path is preferred over the other (which matches the new "optional for everyone" intent). Cancel is unambiguous.

Implementation: a new method on `ImageUploadService` (or inline at both call sites) — `showPhotoChoiceDialog(BuildContext) → Future<String?>` returning `'photo'`, `'skip'`, or `null` for cancel. Reusable by both `chore_dashboard` and `chore_detail`.

## Phase 4 — Spec amendment scope

Spec edits needed:

1. **Decisions table row A** (line 18): rewrite "Optional for adults, required for kids" → "Optional for everyone; kid chooses each submission."
2. **Resolved Questions #6** (line 143): mirror update.
3. **Allowed Actions #2** (line 38): "Submit chore completion with a photo. Kid taps 'Complete' → camera opens → photo uploaded..." → "Submit chore completion, optionally with a photo. Kid taps Complete → choose Take Photo or Skip → photo (if any) uploaded to chore-photos bucket → row added (if photo) → status moves to pending_verification."
4. **Implementation Notes "Kid chore completion" bullet** (line 96): rewrite to describe the optional path.
5. **Batch plan row 4** (line 116): mention the photo-optional UI explicitly.
6. **Implementation Notes "Kid chore completion (Batch 3 Half B + Batch 4)" sub-bullets** (the rewritten section in the amended spec): the kid sub-bullet describes "opens the camera" — needs to become "kid chooses Take Photo or Skip."

Approximately 6 spec edits. Estimated 30-40 lines net change.

Plus a new `/audits/2026-05-kid-perms-spec-amendment-photo-optional.md` implementation report.

The previous big spec amendment commit (`4d74c87` on `docs/kid-perms-spec-amendment-2026-05-24`) sets the pattern for how to structure these. This one is much smaller.

## Phase 5 — Uncommitted Batch 4a handling

### Current uncommitted state

```
 M apps/mobile/lib/screens/chore_dashboard_screen.dart   (kid branch in _completeChore)
 M apps/mobile/lib/screens/chore_detail_screen.dart      (kid branch in _quickUpdateStatus)
 M apps/mobile/lib/services/image_upload_service.dart    (new pickAndUploadPrivate)
?? audits/2026-05-kid-perms-batch-4-investigation.md
?? audits/2026-05-kid-perms-batch-4a-implementation.md
```

### Option 1 — Discard 4a entirely (`git reset --hard`)

Throw away the 130 LOC and start over. **Not recommended.** `pickAndUploadPrivate`, the cleanup-on-failure pattern, and the import changes are correct regardless of the photo-optional policy.

### Option 2 — Modify in place (recommended)

Keep:
- ✅ `pickAndUploadPrivate` in ImageUploadService (universally useful; no changes needed)
- ✅ The two new imports in chore_dashboard + chore_detail (still needed)
- ✅ The cleanup-on-RPC-failure pattern (still correct — only fires when storagePath is non-null)

Modify:
- 🔧 Kid branch in both screens: add a choice dialog step before the camera; make `storagePath` nullable; only attempt cleanup if `storagePath != null`
- 🔧 Pass `p_storage_path: storagePath` (which may be null) to the RPC

Net edits: ~40-60 LOC across the two kid branches (most code stays).

### Option 3 — Commit 4a as-is, ship optional as a 4a-followup

Commit the photo-required Dart now, then ship optional as a separate 4a-followup commit. **Not recommended** — the photo-required intermediate state is wrong per the new policy, and we'd be shipping a known-incorrect default to the iPhone for no benefit.

### Recommendation: Option 2

Modify in place. The uncommitted 4a is salvageable; revising it is cheaper than rebuilding.

## Phase 6 — Batch 4b impact

Cross-checking each Batch 4b scope item against photo-optional:

| Item | Photo-optional impact |
|---|---|
| `redo_chore` RPC (migration 0019) | **None.** Reverts status from `'rejected'` to `'assigned'`; doesn't touch photos. (Note: if migration 0019 becomes the photo-optional fix, the Re-do RPC moves to 0020. Or both can live in 0019.) |
| Re-do button on rejected chore cards | **None.** Kid sees rejection regardless of whether they submitted with photo. |
| Dashboard query broadening to include `'rejected'` | **None.** |
| `'rejected'` UI mapping in chore_dashboard | **None.** |
| Admin reject-with-reason text dialog | **None.** Admin reviews chore submission with or without photo; reason field is independent. |
| **Photo viewer widget** | **Affected** — needs to handle "no photo submitted" gracefully. Two cases: (a) `chore_verification_photos` has 0 rows for this chore → show "No photo submitted" placeholder instead of a thumbnail. (b) `chore_verification_photos` has rows → render thumbnail + tap-modal as planned. ~10 extra LOC in the photo viewer widget. |

**Net impact on 4b**: ~10 extra LOC in the photo viewer widget. Everything else unchanged.

Optional consideration: kid's "My Recent Requests" screen (Batch 6 wishlist context, not Batch 4) similarly needs to handle "no photo" for kid-submitted chore history, if such a view exists in Batch 4b. Worth confirming.

## Phase 7 — Scope estimate per chosen path

Recommended path: **Option A + UI Option 1 + 4a Modify-in-place + spec amendment in follow-up docs commit.**

| Component | LOC | Notes |
|---|---|---|
| Migration `0019_submit_kid_chore_optional_photo.sql` | ~70 | CREATE OR REPLACE on `submit_kid_chore_with_photo`; remove null-path raise; conditional photo INSERT; REVOKE PUBLIC, anon + GRANT authenticated (Supabase pattern 3) |
| ImageUploadService changes | 0 | No changes — `pickAndUploadPrivate` already works |
| Photo choice dialog widget/helper | ~30 | New method `ImageUploadService.showPhotoChoiceDialog(context)` returning `'photo' | 'skip' | null`. Could also live in a `widgets/` file. |
| Kid branch revisions (chore_dashboard) | ~25 | Replace current 40-line block with ~25-line block: choice → optional upload → RPC with nullable path |
| Kid branch revisions (chore_detail) | ~25 | Same pattern |
| Spec amendment (separate commit) | ~30 lines net change across 6 spec edits | |
| Spec-amendment implementation report | ~80 line audit | |

**Total: ~200 LOC across 4 modified files + 1 new migration + 1 amended spec.**

This fits within Batch 4a's revised scope; should NOT be a separate batch. Folding into the existing uncommitted 4a state and shipping as one revised 4a commit + a follow-up docs commit is cleanest.

## Phase 8 — Open questions

**Q1. RPC option** — pick A (recommended), B (two RPCs), or C (rename).

**Q2. UI option** — pick 1 (recommended, upfront choice), 2 (camera-first with cancel fallback), or 3 (separate buttons; not recommended).

**Q3. Uncommitted 4a handling** — pick Option 1 (discard, recommended NO), 2 (modify in place, recommended YES), or 3 (commit + followup, recommended NO).

**Q4. Spec amendment timing** — fold into this branch as a follow-up commit after the code lands, OR start a separate `docs/kid-perms-photo-optional-spec-amendment-2026-05-XX` branch off main. Recommendation: follow-up commit on this branch — the spec change is small and trails the code 1:1.

**Q5 (smaller, flag)**: The RPC name "submit_kid_chore_with_photo" stays under Option A but becomes slightly misleading ("with_photo" but optional). Worth a future-cleanup mention in the spec's "Lessons learned" section, or in `/audits/supabase-patterns-learned.md`? Recommendation: drop a one-line note in the spec amendment ("RPC name retained for backwards-compatibility; the function now accepts an optional storage path"). No code action needed.

**Q6 (smaller, flag)**: Should adult `complete_chore_self` also gain an optional photo path for consistency? The user's intent ("optional for everyone") implies yes — adults could optionally attach a photo of completion. But that's a separate behavior change for adults (currently auto-verify with no photo storage at all) and arguably out of scope for this fix. Recommendation: defer; flag as a followup if user wants symmetry.

**Q7 (smaller, flag)**: After the change, the existing `chore_verification_photos.delete_after` scheduling in `approve_chore` (Batch 2) only fires when there IS a photo row. A no-photo submission won't create one, so no cleanup is needed. Verify that `approve_chore`'s `UPDATE ... chore_verification_photos SET delete_after = ...` line handles "zero rows for this chore_id" gracefully (it should — UPDATE with zero matching rows is a no-op in Postgres). Confirm. (Likely a non-issue.)

## Next steps

1. **You decide** Q1 (RPC option), Q2 (UI option), Q3 (4a handling), Q4 (spec amendment timing). Q5-Q7 are flags only.
2. Per the recommended path:
   - **I write migration 0019** (~70 LOC) using Option A.
   - **I add `showPhotoChoiceDialog`** to `ImageUploadService` (or inline it).
   - **I revise the kid branches** in chore_dashboard + chore_detail (~50 LOC net diff).
   - **Analyzer baseline / after** — expect 0 net new issues beyond the existing rpc-inference-warning convention.
   - **iPhone smoke-test** the 4 flows: take-photo / skip-photo / cancel-choice / cancel-camera.
3. **Commit + push** the revised 4a on `feat/kid-perms-batch-4-kid-photo-flow-2026-05-24`.
4. **Spec amendment** follow-up commit on the same branch (per Q4 recommendation).
5. **Schedule Batch 4b** with the small photo-viewer "no photo" tweak in scope.

The kid permissions workstream remains on track. This discovery is genuinely scope-correcting: the photo-required intent didn't match the user's working notes, and catching it now (before Batch 4a's commit) is cheaper than amending later.
