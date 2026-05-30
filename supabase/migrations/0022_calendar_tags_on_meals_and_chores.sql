/*
 * Migration: Add tag_id to meal_plans and chores
 *
 * Extends the calendar_tags system to cover meals and chores. Previously
 * only calendar_events could be tagged. After this migration, both
 * meal_plans rows and chores rows can optionally reference a calendar_tag.
 *
 * tag_id is nullable: existing rows have NULL tag, which means "untagged".
 * ON DELETE SET NULL ensures deleting a tag doesn't delete the items
 * using it — they just become untagged. Matches the pattern of
 * calendar_events.tag_id.
 *
 * Partial indexes (WHERE tag_id IS NOT NULL) keep the index small while
 * still speeding up filter-by-tag queries.
 *
 * Applied to production Supabase on 2026-05-30 via SQL Editor (Phase 2
 * Migration 1/3 of Bug 1 calendar feature work). This file backfills
 * the change into the repo migration history.
 */

ALTER TABLE public.meal_plans
ADD COLUMN IF NOT EXISTS tag_id uuid REFERENCES public.calendar_tags(id) ON DELETE SET NULL;

ALTER TABLE public.chores
ADD COLUMN IF NOT EXISTS tag_id uuid REFERENCES public.calendar_tags(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_meal_plans_tag_id
  ON public.meal_plans(tag_id)
  WHERE tag_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_chores_tag_id
  ON public.chores(tag_id)
  WHERE tag_id IS NOT NULL;
