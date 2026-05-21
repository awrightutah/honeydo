# Batch Fix 4 — Outcome (shopping display crash + kid chore approval)

Date: 2026-05-21
Branch: `fix/batch-4-shopping-display-and-kid-chores-2026-05-21` (off `fix/chore-verify-flow-2026-05-21`)

## Branch

`fix/batch-4-shopping-display-and-kid-chores-2026-05-21`

## Modified files

- `apps/mobile/lib/screens/shopping_list_screen.dart` — coerce numeric `quantity` to a sensible String before `Text(...)`.
- `apps/mobile/lib/screens/meal_planner_screen.dart` — defensive `.toString()` on meal `notes` rendering.
- `apps/mobile/lib/screens/recipe_detail_screen.dart` — defensive `.toString()` on edit-mode ingredient row.
- `apps/mobile/lib/screens/chore_dashboard_screen.dart` — branch `_verifyChore` on `assignedMember['kind']` so sub_profile chores hit the new member_id-based RPCs.

## New files

- `supabase/migrations/0011_award_points_by_member.sql` — `award_points_to_member` and `check_and_award_achievements_for_member`.
- `audits/2026-05-batch-fix-4-outcome.md` — this report.

## Per-deliverable summary

### Deliverable 1 — shopping list display crash

**Primary fix — `apps/mobile/lib/screens/shopping_list_screen.dart` (around line 682):**

```diff
     final name = item['name'] ?? 'Unknown';
-    final quantity = item['display_quantity'] ?? item['quantity'];
+    final rawQuantity = item['display_quantity'] ?? item['quantity'];
+    final quantity = rawQuantity is num
+        ? (rawQuantity == rawQuantity.truncate()
+            ? rawQuantity.toInt().toString()
+            : rawQuantity.toString())
+        : rawQuantity?.toString();
     final purchased = item['purchased'] ?? false;
     final store = item['store']?['name'];
     final category = item['category'];
```

`item['quantity']` is `numeric` in the schema. When `display_quantity` was null but `quantity` was set, the resulting `num` flowed into `Text(quantity)` → runtime crash.

**Sweep results — other `Text(item[...])` sites that might hit the same issue:**

Searched `shopping_list_screen.dart`, `meal_planner_screen.dart`, `shopping_category_screen.dart`, `recipe_detail_screen.dart`, `rewards_screen.dart`. Two additional sites passed map values directly into `Text` without coercion. Both fixed with the smallest defensive change (`.toString()` on the value at the Text constructor):

**`apps/mobile/lib/screens/meal_planner_screen.dart:496`** — `notes` (text column, but the value is JSON-decoded `dynamic` and could be a number from a malformed import):
```diff
                     if (notes != null && notes.toString().isNotEmpty)
-                      Text(notes, style: TextStyle(...), maxLines: 1, overflow: TextOverflow.ellipsis),
+                      Text(notes.toString(), style: TextStyle(...), maxLines: 1, overflow: TextOverflow.ellipsis),
```

**`apps/mobile/lib/screens/recipe_detail_screen.dart:919`** — ingredient row in edit mode (jsonb data may have a non-string `'raw'`):
```diff
-              title: Text(ingMap['raw'] ?? ingMap['name'] ?? ing.toString()),
+              title: Text((ingMap['raw'] ?? ingMap['name'] ?? ing).toString()),
```

Other `Text()` calls in those files were verified safe (either constants, interpolated strings via `'$x'`, or text-typed schema columns).

### Deliverable 2 — kid chore approval via member_id

**Part 2a — new RPCs.** Created `supabase/migrations/0011_award_points_by_member.sql` containing two new functions: `award_points_to_member(p_member_id, p_household_id, p_points, p_note, p_source_table, p_source_id)` and `check_and_award_achievements_for_member(p_member_id, p_household_id)`. Both verify the member belongs to the household before mutating, then mirror the body of the existing RPCs with `p_member_id` substituted for the `auth_user_id` lookup. The achievement variant reads `current_streak` directly from `household_members` (added in `0009`) rather than calling `calculate_streak`. The original `award_points` and `check_and_award_achievements` are untouched. Full SQL at the end of this report.

**Part 2b — `apps/mobile/lib/screens/chore_dashboard_screen.dart` `_verifyChore` branch:**

```diff
-        // Award points to the user who completed it
-        final assignedMemberId = chore['assigned_to_member_id'] as String;
-        final assignedMember = await Supabase.instance.client
-            .from('household_members')
-            .select('auth_user_id')
-            .eq('id', assignedMemberId)
-            .single();
-
-        await Supabase.instance.client.rpc('award_points', params: {
-          'p_auth_user_id': assignedMember['auth_user_id'],
-          'p_household_id': chore['household_id'],
-          'p_points': points + (chore['bonus_points'] ?? 0),
-          'p_note': 'chore_completion',
-          'p_source_table': 'chores',
-          'p_source_id': choreId,
-        });
-
-        // Check for new achievements
-        await Supabase.instance.client.rpc('check_and_award_achievements', params: {
-          'p_auth_user_id': assignedMember['auth_user_id'],
-          'p_household_id': chore['household_id'],
-        });
+        // Award points to the user who completed it.
+        // Adults have a Supabase auth account (kind = 'adult_auth_user');
+        // kids are sub_profiles with auth_user_id = NULL, so for kids we
+        // call the member_id-based RPC variants (see 0011 migration).
+        final assignedMemberId = chore['assigned_to_member_id'] as String;
+        final assignedMember = await Supabase.instance.client
+            .from('household_members')
+            .select('id, kind, auth_user_id')
+            .eq('id', assignedMemberId)
+            .single();
+
+        final totalPoints = points + (chore['bonus_points'] ?? 0);
+        final isSubProfile = assignedMember['kind'] == 'sub_profile';
+
+        if (isSubProfile) {
+          await Supabase.instance.client.rpc('award_points_to_member', params: {
+            'p_member_id': assignedMember['id'],
+            'p_household_id': chore['household_id'],
+            'p_points': totalPoints,
+            'p_note': 'chore_completion',
+            'p_source_table': 'chores',
+            'p_source_id': choreId,
+          });
+          await Supabase.instance.client.rpc('check_and_award_achievements_for_member', params: {
+            'p_member_id': assignedMember['id'],
+            'p_household_id': chore['household_id'],
+          });
+        } else {
+          await Supabase.instance.client.rpc('award_points', params: {
+            'p_auth_user_id': assignedMember['auth_user_id'],
+            'p_household_id': chore['household_id'],
+            'p_points': totalPoints,
+            'p_note': 'chore_completion',
+            'p_source_table': 'chores',
+            'p_source_id': choreId,
+          });
+          await Supabase.instance.client.rpc('check_and_award_achievements', params: {
+            'p_auth_user_id': assignedMember['auth_user_id'],
+            'p_household_id': chore['household_id'],
+          });
+        }
```

The branch is explicit on `kind` rather than detecting via `auth_user_id == null`, per the brief. Adults keep the auth_user_id path; kids hit the new RPCs.

## Followups

Spotted while doing this work; intentionally not fixed:

1. **`shopping_list_screen.dart` edit sheet (line 260)** uses `item['quantity']?.toString() ?? ''` to seed the edit field. That's safe but produces "1.0" for a numeric 1. If the user wants the edit sheet to also show "1" instead of "1.0", apply the same `truncate()` check pattern there. Currently the user-facing UI is the tile (now fixed) and re-entering a `0` after editing is unlikely. Not worth a change this pass.
2. **`recipe_detail_screen.dart:585-586`** displays calorie counts via interpolation — currently safe. Same for servings (line 577) and prep time (line 419-420). Worth a defensive pass if these ever start showing through dynamic-typed paths.
3. **`shopping_category_screen.dart`** has no item rendering (it manages tags only) — confirmed via re-read.
4. **`rewards_screen.dart:115`** does `Text(reward['description'])`. `description` is a `text` column. If any reward was inserted with a non-string description (e.g., from a buggy admin tool), this would crash. Not changed because the schema constrains the column to text.
5. **Analyzer warnings on `.rpc(...)` calls** — strict-inference flags every untyped rpc call with `inference_failure_on_function_invocation`. This batch adds 2 such warnings (the two new sub_profile-branch rpc calls). They mirror the 2 existing warnings on the adult-branch rpc calls and are not new diagnostic categories. A future batch could provide explicit type arguments to silence them all.
6. **`current_streak` is not yet computed.** `0009_member_streak.sql` added the column with default 0. `check_and_award_achievements_for_member` reads it via SELECT but no code maintains it yet. Streak badges for sub_profiles will only fire once a background job (or trigger) updates `current_streak`. Adult flows have the same issue but go through `check_and_award_achievements` → `calculate_streak` which counts on-the-fly. Worth aligning: either both call `calculate_streak`, or both read `current_streak`, but not split. Not addressed here.
7. **The `_verifyChore` function still calls `_createNextRecurringChoreIfNeeded(chore)` after the points branch.** This is untouched and correct for both adult and kid paths.
8. **`chore_status` for the rejected branch (line 232-235)** writes `'assigned'` instead of the available enum value `'rejected'`. Not a bug — the UI intent is to send the chore back into the assigned queue. Just noting because the enum has `'rejected'` for actual rejections.

## Analyzer deltas

| | Total | Errors | Warnings | Infos |
|---|---|---|---|---|
| Before | 327 | 44 | 78 | 205 |
| After  | 329 | 44 | 80 | 205 |
| Delta  | +2 | 0 | **+2** | 0 |

The +2 warnings are `inference_failure_on_function_invocation` on the two new `.rpc(...)` calls in the sub_profile branch. Same category as the two pre-existing warnings in this function. No new diagnostic categories introduced.

## SQL to apply

Apply migration `0011` in the Supabase SQL Editor. Each `CREATE OR REPLACE FUNCTION` is idempotent; safe to re-run.

```sql
-- 0011_award_points_by_member.sql
--
-- New RPC variants that take member_id directly, for use when the chore was
-- completed by a sub_profile (kid) whose auth_user_id is NULL. The original
-- award_points(p_auth_user_id, ...) and check_and_award_achievements(p_auth_user_id, ...)
-- remain unchanged and continue to be used for adult flows.
--
-- The app branches on household_members.kind:
--   - 'adult_auth_user' -> uses the original RPCs with p_auth_user_id
--   - 'sub_profile'     -> uses these new RPCs with p_member_id
--
-- Full architectural refactor (every site switches to member_id) is deferred
-- to the kid-permissions feature batch. This file is the minimum diff needed
-- to unblock chore approval for kids today.

-- award_points_to_member: variant of award_points that takes member_id directly.
CREATE OR REPLACE FUNCTION award_points_to_member(
  p_member_id UUID,
  p_household_id UUID,
  p_points INTEGER,
  p_note TEXT,
  p_source_table TEXT DEFAULT NULL,
  p_source_id UUID DEFAULT NULL
)
RETURNS VOID AS $$
DECLARE
  v_balance_after INTEGER;
  v_member_exists BOOLEAN;
BEGIN
  -- Verify member exists in the given household
  SELECT EXISTS (
    SELECT 1 FROM household_members
    WHERE id = p_member_id AND household_id = p_household_id
  ) INTO v_member_exists;

  IF NOT v_member_exists THEN
    RAISE EXCEPTION 'Member is not part of this household';
  END IF;

  -- Update points balance
  UPDATE household_members
  SET points_balance = points_balance + p_points
  WHERE id = p_member_id;

  -- Get new balance
  SELECT points_balance INTO v_balance_after
  FROM household_members
  WHERE id = p_member_id;

  -- Create point transaction record
  INSERT INTO point_transactions (
    household_id, member_id, type, amount, balance_after,
    source_table, source_id, note, created_by_member_id
  )
  VALUES (
    p_household_id, p_member_id, 'earned', p_points, v_balance_after,
    p_source_table, p_source_id, p_note, p_member_id
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- check_and_award_achievements_for_member: variant taking member_id.
-- Reads current_streak directly from household_members (added in 0009)
-- instead of calling calculate_streak.
CREATE OR REPLACE FUNCTION check_and_award_achievements_for_member(
  p_member_id UUID,
  p_household_id UUID
)
RETURNS TABLE (badge_key TEXT, badge_name TEXT, icon TEXT) AS $$
DECLARE
  v_total_chores INTEGER;
  v_current_streak INTEGER;
  v_total_points INTEGER;
  v_member_exists BOOLEAN;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM household_members
    WHERE id = p_member_id AND household_id = p_household_id
  ) INTO v_member_exists;

  IF NOT v_member_exists THEN
    RAISE EXCEPTION 'Member is not part of this household';
  END IF;

  SELECT COUNT(*) INTO v_total_chores
  FROM chores
  WHERE assigned_to_member_id = p_member_id
    AND household_id = p_household_id
    AND status = 'verified';

  SELECT current_streak INTO v_current_streak
  FROM household_members
  WHERE id = p_member_id;

  SELECT points_balance INTO v_total_points
  FROM household_members
  WHERE id = p_member_id;

  -- Chore-count milestones
  IF v_total_chores >= 1 THEN
    INSERT INTO achievements (household_id, member_id, badge_key, badge_name, description, icon)
    VALUES (p_household_id, p_member_id, 'first_chore', 'First Chore', 'Completed your very first chore!', '🎉')
    ON CONFLICT (member_id, badge_key) DO NOTHING;
  END IF;

  IF v_total_chores >= 5 THEN
    INSERT INTO achievements (household_id, member_id, badge_key, badge_name, description, icon)
    VALUES (p_household_id, p_member_id, 'getting_started', 'Getting Started', 'Completed 5 chores!', '⭐')
    ON CONFLICT (member_id, badge_key) DO NOTHING;
  END IF;

  IF v_total_chores >= 25 THEN
    INSERT INTO achievements (household_id, member_id, badge_key, badge_name, description, icon)
    VALUES (p_household_id, p_member_id, 'chore_champion', 'Chore Champion', 'Completed 25 chores!', '🏆')
    ON CONFLICT (member_id, badge_key) DO NOTHING;
  END IF;

  IF v_total_chores >= 100 THEN
    INSERT INTO achievements (household_id, member_id, badge_key, badge_name, description, icon)
    VALUES (p_household_id, p_member_id, 'honeydo_hero', 'Honeydo Hero', 'Completed 100 chores!', '🤸')
    ON CONFLICT (member_id, badge_key) DO NOTHING;
  END IF;

  -- Streak milestones
  IF v_current_streak >= 3 THEN
    INSERT INTO achievements (household_id, member_id, badge_key, badge_name, description, icon)
    VALUES (p_household_id, p_member_id, 'on_a_roll', 'On a Roll', '3-day chore streak!', '🔥')
    ON CONFLICT (member_id, badge_key) DO NOTHING;
  END IF;

  IF v_current_streak >= 7 THEN
    INSERT INTO achievements (household_id, member_id, badge_key, badge_name, description, icon)
    VALUES (p_household_id, p_member_id, 'streak_master', 'Streak Master', '7-day chore streak!', '⚡')
    ON CONFLICT (member_id, badge_key) DO NOTHING;
  END IF;

  -- Point milestones
  IF v_total_points >= 100 THEN
    INSERT INTO achievements (household_id, member_id, badge_key, badge_name, description, icon)
    VALUES (p_household_id, p_member_id, 'century_club', 'Century Club', 'Earned 100 points!', '💯')
    ON CONFLICT (member_id, badge_key) DO NOTHING;
  END IF;

  IF v_total_points >= 500 THEN
    INSERT INTO achievements (household_id, member_id, badge_key, badge_name, description, icon)
    VALUES (p_household_id, p_member_id, 'point_tycoon', 'Point Tycoon', 'Earned 500 points!', '💰')
    ON CONFLICT (member_id, badge_key) DO NOTHING;
  END IF;

  -- Return newly awarded achievements
  RETURN QUERY
    SELECT a.badge_key, a.badge_name, a.icon
    FROM achievements a
    WHERE a.member_id = p_member_id
      AND a.household_id = p_household_id
      AND a.earned_at >= NOW() - INTERVAL '5 seconds';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

Nothing committed.
