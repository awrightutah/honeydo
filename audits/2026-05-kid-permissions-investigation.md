# Kid Permissions Workstream — Investigation

Date: 2026-05-22
Branch: `fix/pin-hashing-pass-2-2026-05-22` (read-only; no changes made)
Spec being investigated: `/audits/2026-05-kid-profile-permissions-spec.md`
Status: investigation complete, ready for batch breakdown discussion

## Summary

The spec is 71 lines, well-formed, with 6 allowed actions, 9 disallowed actions, an implementation-notes section, and 5 explicit open questions at the end. The codebase is **partially primed** for this work but has three architectural surprises that affect how the batches should be structured:

1. **The codebase gates permissions on `role`, but the spec gates on `kind`.** Both dimensions exist (`household_role` enum + `member_kind` enum). The 14+ existing permission checks in app code (`role == 'admin'`) implicitly cover most kid restrictions today because sub_profiles default to `role = 'member'`, but this is luck-of-the-default, not enforced policy. The spec wants explicit `kind = 'sub_profile'` gating.
2. **`chore_verification_photos` exists as a table from 0001 but the app never writes to it.** The spec's "kids submit chore completion WITH A PHOTO" is therefore *new work*, not a permission gate — it's a whole new UI flow plus storage upload plus DB writes.
3. **RLS today treats kids and adults identically.** Almost every table policy is `for all using is_household_member(household_id)`. No policy distinguishes `kind`. The spec implies tightening this so kids get a restricted subset, which is one of the largest parts of the work.

The good news: the spec is mostly *new tables and new flows* layered on top of existing infrastructure (PIN-protected sub_profile switching from Pass 2, role-gated admin UI from before). It's a feature batch, not a refactor.

`url_launcher` is already in `pubspec.yaml` — the music-app deep link (allowed action #6) is implementable in a few lines.

## Phase 1 — Spec validation

**First 60 lines of `/audits/2026-05-kid-profile-permissions-spec.md`:**

```
# Kid Profile Permission Model — Product Spec

Date captured: 2026-05-21
Status: Spec (not yet implemented)

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

## Implementation notes (not requirements; for the eventual builder)

### Database changes likely needed

- New table: shopping_wishlist_items (or extend shopping_items with a wishlist boolean column + approved_by_member_id + approved_at). Simpler to extend the existing table.
- New table: meal_requests (household_id, requested_by_member_id, recipe_id, requested_for_date, meal_type, status [pending/approved/denied], decided_by, decided_at, decided_note).
- New table: necessity_categories (household_id, category) so the bypass-wishlist categories are admin-configurable per household.
- New column on household_members (already exists): kind and role. We can use kind = 'sub_profile' to gate most kid restrictions.

### RLS policy changes likely needed

Most existing policies are "household member can do everything." We need to tighten them so sub_profiles get a restricted subset. The fact that sub_profiles have no auth_user_id makes this straightforward — auth.uid() returns the parent's id, and the parent's kind is checked. But this means actions a kid takes must be attributed to the parent's auth user AND the active sub_profile. Two values, not one.
```

### Spec summary

**What kids CAN do (6):**
1. View own chores
2. Submit chore completion with a photo (auto → `pending_verification`)
3. Add to a wishlist (with admin approval) OR add to the real list if category is in the household's "necessity" allowlist
4. Add calendar events (same as adults, no approval)
5. Request a meal from the recipe library (creates `meal_requests` row, admin approves)
6. Open a music app on the device via URL scheme deep link (no in-app player)

**What kids CANNOT do (9):**
1. Edit household settings
2. Approve / verify chores
3. Add or remove members; edit other members' profiles
4. Create, edit, or delete rewards
5. Approve or deny their own meal requests
6. Add directly to the shared shopping list (except necessity categories)
7. View or change billing / subscription
8. Access the audit log or analytics
9. Sign up new auth users or invite new household members

**New tables proposed:**
- `meal_requests` (household_id, requested_by_member_id, recipe_id, requested_for_date, meal_type, status, decided_by, decided_at, decided_note)
- `necessity_categories` (household_id, category)
- Wishlist: spec recommends *extending `shopping_items`* with `is_wishlist` + `approved_by_member_id` + `approved_at` (over a separate `shopping_wishlist_items` table)

**New flows / screens proposed:**
- Kid chore-submit-with-photo UI (camera → upload → DB write → status change)
- Wishlist UI (separate view or filter on shopping list)
- Meal-request UI from recipe library
- Admin "Pending Requests" dashboard section (wishlist items + meal requests)
- Music-app deep link button in kid profile screen

**Open questions (verbatim from spec):**

1. Necessity categories — should the default set ship with the app (hygiene, school supplies, basic food) or be empty until admin configures them?
2. Wishlist approval UX — when admin approves a wishlist item, does it move to the main list automatically or get added as a pending item?
3. Meal requests — what happens if admin denies? Notification to the kid? Sit silently? Auto-archive after N days?
4. Music app preference storage — per-kid preference, or per-device? If per-kid, that's a column on household_members. If per-device, it's in SharedPreferences on the phone.
5. Sub-profile chore photo retention — chore_verification_photos has a delete_after timestamp. Default retention for COPPA compliance?

## Phase 2 — Current state inventory

### Sites that branch on `kind` (12 sites across 9 files)

These are all **visual / labeling**, not permission gates:

| File | Line | Use |
|---|---|---|
| `announcements_screen.dart` | 244, 287 | Pick avatar emoji (👶 for sub_profile) |
| `chore_detail_screen.dart` | 790, 1004, 1026 | Append " 👦" to display name; avatar emoji |
| `chore_templates_screen.dart` | 751 | "👶" prefix on kid names in assignee list |
| `settings_screen.dart` | 467 | Show "Adult · Admin/Member" only if kind == 'adult_auth_user' |
| `activity_feed_screen.dart` | 64, 88, 109, 131, 152, 290, 322 | Tag activity items with member_kind; render kid emoji |
| `profile_screen.dart` | 315 | Display "Kid Profile" vs "Adult Account" label |
| `member_profile_screen.dart` | 157, 188, 209 | Avatar emoji, "Kid Profile" header |
| `chore_dashboard_screen.dart` | 217 | Branch chore-completion RPC by `kind` (uses member_id path for sub_profile) |
| `members_screen.dart` | 128, 129, 314, 316, 325, 354, 368, 429 | Adult/kid counts; avatar; role label says "Kid" if kind=='sub_profile' regardless of role |
| `home_shell_screen.dart` | 263, 460, 462, 466, 468, 471, 476, 725, 746 | Kid icon on profile switcher; route kid tap to verify-and-switch flow; leaderboard kid badge |

**One use is functional, not cosmetic:** `chore_dashboard_screen.dart:217` branches the chore-completion RPC by kind because sub_profiles have `auth_user_id = NULL` (the broken-then-fixed bug from the baseline). Everything else is just visual.

### Sites that branch on `role` (14 sites)

These DO gate permissions:

| File | Line | Behavior |
|---|---|---|
| `settings_screen.dart` | 441, 489, 490 | `isAdmin = role == 'admin'`. Gates "Edit household" trailing icon + onTap. **NOTE: only checks 'admin', not 'owner'.** |
| `chore_dashboard_screen.dart` | 106, 281, 331, 347 | Load pending-verification list only if admin; show "Pending Verification" UI section only if admin |
| `announcements_screen.dart` | 20, 42, 205, 226, 316 | `_isAdmin = role in ('owner','admin')`. Gates FAB to add announcements + edit / delete |
| `chore_detail_screen.dart` | 345, 380, 515 | `isAdmin = role == 'admin'`. Gates Approve/Reject UI on pending_verification chores |
| `member_profile_screen.dart` | 221 | Display badge: 👑 Owner vs ⭐ Admin vs Member |
| `members_screen.dart` | 127, 190, 350, 354, 358 | `isAdmin = role == 'admin'`. Gates "Add Kid Profile" button visibility (so non-admins can't create kids), display label coloring |
| `profile_screen.dart` | 418, 420 | Display label for role |
| `rewards_screen.dart` | 833 | Show "Approve" button on pending redemption only if admin |
| `home_shell_screen.dart` | 565, 567 | (Pass 2 PIN work) `isAdmin = role in ('owner','admin')` for Set-PIN dialog gating |
| `invite_management_screen.dart` | 62, 383 | `_isAdmin = role in ('admin','owner')`. Gates entire screen's invite FAB |
| `household_setup_screen.dart` | 96 | Inserts the household creator with `role: 'admin'` (NOT 'owner') |

**Codebase inconsistency on role:** some checks accept `'owner' OR 'admin'` (announcements, invites, PIN); others accept ONLY `'admin'` (settings, chore dashboard, chore detail, rewards, members). The schema enum allows all three, but `household_setup_screen.dart:96` inserts the creator as `'admin'` (never `'owner'`), so functionally `'owner'` is never assigned in practice today. The spec doesn't address this inconsistency — it just says "admin." Open question implied: should kid permissions check `role IN ('owner','admin')` or just `'admin'`?

### Capability-by-capability map

For each of the 6 allowed actions and 9 disallowed actions in the spec:

| Capability | Spec section | Where in code | Current behavior | Required change |
|---|---|---|---|---|
| View own chores | Allowed #1 | `chore_dashboard_screen.dart:100-101` (`assigned_to_member_id == myMemberId`) | Already filters by active member. Works for kids. | None (already works) |
| Submit chore with PHOTO | Allowed #2 | `chore_dashboard_screen.dart:130-145` (`_completeChore`) | Just updates status to `pending_verification`. NO photo flow. | NEW UI: camera, upload to `chore-photos` bucket, insert `chore_verification_photos` row. Plus gating — adults can still submit without photo (spec is ambiguous about this; see open question). |
| Add to wishlist | Allowed #3 | `shopping_list_screen.dart:789` (`_addItem`), `:1081` (bulk), `meal_planner_screen.dart:712`, `recipe_detail_screen.dart:266` | All 4 sites directly insert into `shopping_items`. No wishlist concept exists. | Extend `shopping_items` with `is_wishlist`, `approved_by_member_id`, `approved_at`. All 4 insert sites need branching: kid → `is_wishlist=true` unless category in necessity_categories. |
| Add calendar events | Allowed #4 | `calendar_screen.dart` (need to verify path) | RLS: `household_scoped_calendar_events for all using is_household_member`. Kids can already insert. | None (already works) |
| Request a meal | Allowed #5 | None — `recipe_detail_screen.dart` inserts directly into `meal_plans` | No meal_requests table exists | NEW table + UI on recipe detail (kid only) + admin pending dashboard |
| Music app deep link | Allowed #6 | None | No deep link button, but `url_launcher: ^6.3.0` is already in pubspec | NEW UI button on kid profile screen + `launchUrl` calls. Storage of preference depends on open question #4. |
| Disallow: edit household settings | Disallowed #1 | `settings_screen.dart:441,489-490` | Already gated by `role == 'admin'`. Kids are role='member' by default → already gated. | Tighten check to also reject by kind if we want defense-in-depth. |
| Disallow: approve/verify chores | Disallowed #2 | `chore_dashboard_screen.dart:106`, `chore_detail_screen.dart:515`, `_verifyChore` at :192 | Already gated by `role == 'admin'` for UI. RLS for `chores` allows all household members — so a tampered client could verify. | RLS tightening: add kind check, OR move chore-approve to a SECURITY DEFINER RPC. |
| Disallow: add/remove members | Disallowed #3 | `members_screen.dart:190` (Add Kid button gated by `isAdmin`); RLS: `household_members_admin_all for all using is_household_admin` | RLS already restricts inserts/updates to admins. **Already enforced.** | Verify that the admin check is broad enough; consider adding kind check for defense-in-depth. |
| Disallow: rewards CRUD | Disallowed #4 | `rewards_screen.dart:833` (admin gate for approve); insert/edit sites need checking | RLS: `household_scoped_rewards for all using is_household_member` — **kids can currently create/edit/delete rewards** | RLS tighten + UI gate |
| Disallow: approve own meal request | Disallowed #5 | n/a (table doesn't exist yet) | n/a | Build into new `meal_requests` RLS: insert ok for kid; update/decide only by admin who is NOT the requester. |
| Disallow: add to shared list | Disallowed #6 | Same 4 insert sites as Allowed #3 | Today: kids can add anything | Branch logic on insert: kid path goes to wishlist unless category in necessity_categories |
| Disallow: billing/subscription | Disallowed #7 | `subscription_screen.dart`; RLS on `subscriptions` is `for select using is_household_admin` (admin only) | RLS already locks kids out of read. App: subscription_screen likely already admin-only (need to verify). | Verify; tighten if needed. |
| Disallow: audit log / analytics | Disallowed #8 | RLS: `audit_logs for select using is_household_admin`; `analytics_events for all using is_household_member` | audit_logs already admin-only. analytics_events is NOT — any member (kid included) can read/write. | Tighten analytics_events RLS if it surfaces in any UI; today no app code reads it that I can see. |
| Disallow: invite new members | Disallowed #9 | `invite_management_screen.dart:62,383` (admin gate); RLS: `household_scoped_invites for all using is_household_admin` | RLS already restricts. **Already enforced.** | Add kind check for defense-in-depth. |

### High-level pattern

About 60% of the spec's disallowed actions are already enforced via `role`-based RLS or `role`-based app gates. The remaining 40% (rewards CRUD, chore-verify RLS, analytics) is genuinely open today.

The spec's allowed actions are 80% new work (photo flow, wishlist, meal requests, music link), 20% no-op (own chores, calendar — already work).

## Phase 3 — Schema inventory

### Tables relevant to the spec

| Table | Source migration | Status for this workstream |
|---|---|---|
| `household_members` | 0001:42 | Already has `kind` and `role` columns. No changes needed. |
| `member_pin_secrets` | 0013 | Pass 2 work — no changes needed. |
| `chores` | 0001:88 | No changes needed. |
| `chore_verification_photos` | 0001:113 | **Exists but app never writes to it.** Schema is sufficient for the spec (chore_id, household_id, uploaded_by_member_id, storage_path, delete_after, created_at). Could add a `rejected_reason text` column if we want to track admin rejection notes. |
| `chore_history` | 0001:123 | No changes needed. |
| `rewards`, `reward_redemptions` | 0001:136-149 | No schema change. RLS tighten only. |
| `meal_plans` | 0001:282 | No changes needed (meal_requests is separate). |
| `shopping_items` | 0001:318 | **Needs new columns: `is_wishlist boolean default false`, `approved_by_member_id uuid`, `approved_at timestamptz`.** Per spec recommendation. |
| `calendar_events` | 0001:199 | No changes needed. |
| `subscriptions` | 0001:340 | No changes needed (admin-only RLS already). |
| `audit_logs` | 0001:406 | No changes needed (admin-only RLS already). |
| `analytics_events` | 0001:382 | RLS tighten only. |
| `meal_requests` | **does not exist** | **NEW TABLE.** Per spec: household_id, requested_by_member_id, recipe_id, requested_for_date, meal_type, status (pending/approved/denied), decided_by, decided_at, decided_note. |
| `necessity_categories` | **does not exist** | **NEW TABLE.** Per spec: household_id, category. Composite PK or surrogate id. Open question: should rows be created automatically on household setup (defaults) or empty by default? |
| `shopping_wishlist_items` | n/a — not used (spec recommends extending shopping_items) | n/a |

### Schema-change table

| Schema change | Spec section | Current state | Required state | Migration order suggestion |
|---|---|---|---|---|
| Add `is_wishlist`, `approved_by_member_id`, `approved_at` to `shopping_items` | Implementation notes / Allowed #3 / Disallowed #6 | Doesn't exist | Three new nullable columns | Batch 1 |
| Create `meal_requests` | Implementation notes / Allowed #5 | Doesn't exist | Full table per spec | Batch 1 |
| Create `necessity_categories` | Implementation notes / Allowed #3 | Doesn't exist | (household_id, category) — open Q: surrogate id or composite PK | Batch 1 |
| Optional: add `rejected_reason text` to `chore_verification_photos` | Allowed #2 (admin can reject) | Doesn't exist | Nullable text column | Batch 2 (with chore-photo flow) |
| Optional: add `music_app_preference text` to `household_members` | Allowed #6 (open question #4) | Doesn't exist | If we choose per-kid preference (open question) | Batch 5 (music link) |

Existing tables the spec touches but doesn't require schema changes for: `chores`, `chore_verification_photos`, `calendar_events`, `meal_plans`, `rewards`, `subscriptions`, `audit_logs`, `analytics_events`, `household_members`.

## Phase 4 — RLS state

### Current policies on tables touched by the spec

| Table | Existing RLS policies | Adequacy for spec |
|---|---|---|
| `household_members` | `select using is_household_member`; `for all using is_household_admin` (admin can insert/update/delete) | **Adequate.** Kids can read other members; admins manage. |
| `chores` | `for all using is_household_member(household_id)` | **Too permissive.** Kids can verify/approve chores at the RLS level. Need tightening for verify/approve actions. |
| `chore_verification_photos` | `for all using is_household_member(household_id)` | **Too permissive.** Anyone in the household can insert/update/delete photos. Need: kid can only insert with their own member_id; admin can update (reject reason, delete_after). |
| `chore_history` | `for all using is_household_member(household_id)` | Adequate for read; writes should be RPC-only (likely already are). |
| `rewards` | `for all using is_household_member(household_id)` | **Too permissive per Disallowed #4.** Kid can currently CRUD rewards. Tighten to admin-only for INSERT/UPDATE/DELETE. |
| `reward_redemptions` | `for all using is_household_member(household_id)` | Probably adequate (kids redeem their own points). Need to verify the spec's intent on whether kids can request redemptions (the spec doesn't explicitly forbid this; only forbids CRUD on rewards themselves). |
| `meal_plans` | `for all using is_household_member(household_id)` | **Too permissive.** Kids shouldn't be able to insert directly into meal_plans — they should go via meal_requests. |
| `shopping_items` | `for all using is_household_member(household_id)` | **Needs branching:** kid inserts must set `is_wishlist=true` unless category in necessity_categories. Likely needs a `WITH CHECK` clause referencing `kind` lookup + a function. |
| `calendar_events` | `for all using is_household_member(household_id)` | **Adequate per spec Allowed #4** (kids can add events). |
| `subscriptions` | `for select using is_household_admin(household_id)` | **Already adequate** (kids can't even read). No changes needed. |
| `audit_logs` | `for select using is_household_admin(household_id)` | **Already adequate.** |
| `analytics_events` | `for all using (household_id is null or is_household_member(household_id))` | Too permissive but probably moot — no UI surfaces it. Tighten if Pass 2.x ever wires it. |
| `feedback_requests` | `for all using is_household_member(household_id)` | Spec doesn't address feedback. Probably fine. |
| `meal_requests` (new) | n/a | **New policies needed:** kids can INSERT (with requested_by_member_id = their member id); kids can SELECT their own requests; admins can SELECT all and UPDATE (to decide). |
| `necessity_categories` (new) | n/a | **New policies needed:** household members can SELECT (kids need to know what's in necessity list to know which categories bypass wishlist); admins can INSERT/UPDATE/DELETE. |

### RLS helper function inventory

Both helpers in `0001:456-477` are `SECURITY DEFINER`, stable, return boolean:

- `is_household_member(target_household_id uuid)` — true if `auth.uid()` has an active row in that household. **Does NOT check `kind`.**
- `is_household_admin(target_household_id uuid)` — true if `auth.uid()` has an active row with `role IN ('owner','admin')` in that household.

**Gap:** there's no `is_household_kid(target_household_id)` or `current_member_kind(target_household_id)` helper. Either:
- (A) Add `is_kid()` that returns `(select kind from household_members where auth_user_id = auth.uid() and household_id = target_household_id) = 'sub_profile'`. Simple to add.
- (B) Use `is_kid_or_admin_check` patterns inline in each policy.

I'd recommend (A) — one new helper function added in Batch 1, mirroring the existing two.

**Subtlety from the spec at line 48:** "But this means actions a kid takes must be attributed to the parent's auth user AND the active sub_profile. Two values, not one."

Today the app passes member_id alongside auth.uid() for chore actions because of the kid/adult auth_user_id split (Pass 2 finding). The spec is correct that any RLS policy referencing the *acting kid* will need both — auth.uid() to know which adult JWT is attached, and a custom claim or RPC parameter to know which sub_profile is "active" on that device. Today this isn't a separate value: the only way a kid acts is by the adult passing the kid's member_id in the write. **The RLS layer cannot know who the "active sub_profile" is — only the app does.** This is a fundamental architectural choice: either (a) all kid-attributable writes go through SECURITY DEFINER RPCs that take member_id as a parameter and do their own auth/permission check inside the function (matching the Pass 2 PIN pattern), or (b) we add a `request.jwt.claim.active_member_id` custom claim that the app injects before writes.

Option (a) is consistent with what we already did in Pass 2. Recommending (a) implicitly through all the new RLS work below.

## Phase 5 — Dependency graph

```
            ┌─────────────────────────────────────┐
            │  0016 schema migration              │
            │  - meal_requests table               │
            │  - necessity_categories table        │
            │  - shopping_items.is_wishlist + ...  │
            │  - is_kid() RLS helper               │
            │  - optional: chore_verification_     │
            │    photos.rejected_reason            │
            └────────────────┬────────────────────┘
                             │
            ┌────────────────┴────────────────────┐
            │  0017 RLS migration                  │
            │  Tighten policies on:                │
            │   chores (verify-admin-only)         │
            │   chore_verification_photos          │
            │   rewards (CRUD admin-only)          │
            │   meal_plans (kid insert blocked)    │
            │   shopping_items (kid → wishlist     │
            │     unless necessity category)       │
            │   meal_requests (kid insert, admin   │
            │     decide)                          │
            │   necessity_categories (member read, │
            │     admin write)                     │
            │   analytics_events (admin-only       │
            │     defense in depth)                │
            └────────────────┬────────────────────┘
                             │
        ┌────────────────────┼────────────────────────────────────┐
        │                    │                                    │
        ▼                    ▼                                    ▼
┌─────────────────┐  ┌────────────────────┐         ┌──────────────────────────┐
│  Batch 2:       │  │  Batch 3:          │         │  Batch 4:                │
│  chore submit-  │  │  wishlist +        │         │  meal_requests flow      │
│  with-photo     │  │  necessity         │         │  - kid: recipe detail    │
│                 │  │  - kid: insert     │         │    "Request this meal"   │
│  - kid flow:    │  │    with is_wish=   │         │  - admin: pending        │
│    camera →     │  │    true (or false  │         │    requests dashboard    │
│    storage →    │  │    if necessity)   │         │  - approve creates       │
│    DB → status  │  │  - admin: review   │         │    meal_plans row;       │
│    change       │  │    wishlist UI,    │         │    deny sets status      │
│  - admin:       │  │    approve / deny  │         │  - notification on       │
│    review with  │  │  - admin: edit     │         │    decide (open Q #3)    │
│    photo        │  │    necessity list  │         │                          │
└─────────────────┘  └────────────────────┘         └──────────────────────────┘
        │                    │                                    │
        └────────────────────┼────────────────────────────────────┘
                             │
                             ▼
                ┌─────────────────────────────┐
                │  Batch 5: kind-based UI     │
                │  hardening                  │
                │  - hide admin actions when  │
                │    _myMembership.kind ==    │
                │    'sub_profile' (defense   │
                │    in depth above RLS)      │
                │  - add isKid() helper in    │
                │    a single shared place    │
                │  - audit every existing     │
                │    role=='admin' check —    │
                │    decide whether to also   │
                │    check kind               │
                └──────────────┬──────────────┘
                               │
                               ▼
                ┌──────────────────────────────┐
                │  Batch 6: music app deep     │
                │  link (smallest, can ship    │
                │  independently any time)     │
                │  - kid profile screen new    │
                │    button → url_launcher     │
                │  - prefs storage per open Q  │
                │    #4 decision               │
                └──────────────────────────────┘
```

Notes on ordering:

- Batches 2, 3, 4 are **independent** of each other once 0016 + 0017 land. They could be picked off in any order or done in parallel by different sessions.
- Batch 5 (kind-based UI hardening) is also independent and could go any time, but pairs well with the others as a cleanup.
- Batch 6 (music link) is entirely standalone — no schema, no RLS, no dependency. Could be done first as a "quick win" if you want momentum, or last.

## Phase 6 — Surprises and open questions

### Surprises spotted during the investigation

1. **`role`-based vs `kind`-based gating mismatch.** The spec proposes `kind = 'sub_profile'` gates; the codebase has 14+ `role`-based gates. The two dimensions overlap today (sub_profiles default to `role='member'`), but this is implicit, not enforced. **Decision needed:** for permission gates, do we (a) add kind checks alongside existing role checks, (b) migrate all role checks to kind checks, or (c) use BOTH (kid OR member as the kid-criterion)? My recommendation: **(a) add kind checks alongside existing role checks** — minimal churn, defense in depth, no behavior change for existing code paths.

2. **`'owner'` is functionally unused.** The schema enum has it but `household_setup_screen.dart:96` inserts the creator as `'admin'`, never `'owner'`. Five places check `role IN ('owner','admin')` (announcements, invites, PIN, member_profile, profile_screen), seven check only `role == 'admin'`. The spec uses "admin" generically. **Implicit decision:** treat `'owner'` and `'admin'` as the same for kid-permission purposes. Recommend documenting this in the kid permissions code rather than fixing the inconsistency in this workstream.

3. **`chore_verification_photos` is a phantom.** Defined in 0001:113 with the bucket policies in 0003:117-145. No app code writes to it. The spec's Allowed #2 (kid submits with photo) is therefore not just a UI change — it's wiring the table to the chore flow for the first time. Adults who today complete chores via `chore_dashboard_screen.dart:_completeChore` (line 130) do NOT upload a photo. **Open question implied by the spec but not stated:** when adults complete chores, should they ALSO be required to upload a photo, or is photo-required only for kids? The current "Approve" UI only shows the chore — there's no photo viewer. Either way, the admin pending-verification UI will need a photo viewer added.

4. **`shopping_items` already has `added_by_member_id`.** This means the wishlist branching can read the inserter's kind via JOIN at insert-time in RLS. No need for a separate column to know who added a wishlist item — `added_by_member_id` is already there. (Just need `is_wishlist`, `approved_by_member_id`, `approved_at`.)

5. **The "active member" architectural question is real.** From spec line 48: "actions a kid takes must be attributed to the parent's auth user AND the active sub_profile. Two values, not one." The Pass 2 PIN work already established the pattern: kid-attributed actions go through SECURITY DEFINER RPCs that take member_id as a parameter and verify the parent (auth.uid()) is in the same household. Recommend continuing this pattern for kid-attributed writes in this workstream (chore submit, wishlist insert, meal request insert) rather than introducing a `request.jwt.claim.active_member_id` custom JWT claim.

6. **Necessity-category gating may require a function, not just a policy.** RLS `WITH CHECK` can reference a subquery against `necessity_categories`, but the logic is "if inserter is sub_profile AND row.is_wishlist = false, then row.category must be in necessity_categories." That's expressible in `WITH CHECK` but ugly. Cleaner: a SECURITY DEFINER RPC `add_shopping_item(p_household_id, p_member_id, p_name, p_category, ...)` that does the kid-vs-adult, necessity-vs-non logic server-side and sets `is_wishlist` appropriately. **Decision needed:** RPC or direct insert with RLS check.

7. **The `is_household_admin` helper checks `auth_user_id = auth.uid()`** which means a sub_profile (auth_user_id IS NULL) calling it would return false. That's correct for "is the *signed-in adult* an admin." But it means sub_profile rows being acted upon by an admin pass through the auth_user_id of the parent — *not* the sub_profile itself — which is exactly what Pass 2's PIN work already established. Consistent.

8. **Calendar (Allowed #4) is already 100% functional with no changes.** Mentioned in case it suggests we can do a 0-LOC ticket to "verify calendar add works for kids" as a quick QA step rather than a build batch.

### Open questions in the spec — implicit-answer audit

1. **Necessity categories default set.** The codebase has zero existing necessity logic. There's nothing implicit to lean on. Spec must answer this explicitly. Suggested default for discussion: hygiene, school supplies, basic groceries — but ship as INSERTs in a migration so admin can delete them, vs hardcoded.

2. **Wishlist approval UX.** Implicit answer in codebase: today, `shopping_items.purchased boolean` is the only "state" on a shopping item. Adding `is_wishlist`, `approved_by_member_id`, `approved_at` as proposed gives us: row stays in shopping_items always, just toggles `is_wishlist` from true to false on approve. Cleaner than moving to a separate list. **Recommend: admin-approve flips `is_wishlist=false`.** Item moves into the active shopping list view (which would filter `where is_wishlist = false`). No automatic purchase state change.

3. **Meal request denial behavior.** No implicit answer; codebase has no notification flow for similar cases. Open. **Hint:** if `notification_preferences.gamification_alerts` is true, we could plumb a notification. Spec needs to specify.

4. **Music app preference storage.** Implicit answer in codebase: `household_members` is a per-member row; SharedPreferences exists for per-device state (ActiveMemberService). Either works. **Recommendation:** per-kid (column on household_members or a new `music_preferences` mini-table) so a kid switching from iPad to phone keeps their choice.

5. **Chore photo retention.** Schema already has `chore_verification_photos.delete_after timestamptz`. The field exists but no cleanup job uses it. Spec needs to specify a default (e.g., 30 days post-verification) AND someone needs to add a Postgres function + scheduled job (Supabase has pg_cron) to actually delete the storage + row.

### New open questions surfaced by this investigation

A. Does the spec apply photo-requirement to adults as well, or kids only? (Adults today don't submit photos.)
B. When admin rejects a kid's chore submission, what happens to the photo — kept for audit, or deleted immediately?
C. For the wishlist/necessity flow, do we use a SECURITY DEFINER RPC or direct insert with RLS `WITH CHECK`?
D. Should the `role = 'owner'` enum value be retired or honored? Implicit answer is "honored where checked, ignored where not, treat same as admin."
E. Existing `role`-based gates: do we keep them, augment them with `kind` checks, or replace them with `kind` checks? Recommend augment.
F. Existing admin "Pending Verification" UI (`chore_dashboard_screen.dart:347`) — does the new "Pending Requests" section live alongside it, or is it a separate screen? Spec line 53 says "new section on admin dashboard," implying same screen.

## Phase 7 — Proposed batch breakdown

| Batch | Scope | Estimated complexity | Dependencies | Suggested branch |
|---|---|---|---|---|
| **1 — schema** | Migration 0016: `meal_requests`, `necessity_categories`, `shopping_items` 3 new columns, `is_kid()` RLS helper, optional `chore_verification_photos.rejected_reason` | Low (pure SQL) | None | `feat/kid-perms-schema-2026-05-xx` |
| **2 — RLS** | Migration 0017: tighten chores verify, chore_verification_photos inserts, rewards CRUD, meal_plans kid-insert block, shopping_items wishlist enforcement, meal_requests policies, necessity_categories policies, analytics defense | Medium (lots of policies, needs careful test) | Batch 1 | same branch or `feat/kid-perms-rls-2026-05-xx` |
| **3 — chore-photo flow** | Kid completion UI with camera; storage upload; DB insert; admin review UI with photo viewer; optional reject reason | Medium-High (new UI, storage integration, error handling) | Batches 1+2 (RLS allows kid-only insert with their own member_id) | `feat/kid-perms-chore-photo-2026-05-xx` |
| **4 — wishlist + necessity** | Extend the 4 shopping_items insert sites; admin "Pending Wishlist" UI; admin "Edit Necessity Categories" UI | Medium (4 insert sites, 2 new UIs) | Batches 1+2 | `feat/kid-perms-wishlist-2026-05-xx` |
| **5 — meal requests** | New table writes; "Request This Meal" on recipe detail (kid-only button); admin "Pending Meal Requests" section; approve creates meal_plan, deny updates status | Medium | Batches 1+2 | `feat/kid-perms-meals-2026-05-xx` |
| **6 — kind-based UI hardening** | Audit all 14 existing `role=='admin'` gates; add `kind != 'sub_profile'` defense-in-depth where appropriate; centralize an `isKid()` helper on `_myMembership` | Low-Medium (mechanical edits across ~9 files, no new behavior) | None — could go any time | `feat/kid-perms-ui-hardening-2026-05-xx` |
| **7 — music app deep link** | Kid profile screen button → `launchUrl` for the chosen app; preference storage per open Q #4 | Low (single screen change, dep already in pubspec) | None — could go any time | `feat/kid-perms-music-2026-05-xx` |

**Total estimated work:** roughly 7 batches. Batches 1+2 must be first; Batches 3/4/5 are independent of each other; Batches 6 and 7 are independent of everything.

## Next steps (what user needs to decide before implementation begins)

Decisions in priority order:

1. **Resolve the 5 open questions in the spec.** Listed above with my hints / recommendations.
2. **Decide the `kind` vs `role` gating philosophy.** My recommendation: **augment**, not replace. New work uses kind checks; existing role checks stay. Both are checked in the new code paths.
3. **Decide RLS-only vs RPC-based enforcement for new flows.** For wishlist insert, chore submit, meal request — I recommend SECURITY DEFINER RPCs consistent with the Pass 2 PIN pattern. Direct inserts with `WITH CHECK` work but are harder to reason about and to evolve.
4. **Answer the 6 new open questions surfaced by this investigation** (Section: "New open questions surfaced," above). Especially:
   - Adult photo requirement (Q A): kids only, or everyone?
   - Owner vs admin enum cleanup (Q D): kept-but-treated-same is fine; just document.
   - Pending Requests UI shape (Q F): one combined section or one per flow type?
5. **Approve the batch order** in Phase 7. Specifically, whether music-app deep link (Batch 7) is a "first quick win" or a "last polish."
6. **Confirm we wait until this branch merges to main first.** Per the merge-outcome doc, the plan was kid permissions on its own branch off main, post-Pass-2. This is consistent with that plan.

Once those are answered, the first concrete deliverable would be migration 0016 (Batch 1 schema), reviewed before applying, on a new branch off main once `fix/pin-hashing-pass-2-2026-05-22` lands.
