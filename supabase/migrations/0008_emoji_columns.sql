-- 0008_emoji_columns.sql
--
-- Adds `emoji` text columns the Flutter app expects:
--   - households.emoji  (read in home_shell_screen.dart:227, 228;
--                        written in settings_screen.dart:260)
--   - calendar_tags.emoji (read in calendar_screen.dart; written by the
--                          default-tags loop in household_setup_screen.dart:106-119)
--
-- Without these columns the Edit-Household update was rejected entirely
-- (losing the name change), and the six default calendar tags inserted
-- during household creation all failed silently.
--
-- Both columns are nullable; existing rows keep their NULL value until
-- the user edits them.

alter table public.households
  add column if not exists emoji text;

alter table public.calendar_tags
  add column if not exists emoji text;
