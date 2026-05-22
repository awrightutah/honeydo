# Baseline Merge — Outcome (v0.1.0-baseline)

Date: 2026-05-22
Tag: `v0.1.0-baseline` (live on `origin`)
Merge commit: `1b2388ef21901c59a3daaa02af66e02a0a976f81` (`1b2388e`)
Repository: `awrightutah/honeydo`

## Summary

The first stable end-to-end build of Honeydo is consolidated on `main` and published to origin. Nine sequential fix branches built between 2026-05-20 and 2026-05-21 — covering critical-missing-features, post-iPhone debug, two RPC/schema-alignment batches, a migration bug patch, a shopping-items RLS fix, an image-mime / calendar layout batch, a chore-verify snackbar fix, a shopping-display + kid-chore-approval batch, and a PL/pgSQL badge_key ambiguity migration — were merged into `main` as a single no-ff merge commit. The result is tagged `v0.1.0-baseline` with an annotated message recording the working state of the app at this point.

Local and origin are in sync. The nine fix branches remain in place (locally and on origin) as a safety net per the user's decision; cleanup is deferred for ~1-2 weeks.

## Pre-merge state

Verified at the start of the workflow:

- **9 fix branches in chain**, each branched off the previous, all pushed to origin, all in sync with their remote counterparts.
- **Working tree had one untracked file**: `audits/2026-05-chore-approval-diagnostic-audit.md` (real diagnostic work product from the kid-chore-approval debugging session).
- **Local `main` was 14 commits behind `origin/main`** — fast-forwardable, no divergence (the 14 commits were the phase 9-18 work that landed on origin/main before today's chain started, ancestral to `fix/critical-missing-features`).

Both pre-merge issues were resolved before touching `main`:
1. The untracked audit file was committed onto the fix tip (`fix/migration-0012-badge-key-ambiguity`) as commit `5006c3d` and pushed to origin.
2. The local main / origin main gap was closed via `git pull origin main` during Deliverable 3 (fast-forward, no conflicts).

## Per-branch commit/file accounting

| # | Branch | Commits added | Files touched | Tip subject |
|---|---|---|---|---|
| 1 | `fix/critical-missing-features` | 10 | 35 | chore: track pubspec.lock and audit reports |
| 2 | `fix/post-iphone-debug-2026-05-21` | 0 | 0 | (same tip as #1; no new work landed under this name) |
| 3 | `fix/post-iphone-batch-2-2026-05-21` | 3 | 77 | chore(mobile): generate ios and android platform folders |
| 4 | `fix/migration-bug-patch-2026-05-21` | 1 | 3 | fix(migrations): patch three real bugs in 0002, 0003, 0004 |
| 5 | `fix/shopping-items-insert-fix-2026-05-21` | 1 | 2 | fix(recipe-detail): add household_id and sanitize quantity on shopping insert |
| 6 | `fix/batch-3-image-and-calendar-2026-05-21` | 1 | 7 | fix(batch-3): image mime, calendar layout, hero tags + kid spec |
| 7 | `fix/chore-verify-flow-2026-05-21` | 1 | 2 | fix(chores): surface actual error in chore verify SnackBar |
| 8 | `fix/batch-4-shopping-display-and-kid-chores-2026-05-21` | 1 | 6 | fix(batch-4): shopping list display crash + kid chore approval |
| 9 | `fix/migration-0012-badge-key-ambiguity` | 2 | 2 | docs(audits): add chore approval diagnostic audit |
|  | **Total** | **20** | — | (plus 1 merge commit) |

Total commits brought onto main by the merge: **21** (20 underlying + 1 merge commit).

## Deliverables 1-7 status

| # | Deliverable | Status |
|---|---|---|
| 1 | Pre-merge audit | ✅ Done. Two unexpected conditions surfaced and resolved as noted above. |
| 2 | Merge strategy decision | ✅ Done. No-ff merge approved by user. |
| 3 | Actual merge | ✅ Done. Merge commit `1b2388e` produced. No conflicts (ort strategy). Working tree clean post-merge. |
| 4 | Tag baseline | ✅ Done. Annotated tag `v0.1.0-baseline` created on `1b2388e`. Tag object SHA: `a25492cfb8fbc2fde67ecc062dc4d8eed89c0a29`. |
| 5 | Push main + tag | ✅ Done. Both pushes were non-force, fast-forward-friendly. Origin/main moved `64bfee8 → 1b2388e`. Tag published. Local and origin in sync. |
| 6 | Branch cleanup | ⏸ **Deferred by user.** Branches preserved for ~1-2 weeks as a regression safety net. |
| 7 | This report | ✅ Done (this file). |

## Merge commit hash and message

**Commit:** `1b2388ef21901c59a3daaa02af66e02a0a976f81` (short: `1b2388e`)
**Parents:**
- `64bfee8dc06d100e27ffe8603b34e8e39b4844a6` (origin/main at time of merge — the phase 9-18 tip)
- `5006c3d8710d799cd219cd756a9482b0c5aaf2c6` (fix tip after the diagnostic-audit commit was added)

**Subject:** `merge: v0.1.0-baseline - first stable end-to-end working build`

Full message body lists the nine workstreams, app state at baseline, and pointers to the audit documents in `/audits/`.

## Tag (`v0.1.0-baseline`) with annotation

**Tag object:** `a25492cfb8fbc2fde67ecc062dc4d8eed89c0a29`
**Type:** annotated (not signed; signing not requested)
**Points to:** commit `1b2388e` (the merge commit)
**Tagger:** awrightutah <andrewwright0520@gmail.com>

**Annotation message (verbatim):**

> First stable end-to-end working build (2026-05-21)
>
> Honeydo can be built and deployed to iPhone with all critical paths verified:
> - User signup and household creation
> - Adult and kid member management
> - Full chore lifecycle (assign, complete, approve, award points, earn achievements)
> - Recipe library and meal planning
> - Shopping list with recipe integration
> - Calendar with default tags
> - Profile photo upload
> - Activity feed
>
> Stack: Flutter 3.44 + Supabase (Postgres 15) + Node.js backend on Railway.
>
> 12 migrations applied (0001-0012). 5 product spec documents preserved in /audits/.
>
> Next: Pass 2 (RLS lockdown, proper PIN hashing via pgcrypto, schema consistency audit) before Phase-1 of any new feature work begins.

The reversibility property: a single `git revert -m 1 1b2388e` undoes the entire baseline cleanly if a regression appears that warrants pulling everything out.

## Push verification

**`git log origin/main --oneline -3`** after the pushes:

```
1b2388e merge: v0.1.0-baseline - first stable end-to-end working build
5006c3d docs(audits): add chore approval diagnostic audit
e2592b1 fix(migrations): resolve badge_key ambiguity in achievement functions
```

**`git ls-remote --tags origin v0.1.0-baseline`:**

```
a25492cfb8fbc2fde67ecc062dc4d8eed89c0a29	refs/tags/v0.1.0-baseline
```

**Local ↔ origin sync:** both `main` refs point to `1b2388ef21901c59a3daaa02af66e02a0a976f81`. ✅

## Branches deleted

**None.** Deliverable 6 (branch cleanup) is deferred per user instruction. The user wants the 9 fix branches preserved for ~1-2 weeks as a safety net against late-discovered regressions.

## Branches remaining (post-merge, pre-cleanup)

Local branches still present:
- `main` (now at `1b2388e`, in sync with origin)
- `fix/critical-missing-features`
- `fix/post-iphone-debug-2026-05-21`
- `fix/post-iphone-batch-2-2026-05-21`
- `fix/migration-bug-patch-2026-05-21`
- `fix/shopping-items-insert-fix-2026-05-21`
- `fix/batch-3-image-and-calendar-2026-05-21`
- `fix/chore-verify-flow-2026-05-21`
- `fix/batch-4-shopping-display-and-kid-chores-2026-05-21`
- `fix/migration-0012-badge-key-ambiguity`

Remote branches still present on `origin`:
- `origin/main`, `origin/HEAD`
- All 9 fix branches (each `origin/fix/...`)
- Pre-existing branches outside this workflow: `origin/chore/supabase-storage-confirmed`, `origin/phase9/core-functionality`, `origin/scaffold/initial-homehub-build`

All 9 fix branches are reachable from `main` via the merge commit, so deleting them later is safe (`git branch -d` will succeed without `-D` because they're fully merged).

When you're ready to clean up, the loop to run is:
```
for b in fix/critical-missing-features fix/post-iphone-debug-2026-05-21 \
         fix/post-iphone-batch-2-2026-05-21 fix/migration-bug-patch-2026-05-21 \
         fix/shopping-items-insert-fix-2026-05-21 fix/batch-3-image-and-calendar-2026-05-21 \
         fix/chore-verify-flow-2026-05-21 fix/batch-4-shopping-display-and-kid-chores-2026-05-21 \
         fix/migration-0012-badge-key-ambiguity ; do
  git branch -d "$b"
  git push origin --delete "$b"
done
```

## Next workstream pointer

Per the tag annotation: **Pass 2 — security and data integrity** is the next planned workstream. The audit work in `/audits/2026-05-pass-1a-flutter-v3.md` flagged three items that belong to Pass 2 and are not yet addressed:

1. **RLS lockdown.** The current policies are largely "any household member can do everything." Tighten by action and by member kind. The kid-permissions spec (`/audits/2026-05-kid-profile-permissions-spec.md`) describes the role-based restrictions that need RLS enforcement, not just app-side UI gating.
2. **Proper PIN hashing via pgcrypto.** Today's SHA-256 without salt over 4-6 digit PINs is recoverable in milliseconds. Move to `crypt(pin, gen_salt('bf'))` with per-row salt, verify server-side in a SECURITY DEFINER function, and revoke client SELECT on `pin_hash`. Documented as SECURITY DEBT comments in `members_screen.dart` and `home_shell_screen.dart` (see CQ2 in the v3 audit).
3. **Schema consistency audit.** The drift map (`/audits/2026-05-schema-drift-map.md`) caught the major cases that were breaking core flows; this pass closes the rest — denormalized columns vs. joins, unused tables (`chore_history`, `analytics_events`, `audit_logs`), and cross-table invariants worth a CHECK constraint or trigger.

The kid permissions feature batch (`/audits/2026-05-kid-profile-permissions-spec.md`) should wait until **after** Pass 2 — it depends on RLS being tightened up first.

The two product specs added in batch 4 (shopping-list roadmap, gamification roadmap) sit in `/audits/` waiting for the kid-permissions work; they're Phase-1 feature batches, not Pass-2 work.

## Followups (carried forward from prior batches)

Items spotted during the fix cycle that did not block the baseline and are not tracked elsewhere:

1. **`current_streak` column is not yet computed.** Added in migration 0009 with default 0; no app or trigger updates it. Streak badges (`on_a_roll`, `streak_master`) will not fire for sub_profiles until a background job or trigger writes this column. Adult flows compute streak on-the-fly via the `calculate_streak` RPC. Worth aligning before the gamification work.
2. **`chore_detail_screen.dart:514` action chip "Verify" updates status but silently skips the points RPC.** The dashboard's Approve button is the only correct path that awards points today. The chore detail screen should mirror `_verifyChore`'s branching logic or call into it.
3. **`chore_detail_screen.dart:48, 310, 321, 518` use `'skipped'` status value.** Not in the `chore_status` enum (`cancelled` is the closest valid value). Same class as the now-fixed `'completed'` bug. Saving a chore as "Skipped" from the dropdown still throws.
4. **`notification_preferences` table has 13 columns the app sets that the schema doesn't have.** Toggles silently no-op. Resolving requires either schema additions or app-side trimming.
5. **Calendar tag management UI does not exist.** Adding/editing tags from the calendar is a feature task, not a fix. Calendar screen reads tags for filter chips and the household-setup default tag insert exists, but no add/edit/delete affordance. Schema is ready.
6. **Long-term consolidation: route ALL chore-completion through `member_id`-based RPCs.** Today's branch is `kind == 'sub_profile'` → new RPC vs. else → old RPC. The new RPC's logic works for adults too (member_id is valid in both cases). Eliminating the auth_user_id-based RPCs would remove the entire class of "kid vs adult" bugs we've been chasing. Suggested as part of the kid-permissions feature batch.

## Files added in this workflow

Only one repository file was created by the merge workflow itself:
- `audits/2026-05-baseline-merge-outcome.md` (this report) — to be committed separately after this report lands.

(The diagnostic-audit file `audits/2026-05-chore-approval-diagnostic-audit.md` was already on the fix tip via commit `5006c3d` before the merge.)
