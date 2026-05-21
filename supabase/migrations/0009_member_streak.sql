-- 0009_member_streak.sql
--
-- Adds streak tracking columns to household_members and updates the
-- get_leaderboard RPC so it returns current_streak.
--
-- The leaderboard sheet (home_shell_screen.dart:615), member profile
-- (member_profile_screen.dart:90), and self profile (profile_screen.dart:351)
-- all read `current_streak` from household_members. Without the column the
-- read silently returns null and every member shows a streak of 0.
--
-- `longest_streak` and `last_completion_date` are added now because future
-- streak-computation code (background job or trigger) will need them. They
-- are not referenced by app code today.

alter table public.household_members
  add column if not exists current_streak integer not null default 0,
  add column if not exists longest_streak integer not null default 0,
  add column if not exists last_completion_date date;


-- get_leaderboard previously returned (member_id, display_name, kind,
-- points_balance, rank). It now also returns current_streak. Changing the
-- return TABLE type requires DROP + CREATE; CREATE OR REPLACE cannot
-- modify the signature.
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
