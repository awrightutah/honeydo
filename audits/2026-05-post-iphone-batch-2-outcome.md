# Post-iPhone Batch 2 — Outcome

Date: 2026-05-21
Branch: `fix/post-iphone-batch-2-2026-05-21` (off `fix/post-iphone-debug-2026-05-21`)
Reference: `audits/2026-05-schema-drift-map.md`, `audits/2026-05-post-iphone-next-steps.md`

---

## Fixes applied

### Fix 1 — `chore_status` enum alignment (writes + filters)

The schema enum has no `'completed'`. Mapped:
- "user marks done" → `'pending_verification'`
- "admin approves" → `'verified'`

UI labels ("Completed", "Verified") preserved; only the underlying enum values changed.

**Diff — `apps/mobile/lib/screens/chore_dashboard_screen.dart:200`**
```diff
       if (approved) {
         // Update chore status
         await Supabase.instance.client.from('chores').update({
-          'status': 'completed',
+          'status': 'verified',
           'verified_at': DateTime.now().toIso8601String(),
           'verified_by_member_id': _myMembership!['id'],
         }).eq('id', choreId);
```

**Diff — `apps/mobile/lib/screens/chore_detail_screen.dart:48` (dropdown options)**
```diff
   final List<Map<String, String>> _statuses = [
     {'value': 'assigned', 'label': 'Assigned'},
     {'value': 'in_progress', 'label': 'In Progress'},
-    {'value': 'completed', 'label': 'Completed'},
+    {'value': 'pending_verification', 'label': 'Completed'},
     {'value': 'verified', 'label': 'Verified'},
     {'value': 'skipped', 'label': 'Skipped'},
   ];
```

**Diff — `apps/mobile/lib/screens/chore_detail_screen.dart:304-323` (color/icon switches)**
```diff
   Color _statusColor(String status) {
     return switch (status) {
       'assigned' => AppColors.skyBlue,
       'in_progress' => AppColors.honeyGold,
-      'completed' => AppColors.grassGreen,
+      'pending_verification' => AppColors.grassGreen,
       'verified' => const Color(0xFF4CAF50),
       'skipped' => Colors.grey,
       _ => Colors.grey,
     };
   }

   IconData _statusIcon(String status) {
     return switch (status) {
       'assigned' => Icons.assignment,
       'in_progress' => Icons.pending,
-      'completed' => Icons.check_circle,
+      'pending_verification' => Icons.check_circle,
       'verified' => Icons.verified,
       'skipped' => Icons.skip_next,
       _ => Icons.help,
     };
   }
```

**Diff — `apps/mobile/lib/screens/chore_detail_screen.dart:514-516` (action chips)**
```diff
                 if (status == 'in_progress' || status == 'assigned')
-                  _buildActionChip('Complete', Icons.check_circle_rounded, AppColors.grassGreen, () => _quickUpdateStatus('completed')),
-                if (status == 'completed' && isAdmin)
+                  _buildActionChip('Complete', Icons.check_circle_rounded, AppColors.grassGreen, () => _quickUpdateStatus('pending_verification')),
+                if (status == 'pending_verification' && isAdmin)
                   _buildActionChip('Verify', Icons.verified_rounded, const Color(0xFF4CAF50), () => _quickUpdateStatus('verified')),
```

**Diff — `apps/mobile/lib/screens/chore_detail_screen.dart:678` (activity log label)**
```diff
                 Text(
-                  '$verifier ${status == 'verified' ? 'verified' : status == 'completed' ? 'completed' : 'updated'} this chore',
+                  '$verifier ${status == 'verified' ? 'verified' : status == 'pending_verification' ? 'completed' : 'updated'} this chore',
                   style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                 ),
```
(The user-visible word "completed" is preserved as the third comparison's value; only the status check changed.)

**Diff — `apps/mobile/lib/screens/chore_detail_screen.dart:875-883` (quick-update side effects)**
```diff
       final updates = <String, dynamic>{'status': newStatus};
-      if (newStatus == 'completed' || newStatus == 'verified') {
+      if (newStatus == 'pending_verification' || newStatus == 'verified') {
         updates['completed_at'] = DateTime.now().toIso8601String();
       }
       ...
-      if ((newStatus == 'completed' || newStatus == 'verified') && previousChore != null) {
+      if ((newStatus == 'pending_verification' || newStatus == 'verified') && previousChore != null) {
         await _createNextRecurringChoreIfNeeded(previousChore);
       }
```

**Diff — `apps/mobile/lib/screens/activity_feed_screen.dart:54`**
```diff
-            .inFilter('status', ['completed', 'verified', 'pending_verification'])
+            .inFilter('status', ['verified', 'pending_verification'])
```

**Diff — `apps/mobile/lib/screens/member_profile_screen.dart:52`**
```diff
-          .inFilter('status', ['verified', 'completed']);
+          .inFilter('status', ['verified', 'pending_verification']);
```

`household_stats_screen.dart:115-116` and `search_screen.dart:460-468` — **no edit needed** on this branch. `household_stats` already filters by `'verified' || 'pending_verification'`; `search_screen`'s `_statusColors` map already uses schema-correct enum keys.

---

### Fix 2 — `award_points` and `check_and_award_achievements` RPC params

The SQL function (verified in `supabase/migrations/0002_gamification_functions.sql:6-15`) is:
```
award_points(p_auth_user_id, p_household_id, p_points, p_note, p_source_table, p_source_id)
```
The Dart side was sending wrong param names AND looking up `user_id` on `household_members` (column is `auth_user_id`).

**Diff — `apps/mobile/lib/screens/chore_dashboard_screen.dart:207-225`**
```diff
         // Award points to the user who completed it
         final assignedMemberId = chore['assigned_to_member_id'] as String;
         final assignedMember = await Supabase.instance.client
             .from('household_members')
-            .select('user_id')
+            .select('auth_user_id')
             .eq('id', assignedMemberId)
             .single();

         await Supabase.instance.client.rpc('award_points', params: {
-          'p_user_id': assignedMember['user_id'],
+          'p_auth_user_id': assignedMember['auth_user_id'],
           'p_household_id': chore['household_id'],
           'p_points': points + (chore['bonus_points'] ?? 0),
-          'p_reason': 'chore_completion',
-          'p_reference_id': choreId,
+          'p_note': 'chore_completion',
+          'p_source_table': 'chores',
+          'p_source_id': choreId,
         });

         // Check for new achievements
         await Supabase.instance.client.rpc('check_and_award_achievements', params: {
-          'p_user_id': assignedMember['user_id'],
+          'p_auth_user_id': assignedMember['auth_user_id'],
           'p_household_id': chore['household_id'],
         });
```

---

### Fix 3 — `increment_master_recipe_added_count` RPC param

**Diff — `apps/mobile/lib/screens/recipe_library_screen.dart:215`**
```diff
       // Increment added_count on master recipe
       await Supabase.instance.client.rpc('increment_master_recipe_added_count',
-          params: {'recipe_id': masterRecipe['id']});
+          params: {'p_recipe_id': masterRecipe['id']});
```

---

### Fix 4 — `activity_feed_screen.dart` table/column rewrites

Three sub-fixes: achievements table, point_transactions columns, reward_redemptions denormalized field → join.

**Diff — `apps/mobile/lib/screens/activity_feed_screen.dart:74-93` (achievements)**
```diff
       // 2. Achievements earned
       try {
         final achievements = await Supabase.instance.client
-            .from('member_achievements')
-            .select('created_at, badge_name, badge_icon, household_members!member_achievements_member_id_fkey(display_name, kind)')
+            .from('achievements')
+            .select('earned_at, badge_name, icon, household_members!achievements_member_id_fkey(display_name, kind)')
             .eq('household_id', householdId)
-            .order('created_at', ascending: false)
+            .order('earned_at', ascending: false)
             .limit(20);

         for (final achievement in achievements) {
           allActivities.add({
             'type': 'achievement_earned',
-            'timestamp': achievement['created_at'],
+            'timestamp': achievement['earned_at'],
             'member_name': achievement['household_members']?['display_name'] ?? 'Someone',
             'member_kind': achievement['household_members']?['kind'] ?? 'adult_auth_user',
             'badge_name': achievement['badge_name'] ?? 'Badge',
-            'badge_icon': achievement['badge_icon'] ?? '🏆',
+            'badge_icon': achievement['icon'] ?? '🏆',
           });
         }
       } catch (_) {}
```

**Diff — `apps/mobile/lib/screens/activity_feed_screen.dart:95-115` (point_transactions)**
```diff
       // 3. Points transactions
       try {
         final transactions = await Supabase.instance.client
             .from('point_transactions')
-            .select('created_at, amount, transaction_type, reason, household_members!point_transactions_member_id_fkey(display_name, kind)')
+            .select('created_at, amount, type, note, household_members!point_transactions_member_id_fkey(display_name, kind)')
             .eq('household_id', householdId)
             .order('created_at', ascending: false)
             .limit(20);

         for (final tx in transactions) {
           allActivities.add({
             'type': 'points',
             'timestamp': tx['created_at'],
             'member_name': tx['household_members']?['display_name'] ?? 'Someone',
             'member_kind': tx['household_members']?['kind'] ?? 'adult_auth_user',
             'amount': tx['amount'] ?? 0,
-            'transaction_type': tx['transaction_type'] ?? 'earned',
-            'reason': tx['reason'] ?? '',
+            'transaction_type': tx['type'] ?? 'earned',
+            'reason': tx['note'] ?? '',
           });
         }
       } catch (_) {}
```
(The local map keys `'transaction_type'` and `'reason'` are kept because downstream rendering still uses them. Only the source columns and Dart-side reads changed.)

**Diff — `apps/mobile/lib/screens/activity_feed_screen.dart:117-136` (reward_redemptions)**
```diff
       // 4. Reward redemptions
       try {
         final redemptions = await Supabase.instance.client
             .from('reward_redemptions')
-            .select('created_at, reward_name, points_cost, household_members!reward_redemptions_member_id_fkey(display_name, kind)')
+            .select('redeemed_at, point_cost, rewards(title, icon), household_members!reward_redemptions_member_id_fkey(display_name, kind)')
             .eq('household_id', householdId)
-            .order('created_at', ascending: false)
+            .order('redeemed_at', ascending: false)
             .limit(20);

         for (final redemption in redemptions) {
           allActivities.add({
             'type': 'reward_redeemed',
-            'timestamp': redemption['created_at'],
+            'timestamp': redemption['redeemed_at'],
             'member_name': redemption['household_members']?['display_name'] ?? 'Someone',
             'member_kind': redemption['household_members']?['kind'] ?? 'adult_auth_user',
-            'reward_name': redemption['reward_name'] ?? 'Reward',
-            'points_cost': redemption['points_cost'] ?? 0,
+            'reward_name': redemption['rewards']?['title'] ?? 'Reward',
+            'points_cost': redemption['point_cost'] ?? 0,
           });
         }
       } catch (_) {}
```

---

### Fix 5 — `member_profile_screen.dart` achievements + columns

**Diff — `apps/mobile/lib/screens/member_profile_screen.dart:58`**
```diff
-          .eq('transaction_type', 'earned');
+          .eq('type', 'earned');
```

**Diff — `apps/mobile/lib/screens/member_profile_screen.dart:72-77` (badge load)**
```diff
       final badges = await Supabase.instance.client
-          .from('member_badges')
-          .select('*, badges(*)')
+          .from('achievements')
+          .select('*')
           .eq('member_id', widget.memberId)
           .order('earned_at', ascending: false)
           .limit(20);
```

**Diff — `apps/mobile/lib/screens/member_profile_screen.dart:295-303` (badge render)**
```diff
       children: _badges.map((badge) {
-        final badgeData = badge['badges'] as Map<String, dynamic>?;
-        final name = badgeData?['name'] ?? 'Badge';
-        final emoji = badgeData?['emoji'] ?? '🏆';
+        final name = badge['badge_name'] ?? 'Badge';
+        final emoji = badge['icon'] ?? '🏆';
         final earnedAt = badge['earned_at'];
```

---

### Fix 6 — `recipe_detail_screen.dart` meal-plan write + shopping-list field

**Diff — `apps/mobile/lib/screens/recipe_detail_screen.dart:343-349` (meal plan write)**
```diff
-        await Supabase.instance.client.from('meal_plan_entries').insert({
+        await Supabase.instance.client.from('meal_plans').insert({
           'household_id': _householdMember!['household_id'],
           'recipe_id': widget.recipeId,
-          'meal_date': selectedDate.toIso8601String().split('T')[0],
+          'planned_for': selectedDate.toIso8601String().split('T')[0],
           'meal_type': selectedMealType,
-          'added_by_member_id': _householdMember!['id'],
+          'created_by_member_id': _householdMember!['id'],
         });
```

**Diff — `apps/mobile/lib/screens/recipe_detail_screen.dart:266` (shopping item field)**
```diff
           await Supabase.instance.client.from('shopping_items').insert({
             'shopping_list_id': selectedListId,
             'name': ingMap['raw'] ?? ingMap['name'] ?? ing.toString(),
             'quantity': ingMap['quantity']?.toString() ?? '',
-            'is_purchased': false,
+            'purchased': false,
           });
```

**Fix 6b: nutrition columns (new migration)** — see `0007_recipe_nutrition.sql` below. No Dart change needed; the reads/writes at recipe_detail:114, 157, 720-723 start working once the migration runs.

---

### Fix 7 — `households.emoji` + `calendar_tags.emoji` (new migration)

Migration `0008_emoji_columns.sql` (below). Verified no app code change needed at `home_shell_screen.dart:218-222, 227-228`, `settings_screen.dart:205, 260, 481`, or `household_setup_screen.dart:106-111` — all sites already produce/consume the `emoji` field; they just needed the column to exist.

---

### Fix 8 — `household_members.current_streak` + `get_leaderboard` RPC update (new migration)

Migration `0009_member_streak.sql` (below). The `get_leaderboard` RPC's current signature (`0002_gamification_functions.sql:67-72`) is `(member_id, display_name, kind, points_balance, rank)` — no `current_streak`. The new migration DROPs and recreates the function to add `current_streak` between `points_balance` and `rank`. Both `longest_streak` and `last_completion_date` are added to the table for future streak-computation code but are not yet consumed by the app.

---

## OUTCOME

**Branch:** `fix/post-iphone-batch-2-2026-05-21` (off `fix/post-iphone-debug-2026-05-21`).

**Modified files (this batch, 6):**
- `apps/mobile/lib/screens/activity_feed_screen.dart`
- `apps/mobile/lib/screens/chore_dashboard_screen.dart`
- `apps/mobile/lib/screens/chore_detail_screen.dart`
- `apps/mobile/lib/screens/member_profile_screen.dart`
- `apps/mobile/lib/screens/recipe_detail_screen.dart`
- `apps/mobile/lib/screens/recipe_library_screen.dart`

**New files (this batch, 3 migrations + this report):**
- `supabase/migrations/0007_recipe_nutrition.sql`
- `supabase/migrations/0008_emoji_columns.sql`
- `supabase/migrations/0009_member_streak.sql`
- `audits/2026-05-post-iphone-batch-2-outcome.md` (this file)

**Still-uncommitted from previous batch (carried into this branch's working tree, not modified here):**
- `apps/mobile/lib/services/feature_tour_service.dart` (FilledButton infinite-width fix)
- `supabase/migrations/0006_post_iphone_fixes.sql` (RLS policy capture)

**Analyzer:**
- Before: 327 issues / 44 errors / 78 warnings / 205 infos
- After:  327 issues / 44 errors / 78 warnings / 205 infos
- Delta:  0 / 0 / 0 / 0

**Migration files that need to be applied to Supabase** — all four (0006-0009) need to land. The 0006 RLS policies are already in the live DB per the prior batch's note; the 0007-0009 schema additions are new. The combined SQL block at the end of this report is idempotent (every statement uses `if not exists` / `drop ... if exists ... ; create ...`) and safe to re-run.

---

## Followups

Spotted while doing this batch; intentionally not fixed:

1. **`chore_detail_screen.dart:48, 310, 321, 518` — `'skipped'` status value.** Same class of bug as the `'completed'` issue: `'skipped'` is not in `chore_status` (the closest enum value is `'cancelled'`). The dropdown option, color map, icon map, and Skip action chip all use it. Saving the screen with status "Skipped" will throw. Out of scope for this batch — flag for next batch.

2. **`recipe_detail_screen.dart:265` writes `'quantity': ingMap['quantity']?.toString() ?? ''`.** The `shopping_items.quantity` column is `numeric`. Passing an empty string or a non-numeric token will throw at insert. The `recipe_library_screen.dart` ingredient-import path handles this correctly (sets `display_quantity` and parses to double). Recipe-detail's "Add to Shopping List" should follow the same pattern.

3. **`activity_feed_screen.dart:54` — the chores activity-feed filter now matches only `verified` + `pending_verification`.** This is correct for "completed work" but excludes the older 'completed' value if any rows from the prior bug period exist with that literal. They shouldn't — Postgres would have rejected the writes — but if you ever loaded test data with `'completed'`, those rows will no longer show in the feed.

4. **`settings_screen.dart` — `Edit Household` sheet sends `'emoji'` and `'name'` together.** After `0008_emoji_columns.sql` lands, this works. Before it lands, the whole update is rejected (losing the name too). If you're rolling the migration out cautiously, apply the migration first.

5. **`notification_preferences` still has ~13 columns the app sets that the schema doesn't have.** Not in this batch's scope. The app's master push toggle and per-category switches silently no-op. Documented in the schema drift map.

6. **`recipe_detail_screen.dart:114, 157, 720-723` recipe-detail nutrition reads/writes** — these are restored after `0007_recipe_nutrition.sql`. The existing reads use `_recipe?['calories_per_serving']`, etc.; the values will be null until the user fills them in via the edit screen. No fallback rendering is needed (the screen already conditionally hides empty nutrition cards).

7. **The drift map noted `household_stats_screen.dart:115` as filtering `'completed'`. On this branch it already filters `'verified' || 'pending_verification'`.** Either the drift map was reading a different revision or that fix landed before the audit. Recording so the next audit knows.

8. **`chore_dashboard_screen.dart:200` writes `'verified'` directly, skipping `'pending_verification'` entirely** when an admin approves a chore from the dashboard. (The chore_detail flow now does the intermediate step via the Complete action chip.) This is intentional — the dashboard "Approve" action represents the admin's verify step, which the prior status was `pending_verification` → `verified`. The status transition is correct; just noting the dashboard skips the intermediate state in some flows.

9. **`get_leaderboard` RPC change in `0009_member_streak.sql` is a signature change** (added a column to the return TABLE). The migration uses `DROP FUNCTION ... ; CREATE FUNCTION ...` rather than `CREATE OR REPLACE`. If any other database object depends on the function's old signature (it shouldn't — no views or other functions reference it), the DROP would fail. Re-running the migration on an environment where it already applied is a no-op (DROP IF EXISTS removes the new version, CREATE re-adds it).

10. **`Notification preferences` `'quiet_hours_enabled'`, `'push_enabled'`, etc.** Out of scope this batch but the same "add columns to schema" approach would unblock the settings screen. A small migration is the right call when you're ready.

---

## Copy-into-SQL-Editor block

This is the concatenation of all uncommitted-but-needed migrations (0006 through 0009). It is idempotent — every statement uses `if not exists` or `drop ... if exists ... ; create ...`. Safe to re-run.

If `0006` was already applied (per the prior batch's note that the policies were added manually in Studio), the `drop policy if exists / create policy` will re-create them cleanly.

```sql
-- =========================================================================
-- 0006_post_iphone_fixes.sql — RLS policies for household creation bootstrap
-- =========================================================================

drop policy if exists profiles_self_insert on public.profiles;
create policy profiles_self_insert
  on public.profiles
  for insert
  to authenticated
  with check (id = auth.uid());

drop policy if exists households_authenticated_insert on public.households;
create policy households_authenticated_insert
  on public.households
  for insert
  to authenticated
  with check (owner_user_id = auth.uid());

drop policy if exists household_members_self_insert on public.household_members;
create policy household_members_self_insert
  on public.household_members
  for insert
  to authenticated
  with check (
    (
      kind = 'adult_auth_user'
      and auth_user_id = auth.uid()
      and exists (
        select 1
        from public.households h
        where h.id = household_id
          and h.owner_user_id = auth.uid()
      )
    )
    or
    public.is_household_admin(household_id)
  );

drop policy if exists households_member_select on public.households;
drop policy if exists households_member_or_owner_select on public.households;
create policy households_member_or_owner_select
  on public.households
  for select
  to authenticated
  using (
    owner_user_id = auth.uid()
    or public.is_household_member(id)
  );


-- =========================================================================
-- 0007_recipe_nutrition.sql — nutrition columns on recipes
-- =========================================================================

alter table public.household_recipes
  add column if not exists calories_per_serving integer,
  add column if not exists protein_g numeric,
  add column if not exists carbs_g numeric,
  add column if not exists fat_g numeric;

alter table public.master_recipes
  add column if not exists calories_per_serving integer,
  add column if not exists protein_g numeric,
  add column if not exists carbs_g numeric,
  add column if not exists fat_g numeric;


-- =========================================================================
-- 0008_emoji_columns.sql — emoji on households + calendar_tags
-- =========================================================================

alter table public.households
  add column if not exists emoji text;

alter table public.calendar_tags
  add column if not exists emoji text;


-- =========================================================================
-- 0009_member_streak.sql — streak fields + get_leaderboard signature update
-- =========================================================================

alter table public.household_members
  add column if not exists current_streak integer not null default 0,
  add column if not exists longest_streak integer not null default 0,
  add column if not exists last_completion_date date;

drop function if exists public.get_leaderboard(uuid);
create function public.get_leaderboard(p_household_id uuid)
returns table (
  member_id uuid,
  display_name text,
  kind member_kind,
  points_balance integer,
  current_streak integer,
  rank bigint
) as $$
select
  hm.id,
  hm.display_name,
  hm.kind,
  hm.points_balance,
  hm.current_streak,
  rank() over (order by hm.points_balance desc) as rank
from public.household_members hm
where hm.household_id = p_household_id
order by hm.points_balance desc;
$$ language sql stable security definer;
```
