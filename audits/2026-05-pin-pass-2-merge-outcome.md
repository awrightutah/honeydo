# Pass 2 PIN security merge — Outcome (v0.2.0-pin-security)

Date: 2026-05-22
Tag: `v0.2.0-pin-security` (live on `origin`)
Merge commit: `297838a05eb31a1b980571dee1ad5848466a6932` (`297838a`)
Repository: `awrightutah/honeydo`

> **See also:** /audits/supabase-patterns-learned.md for Supabase-specific patterns learned during this work.

## Summary

Pass 2 (security) consolidated onto `main` and tagged as `v0.2.0-pin-security`. The merged branch (`fix/pin-hashing-pass-2-2026-05-22`) brought three commits covering: the initial PIN bcrypt RPC batch, the hotfix chain (gen_salt type cast, pgcrypto schema qualification, error-surfacing in catch blocks, four diagnostic audits), and the kid-permissions planning batch (investigation report + spec resolution with 11 decisions and an 8-batch plan).

End-to-end iPhone testing confirmed PIN set, PIN verify (right and wrong), new kid creation, and data export clean of auth secrets prior to merge. No regressions on existing flows.

`fix/pin-hashing-pass-2-2026-05-22` remains preserved locally and on origin as a safety net, matching the policy applied to the 9 fix branches from the v0.1.0-baseline cycle. A new branch `feat/kid-perms-schema-2026-05-22` was created off the merge commit and is ready for Batch 1 of the kid-permissions feature workstream (migration 0016).

## Pre-merge state

Verified at the start of the workflow:

- **Working tree clean** on `fix/pin-hashing-pass-2-2026-05-22`, no uncommitted changes
- **Local fix branch in sync** with `origin/fix/pin-hashing-pass-2-2026-05-22` at `c5926db4026a528ec94739745d2e8fdc87acb9b9`
- **Local `main` in sync** with `origin/main` at `63062768614893734ab38b3017c1e30dfacb27bf` (one docs commit past the `v0.1.0-baseline` tag at `1b2388e`)
- **Exactly 3 commits ahead** of `main`:
  - `c5926db` — docs(audits): resolve kid permissions open questions + update spec
  - `18fd24e` — fix(security): proper PIN hashing via pgcrypto bcrypt server-side (hotfix chain commit)
  - `0904108` — fix(security): proper PIN hashing via pgcrypto bcrypt server-side (initial batch)
- **9 older `fix/*` branches** from 2026-05-21 baseline still present locally + on origin (unchanged this workflow)
- **No conflicts expected**: the branch is purely additive (three new commits, no overlapping edits with main)

`git pull origin main` during Deliverable 3 was a no-op (`Already up to date`); the fast-forward gap was zero.

## Merge commit hash + message

**Commit:** `297838a05eb31a1b980571dee1ad5848466a6932` (short: `297838a`)
**Parents:**
- `6306276dc3...` (previous `origin/main` tip — the baseline-merge outcome report commit)
- `c5926db402...` (fix branch tip after the kid-permissions planning batch)

**Strategy:** `ort`, zero conflicts
**Files:** 15 changed, +2520 / −58
**Subject:** `merge: v0.2.0-pin-security — Pass 2 PIN hashing + kid permissions planning`

**Full message body:**

```
merge: v0.2.0-pin-security — Pass 2 PIN hashing + kid permissions planning

Pass 2 (security) — Proper PIN hashing via pgcrypto bcrypt server-side.

PIN flow rewrite:
- bcrypt hashing via pgcrypto gen_salt('bf'::text, 8), per-row salt
- Hash stored in separate member_pin_secrets table (REVOKE ALL +
  RLS enabled with zero policies — defense in depth)
- Three SECURITY DEFINER RPCs: set_member_pin, verify_member_pin,
  has_member_pin (only path to read or write the hash)
- pin_hash column dropped from household_members
- PIN format ^[0-9]{4,6}$ enforced server-side
- All RPCs verify caller is in the same household + role checks

Three migration files (0013 + 0014 + 0015):
- 0013 amended in place with the working SQL (extensions.crypt,
  extensions.gen_salt, ::text casts)
- 0014 kept for replay history (gen_salt type cast hotfix)
- 0015 kept for replay history (extensions schema qualification)

Three Dart changes:
- members_screen.dart: create kid via set_member_pin RPC
- home_shell_screen.dart: switcher via has_member_pin +
  verify_member_pin, plus Set-PIN dialog for kids without PINs
- data_export_screen.dart: explicit column list, omits pin_hash

Plus error-surfacing fix: catch blocks no longer swallow exceptions.

Kid permissions planning (documentation only):
- /audits/2026-05-kid-permissions-investigation.md
- /audits/2026-05-kid-profile-permissions-spec.md updated with 11
  resolved decisions and 8-batch implementation plan

Tested on iPhone: PIN set + verify + new kid + export verified clean
of auth secrets. Bcrypt 60-char hash stored correctly. Architecture
ready for Batch 1 of kid permissions feature work.

Tag: v0.2.0-pin-security
```

A single `git revert -m 1 297838a` cleanly undoes the entire batch (parent 1 is preserved as the "mainline" reference for revert), matching the reversibility property of the v0.1.0-baseline merge.

## Tag — `v0.2.0-pin-security`

**Tag object SHA:** `08f9adf03590d6f87e08f74aef66e88053166eba`
**Type:** annotated (unsigned; signing was not requested)
**Points to:** commit `297838a` — the merge commit
**Tagger:** `awrightutah <andrewwright0520@gmail.com>`

**Annotation message (verbatim):**

> Pass 2 PIN hashing security release (2026-05-22)
>
> PIN hashing is now properly bcrypt'd server-side via pgcrypto.
>
> Bcrypt with work factor 8, per-row salt, server-side hashing and
> verification through SECURITY DEFINER RPCs. Hash storage is in a
> separate locked-down table that no client role can read.
>
> Includes:
> - Migrations 0013, 0014, 0015 (consolidated PIN bcrypt work)
> - Dart screen changes for the new RPC-based flow
> - Data export leak fix (explicit column list)
> - Error-surfacing fix in catch blocks
>
> Plus planning documents for kid permissions workstream:
> - audits/2026-05-kid-permissions-investigation.md
> - audits/2026-05-kid-profile-permissions-spec.md (with 11
>   resolved decisions and 8-batch plan)
>
> Stack: Flutter 3.44 + Supabase (Postgres 15) + Node.js / Railway.
>
> 15 migrations applied (0001-0015). 6+ product spec documents in
> /audits/.
>
> Next: kid permissions Batch 1 (schema migration 0016).

## Push verification

**Push outputs (verbatim):**

```
$ git push origin main
To https://github.com/awrightutah/honeydo.git
   6306276..297838a  main -> main

$ git push origin v0.2.0-pin-security
To https://github.com/awrightutah/honeydo.git
 * [new tag]         v0.2.0-pin-security -> v0.2.0-pin-security
```

Both pushes were non-force, fast-forward-friendly.

**`git log origin/main --oneline -3`** after the pushes:

```
297838a merge: v0.2.0-pin-security — Pass 2 PIN hashing + kid permissions planning
c5926db docs(audits): resolve kid permissions open questions + update spec
18fd24e fix(security): proper PIN hashing via pgcrypto bcrypt server-side
```

**`git ls-remote --tags origin v0.2.0-pin-security`:**

```
08f9adf03590d6f87e08f74aef66e88053166eba	refs/tags/v0.2.0-pin-security
```

`08f9adf…` is the tag object SHA (annotated tags are stored as git objects that wrap the commit). The wrapped commit is `297838a`, already verified via `git tag -v` during Deliverable 4.

**Sync check:** local `main` and `origin/main` both point to `297838a05eb31a1b980571dee1ad5848466a6932` ✅

## New branch created — `feat/kid-perms-schema-2026-05-22`

```
$ git checkout -b feat/kid-perms-schema-2026-05-22
Switched to a new branch 'feat/kid-perms-schema-2026-05-22'

$ git branch --show-current
feat/kid-perms-schema-2026-05-22

$ git log --oneline -3
297838a merge: v0.2.0-pin-security — Pass 2 PIN hashing + kid permissions planning
c5926db docs(audits): resolve kid permissions open questions + update spec
18fd24e fix(security): proper PIN hashing via pgcrypto bcrypt server-side

$ git rev-parse HEAD
297838a05eb31a1b980571dee1ad5848466a6932
```

The new branch points directly at the `v0.2.0-pin-security` merge commit. It is local-only (no upstream tracking yet — the first push will use `--set-upstream`, same pattern as the PIN branch).

## Branches preserved (not deleted this workflow)

Per instruction, no branch cleanup was performed:

- `fix/pin-hashing-pass-2-2026-05-22` (the branch just merged) — preserved locally + on origin
- `fix/critical-missing-features` (from 2026-05-20)
- `fix/post-iphone-debug-2026-05-21`
- `fix/post-iphone-batch-2-2026-05-21`
- `fix/migration-bug-patch-2026-05-21`
- `fix/shopping-items-insert-fix-2026-05-21`
- `fix/batch-3-image-and-calendar-2026-05-21`
- `fix/chore-verify-flow-2026-05-21`
- `fix/batch-4-shopping-display-and-kid-chores-2026-05-21`
- `fix/migration-0012-badge-key-ambiguity`

When you're ready to clean up the older batch (the 9 fix branches from 2026-05-21), the loop from `/audits/2026-05-baseline-merge-outcome.md` still applies. The Pass-2 branch should hold for ~1-2 weeks under the same safety-net policy before being added to a future cleanup loop.

## Ready for Batch 1 (kid permissions schema migration 0016)

Active branch: `feat/kid-perms-schema-2026-05-22`. Per the resolved spec (`/audits/2026-05-kid-profile-permissions-spec.md`), Batch 1 scope is:

| Schema change | Notes |
|---|---|
| `meal_requests` (new table) | `id, household_id, requested_by_member_id, recipe_id, requested_for_date, meal_type, status check ('pending','approved','denied'), decided_by_member_id, decided_at, decided_note, created_at` — auto-archive after 30 days |
| `necessity_categories` (new table) | `(household_id, category)` composite PK; ship 4 defaults per household at signup (Hygiene, School Supplies, Basic Groceries, Medication) |
| `shopping_items` +3 columns | `is_wishlist boolean default false`, `approved_by_member_id uuid`, `approved_at timestamptz` |
| `household_members.music_app_preference text` | Nullable; per-kid preference for the music app deep link |
| `chore_verification_photos.rejected_reason text` | Nullable; admin reject note |
| `is_household_kid(target_household_id uuid)` RLS helper | Mirrors `is_household_member` and `is_household_admin` |
| pg_cron job | Daily; deletes Storage objects + `chore_verification_photos` rows where `delete_after < now()` |

Implementation order will be migration file → review → apply to Supabase → confirm → commit. RLS tightening + SECURITY DEFINER RPCs come in Batch 2 on a follow-up branch (or stacked on this one — your call when we get there).

## Followups (carried forward, none new from this workflow)

The followups list from `/audits/2026-05-pin-hashing-fix-outcome.md` carries over unchanged:

1. Rate limiting on `verify_member_pin` (Pass 2.1).
2. Standalone Change-PIN UI in members management (Pass 2.1).
3. Combined `create_sub_profile_with_pin` atomic RPC (Pass 2.1).

Plus the followups from `/audits/2026-05-baseline-merge-outcome.md` that are still open:

1. `current_streak` column has no writer (Pass 2.x).
2. `chore_detail_screen.dart:514` action chip skips the points RPC.
3. `'skipped'` status string in `chore_detail_screen.dart` is not in the `chore_status` enum.
4. `notification_preferences` schema/app drift (13 missing columns).
5. Calendar tag management UI does not exist.
6. Long-term: route all chore completion through `member_id`-based RPCs.

These are not blockers for Batch 1.

## Files added in this workflow

Only one repository file is created by the merge workflow itself:
- `audits/2026-05-pin-pass-2-merge-outcome.md` (this report) — currently uncommitted; will be added on the next commit when you give the word.
