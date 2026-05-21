-- 0012_fix_badge_key_ambiguity.sql
-- 
-- Both check_and_award_achievements and check_and_award_achievements_for_member
-- raised PostgresException 42702 "column reference badge_key is ambiguous" on
-- every call. The RETURNS TABLE (badge_key TEXT, ...) signature creates implicit
-- OUT parameter variables that collide with column names referenced inside
-- INSERT INTO achievements (...) ON CONFLICT (member_id, badge_key) clauses.
-- 
-- Fix: add #variable_conflict use_column directive so PL/pgSQL prefers column
-- references when the name is ambiguous.
-- 
-- Uses DROP+CREATE because the originally-compiled cached query plan was the
-- broken version; CREATE OR REPLACE alone may not force a recompile.

DROP FUNCTION IF EXISTS check_and_award_achievements(uuid, uuid);

CREATE FUNCTION check_and_award_achievements(
  p_auth_user_id UUID,
  p_household_id UUID
)
RETURNS TABLE (badge_key TEXT, badge_name TEXT, icon TEXT) AS $$
#variable_conflict use_column
DECLARE
  v_member_id UUID;
  v_total_chores INTEGER;
  v_current_streak INTEGER;
  v_total_points INTEGER;
BEGIN
  SELECT id INTO v_member_id
  FROM household_members
  WHERE auth_user_id = p_auth_user_id AND household_id = p_household_id;

  IF v_member_id IS NULL THEN
    RAISE EXCEPTION 'User is not a member of this household';
  END IF;

  SELECT COUNT(*) INTO v_total_chores
  FROM chores
  WHERE assigned_to_member_id = v_member_id
    AND household_id = p_household_id
    AND status = 'verified';

  v_current_streak := calculate_streak(p_auth_user_id, p_household_id);

  SELECT points_balance INTO v_total_points
  FROM household_members
  WHERE id = v_member_id;

  IF v_total_chores >= 1 THEN
    INSERT INTO achievements (household_id, member_id, badge_key, badge_name, description, icon)
    VALUES (p_household_id, v_member_id, 'first_chore', 'First Chore', 'Completed your very first chore!', '🎉')
    ON CONFLICT (member_id, badge_key) DO NOTHING;
  END IF;

  IF v_total_chores >= 5 THEN
    INSERT INTO achievements (household_id, member_id, badge_key, badge_name, description, icon)
    VALUES (p_household_id, v_member_id, 'getting_started', 'Getting Started', 'Completed 5 chores!', '⭐')
    ON CONFLICT (member_id, badge_key) DO NOTHING;
  END IF;

  IF v_total_chores >= 25 THEN
    INSERT INTO achievements (household_id, member_id, badge_key, badge_name, description, icon)
    VALUES (p_household_id, v_member_id, 'chore_champion', 'Chore Champion', 'Completed 25 chores!', '🏆')
    ON CONFLICT (member_id, badge_key) DO NOTHING;
  END IF;

  IF v_total_chores >= 100 THEN
    INSERT INTO achievements (household_id, member_id, badge_key, badge_name, description, icon)
    VALUES (p_household_id, v_member_id, 'honeydo_hero', 'Honeydo Hero', 'Completed 100 chores!', '🤸')
    ON CONFLICT (member_id, badge_key) DO NOTHING;
  END IF;

  IF v_current_streak >= 3 THEN
    INSERT INTO achievements (household_id, member_id, badge_key, badge_name, description, icon)
    VALUES (p_household_id, v_member_id, 'on_a_roll', 'On a Roll', '3-day chore streak!', '🔥')
    ON CONFLICT (member_id, badge_key) DO NOTHING;
  END IF;

  IF v_current_streak >= 7 THEN
    INSERT INTO achievements (household_id, member_id, badge_key, badge_name, description, icon)
    VALUES (p_household_id, v_member_id, 'streak_master', 'Streak Master', '7-day chore streak!', '⚡')
    ON CONFLICT (member_id, badge_key) DO NOTHING;
  END IF;

  IF v_total_points >= 100 THEN
    INSERT INTO achievements (household_id, member_id, badge_key, badge_name, description, icon)
    VALUES (p_household_id, v_member_id, 'century_club', 'Century Club', 'Earned 100 points!', '💯')
    ON CONFLICT (member_id, badge_key) DO NOTHING;
  END IF;

  IF v_total_points >= 500 THEN
    INSERT INTO achievements (household_id, member_id, badge_key, badge_name, description, icon)
    VALUES (p_household_id, v_member_id, 'point_tycoon', 'Point Tycoon', 'Earned 500 points!', '💰')
    ON CONFLICT (member_id, badge_key) DO NOTHING;
  END IF;

  RETURN QUERY
    SELECT a.badge_key, a.badge_name, a.icon
    FROM achievements a
    WHERE a.member_id = v_member_id
      AND a.household_id = p_household_id
      AND a.earned_at >= NOW() - INTERVAL '5 seconds';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


DROP FUNCTION IF EXISTS check_and_award_achievements_for_member(uuid, uuid);

CREATE FUNCTION check_and_award_achievements_for_member(
  p_member_id UUID,
  p_household_id UUID
)
RETURNS TABLE (badge_key TEXT, badge_name TEXT, icon TEXT) AS $$
#variable_conflict use_column
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

  RETURN QUERY
    SELECT a.badge_key, a.badge_name, a.icon
    FROM achievements a
    WHERE a.member_id = p_member_id
      AND a.household_id = p_household_id
      AND a.earned_at >= NOW() - INTERVAL '5 seconds';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;