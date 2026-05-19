-- Honeydo: Point awarding function and gamification support
-- Run this in the Supabase SQL Editor

-- ─── Function: award_points ───────────────────────────────────────────────────────
-- Awards points to a household member and creates a point transaction record.
CREATE OR REPLACE FUNCTION award_points(
  p_auth_user_id UUID,
  p_household_id UUID,
  p_points INTEGER,
  p_note TEXT,
  p_source_table TEXT DEFAULT NULL,
  p_source_id UUID DEFAULT NULL
)
RETURNS VOID AS $$
DECLARE
  v_member_id UUID;
  v_balance_after INTEGER;
BEGIN
  -- Find the household member record
  SELECT id, points_balance INTO v_member_id, v_balance_after
  FROM household_members
  WHERE auth_user_id = p_auth_user_id AND household_id = p_household_id;

  IF v_member_id IS NULL THEN
    RAISE EXCEPTION 'User is not a member of this household';
  END IF;

  -- Update points balance
  UPDATE household_members
  SET points_balance = points_balance + p_points
  WHERE id = v_member_id;

  -- Get new balance
  SELECT points_balance INTO v_balance_after
  FROM household_members
  WHERE id = v_member_id;

  -- Create point transaction record
  INSERT INTO point_transactions (
    household_id,
    member_id,
    type,
    amount,
    balance_after,
    source_table,
    source_id,
    note,
    created_by_member_id
  )
  VALUES (
    p_household_id,
    v_member_id,
    'earned',
    p_points,
    v_balance_after,
    p_source_table,
    p_source_id,
    p_note,
    v_member_id
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ─── Function: get_leaderboard ─────────────────────────────────────────────────────
-- Returns household members sorted by points balance for the leaderboard.
CREATE OR REPLACE FUNCTION get_leaderboard(p_household_id UUID)
RETURNS TABLE (
  member_id UUID,
  display_name TEXT,
  kind member_kind,
  points_balance INTEGER,
  rank BIGINT
) AS $$
SELECT
  hm.id,
  hm.display_name,
  hm.kind,
  hm.points_balance,
  RANK() OVER (ORDER BY hm.points_balance DESC) AS rank
FROM household_members hm
WHERE hm.household_id = p_household_id
ORDER BY hm.points_balance DESC;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- ─── Function: calculate_streak ─────────────────────────────────────────────────────
-- Calculates the current streak of consecutive days with at least one completed chore.
CREATE OR REPLACE FUNCTION calculate_streak(
  p_auth_user_id UUID,
  p_household_id UUID
)
RETURNS INTEGER AS $$
DECLARE
  v_streak INTEGER := 0;
  v_check_date DATE := CURRENT_DATE - 1;
  v_has_chore BOOLEAN;
BEGIN
  -- Check today first
  SELECT EXISTS (
    SELECT 1 FROM chores
    WHERE assigned_to_member_id = (
      SELECT id FROM household_members
      WHERE auth_user_id = p_auth_user_id AND household_id = p_household_id
    )
      AND household_id = p_household_id
      AND status = 'completed'
      AND completed_at::date = CURRENT_DATE
  ) INTO v_has_chore;

  IF v_has_chore THEN
    v_streak := 1;
  END IF;

  -- Check previous days going backwards
  LOOP
    SELECT EXISTS (
      SELECT 1 FROM chores
      WHERE assigned_to_member_id = (
        SELECT id FROM household_members
        WHERE auth_user_id = p_auth_user_id AND household_id = p_household_id
      )
        AND household_id = p_household_id
        AND status = 'completed'
        AND completed_at::date = v_check_date
    ) INTO v_has_chore;

    IF v_has_chore THEN
      v_streak := v_streak + 1;
      v_check_date := v_check_date - 1;
    ELSE
      EXIT;
    END IF;
  END LOOP;

  RETURN v_streak;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

-- ─── Function: check_and_award_achievements ─────────────────────────────────────────
-- Checks if a user has earned any new achievements and awards them.
CREATE OR REPLACE FUNCTION check_and_award_achievements(
  p_auth_user_id UUID,
  p_household_id UUID
)
RETURNS TABLE (badge_key TEXT, badge_name TEXT, icon TEXT) AS $$
DECLARE
  v_member_id UUID;
  v_total_chores INTEGER;
  v_current_streak INTEGER;
  v_total_points INTEGER;
BEGIN
  -- Get member_id
  SELECT id INTO v_member_id
  FROM household_members
  WHERE auth_user_id = p_auth_user_id AND household_id = p_household_id;

  IF v_member_id IS NULL THEN
    RAISE EXCEPTION 'User is not a member of this household';
  END IF;

  -- Get user stats
  SELECT COUNT(*) INTO v_total_chores
  FROM chores
  WHERE assigned_to_member_id = v_member_id
    AND household_id = p_household_id
    AND status = 'completed';

  v_current_streak := calculate_streak(p_auth_user_id, p_household_id);

  SELECT points_balance INTO v_total_points
  FROM household_members
  WHERE id = v_member_id;

  -- First Chore
  IF v_total_chores >= 1 THEN
    INSERT INTO achievements (household_id, member_id, badge_key, badge_name, description, icon)
    VALUES (p_household_id, v_member_id, 'first_chore', 'First Chore', 'Completed your very first chore!', '🎉')
    ON CONFLICT (member_id, badge_key) DO NOTHING;
  END IF;

  -- 5 Chores
  IF v_total_chores >= 5 THEN
    INSERT INTO achievements (household_id, member_id, badge_key, badge_name, description, icon)
    VALUES (p_household_id, v_member_id, 'getting_started', 'Getting Started', 'Completed 5 chores!', '⭐')
    ON CONFLICT (member_id, badge_key) DO NOTHING;
  END IF;

  -- 25 Chores
  IF v_total_chores >= 25 THEN
    INSERT INTO achievements (household_id, member_id, badge_key, badge_name, description, icon)
    VALUES (p_household_id, v_member_id, 'chore_champion', 'Chore Champion', 'Completed 25 chores!', '🏆')
    ON CONFLICT (member_id, badge_key) DO NOTHING;
  END IF;

  -- 100 Chores
  IF v_total_chores >= 100 THEN
    INSERT INTO achievements (household_id, member_id, badge_key, badge_name, description, icon)
    VALUES (p_household_id, v_member_id, 'honeydo_hero', 'Honeydo Hero', 'Completed 100 chores!', '🤸')
    ON CONFLICT (member_id, badge_key) DO NOTHING;
  END IF;

  -- 3-day streak
  IF v_current_streak >= 3 THEN
    INSERT INTO achievements (household_id, member_id, badge_key, badge_name, description, icon)
    VALUES (p_household_id, v_member_id, 'on_a_roll', 'On a Roll', '3-day chore streak!', '🔥')
    ON CONFLICT (member_id, badge_key) DO NOTHING;
  END IF;

  -- 7-day streak
  IF v_current_streak >= 7 THEN
    INSERT INTO achievements (household_id, member_id, badge_key, badge_name, description, icon)
    VALUES (p_household_id, v_member_id, 'streak_master', 'Streak Master', '7-day chore streak!', '⚡')
    ON CONFLICT (member_id, badge_key) DO NOTHING;
  END IF;

  -- 100 points
  IF v_total_points >= 100 THEN
    INSERT INTO achievements (household_id, member_id, badge_key, badge_name, description, icon)
    VALUES (p_household_id, v_member_id, 'century_club', 'Century Club', 'Earned 100 points!', '💯')
    ON CONFLICT (member_id, badge_key) DO NOTHING;
  END IF;

  -- 500 points
  IF v_total_points >= 500 THEN
    INSERT INTO achievements (household_id, member_id, badge_key, badge_name, description, icon)
    VALUES (p_household_id, v_member_id, 'point_tycoon', 'Point Tycoon', 'Earned 500 points!', '💰')
    ON CONFLICT (member_id, badge_key) DO NOTHING;
  END IF;

  -- Return newly awarded achievements
  RETURN QUERY
    SELECT a.badge_key, a.badge_name, a.icon
    FROM achievements a
    WHERE a.member_id = v_member_id
      AND a.household_id = p_household_id
      AND a.earned_at >= NOW() - INTERVAL '5 seconds';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ─── Function: increment_master_recipe_added_count ─────────────────────────────────
-- Increments the added_count on a master recipe when added to a household
CREATE OR REPLACE FUNCTION increment_master_recipe_added_count(p_recipe_id UUID)
RETURNS VOID AS $$
BEGIN
  UPDATE master_recipes
  SET added_count = added_count + 1
  WHERE id = p_recipe_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;