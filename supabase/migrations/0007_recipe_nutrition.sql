-- 0007_recipe_nutrition.sql
--
-- Adds per-serving nutrition columns to both household and master recipes.
-- The Flutter recipe detail screen reads/writes these fields
-- (recipe_detail_screen.dart:114, 157, 720-723); without these columns the
-- recipe save UPDATE was rejected by Postgres.
--
-- All columns are nullable so existing rows continue to work.
-- master_recipes gets the same columns so master-library imports can
-- carry nutrition data forward into household_recipes via the existing
-- "add to household" flow.

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
