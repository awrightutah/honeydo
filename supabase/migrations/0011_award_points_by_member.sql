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
