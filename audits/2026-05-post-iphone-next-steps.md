# Post-iPhone next-steps report

Date: 2026-05-21
Branch: `fix/post-iphone-debug-2026-05-21` (off `fix/critical-missing-features`)
Reference: `audits/2026-05-schema-drift-map.md` for the full drift inventory.

---

## What was fixed in this pass

| # | Fix | Files | Severity |
|---|---|---|---|
| A | Chores tab: changed `inFilter('status', ['assigned', 'pending'])` to `inFilter('status', ['assigned', 'in_progress'])`. The `'pending'` value isn't in the `chore_status` enum so Postgres rejected the query — that's why the tab errored even with an empty `chores` table. | `lib/screens/chore_dashboard_screen.dart:101` | Critical (tab unreachable) |
| B | Feature tour FilledButton infinite-width: added `minimumSize: Size.zero` and `tapTargetSize: MaterialTapTargetSize.shrinkWrap` so the button doesn't inherit the global `Size.fromHeight(52)` minimum (which expands to `double.infinity` width inside a `Row`). | `lib/services/feature_tour_service.dart:259-267` | High (renders a sea of red error boxes; tour blocked) |
| C | `mounted` guards added to the two specific load methods flagged in the error log. Removed the now-redundant inner `if (mounted)` block in recipe_library. | `lib/screens/chore_dashboard_screen.dart:115, 121` and `lib/screens/recipe_library_screen.dart:97, 105` | Medium |
| D | RLS policies captured: the four policies added manually in Supabase Studio after first-run setup are now in version control. New file: `supabase/migrations/0006_post_iphone_fixes.sql`. | `supabase/migrations/0006_post_iphone_fixes.sql` (new) | Medium (no live change; lets fresh environments reach the same state) |

Analyzer: 327 issues before, 327 issues after. No new diagnostics.

---

## What is still broken (per the schema drift map)

Listed by tab/screen. Every item is documented in `2026-05-schema-drift-map.md` with file + line.

### Chores tab
- **After approve/reject, the RPC call to `award_points` will fail** because the Dart side sends `p_user_id` / `p_reason` / `p_reference_id` while the SQL function expects `p_auth_user_id` / `p_note` / `p_source_id` (+ `p_source_table`). `check_and_award_achievements` has the same `p_user_id` vs `p_auth_user_id` mismatch.
- **`status = 'completed'`** writes (when an admin approves a chore at `chore_dashboard_screen.dart:198`, when the chore-detail dropdown saves status, when `_quickUpdateStatus` runs) will throw — `'completed'` isn't in `chore_status`. The valid post-approve status is `'verified'`.
- **`household_members.user_id`** lookup at `chore_dashboard_screen.dart:207` returns null — the column is `auth_user_id`. As a result, even if the RPC param names were right, the `p_auth_user_id` value passed in would be null.

### Chore detail screen
- **`chore_verifications` table doesn't exist** — the activity log query is silently empty.
- **`_statuses` dropdown** offers `'completed'` and `'verified'` — saving with `'completed'` throws.

### Activity Feed (drawer menu)
- **`member_achievements`** table doesn't exist (should be `achievements`).
- **`point_transactions.transaction_type`** (should be `type`) and **`reason`** (should be `note`) — fields missing.
- **`reward_redemptions.created_at`** (should be `redeemed_at`), **`points_cost`** (should be `point_cost`), **`reward_name`** (denormalized field that doesn't exist; needs join to `rewards`).
- Each sub-fetch is wrapped in `try / catch (_) {}` so the screen shows "No activity yet" instead of erroring. But nothing will ever appear.

### Member Profile (from leaderboard tap)
- **`member_badges`** table doesn't exist (should be `achievements`).
- **`current_streak`** column missing on `household_members` (referenced from the leaderboard RPC result via the fallback path).
- **`transaction_type`** wrong on `point_transactions` query.

### Recipe Detail
- **Edit / Save** sends `calories_per_serving`, `protein_g`, `carbs_g`, `fat_g` columns that don't exist — UPDATE will throw.
- **"Add to Meal Plan"** writes to `meal_plan_entries` with column `meal_date` — table doesn't exist; should be `meal_plans` with `planned_for`.
- **"Add to Shopping List"** writes `is_purchased: false` — column doesn't exist; should be `purchased`. The DB default kicks in so behavior is right by accident, but a future schema tightening would break it.

### Recipe Library
- **`increment_master_recipe_added_count` RPC** is called with param `recipe_id` instead of `p_recipe_id` — the count never increments.

### Settings
- **Edit Household** updates `households.emoji` — column doesn't exist; the update is rejected entirely (so even the name change is lost).
- **Change Password** sheet collects a "current password" field that is never verified.

### Notification Preferences
- **13 columns the screen toggles** don't exist on the table: `push_enabled`, `chore_assignments`, `chore_verification`, `overdue_alerts`, `meal_reminders`, `shopping_updates`, `achievement_notifications`, `points_updates`, `streak_reminders`, `member_joined`, `household_announcements`, `quiet_hours_enabled`, plus the screen's own `household_id` filter. Upserts succeed (Supabase ignores unknown columns rather than rejecting) so no error UI, but the toggles persist nothing.

### Data Export
- **`data_export_screen.dart:166`** reads from non-existent `recipes` table. The JSON export will throw → catch-all → "Export failed" toast.

### Calendar
- **Default tag inserts at `household_setup_screen.dart:106-119`** include an `emoji` column that doesn't exist on `calendar_tags` — each of the six default-tag inserts fails. A freshly-created household has zero calendar tags as a result.
- **Calendar realtime subscribes to `choresVersion`** (not `calendarEventsVersion`) because `RealtimeService` doesn't subscribe to the `calendar_events` table at all. Calendar reloads on chore changes, not event changes.

### Home Shell
- **`households.emoji` read** at `home_shell_screen.dart:227, 228` — silently null, just no emoji icon next to household name (cosmetic only).

---

## Recommended next batch

Ordered by reach (how many user-visible flows it unblocks per fix):

1. **Add a `0007_chore_status_align.sql` migration that extends `chore_status` with `'completed'`** OR (preferred) **change the app to use the existing enum** (`pending_verification` for "user marked done", `verified` for "admin approved"). Approach: change `chore_dashboard_screen.dart:198` to write `'verified'`, change `chore_detail_screen.dart:48, 197, 875` similarly. Removes ~6 production write paths that currently throw.
2. **Fix the two RPC param name mismatches** in `chore_dashboard_screen.dart:211-217` and `:220-223`: `p_user_id` → `p_auth_user_id`, `p_reason` → `p_note`, `p_reference_id` → `p_source_id`, drop `p_household_id` arg ordering verification, add `p_source_table: 'chores'` if you want the source-link populated. Also fix `recipe_library_screen.dart:215` to send `p_recipe_id` not `recipe_id`. Together these get chore-approval points-and-achievements working end-to-end.
3. **Choose the achievements table once and fix everywhere.** The schema has `achievements`. Change `activity_feed_screen.dart:77` and `member_profile_screen.dart:73` to read from that table. Side-effect: unlocks the activity feed (currently empty).
4. **Fix the `meal_plan_entries` write in `recipe_detail_screen.dart:343`** to use `meal_plans` with `planned_for`. Makes "Add to Meal Plan" from a recipe detail screen actually save.
5. **Decide what to do with the household emoji.** Either (a) add an `emoji text` column to `households` in a new migration and the settings edit works for free, or (b) remove the emoji read/write from the three screens that reference it. (a) is one SQL line; (b) is three small Dart edits.

A 6th high-leverage move not strictly a "fix": **add an `emoji text` column to `calendar_tags`** so the household-setup default tags actually insert. One SQL line, six inserts now succeed.

---

## Risks to watch for

Things the user is likely to tap that will produce errors:

- **Tap "+" on the Chores tab and create a chore** → the chore inserts fine (no RLS or schema mismatch on insert). Listing it via `_loadData` is now fixed.
- **Tap "Mark complete" on a chore** → writes `status = 'pending_verification'` (valid) and calls `_loadData` (works). UI shows the chore in admin's "Pending Verification" section.
- **Tap "Approve" on a pending chore (admin)** → writes `status = 'completed'` (**invalid enum**) → throws → toast: "Could not update chore status." Fix in next batch (item 1).
- **Tap "+ Add Reward" in Rewards** → insert works (`rewards` schema matches). Redeem a reward → the multi-step write at `rewards_screen.dart:202-226` succeeds at the row level (table matches) but is non-atomic; partial-failure risk remains.
- **Open Recipe Library → tap a recipe → edit → save** → throws on the calories/protein/carbs/fat columns. Fix in next batch (item 5 or add the columns).
- **Open Recipe Detail → "Add to Meal Plan"** → throws (wrong table). Fix in next batch (item 4).
- **Open Settings → edit Household name/emoji** → throws on the `emoji` column. Fix in next batch (item 5).
- **Open Activity Feed (drawer)** → silently empty regardless of household activity. Item 3.
- **Open Calendar** → no default tags (insert loop in household_setup fails). User can create tags manually; the default seeds are silently dropped on household creation.
- **Open the leaderboard sheet → tap a member** → `MemberProfileScreen` loads but shows zero badges. The PIN-switching flow that calls `pin_hash` and `current_streak` still works for the PIN check itself; only the streak display is broken.
- **Toggle any setting in Notification Preferences** → "Preference updated" toast appears, but reopening the screen shows the toggle reverted because the column doesn't exist (Supabase ignores unknown keys silently rather than persisting). User trust risk.

Nothing observed in this pass is a crash risk beyond the FilledButton-infinite-width (already fixed). The Activity Feed and most recipe/meal flows fail soft (caught exceptions → empty state or error toast).
