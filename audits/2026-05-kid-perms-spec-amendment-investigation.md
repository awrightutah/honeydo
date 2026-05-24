# Kid Permissions Spec Amendment — Investigation

Date: 2026-05-24
Branch: `docs/kid-perms-spec-amendment-2026-05-24` (read-only investigation; no edits, no commits)
Spec under review: `/audits/2026-05-kid-profile-permissions-spec.md` (162 lines)
Status: drift inventory complete — **9 drift categories surfaced + minor wording cleanups**; amendment plan in Phase 3 below

## Summary

The spec was written between the original "5 open questions" capture (2026-05-21) and the "11 resolved questions" amendment (2026-05-22), then frozen before Batch 1 began. Across Batches 1, 2, 2-hotfix (0018), 3 Half A, and 3 Half B, implementation either refined the spec's prescriptions or deliberately diverged. Nine areas drifted; all are documented in the batch investigation/implementation reports but not yet reflected in the spec itself.

**Categories of drift** (counts of spec text changes proposed):
- **2a is_household_kid → is_member_kid** — 2 spec mentions
- **2b `chore_verification_photos.rejected_reason` not added** — 4 spec mentions
- **2c pg_cron deferred (not shipped)** — 4 spec mentions
- **2d 5 RPCs → 6 RPCs (added `complete_chore_self`)** — 1 spec mention (Batch 2 row) + helper count in Implementation Notes
- **2e/2f Owner backfill DID happen** (spec says it didn't) — 3 spec mentions
- **2g Anon revoke pattern** — not in spec; recommend adding a note
- **2h Batch 3 split into Half A + Half B** — 1 spec row to split
- **2i Other drift**: status section header (stale), roadmap section (stale), `canApproveRequests` → `canDecideRequests` rename, more helper methods than spec listed, "kid INSERT must reference their own member_id" describes an unimplemented approach (we used `WITH CHECK (false)` instead), "RLS for UPDATE tightened to admin-only on the `status` column path" is misleading (RLS is row-level not column-level)

Batches 4-8 descriptions are still accurate but **Batch 4 scope should be expanded** to include: (a) replacing the kid TODOs in `_completeChore`/`_quickUpdateStatus`, (b) the Re-do affordance for rejected chores, and (c) the `'rejected'` UI rendering in `chore_dashboard_screen.dart` (Half B added it to chore_detail only).

## Phase 1 — Current spec structure

Section map (162 lines total):

| Lines | Section | Status |
|---|---|---|
| 1-5 | Title + status block | **Stale** — status says "Implementation-ready (Batch 1 next)"; reality is Batches 1-3 Half B shipped |
| 7-23 | Decisions (2026-05-22) table | Mostly accurate; row 5 (pg_cron), row B (rejected_reason), row D (no-backfill claim) drifted |
| 25-31 | Background | Stable; could be clarified now that enforcement exists |
| 33-54 | Allowed / Disallowed actions | Stable — aspirational, didn't drift |
| 56-69 | Implementation notes → Database changes | Two bullets drifted (rejected_reason, pg_cron); rest is correct |
| 71-83 | Implementation notes → RLS policy changes | Two areas drifted (is_household_kid name; "kid INSERT must reference their own member_id"); rest mostly correct, some wording could be sharpened |
| 85-97 | Implementation notes → App changes | One bullet drifted (owner backfill claim); kid chore completion bullet describes Batch 4 future work as if present-tense |
| 99-107 | Meal-decision notification channels | Stable (future intent) |
| 109-122 | Batch plan table | Batches 1-3 rows need amending (helper name, RPC count, Half A/Half B split, deferred pg_cron); Batches 4-8 mostly accurate |
| 124-153 | Resolved questions (1-11) | Mirrors Decisions table; same three drifts (#5 pg_cron, #7 rejected_reason, #9 no-backfill) |
| 155-161 | Where this fits in the roadmap | **Stale** — Pass 2 is complete, not "in progress"; Pass 3 progress not reflected |

Most-likely-to-need-updating: lines 1-5 (status), 7-23 (Decisions rows 5, B, D), 56-69 (DB changes), 71-83 (RLS changes), 85-97 (App changes — bullet 3 + bullet 8), 109-122 (Batch plan rows 1, 2, 3), 124-153 (Resolved questions #5, #7, #9), 155-161 (roadmap).

## Phase 2 — Drift inventory

### 2a. `is_household_kid` → `is_member_kid`

**Spec mentions (2 locations):**

Line 75 (Implementation notes → RLS policy changes):
> - New helper function `public.is_household_kid(target_household_id uuid)` returning boolean, mirroring `is_household_member` and `is_household_admin`.

Line 113 (Batch plan, Batch 1 row):
> Migration 0016 (schema): `meal_requests`, `necessity_categories` (with 4 default rows per household), `shopping_items` 3 new columns, `household_members.music_app_preference`, `chore_verification_photos.rejected_reason`, `is_household_kid()` RLS helper, daily pg_cron job for 30-day photo retention

**What shipped:** Batch 1's investigation found `is_household_kid` architecturally impossible — sub_profiles have `auth_user_id IS NULL` so a helper filtering on `auth.uid()` can never match. Batch 2's migration 0017 (lines 67-87) added `is_member_kid(p_member_id uuid)` instead, used inside the SECURITY DEFINER RPCs.

### 2b. `chore_verification_photos.rejected_reason` column NOT added

**Spec mentions (4 locations):**

Line 19 (Decisions table, row B):
> `chore_verification_photos.rejected_reason text` column added so admin can record why. Same 30-day retention applies.

Line 68 (Implementation notes → Database changes):
> - **`chore_verification_photos.rejected_reason text`** — nullable. Recorded by admin when rejecting a kid's submission.

Line 113 (Batch plan, Batch 1 row): cited under what 0016 ships.

Line 145 (Resolved questions #7):
> Photo kept for audit. `chore_verification_photos.rejected_reason text` records the admin's note. Same 30-day retention applies; the cron job deletes both verified and rejected photos after that window.

**What shipped:** Batch 1 investigation flagged that `chores.rejected_reason` already exists from migration 0001:107. Adding the column on photos table creates two sources of truth. Migration 0016 omitted it; Batch 2's `approve_chore` RPC writes the rejection reason to `chores.rejected_reason` (single source of truth).

### 2c. pg_cron 30-day cleanup — deferred (not shipped)

**Spec mentions (4 locations):**

Line 17 (Decisions table, row 5):
> 30 days post-decision (verified OR rejected), enforced by a pg_cron job that deletes the storage object and the `chore_verification_photos` row.

Line 69 (Implementation notes → Database changes):
> - **30-day photo retention via pg_cron**: a scheduled job runs daily, deletes Storage objects + rows where `delete_after < now()`. `delete_after` is set when status transitions to `verified` OR `rejected` (now + interval '30 days').

Line 113 (Batch plan, Batch 1 row): "daily pg_cron job for 30-day photo retention".

Line 141 (Resolved questions #5):
> A pg_cron job runs daily, deleting Storage objects + `chore_verification_photos` rows where `delete_after < now()`. `delete_after` is set when chore status transitions to `verified` OR `rejected`.

**What shipped:** Batch 1 investigation deferred this — pg_cron not enabled on the Supabase project, and storage-object cleanup needs an Edge Function design pass. Batch 2's `approve_chore` writes `delete_after = now() + interval '30 days'` correctly, but no cron deletes rows. Currently a known followup (mentioned in Batch 1 implementation and Batch 2 implementation reports).

### 2d. 5 SECURITY DEFINER RPCs → 6 RPCs (added `complete_chore_self`)

**Spec mentions (1 explicit list):**

Line 114 (Batch plan, Batch 2 row):
> Plus SECURITY DEFINER RPCs: `approve_chore`, `add_shopping_item`, `submit_kid_chore_with_photo`, `create_meal_request`, `decide_meal_request`.

**What shipped:** Migration 0017 added a 6th RPC — `complete_chore_self(p_chore_id, p_member_id)` — for the non-admin adult self-complete path. Without it, after Batch 2's RLS lockdown to admin-only chore UPDATEs, non-admin adults could not complete their own chores. Per Q3 of Batch 2 investigation.

### 2e / 2f. Owner backfill DID happen (spec says it didn't)

**Spec mentions (3 locations claiming "no backfill"):**

Line 21 (Decisions table, row D):
> Existing `household_setup_screen.dart:96` will be updated to insert creators as `'owner'` going forward (existing rows stay `'admin'` — no backfill).

Line 89 (Implementation notes → App changes):
> Existing rows that say `'admin'` for creators are NOT backfilled in this workstream (out of scope). Permission gates always accept `('owner', 'admin')`.

Line 149 (Resolved questions #9):
> Setup flow updated to insert creator as `'owner'` going forward; legacy `'admin'` rows for past creators are not backfilled in this workstream.

**What shipped:** Migration 0016's step 7 ran the backfill UPDATE:

```sql
UPDATE public.household_members hm
   SET role = 'owner', updated_at = now()
  FROM public.households h
 WHERE hm.household_id = h.id
   AND hm.auth_user_id = h.owner_user_id
   AND hm.role = 'admin';
```

Per the user's Batch 1 brief: "small addition agreed in chat" added the backfill on top of the spec's no-backfill intent. The backfill is generalized — affects every household where the creator's row says `role='admin'`, not just Wrights. Idempotent (filters on `role='admin'` so re-runs are no-ops once promoted).

### 2g. Anon revoke pattern — missing from spec

The spec doesn't yet capture the Supabase-specific REVOKE lesson learned from migration 0018:

> Supabase default-grants EXECUTE to anon, authenticated, AND service_role on every function created in the public schema. `REVOKE ALL ... FROM PUBLIC` does NOT catch the explicit per-role grants. Future RPC migrations must `REVOKE ALL ... FROM PUBLIC, anon` (not just `PUBLIC`). Verify with both `has_function_privilege` AND `information_schema.routine_privileges` — they can disagree on what counts as revoked.

This is now a third entry in the "Supabase-quirk lessons" alongside (1) `'bf'::text` cast for `gen_salt` and (2) `extensions.` schema qualification for pgcrypto. Worth a short "Implementation patterns" or "Lessons learned" section.

### 2h. Batch 3 split into Half A + Half B

**Spec mentions (1 location):**

Line 115 (Batch plan, Batch 3 row):
> `apps/mobile/lib/utils/permissions.dart` — new Dart helper module. Migrate the 14 existing `role == 'admin'` gates to the helper. Update `household_setup_screen.dart:96` to insert creator as `'owner'`.

**What shipped:** Two halves on two branches:
- **Half A** (commit `dbeea55`): exactly what the spec described — Permissions helper, 11 functional role gate refactors, `'admin'` → `'owner'` insert flip.
- **Half B** (commit `34d9079` / `04fd21a`): NOT in the spec. Migrated `_verifyChore` to `approve_chore` RPC, `_completeChore` to `complete_chore_self` (adult path) with kid TODO, `_quickUpdateStatus` two-path migration, `_saveChore` `canEdit` tightening, `'rejected'` UI mapping in chore_detail. This was necessary because Batch 2's RLS tightening broke non-admin adult chore completion; Half A's helper alone didn't fix that.

Spec should split into 3a + 3b or describe Batch 3 as covering both pieces.

### 2i. Other drift

**Status block (line 1-5):**
> Date captured: 2026-05-21
> Decisions resolved: 2026-05-22
> Status: Implementation-ready (Batch 1 next, on its own branch off main after `fix/pin-hashing-pass-2-2026-05-22` lands)

Stale — Pass 2 PIN work merged (v0.2.0-pin-security tagged 2026-05-22); Batches 1-3 Half B all complete on branches; Batch 4 next. Should be "Batches 1-3 Half B complete; Batch 4 next."

**Background "Currently all members share..." (line 31):**
> Currently all members share the same `household_role` ('owner', 'admin', 'member') and the same RLS policies. There is no enforced distinction between what an adult-member and a kid-sub-profile can do. This spec defines the distinction.

Tense issue: as of migration 0017 + 0018 + Half A + Half B, the enforcement exists. Could be reworded to "This spec defined the distinction; Batches 1-3 Half B implemented the backend half (schema, RLS, RPCs) and the role-gate refactor. Batches 4-8 implement the remaining user-facing flows."

**`canApproveRequests` → `canDecideRequests` rename (line 87):**
Spec lists `canApproveRequests` in the Permissions helper exports; actual file at `apps/mobile/lib/utils/permissions.dart` exports `canDecideRequests`. Minor — rename in spec to match reality.

**More Permissions helpers shipped than spec listed (line 87):**
Spec lists 5 action helpers: `canEditHousehold`, `canVerifyChores`, `canManageMembers`, `canManageRewards`, `canApproveRequests`. Actual file ships 10:
- `canEditHousehold` ✓
- `canVerifyChores` ✓
- `canEditAnyChore` (new)
- `canManageMembers` ✓
- `canInviteMembers` (new)
- `canManageRewards` ✓
- `canDecideRequests` (renamed from `canApproveRequests`)
- `canManageNecessityCategories` (new)
- `canManageBilling` (new)
- `canManageAnnouncements` (new)

Spec should list all 10 (or describe the pattern without enumerating, with "see `apps/mobile/lib/utils/permissions.dart` for the full list").

**RLS for chores: "admin-only on the `status` column path" (line 76):**
> `chores`: verify/approve actions move behind a SECURITY DEFINER RPC `approve_chore(p_chore_id, p_approved, p_reason)` that checks caller is `is_household_admin`. RLS for UPDATE tightened to admin-only on the `status` column path.

Misleading. Postgres RLS is row-level, not column-level. What 0017 actually did: tightened the whole chores UPDATE policy to `is_household_admin`. Should reword to "RLS for UPDATE tightened to admin-only (the whole row, not just status — Postgres RLS is row-level)."

**RLS for `chore_verification_photos`: "kid INSERT must reference their own member_id" (line 77):**
> `chore_verification_photos`: kid INSERT must reference their own member_id; admin UPDATE allowed for `rejected_reason`; SELECT remains household-scoped.

Doesn't match what shipped. Migration 0017 has 4 policies on the table:
- SELECT: `is_household_member`
- INSERT: `WITH CHECK (false)` — blocks ALL direct INSERT (the `submit_kid_chore_with_photo` SECURITY DEFINER RPC bypasses)
- UPDATE: `is_household_admin`
- DELETE: `is_household_admin`

The spec's "kid INSERT must reference their own member_id" describes a per-row WITH-CHECK approach we didn't implement. Should reword to "INSERT fully blocked at RLS; kid submissions go through `submit_kid_chore_with_photo` RPC (SECURITY DEFINER bypass). UPDATE/DELETE admin-only."

**Kid chore completion in App changes (line 96):**
> **Kid chore completion** opens the camera instead of just updating status. Photo uploads to the `chore-photos` bucket, row inserts into `chore_verification_photos`, status transitions to `pending_verification`. Adults retain the no-photo path.

Two issues:
1. Describes Batch 4 work in present tense. As of Half B, the kid path is still a direct UPDATE (with TODO comment); the camera/upload/RPC path is Batch 4.
2. "Adults retain the no-photo path" — Half B changed this. Adults now use `complete_chore_self` which auto-verifies (`status='verified'` directly, no admin step). Spec should note that adults no longer go through `pending_verification`.

Should rewrite to describe the post-Half-B reality + the pending Batch 4 work on the kid path.

**Roadmap section (lines 155-161):**
Stale references to Pass 2 "in progress" and the workstream as "⏳" pending. Pass 2 merged to main as v0.2.0-pin-security; Batches 1-3 Half B are committed (unmerged but complete). Update to reflect actual state.

## Phase 3 — Proposed amendments section-by-section

### Amendment A — Status block (lines 3-5)

**Current:**
```
Date captured: 2026-05-21
Decisions resolved: 2026-05-22
Status: Implementation-ready (Batch 1 next, on its own branch off main after `fix/pin-hashing-pass-2-2026-05-22` lands)
```

**Proposed:**
```
Date captured: 2026-05-21
Decisions resolved: 2026-05-22
Spec amended: 2026-05-24
Status: Batches 1, 2, 3 Half A, 3 Half B complete on stacked feature branches (unmerged at time of amendment). Batches 4-8 not yet started.
```

**Reason:** reflect actual progress so the spec stops being misread as "implementation hasn't started."

### Amendment B — Decisions table row 5 (line 17)

**Current:**
> 30 days post-decision (verified OR rejected), enforced by a pg_cron job that deletes the storage object and the `chore_verification_photos` row.

**Proposed:**
> 30 days post-decision (verified OR rejected). `approve_chore` RPC (Batch 2) writes `delete_after = now() + interval '30 days'` correctly. The actual cleanup job is **deferred** — pg_cron isn't enabled on the project and Storage-object deletion needs an Edge Function design pass. Tracked as a known followup.

**Reason:** matches actual implementation; flags the deferred work.

### Amendment C — Decisions table row B (line 19)

**Current:**
> Photo kept for audit. `chore_verification_photos.rejected_reason text` column added so admin can record why. Same 30-day retention applies.

**Proposed:**
> Photo kept for audit. Rejection reason stored in the **existing** `chores.rejected_reason` column (from 0001:107) — single source of truth. Migration 0016 deliberately did NOT add a new column on `chore_verification_photos`. The `approve_chore` RPC writes `chores.rejected_reason` on reject. Same 30-day retention applies via `chore_verification_photos.delete_after`.

**Reason:** matches what shipped; explains why.

### Amendment D — Decisions table row D (line 21)

**Current:**
> **Honor.** Owner = household creator, set on signup, immutable. Admin = promoted by owner. Permission gates use `role IN ('owner', 'admin')`. Existing `household_setup_screen.dart:96` will be updated to insert creators as `'owner'` going forward (existing rows stay `'admin'` — no backfill).

**Proposed:**
> **Honor.** Owner = household creator, set on signup, immutable. Admin = promoted by owner. Permission gates use `role IN ('owner', 'admin')`. `household_setup_screen.dart:96` updated in Batch 3 Half A to insert creators as `'owner'` going forward. Migration 0016 **also backfilled** legacy rows: every `household_members.role='admin'` row where `auth_user_id = households.owner_user_id` was promoted to `'owner'`. Generalized + idempotent.

**Reason:** the no-backfill claim contradicts what shipped. Backfill was added during Batch 1 implementation per user direction.

### Amendment E — Database changes bullet on rejected_reason (line 68)

**Current:**
> - **`chore_verification_photos.rejected_reason text`** — nullable. Recorded by admin when rejecting a kid's submission.

**Proposed:**
> - ~~`chore_verification_photos.rejected_reason text`~~ — **deliberately omitted** from migration 0016. `chores.rejected_reason` (existed from 0001) is the single source of truth for rejection notes. `approve_chore` RPC writes it.

**Reason:** matches what shipped.

### Amendment F — Database changes bullet on pg_cron (line 69)

**Current:**
> - **30-day photo retention via pg_cron**: a scheduled job runs daily, deletes Storage objects + rows where `delete_after < now()`. `delete_after` is set when status transitions to `verified` OR `rejected` (now + interval '30 days').

**Proposed:**
> - **30-day photo retention**: `delete_after` column is written correctly by `approve_chore` (RPC sets it to `now() + interval '30 days'` on both verify and reject). The actual scheduled-cleanup job is **deferred** until (a) pg_cron is enabled on the Supabase project, and (b) the Storage-object deletion path is designed (the DB-row delete alone would leave orphan files in the `chore-photos` bucket — likely an Edge Function call inside the cron body). No deadline pressure; the chore-photo flow doesn't ship until Batch 4 and no photos exist yet, so we have 30+ days of operational runway after Batch 4 ships.

**Reason:** matches what shipped + flags the open design pass for the cron migration.

### Amendment G — RLS section, helper name + chores wording + photos wording (lines 75-77)

**Current:**
> - New helper function `public.is_household_kid(target_household_id uuid)` returning boolean, mirroring `is_household_member` and `is_household_admin`.
> - `chores`: verify/approve actions move behind a SECURITY DEFINER RPC `approve_chore(p_chore_id, p_approved, p_reason)` that checks caller is `is_household_admin`. RLS for UPDATE tightened to admin-only on the `status` column path.
> - `chore_verification_photos`: kid INSERT must reference their own member_id; admin UPDATE allowed for `rejected_reason`; SELECT remains household-scoped.

**Proposed:**
> - New helper function `public.is_member_kid(p_member_id uuid)` returning boolean. **Replaces the originally-proposed `is_household_kid(target_household_id)`** which was architecturally impossible (sub_profiles have `auth_user_id IS NULL`, so a helper filtering on `auth.uid()` could never match a kid). `is_member_kid` takes a member_id directly and is used inside SECURITY DEFINER RPCs.
> - `chores`: verify/approve/complete actions move behind SECURITY DEFINER RPCs (`approve_chore`, `complete_chore_self`, `submit_kid_chore_with_photo`). RLS for INSERT/UPDATE/DELETE all tightened to `is_household_admin` — the whole row, since Postgres RLS is row-level not column-level. Adult and kid completion both go through RPCs.
> - `chore_verification_photos`: INSERT fully blocked at the RLS layer (`WITH CHECK (false)`); kid submissions go through `submit_kid_chore_with_photo` RPC (SECURITY DEFINER bypass). UPDATE/DELETE admin-only.

**Reason:** matches what shipped + explains the renamed helper and the actually-shipped RLS approach.

### Amendment H — App changes bullet 1 (Permissions helper list, line 87)

**Current:**
> - **Permissions helper at `apps/mobile/lib/utils/permissions.dart`** — exports `isAdmin(membership)`, `isKid(membership)`, `isOwner(membership)`, and action-named helpers (`canEditHousehold`, `canVerifyChores`, `canManageMembers`, `canManageRewards`, `canApproveRequests`). The 14 existing `role == 'admin'` gates migrate to this helper. New gates throughout the kid-permissions UI use it too.

**Proposed:**
> - **Permissions helper at `apps/mobile/lib/utils/permissions.dart`** (Batch 3 Half A) — exports identity helpers (`isAdmin`, `isKid`, `isOwner`) and 10 action helpers (`canEditHousehold`, `canVerifyChores`, `canEditAnyChore`, `canManageMembers`, `canInviteMembers`, `canManageRewards`, `canDecideRequests`, `canManageNecessityCategories`, `canManageBilling`, `canManageAnnouncements`). All action helpers delegate to `isAdmin` today; the named helpers exist so call sites document intent and so per-action permissions can tighten one without touching the others. 11 existing role gates across 9 screens migrated to the helper in Half A. 5 display-only role reads intentionally NOT migrated (they need three-way role distinction for badges).

**Reason:** matches what shipped + describes design rationale.

### Amendment I — App changes bullet 3 (owner backfill claim, line 89)

**Current:**
> - **Owner role wiring**: `household_setup_screen.dart` updated to insert household creator with `'role': 'owner'`. Existing rows that say `'admin'` for creators are NOT backfilled in this workstream (out of scope). Permission gates always accept `('owner', 'admin')`.

**Proposed:**
> - **Owner role wiring**: `household_setup_screen.dart` updated in Batch 3 Half A to insert household creator with `'role': 'owner'`. Migration 0016 **also backfilled** legacy creator rows (`role='admin'` AND `auth_user_id = households.owner_user_id` → `role='owner'`). Permission gates always accept `('owner', 'admin')`.

**Reason:** matches what shipped.

### Amendment J — App changes bullet 8 (kid chore completion, line 96)

**Current:**
> - **Kid chore completion** opens the camera instead of just updating status. Photo uploads to the `chore-photos` bucket, row inserts into `chore_verification_photos`, status transitions to `pending_verification`. Adults retain the no-photo path.

**Proposed:**
> - **Chore completion (Batch 3 Half B + Batch 4)**: All chore completions now go through RPCs (Half B).
>   - **Adult self-complete** (Half B): tapping Complete on own chore calls `complete_chore_self` RPC → status goes directly to `'verified'` (no admin step; points awarded immediately). This is a behavior change from pre-Half-B where adult completions went through `'pending_verification'`.
>   - **Admin approve / reject** (Half B): the admin verify flow on a kid's pending submission calls `approve_chore` RPC. Reject sets `status='rejected'` (final until Batch 4's Re-do affordance lands).
>   - **Kid completion (Batch 4)**: opens the camera; photo uploads to the `chore-photos` bucket; status goes to `'pending_verification'`; admin reviews. Half B left a TODO in `_completeChore` and `_quickUpdateStatus` pointing at this. Today the kid path is a direct UPDATE that works only because the JWT is the adult's — Batch 4 replaces it with `submit_kid_chore_with_photo` RPC.

**Reason:** matches what shipped (Half B reality) + flags Batch 4's remaining work.

### Amendment K — Batch plan table row 1 (line 113)

**Current:**
> Migration 0016 (schema): `meal_requests`, `necessity_categories` (with 4 default rows per household), `shopping_items` 3 new columns, `household_members.music_app_preference`, `chore_verification_photos.rejected_reason`, `is_household_kid()` RLS helper, daily pg_cron job for 30-day photo retention

**Proposed:**
> ✅ **Shipped** as migration 0016 + commit `eed3930` on `feat/kid-perms-schema-2026-05-22`. Schema: `meal_requests`, `necessity_categories` (with 4 default rows per household via trigger + backfill), `shopping_items` 3 new columns, `household_members.music_app_preference`. Owner-role backfill for legacy `'admin'` creator rows. **Deliberately omitted**: `chore_verification_photos.rejected_reason` (use `chores.rejected_reason`), `is_household_kid()` (replaced by `is_member_kid(p_member_id)` in Batch 2), daily pg_cron job (deferred — pg_cron not enabled + storage cleanup design pending).

**Reason:** captures actual shipped state, including deliberate omissions.

### Amendment L — Batch plan table row 2 (line 114)

**Current:**
> Migration 0017 (RLS): tighten chores verify, chore_verification_photos inserts, rewards CRUD, meal_plans kid-insert block, shopping_items wishlist enforcement, meal_requests policies, necessity_categories policies, analytics defense. Plus SECURITY DEFINER RPCs: `approve_chore`, `add_shopping_item`, `submit_kid_chore_with_photo`, `create_meal_request`, `decide_meal_request`.

**Proposed:**
> ✅ **Shipped** as migrations 0017 + 0018 (anon hotfix) + commit `078e25e` on `feat/kid-perms-rls-rpcs-batch-2-2026-05-22`. RLS tightening on 8 tables (chores, chore_verification_photos, rewards, meal_plans, shopping_items, meal_requests, necessity_categories, analytics_events). 6 SECURITY DEFINER RPCs (one more than originally planned): `approve_chore`, `complete_chore_self` (**added during implementation**, per Q3 — adult self-complete after admin-only RLS lockdown), `submit_kid_chore_with_photo`, `add_shopping_item`, `create_meal_request`, `decide_meal_request`. Plus `is_member_kid(p_member_id)` helper. Migration 0018 hotfix added `REVOKE EXECUTE ... FROM anon` for all 6 RPCs (Supabase default-grants EXECUTE to anon on every public function).

**Reason:** captures the 6th RPC + the 0018 hotfix + actual commit references.

### Amendment M — Batch plan table row 3 (line 115)

**Current:**
> `apps/mobile/lib/utils/permissions.dart` — new Dart helper module. Migrate the 14 existing `role == 'admin'` gates to the helper. Update `household_setup_screen.dart:96` to insert creator as `'owner'`.

**Proposed (split into 3a + 3b):**
> ✅ **Batch 3 Half A (shipped)** as commit `dbeea55` on `feat/kid-perms-helper-batch-3-half-a-2026-05-22`. New `apps/mobile/lib/utils/permissions.dart` with 3 identity + 10 action helpers. 11 functional role gates across 9 screens migrated to the helper (5 display-only role reads intentionally left alone). `household_setup_screen.dart:96` insert flipped from `'admin'` to `'owner'`.
>
> ✅ **Batch 3 Half B (shipped)** as commit `34d9079` on `feat/kid-perms-chore-rpcs-batch-3-half-b-2026-05-22`. Migrated `_verifyChore` to `approve_chore` RPC (~70 → ~17 lines; kid/adult points branching now server-side). `_completeChore` branches on `Permissions.isKid(_myMembership)`: adult → `complete_chore_self` RPC, kid → direct UPDATE with TODO (Batch 4 replaces). `_quickUpdateStatus` in chore_detail similarly branched. `_saveChore.canEdit` tightened to admin-only. `'rejected'` status mapping added to chore_detail status maps. Required to unblock non-admin adult completion after Batch 2's chores RLS lockdown.

**Reason:** captures both halves + the rationale for splitting.

### Amendment N — Resolved questions #5, #7, #9 (lines 141-149)

Same updates as Amendments B, C, D respectively; the Resolved questions section duplicates the Decisions table content. Either trim duplication or update both.

### Amendment O — Roadmap section (lines 155-161)

**Current:**
> 1. ✅ Pass 1 — fix work and stable baseline merge to main (`v0.1.0-baseline`, tagged 2026-05-21).
> 2. ✅ Pass 2 — security and data integrity, in progress. PIN hashing landed on `fix/pin-hashing-pass-2-2026-05-22` (commits `0904108` and `18fd24e`); broader RLS audit and any remaining schema consistency follow.
> 3. ⏳ This kid-permissions workstream as a feature batch on its own branch off main, after Pass 2 merges. 8 batches planned (see "Batch plan" section).

**Proposed:**
> 1. ✅ Pass 1 — fix work and stable baseline merge to main (`v0.1.0-baseline`, tagged 2026-05-21).
> 2. ✅ Pass 2 — security and data integrity. PIN hashing merged as `v0.2.0-pin-security` (tagged 2026-05-22). Broader RLS audit happens as part of Pass 3 (this workstream).
> 3. ⏳ Pass 3 — this kid-permissions workstream. Batches 1, 2, 3 Half A, 3 Half B complete on stacked feature branches (unmerged). Batches 4-8 not yet started.
> 4. ⏳ Pass 4 — Today Dashboard. Concept stub captured at `/audits/2026-05-pass-4-today-dashboard-spec.md`; design deferred until Pass 3 ships.

**Reason:** matches actual state; adds Pass 4 placeholder.

### Amendment P — Add a "Lessons learned" section (new)

**Proposed (new section, after Implementation notes or in roadmap area):**

> ## Implementation lessons captured during Batches 1-3
>
> Three Supabase-specific patterns surfaced and should be applied to all future RPC migrations:
>
> 1. **pgcrypto schema qualification.** Pass 2's PIN hashing arc (migrations 0013→0014→0015) discovered that pgcrypto's `crypt` and `gen_salt` live in the `extensions` schema, not `public`. SECURITY DEFINER functions with `SET search_path = public` can't see them. Always qualify as `extensions.crypt(...)`, `extensions.gen_salt(...)`.
>
> 2. **`'bf'::text` cast on `gen_salt`.** Postgres treats unquoted string literals as `unknown`; the overload resolver can't bridge to `gen_salt(text, integer)` without an explicit cast.
>
> 3. **Revoke EXECUTE from anon explicitly.** Supabase default-grants `EXECUTE` to `anon`, `authenticated`, AND `service_role` on every public-schema function. `REVOKE ALL FROM PUBLIC` does NOT catch these per-role grants. Use `REVOKE ALL FROM PUBLIC, anon`. Verify with both `has_function_privilege('anon', ...)` AND `information_schema.routine_privileges` — they can disagree.
>
> These are non-obvious to developers who think in vanilla Postgres terms. Migration 0014, 0015, and 0018 each landed as hotfixes because the original migrations missed one of these.

**Reason:** preserves the lessons-learned cost; future RPC migrations are less likely to repeat the mistakes.

## Phase 4 — Sections that stay unchanged

These sections are still accurate and don't need amending:

- **Lines 7-23 (Decisions table) rows 1, 2, 3, 4, 6/A, 8/C, 10/E, 11/F** — implementation matched these decisions.
- **Lines 25-31 (Background)** — first sentence still correct; second-to-last sentence ("This spec defines the distinction") is fine. Could be sharpened (see 2i) but not required.
- **Lines 33-54 (Allowed / Disallowed actions)** — aspirational, didn't drift. Batches 4-8 are still working toward these.
- **Lines 60-66 (Implementation notes → DB changes, first three bullets — shopping_items extension, meal_requests table, necessity_categories table, music_app_preference column)** — all shipped as described.
- **Lines 78-83 (RLS for rewards, meal_plans, shopping_items, meal_requests, necessity_categories, analytics)** — all shipped as described.
- **Lines 90-97 (App changes bullets 4-8 except bullet on kid chore completion)** — Pending Requests, Kid recipe library, Kid shopping list, Kid profile screen — all still pending (Batches 4-6, 8); descriptions still match intent.
- **Lines 99-107 (Meal-decision notification channels)** — still future intent (Batch 6).
- **Lines 116-120 (Batch plan rows 4-8)** — still future intent; mostly accurate (see Phase 5 for cross-check).
- **Lines 128-137, 139-148, 151-153 (Resolved questions #1, 2, 3, 4, 6, 8, 10, 11)** — unchanged.

About 60% of the spec is unchanged.

## Phase 5 — Batch 4-8 cross-check

| Batch | Current spec description | Cross-check vs Batches 1-3 reality | Verdict |
|---|---|---|---|
| **4** — Chore submit-with-photo | Kid camera path; admin review with photo viewer + reject reason field | Need to add: (a) replace kid TODOs in `_completeChore` and `_quickUpdateStatus`; (b) the Re-do affordance for rejected chores (Half B introduced `'rejected'` as a final status); (c) `'rejected'` UI mapping in chore_dashboard (Half B added it to chore_detail only); (d) Option B query broadening if not picked up in a separate fix-it (the verified-chores branch is doing UI gate only). | **Expand scope** — additions documented in Half B implementation report |
| **5** — Wishlist + necessity | Branch 4 shopping insert sites; Pending Wishlist UI; Edit Necessity Categories screen | No drift. `add_shopping_item` RPC ready (Batch 2); necessity defaults seeded (Batch 1). | OK as-is |
| **6** — Meal requests + APNs push | Recipe detail "Request this meal" + admin pending dashboard + 3-channel notify + APNs setup | No drift. `create_meal_request` and `decide_meal_request` RPCs ready (Batch 2). | OK as-is |
| **7** — Kind-based UI hardening | Audit 14 migrated role gates + add kind defense-in-depth + kid-only badges | Slight wording fix: Half A migrated 11 functional gates (not 14). The other 5 are display-only and explicitly NOT migrated. | Minor wording fix |
| **8** — Music app deep link | Play Music button + app picker + url_launcher | No drift. `music_app_preference` column ready (Batch 1). `url_launcher` already in pubspec. | OK as-is |

Plus a new line item (not currently a batch):

- **Batch 9 (or part of a Pass-2.x cleanup)** — pg_cron photo cleanup migration. After (a) pg_cron is confirmed enabled, (b) Storage cleanup design pass complete. Could land before or after Batches 4-8.

## Open questions

1. **How much of the "deliberate omissions" detail belongs in the spec vs the audit history?** The spec could either:
   - Capture every divergence in-line ("✗ NOT added because…")
   - Stay forward-looking and refer to the audit/implementation reports for divergence rationale
   
   Recommendation: in-line for the small set of divergences (helper rename, column omission, pg_cron deferral, 6th RPC, owner backfill) so future readers don't have to cross-reference audits to know what shipped. Long form lives in the per-batch audit docs.

2. **Should the spec keep the original Status block as historical record, or rewrite as "current state"?** Recommendation: keep the date trail (`Date captured`, `Decisions resolved`, `Spec amended`) but replace the `Status:` line with current state.

3. **Should the spec amendment commit be done on the current branch (`docs/kid-perms-spec-amendment-2026-05-24`), or stacked on top of Half B's branch so it travels with the kid-perms code?** Either works; the docs change is mostly text and doesn't depend on the code being merged. Recommendation: stay on current branch (off main) so it can land independently if you'd rather merge it first.

4. **Should the Resolved Questions section be trimmed?** It duplicates content from the Decisions table. Could be reduced to a "see Decisions table at top" pointer. Out of scope for this amendment unless you want to compress.

## Next steps

1. **You review** the 16 proposed amendments (A through P) and pick which to apply / skip / modify.
2. **I write the amended spec** as a single edit pass, with all approved changes integrated.
3. **Optional**: also touch up `Resolved questions` section to mirror any Decisions table changes (or leave it as duplication; flag).
4. **Commit + push** the amended spec on this branch.
5. **Apply Phase 5 Batch 4 expansion** — add the Re-do affordance, the kid-TODO replacement, and `'rejected'` UI mapping in chore_dashboard to Batch 4 scope so the next investigation pass for Batch 4 starts from an accurate baseline.

After this lands, the spec accurately reflects what's in the codebase up through Batch 3 Half B, and Batch 4 work has a corrected target.
