# Kid Profile Permission Model — Product Spec

Date captured: 2026-05-21
Decisions resolved: 2026-05-22
Status: Implementation-ready (Batch 1 next, on its own branch off main after `fix/pin-hashing-pass-2-2026-05-22` lands)

## Decisions (2026-05-22)

The 5 open questions originally listed in the spec plus the 6 surfaced during the kid-permissions investigation (`/audits/2026-05-kid-permissions-investigation.md`) are resolved as follows. Implementation notes and the batch plan below assume these answers.

| # | Source | Question | Decision |
|---|---|---|---|
| 1 | spec | Necessity categories default set | Ship 4 defaults via migration: **Hygiene**, **School Supplies**, **Basic Groceries**, **Medication**. Admins can edit/delete per household. |
| 2 | spec | Wishlist approval UX | Admin approve flips `is_wishlist = false` on the existing `shopping_items` row. Active shopping list view filters `where is_wishlist = false`, so the item appears automatically. No row migration, no separate list. |
| 3 | spec | Meal request decision — notification, silence, or auto-archive? | **Three channels:** activity feed entry, "My recent requests" view on recipe library, AND iOS push notification (if push is enabled in the app). Same channels fire on both approve and deny. Auto-archive after 30 days. |
| 4 | spec | Music app preference storage | Per-kid via new `household_members.music_app_preference text` column. A kid switching devices keeps their choice. |
| 5 | spec | Chore photo retention (COPPA) | 30 days post-decision (verified OR rejected), enforced by a pg_cron job that deletes the storage object and the `chore_verification_photos` row. |
| A | investigation | Adult photo requirement | Optional for everyone. Kid and adult both see a choice: Take Photo or Skip Photo. Decision per-submission. (REVERSED 2026-05-24 — original Q6 codified "required for kids" but user intent was always optional for all. Implemented via migration 0019.) |
| B | investigation | Reject-photo handling | Photo kept for audit. `chore_verification_photos.rejected_reason text` column added so admin can record why. Same 30-day retention applies. |
| C | investigation | Enforcement: RPC vs RLS `WITH CHECK` | **SECURITY DEFINER RPCs** for kid-attributable writes (chore submit, wishlist add, meal request), consistent with the Pass 2 PIN pattern. RLS policies still tighten but the RPCs carry the kid-vs-adult + necessity-category branching logic. |
| D | investigation | Owner enum value — retire or honor? | **Honor.** Owner = household creator, set on signup, immutable. Admin = promoted by owner. Permission gates use `role IN ('owner', 'admin')`. Existing `household_setup_screen.dart:96` will be updated to insert creators as `'owner'` going forward (existing rows stay `'admin'` — no backfill). |
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
2. Submit chore completion, optionally with a photo. Kid taps "Complete" → 3-button choice (Take Photo / Skip Photo / Cancel). If "Take Photo": camera opens → photo uploaded to chore-photos bucket → row added to chore_verification_photos. If "Skip Photo": no photo upload, no row added. Either way, status moves to pending_verification. Admin reviews and verifies/rejects. (UPDATED 2026-05-24 per the Q-A reversal — was previously camera-required for kids.)
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
- **`chore_verification_photos.rejected_reason text`** — nullable. Recorded by admin when rejecting a kid's submission.
- **30-day photo retention via pg_cron**: a scheduled job runs daily, deletes Storage objects + rows where `delete_after < now()`. `delete_after` is set when status transitions to `verified` OR `rejected` (now + interval '30 days').

### RLS policy changes

Almost every existing table policy is `for all using is_household_member(household_id)` — too permissive for the kid model. The tightening:

- New helper function `public.is_household_kid(target_household_id uuid)` returning boolean, mirroring `is_household_member` and `is_household_admin`.
- `chores`: verify/approve actions move behind a SECURITY DEFINER RPC `approve_chore(p_chore_id, p_approved, p_reason)` that checks caller is `is_household_admin`. RLS for UPDATE tightened to admin-only on the `status` column path.
- `chore_verification_photos`: kid INSERT must reference their own member_id; admin UPDATE allowed for `rejected_reason`; SELECT remains household-scoped.
- `rewards`: SELECT remains household-scoped; INSERT/UPDATE/DELETE admin-only.
- `meal_plans`: kid INSERT blocked. Kid inserts go through `meal_requests`; admin-approved requests are inserted into `meal_plans` by the approve RPC.
- `shopping_items`: kid INSERT goes through SECURITY DEFINER RPC `add_shopping_item(p_household_id, p_member_id, p_name, p_category, ...)` that sets `is_wishlist=true` unless `category` is in `necessity_categories` for the household. Adult INSERT can stay direct (RLS `WITH CHECK` ensures adult-only direct insert with `is_wishlist=false`).
- `meal_requests`: kids INSERT their own; SELECT own + same-household; admins SELECT all and UPDATE to decide.
- `necessity_categories`: SELECT household-scoped (kids need to know which categories bypass wishlist); INSERT/UPDATE/DELETE admin-only.
- `analytics_events`: tighten to admin-only as defense-in-depth (Disallowed #8).

### App changes

- **Permissions helper at `apps/mobile/lib/utils/permissions.dart`** — exports `isAdmin(membership)`, `isKid(membership)`, `isOwner(membership)`, and action-named helpers (`canEditHousehold`, `canVerifyChores`, `canManageMembers`, `canManageRewards`, `canApproveRequests`). The 14 existing `role == 'admin'` gates migrate to this helper. New gates throughout the kid-permissions UI use it too.
- **ActiveMemberService** already tracks active member. Every kid-attributable write passes `active_member_id` as a parameter to the SECURITY DEFINER RPC.
- **Owner role wiring**: `household_setup_screen.dart` updated to insert household creator with `'role': 'owner'`. Existing rows that say `'admin'` for creators are NOT backfilled in this workstream (out of scope). Permission gates always accept `('owner', 'admin')`.
- **Unified Pending Requests dashboard**: the existing admin "Pending Verification" section on the chore dashboard expands into a "Pending Requests" tab/grouping that surfaces:
  - Pending chore verifications (with photo viewer for kid submissions)
  - Pending wishlist items (with category, requester, approve / deny)
  - Pending meal requests (with recipe, requested date/meal, requester, approve / deny + note field)
- **Kid recipe library** adds a "Request this meal" button on each recipe (visible only when active member is sub_profile). Adults still see "Add to meal plan" (the existing flow).
- **Kid shopping list** branches the 4 existing insert sites — `shopping_list_screen.dart:789`, `:1081`, `meal_planner_screen.dart:712`, `recipe_detail_screen.dart:266` — to call `add_shopping_item` RPC when active member is sub_profile. Adults retain direct insert.
- **Kid chore completion** presents a 3-button choice dialog: Take Photo, Skip Photo, or Cancel. If "Take Photo": camera opens → upload to `chore-photos` bucket → row inserts into `chore_verification_photos` → status transitions to `pending_verification`. If "Skip Photo": no photo upload, no row inserted; status still transitions to `pending_verification`. Cancel = no-op. The same RPC `submit_kid_chore_with_photo` handles both paths (migration 0019 made `p_storage_path` nullable; the photo INSERT is conditional on `v_has_photo`). Adults' no-photo path (`complete_chore_self`) unchanged. (REVISED 2026-05-24 per Q-A reversal; commit ed626bb.)
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
| **1** | Migration 0016 (schema): `meal_requests`, `necessity_categories` (with 4 default rows per household), `shopping_items` 3 new columns, `household_members.music_app_preference`, `chore_verification_photos.rejected_reason`, `is_household_kid()` RLS helper, daily pg_cron job for 30-day photo retention | Low (pure SQL) | None | `feat/kid-perms-schema` |
| **2** | Migration 0017 (RLS): tighten chores verify, chore_verification_photos inserts, rewards CRUD, meal_plans kid-insert block, shopping_items wishlist enforcement, meal_requests policies, necessity_categories policies, analytics defense. Plus SECURITY DEFINER RPCs: `approve_chore`, `add_shopping_item`, `submit_kid_chore_with_photo`, `create_meal_request`, `decide_meal_request`. | Medium (many policies + RPCs, careful testing) | Batch 1 | same branch or `feat/kid-perms-rls` |
| **3** | `apps/mobile/lib/utils/permissions.dart` — new Dart helper module. Migrate the 14 existing `role == 'admin'` gates to the helper. Update `household_setup_screen.dart:96` to insert creator as `'owner'`. | Low-Medium (mechanical, ~9 files) | None — can land independently | `feat/kid-perms-helper` |
| **4** | Chore submission flow with **optional** photo: kid 3-button choice (Take Photo / Skip / Cancel), conditional storage upload, RPC accepts null path (migration 0019), admin review UI with photo viewer (handles "no photo submitted" state) + reject-with-reason field + Re-do affordance for rejected chores + admin photo-delete button. **Batch 4a ✅ shipped 2026-05-24 (commit ed626bb): photo-optional kid submission + migration 0019.** Batch 4b remaining: Re-do, photo viewer, admin reject UI, dashboard "rejected" mapping, admin delete-photo. | Medium-High | Batches 1+2 (RPCs in place) | `feat/kid-perms-batch-4-kid-photo-flow-2026-05-24` (4a shipped; 4b TBD) |
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

5. **Chore photo retention (COPPA)** — 30 days from the verification decision. A pg_cron job runs daily, deleting Storage objects + `chore_verification_photos` rows where `delete_after < now()`. `delete_after` is set when chore status transitions to `verified` OR `rejected`.

6. **Adult photo requirement (Q A from investigation)** — Optional for everyone. Kid and adult both see the same UX: a choice between Take Photo and Skip Photo, decided per submission. Adult "Complete" still routes through `complete_chore_self` (auto-verifies, no admin step); kid "Complete" routes through `submit_kid_chore_with_photo` (goes to `pending_verification` for admin review, with or without a photo). (REVERSED 2026-05-24 — the original "required for kids" answer didn't match the user's actual intent, which was always optional. Implemented via migration 0019 and Batch 4a Dart revisions; commit ed626bb. See `/audits/2026-05-kid-perms-photo-optional-investigation.md` for the full reasoning.)

7. **Reject-photo handling (Q B)** — Photo kept for audit. `chore_verification_photos.rejected_reason text` records the admin's note. Same 30-day retention applies; the cron job deletes both verified and rejected photos after that window.

8. **Enforcement model (Q C)** — SECURITY DEFINER RPCs for kid-attributable writes, consistent with the Pass 2 PIN pattern. RLS policies provide outer perimeter enforcement; the RPCs carry the kid-vs-adult + category-bypass branching.

9. **Owner enum value (Q D)** — Honored, not retired. Owner = household creator, immutable. Admin = promoted by owner. All permission gates accept `('owner', 'admin')`. Setup flow updated to insert creator as `'owner'` going forward; legacy `'admin'` rows for past creators are not backfilled in this workstream.

10. **Role-gate augmentation (Q E)** — Centralize via `apps/mobile/lib/utils/permissions.dart`. Migrate the 14 existing role checks to the helper. Add kind-based checks at the helper layer where the spec's Disallowed actions warrant defense-in-depth above the RLS layer.

11. **Pending Requests UI shape (Q F)** — One unified Pending Requests dashboard (chore verifications + wishlist + meal requests), expanded from the existing admin "Pending Verification" section on the chore dashboard.

## Where this fits in the roadmap

This is a Pass-3 (UX / features) item from the original audit. It is a significant cross-cutting change touching: app code, schema, RLS, and new UI patterns. Current sequencing:

1. ✅ Pass 1 — fix work and stable baseline merge to main (`v0.1.0-baseline`, tagged 2026-05-21).
2. ✅ Pass 2 — security and data integrity, in progress. PIN hashing landed on `fix/pin-hashing-pass-2-2026-05-22` (commits `0904108` and `18fd24e`); broader RLS audit and any remaining schema consistency follow.
3. ⏳ This kid-permissions workstream as a feature batch on its own branch off main, after Pass 2 merges. 8 batches planned (see "Batch plan" section).
