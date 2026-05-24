# Kid Permissions Spec Amendment — Implementation

Date: 2026-05-24
Branch: `docs/kid-perms-spec-amendment-2026-05-24` (working-tree only; no commits)
Scope: apply 16 amendments to the kid-perms spec + create standalone `supabase-patterns-learned.md`
Status: code complete — **not committed**

## Summary

All 16 amendments (A through P) applied to `/audits/2026-05-kid-profile-permissions-spec.md`. Amendment P content extracted into a separate, standalone file `/audits/supabase-patterns-learned.md` so future RPC migrations can reference it without needing to read the full kid-perms spec. The kid-perms spec gained a brief "Supabase patterns referenced by this workstream" section at the end, three bullets, pointing to the patterns file.

Batch 4 row in the batch plan expanded from a single sentence to a 6-item scope list covering both originally-planned work and three new items carried forward from Batches 2/3 (Re-do affordance, kid TODO replacement, `'rejected'` dashboard UI mapping).

The spec is now accurate as of Batch 3 Half B (commit `34d9079`). Resolved Questions section duplication preserved per user direction.

## Files modified

| File | Change |
|---|---|
| `audits/2026-05-kid-profile-permissions-spec.md` | 16 amendments applied (status block, 3 Decisions table rows, 2 DB-changes bullets, RLS section, 2 App-changes bullets, kid chore completion bullet, 4 batch plan rows including a new Half A/B split, 3 Resolved Questions entries, roadmap section, new patterns cross-reference section) |

## Files created

| File | Lines | Purpose |
|---|---|---|
| `audits/supabase-patterns-learned.md` | 64 | Standalone reference of 3 Supabase-specific patterns (pgcrypto qualification, `::text` casts, REVOKE PUBLIC, anon). Future RPC migrations should read this first. |
| `audits/2026-05-kid-perms-spec-amendment-implementation.md` | this | Implementation report |

## Per-amendment confirmation

| # | Scope | Status |
|---|---|---|
| **A** | Status block (lines 3-5) | Applied. Added `Spec amended: 2026-05-24` line; replaced status text with "Batches 1, 2, 3 Half A, 3 Half B complete on stacked branches; Batches 4-8 pending". Kept the date trail. |
| **B** | Decisions table row 5 (chore photo retention) | Applied. Added "**As implemented (Batch 2):** … **Deferred:** …" structure noting pg_cron deferral. |
| **C** | Decisions table row B (reject-photo handling) | Applied. Noted `chore_verification_photos.rejected_reason` was deliberately not added; `chores.rejected_reason` used instead. |
| **D** | Decisions table row D (owner enum value) | Applied. Noted backfill via migration 0016 step 7 did happen; generalized + idempotent. |
| **E** | DB changes bullet on rejected_reason (line ~68) | Applied. Used `~~strikethrough~~` + "deliberately omitted" + rationale pointing to `chores.rejected_reason`. |
| **F** | DB changes bullet on pg_cron | Applied. Noted `delete_after` is written correctly by `approve_chore`; the cleanup job is deferred until pg_cron is enabled + Edge Function design completed. Added operational-runway note (30+ days post Batch 4). |
| **G** | RLS section (3 sub-bullets: helper name + chores + photos) | Applied. Renamed `is_household_kid` → `is_member_kid(p_member_id)` with architectural rationale. Fixed "RLS for UPDATE tightened to admin-only on the `status` column path" misleading wording (Postgres RLS is row-level). Fixed kid-INSERT wording on chore_verification_photos (`WITH CHECK (false)` blocks all direct INSERT; RPC bypasses via SECURITY DEFINER). |
| **H** | App changes Permissions helper bullet | Applied. Listed all 10 action helpers and 3 identity helpers. Renamed `canApproveRequests` → `canDecideRequests` to match actual codebase. Noted Half A scope (11 functional gates migrated; 5 display-only intentionally left). |
| **I** | App changes owner role wiring bullet | Applied. Noted Half A flipped the insert + migration 0016 step 7 backfilled legacy rows. |
| **J** | Kid chore completion bullet | Applied. Rewrote as a 3-sub-bullet structure: adult self-complete (shipped Half B, auto-verifies), admin approve/reject (shipped Half B, reject sets `'rejected'` final), kid completion (Batch 4 work pending; today's direct UPDATE has a TODO comment). |
| **K** | Batch plan row 1 | Applied. Marked ✅ shipped (commit `adb1b0a` on `feat/kid-perms-schema-2026-05-22`). Listed the owner backfill as added during implementation. Listed the three deliberate omissions (is_household_kid, rejected_reason column, pg_cron). |
| **L** | Batch plan row 2 | Applied. Marked ✅ shipped (commit `5f0cf13` on `feat/kid-perms-rls-rpcs-batch-2-2026-05-22`). Listed all 6 RPCs (added `complete_chore_self`). Referenced migration 0018 hotfix with link to `supabase-patterns-learned.md`. |
| **M** | Batch plan row 3 — split into Half A + Half B | Applied. Half A: ✅ shipped (commit `2790f48`). Half B: ✅ shipped (commit `34d9079`). Each with a brief scope summary. |
| **N** | Resolved Questions #5, #7, #9 | Applied. Three separate edits mirroring the Decisions table updates from B, C, D. Duplication preserved per user direction. |
| **O** | Roadmap section | Applied. Marked Pass 2 ✅ complete (v0.2.0-pin-security). Reflected Pass 3 progress (Batches 1, 2, 3 Half A, 3 Half B complete; Batches 4-8 pending). Added Pass 4 line item pointing to the stub at `/audits/2026-05-pass-4-today-dashboard-spec.md`. |
| **P** | Lessons learned content | **Applied with modification.** Per user direction, full content extracted to standalone `/audits/supabase-patterns-learned.md` rather than embedded in the spec. The spec gained a "Supabase patterns referenced by this workstream" section at the end (~10 lines) listing the 3 patterns by name + 1-line each + pointer to the patterns file. |

All 16 amendments completed.

## Batch 4 scope updates (Phase 2)

Original Batch 4 row was a single sentence: "Chore submit-with-photo flow: kid camera path, storage upload, DB insert via RPC, admin review UI with photo viewer + reject reason field."

Expanded to 6 numbered scope items (per user's Phase 2 instructions):

1. **Original** — kid camera path via `image_picker` + `chore-photos` Storage upload + `submit_kid_chore_with_photo` RPC integration.
2. **Carry-from-Half-B** — replace the kid TODO'd direct-UPDATE paths in `chore_dashboard_screen.dart:_completeChore` and `chore_detail_screen.dart:_quickUpdateStatus` with `submit_kid_chore_with_photo` RPC calls.
3. **New** — Re-do affordance for rejected chores: kid sees Re-do button on a `'rejected'` chore card; tap reverts status to `'assigned'` and clears `chores.rejected_reason`.
4. **New** — `'rejected'` status UI mapping in `chore_dashboard_screen.dart` rendering (Half B added it to chore_detail; Batch 4 extends to dashboard).
5. **Original** — admin reject-with-reason UI: text field for `p_reason` in the rejection flow (Half B passes `null`).
6. **Original** — photo viewer for admin reviewing kid submissions.

Each marked with **Original** / **Carry-from-Half-B** / **New** so the source of each scope item is traceable.

## Git state (uncommitted)

```
$ git status --short
 M audits/2026-05-kid-profile-permissions-spec.md
?? audits/2026-05-kid-perms-spec-amendment-implementation.md
?? audits/2026-05-kid-perms-spec-amendment-investigation.md
?? audits/supabase-patterns-learned.md
```

1 modified spec + 1 new patterns file + 2 new audit docs (investigation + implementation reports). Branch otherwise clean on `docs/kid-perms-spec-amendment-2026-05-24`.

## Open followups

1. **Should `/audits/supabase-patterns-learned.md` be cross-referenced from the Pass 2 PIN spec (or audit history) too?** The 3 patterns include 2 from Pass 2 debugging (pgcrypto qualification, `::text` cast). Adding a cross-link from Pass 2's report set (e.g., `2026-05-pin-qualify-pgcrypto-fix.md`, `2026-05-pin-gen-salt-fix.md`) would make the patterns more discoverable for future reads of the PIN security trail. **Not done in this batch** — flag for user decision.

2. **Should the Resolved Questions section be trimmed?** Still duplicates content from the Decisions table at the top of the spec. User decision was to preserve the duplication. Could revisit in a future docs cleanup.

3. **Should the spec amendment commit be its own PR or stacked on top of Half B?** Currently on `docs/kid-perms-spec-amendment-2026-05-24` which is off main (parallel to the kid-perms branch stack, not stacked on it). Either merge order works since this is docs-only and conflict-free with the code changes. User will decide when ready to commit.

4. **Consider adding a section pointer to `/audits/supabase-patterns-learned.md` from the Pass-2 PIN security audits.** The 3 patterns trace back to migrations 0014, 0015, 0018; the audits documented the individual fixes but didn't pull them into a single forward-reference. Could be a one-line addition to each Pass 2 audit doc. **Not in this batch.**

## Next steps

1. **You review** the modified spec (`audits/2026-05-kid-profile-permissions-spec.md`) and the new patterns file (`audits/supabase-patterns-learned.md`).
2. **Commit** when satisfied:
   - All 4 modified/created files in one commit: spec + patterns + this report + the investigation report.
   - Or split into 2 commits: spec + patterns in one (substantive), audit reports in another (documentation).
3. **Push** with `--set-upstream` on the current branch.
4. **Schedule Batch 4 investigation** when ready — the expanded Batch 4 row in the spec serves as the input.
