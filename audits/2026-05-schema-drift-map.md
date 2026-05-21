# Schema Drift Map — Flutter app vs. Supabase migrations

Date: 2026-05-21
Branch: `fix/post-iphone-debug-2026-05-21`
SDK: `supabase_flutter 2.12.4` / `postgrest 2.7.0` (verified from `pubspec.lock`)
Migrations read: `0001_initial_schema.sql`, `0002_gamification_functions.sql`, `0003_storage_policies.sql`, `0004_chore_comments.sql`, `0005_announcements.sql`
Files inventoried: 30 screens + 8 services + main.dart (210 distinct Supabase entry points: `.from`, `.rpc`, `.channel`, `.functions.invoke`, `.storage.from`).

---

## SDK method drift

`postgrest 2.7.0` exposes `inFilter(column, List)` (defined at `~/.pub-cache/hosted/pub.dev/postgrest-2.7.0/lib/src/postgrest_filter_builder.dart:237`). It does **not** expose `inSet(...)`.

`grep -rn '\.inSet(' apps/mobile/lib/` → **0 matches.** The earlier prompt's worry about `.inSet`/`.inFilter` drift is resolved on this branch; all three call sites use `.inFilter`:
- `apps/mobile/lib/screens/activity_feed_screen.dart:54`
- `apps/mobile/lib/screens/chore_dashboard_screen.dart:101`
- `apps/mobile/lib/screens/member_profile_screen.dart:52`

No SDK method drift remains.

---

## Tables: what app uses vs. what schema has

Columns listed are only those touched by the app via select/insert/update (not exhaustive).

| Table | App-referenced columns | Schema columns (selected) | Mismatches |
|---|---|---|---|
| `profiles` | `id`, `email`, `display_name`, `avatar_url` | `id`, `email`, `display_name`, `avatar_url`, `created_at`, `updated_at` | none |
| `households` | `id`, `name`, `theme_color`, `owner_user_id`, `tier`, `subscription_status`, **`emoji`** | `id`, `name`, `theme_color`, `owner_user_id`, `tier`, `subscription_status`, `subscription_grace_ends_at`, `created_at`, `updated_at` | **`households.emoji` not in schema** (read in `home_shell_screen.dart:227, 228`; written in `settings_screen.dart:260`) |
| `household_members` | `id`, `household_id`, `kind`, `role`, `auth_user_id`, `display_name`, `avatar_url`, `pin_hash`, `points_balance`, `is_active`, `created_by`, **`current_streak`**, **`user_id`** | `id`, `household_id`, `kind`, `role`, `auth_user_id`, `display_name`, `avatar_url`, `pin_hash`, `points_balance`, `is_active`, `created_by`, `created_at`, `updated_at` | **`current_streak` not in schema** (read in `home_shell_screen.dart:615`, `member_profile_screen.dart:90`, `profile_screen.dart:351`); **`user_id` not in schema** (read in `chore_dashboard_screen.dart:207`, referenced when looking up the assigned member's auth user for `award_points` RPC; column is `auth_user_id`) |
| `household_invites` | `code`, `expires_at`, `max_uses`, `use_count`, `revoked_at`, `created_by`, `household_id`, `id` | same | none |
| `chore_templates` | `title`, `description`, `room_or_category`, `difficulty`, `suggested_points`, `suggested_frequency`, `icon`, `is_system`, `household_id` | same | none |
| `chores` | `id`, `household_id`, `title`, `description`, `assigned_to_member_id`, `created_by_member_id`, `point_value`, `bonus_points`, `difficulty`, `due_at`, `recurrence_rule`, `status`, `completed_at`, `verified_at`, `verified_by_member_id`, `chore_of_day_date` | all present | **`status` enum values used in app that are not in `chore_status`**: `'pending'` (chore_dashboard:101), `'completed'` (chore_detail:48, 197, 875; chore_dashboard:198; activity_feed:54; household_stats:115, 116; member_profile:52; achievements RPC reads; etc.); `'in_progress'` is in enum but rarely used. Enum is: `assigned, in_progress, pending_verification, verified, rejected, overdue, cancelled` |
| `chore_verifications` (table referenced) | `chore_id`, `verifier_member_id`, `created_at`, `status` | **table does not exist** | only `chore_verification_photos` exists in schema |
| `chore_history` | unused by app | full schema | not referenced — see "Tables in schema but never queried" |
| `chore_comments` (0004) | `chore_id`, `member_id`, `comment`, `created_at` | `id`, `chore_id`, `member_id`, `comment`, `created_at`, `updated_at` | none |
| `rewards` | `id`, `household_id`, `title`, `description`, `point_cost`, `icon`, `is_active`, `created_by_member_id` | same | none |
| `reward_redemptions` | `id`, `household_id`, `reward_id`, `member_id`, `point_cost`, `status`, `approved_by_member_id`, `approved_at`, `redeemed_at`, **`created_at`**, **`points_cost`**, **`reward_name`** | `id`, `household_id`, `reward_id`, `member_id`, `point_cost`, `status`, `redeemed_at`, `approved_by_member_id`, `approved_at` | **`created_at` not in schema** (activity_feed:120 orders by it); **`points_cost` not in schema** (activity_feed:121, 133 reads it — column is `point_cost`); **`reward_name` not in schema** (activity_feed:121, 132 — would need a join to `rewards.title`) |
| `point_transactions` | `id`, `household_id`, `member_id`, `type`, `amount`, `balance_after`, `source_table`, `source_id`, `note`, `created_by_member_id`, **`transaction_type`**, **`reason`** | `type`, `note` (the others match) | **`transaction_type` not in schema** — column is `type` (activity_feed:99, 111 use `transaction_type`; member_profile:58 uses it). **`reason` not in schema** — column is `note` (activity_feed:99, 112 read `reason`) |
| `achievements` | `id`, `household_id`, `member_id`, `badge_key`, `badge_name`, `description`, `icon`, `earned_at` | same | none |
| `member_achievements` (table referenced) | `badge_name`, `badge_icon`, `household_id`, `member_id`, `created_at` | **table does not exist** | App reads from this in `activity_feed_screen.dart:77-93` — schema has `achievements` with `badge_key`, `badge_name`, `icon`, `earned_at` |
| `member_badges` (table referenced) | join to `badges` table | **neither `member_badges` nor `badges` exists** | App reads in `member_profile_screen.dart:72-77` — the `achievements` table is the schema's equivalent |
| `calendar_tags` | `id`, `household_id`, `name`, `icon`, `color`, **`emoji`** | `id`, `household_id`, `name`, `icon`, `color`, `created_by_member_id`, ... | **`calendar_tags.emoji` not in schema** (read in calendar_screen as `tag['emoji']`; default tags inserted at `household_setup_screen.dart:106-112` with `{'name':..., 'color':..., 'emoji':...}` will fail at insert) |
| `calendar_events` | `id`, `household_id`, `title`, `description`, `starts_at`, `ends_at`, `all_day`, `tag_id`, `created_by_member_id`, `reminder_minutes_before`, `color_override` | same | none |
| `calendar_event_members` | `event_id`, `member_id` | same | none |
| `master_recipes` | `id`, `title`, `description`, `ingredients`, `steps`, `prep_time_minutes`, `cook_time_minutes`, `servings`, `difficulty`, `cuisine`, `tags`, `image_url`, `source_url`, `status`, `average_rating`, `rating_count` | same + `added_count`, `approved_at`, etc. | none |
| `household_recipes` | `id`, `household_id`, `master_recipe_id`, `title`, `description`, `ingredients`, `steps`, `prep_time_minutes`, `cook_time_minutes`, `servings`, `difficulty`, `cuisine`, `image_url`, `source`, `source_url`, `is_favorite`, `created_by_member_id`, **`calories_per_serving`**, **`protein_g`**, **`carbs_g`**, **`fat_g`** | full schema (no nutrition columns) | **`calories_per_serving`, `protein_g`, `carbs_g`, `fat_g` not in schema** (recipe_detail:114, 157, 720-723 read/write them; an UPDATE that includes any of these keys will be rejected) |
| `recipes` (table referenced) | full table scan in data_export | **table does not exist** | `data_export_screen.dart:166` reads `from('recipes')` — should be `from('household_recipes')` |
| `meal_plans` | `id`, `household_id`, `planned_for`, `meal_type`, `recipe_id`, `custom_title`, `assigned_cook_member_id`, `servings`, `notes`, `created_by_member_id` | same | none |
| `meal_plan_entries` (table referenced) | `household_id`, `recipe_id`, `meal_date`, `meal_type`, `added_by_member_id` | **table does not exist** | `recipe_detail_screen.dart:343-349` writes to this — should be `meal_plans` with `planned_for` column instead of `meal_date` |
| `stores` | `id`, `household_id`, `name`, `address`, `is_default`, `created_by_member_id` | same | none |
| `shopping_lists` | `id`, `household_id`, `name`, `is_active`, `created_by_member_id`, `archived_at` | same | none |
| `shopping_items` | `id`, `household_id`, `shopping_list_id`, `name`, `quantity`, `unit`, `display_quantity`, `store_id`, `category`, `purchased`, `purchased_by_member_id`, `purchased_at`, `source_recipe_id`, `source_meal_plan_id`, `added_by_member_id`, `sort_order`, **`is_purchased`** | as listed; **NO** `is_purchased` | **`is_purchased` not in schema** — `recipe_detail_screen.dart:266` inserts `'is_purchased': false`; everywhere else uses `purchased`. This row's `purchased` defaults to false at the DB level, so the bug is that `is_purchased` is ignored, but no error |
| `subscriptions` | `tier`, `status`, `current_period_ends_at` | full schema | none |
| `notification_preferences` | `member_id`, **`household_id`**, **`push_enabled`**, `morning_digest`, `evening_recap`, `chore_reminders`, **`chore_assignments`**, **`chore_verification`**, **`overdue_alerts`**, **`meal_reminders`**, **`shopping_updates`**, **`achievement_notifications`**, **`points_updates`**, **`streak_reminders`**, **`member_joined`**, **`household_announcements`**, `verification_alerts`, `gamification_alerts`, `calendar_reminders`, **`quiet_hours_enabled`**, `quiet_hours_start`, `quiet_hours_end` | `id`, `member_id`, `morning_digest`, `evening_recap`, `chore_reminders`, `verification_alerts`, `gamification_alerts`, `calendar_reminders`, `quiet_hours_start`, `quiet_hours_end`, `updated_at` | **Many app-only columns**: `household_id`, `push_enabled`, `chore_assignments`, `chore_verification`, `overdue_alerts`, `meal_reminders`, `shopping_updates`, `achievement_notifications`, `points_updates`, `streak_reminders`, `member_joined`, `household_announcements`, `quiet_hours_enabled`. Schema covers a different (smaller) set of toggles. Upserts from `settings_screen.dart:101-107` and `notification_preferences_screen.dart` will succeed for the columns that exist and silently drop the rest |
| `device_tokens` | `member_id`, `platform`, `token`, `last_seen_at` | same | none |
| `feedback_requests` | `household_id`, `submitted_by_member_id`, `type`, `title`, `description`, `status`, `admin_notes` | same | none |
| `analytics_events` | unused by app | full schema | not referenced |
| `audit_logs` | unused by app | full schema | not referenced |
| `chore_verification_photos` | unused by app | full schema | not referenced |
| `master_recipe_ratings` | unused by app | full schema | not referenced |
| `announcements` (0005) | `id`, `household_id`, `created_by_member_id`, `title`, `message`, `is_pinned`, `created_at` | same | none |

---

## Tables referenced by app but missing from schema

5 tables. App calls will error or silently fail.

| App reference | Where | What the app expects | Schema equivalent |
|---|---|---|---|
| `chore_verifications` | `chore_detail_screen.dart:131` (select to populate activity log) | rows tied to a chore_id with `verifier_member_id`, `status`, `created_at` | wrap in `try/catch (_) {}` already swallows the error; activity log silently stays empty. Schema's `chore_history` is the closest concept. |
| `member_achievements` | `activity_feed_screen.dart:77` | columns `badge_name`, `badge_icon`, joined to `household_members` | should be `achievements` (with `badge_name`, `icon`, no `badge_icon`) |
| `member_badges` | `member_profile_screen.dart:73` | join to `badges` table | should be `achievements` |
| `meal_plan_entries` | `recipe_detail_screen.dart:343` (insert) | `recipe_id`, `meal_date`, `meal_type`, `household_id`, `added_by_member_id` | `meal_plans` table; column rename `meal_date` → `planned_for`; also missing `created_by_member_id` |
| `recipes` | `data_export_screen.dart:166` (select for export) | full table | should be `household_recipes` |

---

## Tables in schema but never queried by app

These exist in migrations but no screen/service touches them. Either dead schema or a feature that was planned but never wired:

- `chore_history` (likely meant for completion log; app uses `chores.completed_at` + ad-hoc queries in `household_stats_screen.dart`)
- `chore_verification_photos` (photos feature exists in schema but no UI/upload uses it)
- `master_recipe_ratings` (ratings shown in recipe library are read from `master_recipes.average_rating`, not from this table)
- `analytics_events` (no event emitter in the app)
- `audit_logs` (no audit writes from the app)

---

## RPCs

| RPC name | App call site(s) | App params | Schema signature | Mismatch |
|---|---|---|---|---|
| `award_points` | `chore_dashboard_screen.dart:211` | `p_user_id, p_household_id, p_points, p_reason, p_reference_id` | `(p_auth_user_id, p_household_id, p_points, p_note, p_source_table, p_source_id)` | **Wrong param names.** `p_user_id` not accepted (should be `p_auth_user_id`); `p_reason` not accepted (should be `p_note`); `p_reference_id` not accepted (should be `p_source_id`; `p_source_table` missing). RPC call will fail. |
| `check_and_award_achievements` | `chore_dashboard_screen.dart:220` | `p_user_id, p_household_id` | `(p_auth_user_id, p_household_id)` | **Wrong param name.** `p_user_id` should be `p_auth_user_id`. |
| `get_leaderboard` | `home_shell_screen.dart:558` | `p_household_id` | `(p_household_id)` returns `(member_id, display_name, kind, points_balance, rank)` | OK signature, but app expects fields `id`, `current_streak`, `member_id`, `auth_user_id` — only `member_id`, `display_name`, `kind`, `points_balance`, `rank` are returned. `current_streak` and `id` not in RPC result. |
| `increment_master_recipe_added_count` | `recipe_library_screen.dart:215` | `recipe_id` | `(p_recipe_id)` | **Param name mismatch:** Dart side sends `{'recipe_id': ...}` instead of `{'p_recipe_id': ...}`. |
| `calculate_streak` | (no app caller) | n/a | exists | unused |

---

## Status-enum drift on `chores.status`

Schema enum (`chore_status`): `assigned, in_progress, pending_verification, verified, rejected, overdue, cancelled`.

App uses these literal values when filtering or updating:

- `'pending'` — `chore_dashboard_screen.dart:101` (inFilter) — **NOT in enum, breaks the Chores tab**
- `'completed'` — `chore_dashboard_screen.dart:198` (update on approve), `chore_detail_screen.dart:48` (dropdown option), `chore_detail_screen.dart:875` (quick action), `activity_feed_screen.dart:54` (filter), `household_stats_screen.dart:115` (filter), `member_profile_screen.dart:52` (filter), `search_screen.dart` (status display label) — **NOT in enum**
- `'verified'`, `'pending_verification'`, `'assigned'`, `'rejected'`, `'overdue'`, `'cancelled'`, `'in_progress'` — all OK

App's mental model: `assigned → in_progress → completed → verified`. Schema's mental model: `assigned → in_progress → pending_verification → verified|rejected`. The app uses `'completed'` as a synonym for both `pending_verification` and `verified` depending on context.

---

## RLS gaps (now closed manually but not in migrations)

Per the prompt's CONTEXT, four policies were added manually in Supabase Studio after first-time setup failed:

1. `profiles_self_insert` — INSERT on `profiles` WITH CHECK `id = auth.uid()`
2. `households_authenticated_insert` — INSERT on `households` WITH CHECK `owner_user_id = auth.uid()`
3. `household_members_self_insert` — INSERT on `household_members` WITH CHECK conditions for self-as-adult or admin-of-target-household
4. Replaced `households_member_select` with `households_member_or_owner_select` — SELECT allows owner OR member

These exist in the live DB but **not** in any migration file. Captured by this pass in `supabase/migrations/0006_post_iphone_fixes.sql`.

`0001_initial_schema.sql` only defined SELECT/UPDATE/ALL-with-membership policies; it never defined INSERT policies for the bootstrap chain (profile → household → member). That's the gap.

Also worth noting: `household_scoped_chores` (0001:521) is `FOR ALL USING (is_household_member(household_id))` — this means INSERT/UPDATE/DELETE all gated by `USING`, with no `WITH CHECK`. Per PostgreSQL semantics, a `FOR ALL` policy with only `USING` applies `USING` as `WITH CHECK` too. So `is_household_member(household_id) = true` is required to insert a chore — which is correct, but worth confirming once a chore is actually created from the app.

---

## Highest-impact mismatches (top 10 by user-visible damage)

1. **`chores.status IN ('assigned', 'pending')` filter in `chore_dashboard_screen.dart:101`** — Chores tab cannot load any chores. Postgres rejects the query because `'pending'` is not a valid `chore_status`. (This is the symptom the user is hitting now.)
2. **`award_points` and `check_and_award_achievements` RPC param names** in `chore_dashboard_screen.dart:211, 220` — chore approval will throw. Once chores load, completing/verifying any chore breaks.
3. **`chore_status` enum has no `'completed'`** — every code path that updates a chore to `'completed'` (chore_dashboard:198, chore_detail:48, 197, 875) will throw. Chores can never be marked completed by the app.
4. **`household_recipes.calories_per_serving`, `protein_g`, `carbs_g`, `fat_g`** — any recipe save from `recipe_detail_screen.dart:151-167` will fail at the update because these columns don't exist. Recipe edit screen breaks.
5. **`recipe_detail_screen.dart:343` writes to `meal_plan_entries`** — the "Add to Meal Plan" action from the recipe detail screen will throw. (Meal Planner's own screen uses `meal_plans` correctly.)
6. **`data_export_screen.dart:166` reads from non-existent `recipes` table** — JSON/CSV export will partially fail; the export will silently exclude recipes (try/catch swallows).
7. **`activity_feed_screen.dart` references `member_achievements`, `point_transactions.transaction_type`, `point_transactions.reason`, `reward_redemptions.points_cost`, `reward_redemptions.reward_name`, `reward_redemptions.created_at`** — Activity Feed will show no activity (all sub-fetches caught by `catch (_) {}` and yield empty arrays).
8. **`member_profile_screen.dart:73` reads from non-existent `member_badges`** — viewing any member's profile from the leaderboard shows zero badges even when achievements exist. Also references `transaction_type` and `current_streak`.
9. **`households.emoji` doesn't exist** — `home_shell_screen.dart:227, 228` reads it for the app bar (will be null → no emoji shown — harmless). `settings_screen.dart:260` writes it on household edit — the update will be rejected. Editing the household from settings breaks.
10. **`notification_preferences` has 13 app-side columns the schema lacks** — every toggle the user flips in `notification_preferences_screen.dart` is silently discarded; only `morning_digest`, `evening_recap`, `chore_reminders`, `verification_alerts`, `gamification_alerts`, `calendar_reminders`, `quiet_hours_start`, `quiet_hours_end` actually persist. App's master "Push Notifications" toggle (`push_enabled`) does nothing.

Tier 2 (visible but lower impact):
- `household_members.current_streak` missing → streak displays always 0 (home_shell leaderboard, member_profile, profile).
- `household_members.user_id` lookup in `chore_dashboard_screen.dart:207` returns null; the `award_points` RPC then errors with "user is not a member" (the column should be `auth_user_id`).
- `calendar_tags.emoji` missing → default tag inserts at `household_setup_screen.dart:106-119` will fail one-by-one. Household creation actually works because the for-loop wraps in implicit RLS context, but each insert error is swallowed (no explicit try/catch in the helper). On a fresh household, default tags are likely all missing.
- `recipe_library_screen.dart:215` calls `increment_master_recipe_added_count` with param `recipe_id` instead of `p_recipe_id` — adding a master recipe to your library increments the count silently 0 times.
- `chore_detail_screen.dart:131` reads `chore_verifications` (table doesn't exist) — activity log on chore detail is always empty.

---

## Where each finding will be fixed in this pass

- **#1 (chores filter)** — fixed in `chore_dashboard_screen.dart` as part of Deliverable 2A.
- **#2 (RPC params), #3 (status enum), #4 (recipe nutrition), #5 (meal_plan_entries), #7 (activity feed), #8 (member_badges), #9 (households.emoji), #10 (notification_preferences)** — **out of scope for this pass.** Documented here so the next batch knows the shape.
- **Manual RLS policies** — captured in `0006_post_iphone_fixes.sql` (Deliverable 2D).
- **FilledButton infinite-width** — fixed in `feature_tour_service.dart` (Deliverable 2B).
- **setState-after-dispose in two specific load methods** — fixed in `chore_dashboard_screen.dart:115-124` and `recipe_library_screen.dart:97-110` (Deliverable 2C).
