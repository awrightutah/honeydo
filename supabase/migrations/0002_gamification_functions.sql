-- Honeydo: Point awarding function and gamification support
-- Run this in the Supabase SQL Editor

-- ── Function: award_points ──────────────────────────────────────────────────
-- Awards points to a household member and creates a point transaction record.
CREATE OR REPLACE FUNCTION award_points(
  p_user_id UUID,
  p_household_id UUID,
  p_points INTEGER,
  p_reason TEXT,
  p_reference_id UUID DEFAULT NULL
)
RETURNS VOID AS $$
DECLARE
  v_member_id UUID;
BEGIN
  -- Find the household member record
  SELECT id INTO v_member_id
  FROM household_members
  WHERE user_id = p_user_id AND household_id = p_household_id;

  IF v_member_id IS NULL THEN
    RAISE EXCEPTION 'User is not a member of this household';
  END IF;

  -- Update points balance
  UPDATE household_members
  SET points_balance = points_balance + p_points
  WHERE id = v_member_id;

  -- Create point transaction record
  INSERT INTO point_transactions (household_id, user_id, amount, transaction_type, reason, reference_id)
  VALUES (p_household_id, p_user_id, p_points, 'earned', p_reason, p_reference_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── Function: get_leaderboard ────────────────────────────────────────────────
-- Returns household members sorted by points balance for the leaderboard.
CREATE OR REPLACE FUNCTION get_leaderboard(p_household_id UUID)
RETURNS TABLE (
  user_id UUID,
  display_name TEXT,
  kind member_kind,
  points_balance INTEGER,
  rank BIGINT
) AS $$
SELECT
  hm.user_id,
  hm.display_name,
  hm.kind,
  hm.points_balance,
  RANK() OVER (ORDER BY hm.points_balance DESC) AS rank
FROM household_members hm
WHERE hm.household_id = p_household_id
ORDER BY hm.points_balance DESC;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- ── Function: calculate_streak ──────────────────────────────────────────────
-- Calculates the current streak of consecutive days with at least one completed chore.
CREATE OR REPLACE FUNCTION calculate_streak(
  p_user_id UUID,
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
    WHERE assigned_to = p_user_id
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
      WHERE assigned_to = p_user_id
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

-- ── Function: check_and_award_achievements ──────────────────────────────────
-- Checks if a user has earned any new achievements and awards them.
CREATE OR REPLACE FUNCTION check_and_award_achievements(
  p_user_id UUID,
  p_household_id UUID
)
RETURNS TABLE (achievement_name TEXT, achievement_emoji TEXT) AS $$
DECLARE
  v_total_chores INTEGER;
  v_current_streak INTEGER;
  v_total_points INTEGER;
BEGIN
  -- Get user stats
  SELECT COUNT(*) INTO v_total_chores
  FROM chores
  WHERE assigned_to = p_user_id AND household_id = p_household_id AND status = 'completed';

  v_current_streak := calculate_streak(p_user_id, p_household_id);

  SELECT points_balance INTO v_total_points
  FROM household_members
  WHERE user_id = p_user_id AND household_id = p_household_id;

  -- First Chore
  IF v_total_chores >= 1 THEN
    INSERT INTO achievements (household_id, user_id, name, emoji, description)
    VALUES (p_household_id, p_user_id, 'First Chore', '🎉', 'Completed your very first chore!')
    ON CONFLICT (household_id, user_id, name) DO NOTHING;
  END IF;

  -- 5 Chores
  IF v_total_chores >= 5 THEN
    INSERT INTO achievements (household_id, user_id, name, emoji, description)
    VALUES (p_household_id, p_user_id, 'Getting Started', '⭐', 'Completed 5 chores!')
    ON CONFLICT (household_id, user_id, name) DO NOTHING;
  END IF;

  -- 25 Chores
  IF v_total_chores >= 25 THEN
    INSERT INTO achievements (household_id, user_id, name, emoji, description)
    VALUES (p_household_id, p_user_id, 'Chore Champion', '🏆', 'Completed 25 chores!')
    ON CONFLICT (household_id, user_id, name) DO NOTHING;
  END IF;

  -- 100 Chores
  IF v_total_chores >= 100 THEN
    INSERT INTO achievements (household_id, user_id, name, emoji, description)
    VALUES (p_household_id, p_user_id, 'Honeydo Hero', '🦸', 'Completed 100 chores!')
    ON CONFLICT (household_id, user_id, name) DO NOTHING;
  END IF;

  -- 3-day streak
  IF v_current_streak >= 3 THEN
    INSERT INTO achievements (household_id, user_id, name, emoji, description)
    VALUES (p_household_id, p_user_id, 'On a Roll', '🔥', '3-day chore streak!')
    ON CONFLICT (household_id, user_id, name) DO NOTHING;
  END IF;

  -- 7-day streak
  IF v_current_streak >= 7 THEN
    INSERT INTO achievements (household_id, user_id, name, emoji, description)
    VALUES (p_household_id, p_user_id, 'Streak Master', '⚡', '7-day chore streak!')
    ON CONFLICT (household_id, user_id, name) DO NOTHING;
  END IF;

  -- 100 points
  IF v_total_points >= 100 THEN
    INSERT INTO achievements (household_id, user_id, name, emoji, description)
    VALUES (p_household_id, p_user_id, 'Century Club', '💯', 'Earned 100 points!')
    ON CONFLICT (household_id, user_id, name) DO NOTHING;
  END IF;

  -- 500 points
  IF v_total_points >= 500 THEN
    INSERT INTO achievements (household_id, user_id, name, emoji, description)
    VALUES (p_household_id, p_user_id, 'Point Tycoon', '💰', 'Earned 500 points!')
    ON CONFLICT (household_id, user_id, name) DO NOTHING;
  END IF;

  -- Return newly awarded achievements
  RETURN QUERY
    SELECT a.name, a.emoji
    FROM achievements a
    WHERE a.user_id = p_user_id
      AND a.household_id = p_household_id
      AND a.awarded_at >= NOW() - INTERVAL '5 seconds';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
