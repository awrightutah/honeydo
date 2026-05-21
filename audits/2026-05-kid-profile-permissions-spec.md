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

### App changes likely needed

- ActiveMemberService already tracks who the active member is (adult or kid). Every write should pass active_member_id explicitly and the UI should hide or disable admin-only actions when the active member is a sub_profile.
- New "Pending Requests" section on admin dashboard for meal requests and wishlist items needing approval.
- New deep-link handler in the kid profile screen for music apps.

## Open questions to resolve before building

1. Necessity categories — should the default set ship with the app (hygiene, school supplies, basic food) or be empty until admin configures them?
2. Wishlist approval UX — when admin approves a wishlist item, does it move to the main list automatically or get added as a pending item?
3. Meal requests — what happens if admin denies? Notification to the kid? Sit silently? Auto-archive after N days?
4. Music app preference storage — per-kid preference, or per-device? If per-kid, that's a column on household_members. If per-device, it's in SharedPreferences on the phone.
5. Sub-profile chore photo retention — chore_verification_photos has a delete_after timestamp. Default retention for COPPA compliance?

## Where this fits in the roadmap

This is a Pass-3 (UX / features) item from the original audit. It is a significant cross-cutting change touching: app code, schema, RLS, and new UI patterns. Suggested order:

1. Finish current Pass 1 fix work + reach a stable baseline merge to main
2. Pass 2 (security and data integrity) — fix PIN hashing properly, lock down RLS broadly, audit cross-table consistency
3. Then this kid-permissions work as a feature batch on its own branch
