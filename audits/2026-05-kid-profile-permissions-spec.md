# Kid Profile Permission Model — Product Spec

Date captured: 2026-05-21
Decisions resolved: 2026-05-22
Spec amended: 2026-05-24
Status: Batches 1, 2, 3 Half A, 3 Half B complete on stacked branches; Batches 4-8 pending

## Decisions (2026-05-22)

The 5 open questions originally listed in the spec plus the 6 surfaced during the kid-permissions investigation (`/audits/2026-05-kid-permissions-investigation.md`) are resolved as follows. Implementation notes and the batch plan below assume these answers.

| # | Source | Question | Decision |
|---|---|---|---|
| 1 | spec | Necessity categories default set | Ship 4 defaults via migration: **Hygiene**, **School Supplies**, **Basic Groceries**, **Medication**. Admins can edit/delete per household. |
| 2 | spec | Wishlist approval UX | Admin approve flips `is_wishlist = false` on the existing `shopping_items` row. Active shopping list view filters `where is_wishlist = false`, so the item appears automatically. No row migration, no separate list. |
| 3 | spec | Meal request decision — notification, silence, or auto-archive? | **Three channels:** activity feed entry, "My recent requests" view on recipe library, AND iOS push notification (if push is enabled in the app). Same channels fire on both approve and deny. Auto-archive after 30 days. |
| 4 | spec | Music app preference storage | Per-kid via new `household_members.music_app_preference text` column. A kid switching devices keeps their choice. |
| 5 | spec | Chore photo retention (COPPA) | 30 days post-decision (verified OR rejected). **As implemented (Batch 2):** `approve_chore` RPC writes `delete_after = now() + interval '30 days'` correctly. **Deferred:** the actual deletion job — pg_cron isn't enabled on the project and Storage-object cleanup needs an Edge Function design pass. Tracked as a known followup. |
| A | investigation | Adult photo requirement | Optional for adults, **required for kids**. Adult "Complete" button stays as today; kid "Complete" button opens the camera. |
| B | investigation | Reject-photo handling | Photo kept for audit. **As implemented (Batch 1 + 2):** `chore_verification_photos.rejected_reason` column was **deliberately not added** — `chores.rejected_reason` (existed from migration 0001:107) is used instead as the single source of truth. `approve_chore` RPC writes it on reject. Same 30-day retention applies via `chore_verification_photos.delete_after`. |
| C | investigation | Enforcement: RPC vs RLS `WITH CHECK` | **SECURITY DEFINER RPCs** for kid-attributable writes (chore submit, wishlist add, meal request), consistent with the Pass 2 PIN pattern. RLS policies still tighten but the RPCs carry the kid-vs-adult + necessity-category branching logic. |
| D | investigation | Owner enum value — retire or honor? | **Honor.** Owner = household creator, set on signup, immutable. Admin = promoted by owner. Permission gates use `role IN ('owner', 'admin')`. **As implemented:** `household_setup_screen.dart:96` updated in Batch 3 Half A to insert creators as `'owner'` going forward. Migration 0016 step 7 **also backfilled** legacy rows (`role='admin'` AND `auth_user_id = households.owner_user_id` → `'owner'`). Generalized + idempotent. |
| E | investigation | Existing role-based gates: keep, augment with kind, or replace? | **Augment.** Centralize via new `apps/mobile/lib/utils/permissions.dart` exporting `isAdmin(membership)`, `isKid(membership)`, `canEditChore(membership)`, etc. Existing 14 role gates migrate to use the helper; new kind-based gates added where defense in depth matters. |
| F | investigation | Pending Requests UI shape | **One unified Pending Requests dashboard** showing pending chore verifications, pending wishlist items, and pending meal requests in one place. Lives where the existing chore_dashboard:347 "Pending Verification" section is, expanded into a tabbed or grouped view. |

## Background

Honeydo supports two `member_kind` values:
- `adult_auth_user` — adult users who log in via Supabase auth
- `sub_profile` — kid profiles guarded by a PIN, switched into from an adult's session

Currently all members share the same `household_role` ('owner', 'admin', 'member') and the same RLS policies. There is no enforced distinction between what an adult-member and a kid-sub-profile can do. This spec defines the distinction.

## Kid (sub_profile) permissions

### Allowed actions

1. View own chores. Kids see chores assigned to them in the Chores tab.
2. Submit chore completion with a photo. Kid taps "Complete" → camera opens → photo uploaded to chore-photos bucket → row added to chore_verification_photos → chore status moves to pending_verification. Admin reviews and verifies/rejects.
3. Add to a wishlist shopping bucket. Kids cannot add directly to the household shared shopping list. They add to a "wishlist" — items there require admin approval before they move to the real list. Exception: a small set of "necessity" categories (hygiene, school supplies) can go directly without approval. The category set is configurable per-household by the admin.
4. Add events to the household calendar. Same as adults. No approval needed.
5. Request a meal from the recipe library. Kid taps a recipe → "Request this meal" → row added to a meal_requests table (new) → shows up on admin dashboard as a pending request → admin approves (creates a meal_plan entry) or denies (with optional reason).
6. Open a music player app on the device. Settings or profile screen has a "Play music" button → opens the kid's preferred music app via URL scheme deep link (Spotify, Apple Music, YouTube Music). Doesn't play in-app — it just hands off to the system app the kid chose.

### Disallowed actions

1. Edit household settings (name, theme, emoji, subscription).
2. Approve / verify chores.
3. Add or remove members; edit other members' profiles.
4. Create, edit, or delete rewards.
5. Approve or deny their own meal requests.
6. Add directly to the shared shopping list (except in approved necessity categories).
7. View or change billing / subscription / authorize.net details.
8. Access the audit log or analytics.
9. Sign up new auth users or invite new household members.

## Implementation notes

### Database changes

- **Extend `shopping_items`** with three columns (single-table wishlist model — no separate `shopping_wishlist_items` table):
  - `is_wishlist boolean not null default false`
  - `approved_by_member_id uuid references public.household_members(id) on delete set null`
  - `approved_at timestamptz`
  - Admin approve flips `is_wishlist = false`; active list view filters `where is_wishlist = false`.
- **New table `meal_requests`**: `id`, `household_id`, `requested_by_member_id`, `recipe_id` (references `household_recipes`), `requested_for_date date`, `meal_type meal_type`, `status text default 'pending' check (status in ('pending','approved','denied'))`, `decided_by_member_id`, `decided_at`, `decided_note text`, `created_at`. Auto-archive (soft-delete or hard-delete) after 30 days. On admin decide, three notification channels fire (see "Meal-decision notification channels" below).
- **New table `necessity_categories`**: `(household_id, category)` composite PK. Ship 4 default rows per household on signup (Hygiene, School Supplies, Basic Groceries, Medication) via a trigger on household insert or via the household-setup RPC.
- **`household_members.music_app_preference text`** — nullable. Examples: `'spotify'`, `'apple_music'`, `'youtube_music'`. The app maps the string to a launch URL.
- ~~**`chore_verification_photos.rejected_reason text`**~~ — **deliberately omitted** from migration 0016. The existing `chores.rejected_reason` column (from 0001:107) is the single source of truth for rejection notes. `approve_chore` RPC writes it.
- **30-day photo retention**: `delete_after` column is written correctly by `approve_chore` (RPC sets it to `now() + interval '30 days'` on both verify and reject — shipped Batch 2). The actual scheduled-cleanup job is **deferred** until (a) pg_cron is enabled on the Supabase project, and (b) the Storage-object deletion path is designed (the DB-row delete alone would leave orphan files in the `chore-photos` bucket — likely an Edge Function call inside the cron body). No deadline pressure; the chore-photo flow doesn't ship until Batch 4 and no photos exist yet, so we have 30+ days of operational runway after Batch 4 ships.

### RLS policy changes

Almost every existing table policy is `for all using is_household_member(household_id)` — too permissive for the kid model. The tightening:

- New helper function `public.is_member_kid(p_member_id uuid)` returning boolean. **Replaces the originally-proposed `is_household_kid(target_household_id)`** which was architecturally impossible — sub_profiles have `auth_user_id IS NULL` so a helper filtering on `auth.uid()` could never match. `is_member_kid` takes a member_id directly and is used inside SECURITY DEFINER RPCs.
- `chores`: verify/approve/complete actions move behind SECURITY DEFINER RPCs (`approve_chore`, `complete_chore_self`, `submit_kid_chore_with_photo`). RLS for INSERT/UPDATE/DELETE all tightened to `is_household_admin` — the whole row, since Postgres RLS is row-level not column-level. Adult and kid completion both go through RPCs.
- `chore_verification_photos`: INSERT fully blocked at the RLS layer (`WITH CHECK (false)`); kid submissions go through `submit_kid_chore_with_photo` RPC (SECURITY DEFINER bypass). UPDATE/DELETE admin-only; SELECT remains household-scoped.
- `rewards`: SELECT remains household-scoped; INSERT/UPDATE/DELETE admin-only.
- `meal_plans`: kid INSERT blocked. Kid inserts go through `meal_requests`; admin-approved requests are inserted into `meal_plans` by the approve RPC.
- `shopping_items`: kid INSERT goes through SECURITY DEFINER RPC `add_shopping_item(p_household_id, p_member_id, p_name, p_category, ...)` that sets `is_wishlist=true` unless `category` is in `necessity_categories` for the household. Adult INSERT can stay direct (RLS `WITH CHECK` ensures adult-only direct insert with `is_wishlist=false`).
- `meal_requests`: kids INSERT their own; SELECT own + same-household; admins SELECT all and UPDATE to decide.
- `necessity_categories`: SELECT household-scoped (kids need to know which categories bypass wishlist); INSERT/UPDATE/DELETE admin-only.
- `analytics_events`: tighten to admin-only as defense-in-depth (Disallowed #8).

### App changes

- **Permissions helper at `apps/mobile/lib/utils/permissions.dart`** (Batch 3 Half A) — exports 3 identity helpers (`isKid`, `isAdmin`, `isOwner`) and 10 action helpers: `canEditHousehold`, `canVerifyChores`, `canEditAnyChore`, `canManageMembers`, `canInviteMembers`, `canManageRewards`, `canDecideRequests` (renamed from the original `canApproveRequests`), `canManageNecessityCategories`, `canManageBilling`, `canManageAnnouncements`. All action helpers delegate to `isAdmin` today; the named helpers exist so call sites document intent and so per-action permissions can tighten one without touching the others. 11 functional role gates across 9 screens migrated in Half A; 5 display-only role reads intentionally NOT migrated (they need three-way role distinction for badges).
- **ActiveMemberService** already tracks active member. Every kid-attributable write passes `active_member_id` as a parameter to the SECURITY DEFINER RPC.
- **Owner role wiring**: `household_setup_screen.dart` updated in Batch 3 Half A to insert household creator with `'role': 'owner'`. Migration 0016 step 7 **also backfilled** legacy creator rows (`role='admin'` AND `auth_user_id = households.owner_user_id` → `role='owner'`). Permission gates always accept `('owner', 'admin')`.
- **Unified Pending Requests dashboard**: the existing admin "Pending Verification" section on the chore dashboard expands into a "Pending Requests" tab/grouping that surfaces:
  - Pending chore verifications (with photo viewer for kid submissions)
  - Pending wishlist items (with category, requester, approve / deny)
  - Pending meal requests (with recipe, requested date/meal, requester, approve / deny + note field)
- **Kid recipe library** adds a "Request this meal" button on each recipe (visible only when active member is sub_profile). Adults still see "Add to meal plan" (the existing flow).
- **Kid shopping list** branches the 4 existing insert sites — `shopping_list_screen.dart:789`, `:1081`, `meal_planner_screen.dart:712`, `recipe_detail_screen.dart:266` — to call `add_shopping_item` RPC when active member is sub_profile. Adults retain direct insert.
- **Chore completion (Batch 3 Half B + Batch 4)**: all chore completions now go through RPCs (Half B established the pattern).
  - **Adult self-complete (shipped Half B)**: tapping Complete on own chore calls `complete_chore_self` RPC → status goes directly to `'verified'` (no admin step; points awarded immediately). This is a behavior change from pre-Half-B where adult completions also went through `'pending_verification'`.
  - **Admin approve / reject (shipped Half B)**: the admin verify flow calls `approve_chore` RPC. Reject sets `status='rejected'` (final until Batch 4's Re-do affordance lands; admin workaround in the gap is delete + recreate).
  - **Kid completion (Batch 4)**: opens the camera; photo uploads to the `chore-photos` bucket; status transitions to `'pending_verification'`; admin reviews. Half B left a TODO in `_completeChore` and `_quickUpdateStatus` pointing at this. Today the kid path is a direct UPDATE that works only because the JWT is the parent adult's — Batch 4 replaces it with `submit_kid_chore_with_photo` RPC.
- **Kid profile screen** new "Play Music" button + a small picker for music app preference. Uses `url_launcher` (already in pubspec) for the deep link.

### Meal-decision notification channels

When the admin approves or denies a meal request via the `decide_meal_request` RPC (Batch 2), the kid is notified through **three independent channels** with the same content. Message format example: "Mom approved your Mac and Cheese request" or "Mom denied your taco request: not on the meal plan budget."

1. **Activity feed entry** on the kid's side. New row in the activity feed surface (existing infrastructure in `activity_feed_screen.dart`). Member kind tagging already exists for activity rows.
2. **"My recent requests" view** on the kid-side recipe library. A new small section listing the kid's `meal_requests` rows with status (pending/approved/denied) and `decided_note` rendered when present.
3. **iOS push notification** with the same message. Honors the user's `notification_preferences` (existing table) — if push is disabled, this channel is skipped silently; the activity feed entry and recent-requests view still appear.

This is the first push-enabled feature in the app. Push infrastructure (APNs setup, device token registration via the existing `device_tokens` table, server-side dispatch) lands in Batch 6 and is designed to be reusable for chore-approval and wishlist-approval notifications in later passes.

## Batch plan

| Batch | Scope | Complexity | Dependencies | Branch suggestion |
|---|---|---|---|---|
| **1** ✅ | Migration 0016 (schema): `meal_requests`, `necessity_categories` (with 4 default rows seeded per household via trigger + backfill), `shopping_items` 3 new columns (`is_wishlist`, `approved_by_member_id`, `approved_at`), `household_members.music_app_preference`. **Plus owner-role backfill** (added during implementation per user direction). **Deliberately omitted**: `is_household_kid()` (replaced by `is_member_kid(p_member_id)` in Batch 2), `chore_verification_photos.rejected_reason` (uses existing `chores.rejected_reason`), pg_cron cleanup job (deferred — pg_cron not enabled + storage cleanup design pending). | Low (pure SQL) | None | Shipped: commit `adb1b0a` on `feat/kid-perms-schema-2026-05-22` |
| **2** ✅ | Migrations 0017 + 0018 hotfix (RLS): tighten chores, chore_verification_photos, rewards, meal_plans, shopping_items, meal_requests, necessity_categories, analytics_events. Plus **6 SECURITY DEFINER RPCs** (one more than originally planned): `approve_chore`, `complete_chore_self` (**added during implementation** per Q3 — non-admin adult self-complete path after admin-only RLS lockdown), `submit_kid_chore_with_photo`, `add_shopping_item`, `create_meal_request`, `decide_meal_request`. Plus `is_member_kid(p_member_id)` helper. Migration 0018 hotfix added `REVOKE EXECUTE ... FROM anon` for all 6 RPCs (Supabase default-grants EXECUTE to anon on every public-schema function — see `/audits/supabase-patterns-learned.md` pattern 3). | Medium (many policies + RPCs, careful testing) | Batch 1 | Shipped: commit `5f0cf13` on `feat/kid-perms-rls-rpcs-batch-2-2026-05-22` |
| **3 Half A** ✅ | `apps/mobile/lib/utils/permissions.dart` — new Dart helper module (3 identity + 10 action helpers). Migrate 11 functional `role == 'admin'` gates across 9 screens to the helper (5 display-only role reads intentionally left alone). Update `household_setup_screen.dart:96` to insert creator as `'owner'`. | Low-Medium (mechanical) | None — can land independently | Shipped: commit `2790f48` on `feat/kid-perms-helper-batch-3-half-a-2026-05-22` |
| **3 Half B** ✅ | Migrate chore mutation flows to Batch 2's RPCs. `_verifyChore` → `approve_chore` RPC (~70 → ~17 lines; kid/adult points branching now server-side). `_completeChore` branches on `Permissions.isKid(_myMembership)`: adult → `complete_chore_self` RPC, kid → direct UPDATE with TODO (Batch 4 replaces). `_quickUpdateStatus` two-path migration (Complete + Verify chips). `_saveChore.canEdit` tightened to admin-only. `'rejected'` UI mapping added to chore_detail status maps. **Required** to unblock non-admin adult completion after Batch 2's chores RLS lockdown. | Medium | Batches 1+2+3 Half A | Shipped: commit `34d9079` on `feat/kid-perms-chore-rpcs-batch-3-half-b-2026-05-22` |
| **4** | Chore submit-with-photo flow. Scope items: (1) **original** — kid camera path via `image_picker` + `chore-photos` Storage upload + `submit_kid_chore_with_photo` RPC integration. (2) **carry-from-Half-B** — replace the kid TODO'd direct-UPDATE paths in `chore_dashboard_screen.dart:_completeChore` and `chore_detail_screen.dart:_quickUpdateStatus` with `submit_kid_chore_with_photo` RPC calls. (3) **new** — Re-do affordance for rejected chores (kid sees Re-do button on a `'rejected'` chore card; tap reverts status to `'assigned'` and clears `chores.rejected_reason`). (4) **new** — `'rejected'` status UI mapping in `chore_dashboard_screen.dart` rendering (Half B added it to chore_detail; Batch 4 extends to dashboard). (5) **original** — admin reject-with-reason UI: text field for `p_reason` in the rejection flow (Half B passes `null`). (6) **original** — photo viewer for admin reviewing kid submissions. | Medium-High | Batches 1+2+3 Half A+B | `feat/kid-perms-chore-photo` |
| **5** | Wishlist + necessity flow: branch the 4 shopping insert sites to use the RPC; admin "Pending Wishlist" section in Pending Requests; admin "Edit Necessity Categories" screen. | Medium | Batches 1+2+3 (uses permissions helper) | `feat/kid-perms-wishlist` |
| **6** | Meal requests flow: "Request this meal" on recipe detail (kid-only via permissions helper); admin "Pending Meal Requests" section in Pending Requests; approve creates `meal_plans` row, deny updates status + decided_note; kid "My recent requests" view; activity feed entry on decide; **iOS push notification on decide**. Includes APNs setup and device-token registration. **This is the first push-enabled feature; subsequent batches may retrofit push to chore approvals and wishlist approvals.** | Medium-High (now includes push infrastructure) | Batches 1+2+3 | `feat/kid-perms-meals` |
| **7** | Kind-based UI hardening: audit the 14 migrated role gates and the new helper to add `kind == 'sub_profile'` checks for defense-in-depth where the spec's Disallowed actions warrant it. Add kid-only badges, hide admin-only screens fully from sub_profile sessions. | Low-Medium | Batch 3 | `feat/kid-perms-ui-hardening` |
| **8** | Music app deep link: new "Play Music" button on kid profile screen with app picker; `url_launcher` deep links; preference stored in `household_members.music_app_preference`. | Low (single screen + dep already in pubspec) | Batch 1 (column) | `feat/kid-perms-music` |

Batches 1+2 must be first. Batches 4/5/6 are independent of each other and can run in parallel by different sessions. Batch 3 is foundational for the UI batches but has no schema/RLS dependency, so it can land any time after Batch 1+2 (or even before — it's pure Dart). Batches 7 and 8 are smallest and can ship in either order at the end.

## Resolved questions

The original "Open questions to resolve before building" section's 5 questions, plus the 6 surfaced by the kid-permissions investigation, are now answered. Detail beyond the table at the top of this doc:

1. **Necessity categories default set** — Ship four: Hygiene, School Supplies, Basic Groceries, Medication. Inserted per household at signup (either via trigger on `households` INSERT, or inside the household-setup RPC if one exists). Admins can edit or delete per their household.

2. **Wishlist approval UX** — Item stays in `shopping_items` always. `is_wishlist=true` means "pending kid request"; admin approve flips to `false` and the item appears in the active shopping list view (which filters `where is_wishlist = false`). No row migration, no separate list table. Admins can deny by deleting the row (DELETE is admin-only via RLS).

3. **Meal request decision UX** — On admin approve OR deny, three independent channels notify the kid with the same message (e.g., "Mom approved your Mac and Cheese request" / "Mom denied your taco request: not on the meal plan budget"):
   - Activity feed entry on the kid's side (existing infrastructure in `activity_feed_screen.dart`).
   - "My recent requests" view on the kid-side recipe library: list of the kid's `meal_requests` rows with status (pending/approved/denied) and `decided_note` rendered if present.
   - iOS push notification, honoring `notification_preferences` — if push is off, this channel is skipped silently; the other two still appear.
   
   Auto-archive (hard-delete) after 30 days, same retention window as chore photos. Batch 6 lands the APNs setup and device-token registration; this is the first push-enabled feature.

4. **Music app preference storage** — Per-kid via `household_members.music_app_preference text` column. Survives device switches.

5. **Chore photo retention (COPPA)** — 30 days from the verification decision. **As implemented (Batch 2):** `approve_chore` RPC writes `delete_after = now() + interval '30 days'` when chore status transitions to `verified` OR `rejected`. **Deferred:** the actual scheduled-cleanup job (pg_cron) — pg_cron isn't enabled on the project and Storage-object cleanup needs an Edge Function design pass. No deadline pressure since the chore-photo flow doesn't ship until Batch 4.

6. **Adult photo requirement (Q A from investigation)** — Optional for adults, required for kids. Adult "Complete" button stays as today (status update only); kid "Complete" button opens the camera.

7. **Reject-photo handling (Q B)** — Photo kept for audit. **As implemented (Batch 1 + 2):** `chore_verification_photos.rejected_reason` was **deliberately not added** — the existing `chores.rejected_reason` column (from migration 0001:107) is used instead as the single source of truth. `approve_chore` RPC writes it on reject. Same 30-day retention applies via `chore_verification_photos.delete_after` (cron cleanup deferred — see #5).

8. **Enforcement model (Q C)** — SECURITY DEFINER RPCs for kid-attributable writes, consistent with the Pass 2 PIN pattern. RLS policies provide outer perimeter enforcement; the RPCs carry the kid-vs-adult + category-bypass branching.

9. **Owner enum value (Q D)** — Honored, not retired. Owner = household creator, immutable. Admin = promoted by owner. All permission gates accept `('owner', 'admin')`. **As implemented:** `household_setup_screen.dart:96` updated in Batch 3 Half A to insert creator as `'owner'` going forward. Migration 0016 step 7 **also backfilled** legacy rows (`role='admin'` AND `auth_user_id = households.owner_user_id` → `'owner'`) — added during Batch 1 implementation per user direction. Generalized + idempotent.

10. **Role-gate augmentation (Q E)** — Centralize via `apps/mobile/lib/utils/permissions.dart`. Migrate the 14 existing role checks to the helper. Add kind-based checks at the helper layer where the spec's Disallowed actions warrant defense-in-depth above the RLS layer.

11. **Pending Requests UI shape (Q F)** — One unified Pending Requests dashboard (chore verifications + wishlist + meal requests), expanded from the existing admin "Pending Verification" section on the chore dashboard.

## Where this fits in the roadmap

This is a Pass-3 (UX / features) item from the original audit. It is a significant cross-cutting change touching: app code, schema, RLS, and new UI patterns. Current sequencing:

1. ✅ Pass 1 — fix work and stable baseline merge to main (`v0.1.0-baseline`, tagged 2026-05-21).
2. ✅ Pass 2 — security and data integrity. PIN hashing merged to main as `v0.2.0-pin-security` (tagged 2026-05-22). Broader RLS audit happens as part of Pass 3 (this workstream, via Batch 2's tightening).
3. ⏳ Pass 3 — this kid-permissions workstream. **Batches 1, 2, 3 Half A, 3 Half B complete** on stacked feature branches (unmerged at time of amendment). **Batches 4-8 pending.** 8 batches planned total (see "Batch plan" section).
4. ⏳ Pass 4 — Today Dashboard. Concept stub captured at `/audits/2026-05-pass-4-today-dashboard-spec.md`; design deferred until Pass 3 ships.

## Supabase patterns referenced by this workstream

Three Supabase-specific gotchas surfaced during Pass 2 (PIN hashing) and Pass 3 Batch 2 (RPC migration). Documented in `/audits/supabase-patterns-learned.md`:

1. **Fully qualify pgcrypto functions** (`extensions.crypt`, `extensions.gen_salt`) — pgcrypto lives in the `extensions` schema, invisible to `SET search_path = public` functions.
2. **Explicit `::text` casts on overloaded functions** (e.g., `gen_salt('bf'::text, 8)`) — Postgres can otherwise pick the wrong overload.
3. **REVOKE EXECUTE FROM PUBLIC, anon** (not just PUBLIC) — Supabase default-grants EXECUTE to anon/authenticated/service_role on every public-schema function; REVOKE from PUBLIC alone doesn't catch the per-role grants.

Read the patterns file before writing any new SECURITY DEFINER RPC or pgcrypto-touching migration. Batch 2's migrations (0014, 0015, 0018) all landed as hotfixes because the original migrations missed one of these.
