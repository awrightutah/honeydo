/*
 * Migration: Tighten calendar_tags RLS to admin-only mutations
 *
 * Previous policy: household_scoped_calendar_tags allowed ALL operations
 * to any active household member. This let kids delete tags being used
 * across the household.
 *
 * New shape:
 *   - SELECT: any household member (kids need to see tags to pick them)
 *   - INSERT/UPDATE/DELETE: household admins only
 *
 * Matches the pattern of household_invites (admin-only) but with SELECT
 * deliberately open because tags are display data, not credentials.
 *
 * Applied to production Supabase on 2026-05-30 via SQL Editor (Phase 2
 * Migration 2/3 of Bug 1 calendar feature work). This file backfills
 * the change into the repo migration history.
 */

DROP POLICY IF EXISTS household_scoped_calendar_tags ON public.calendar_tags;

CREATE POLICY calendar_tags_member_select
  ON public.calendar_tags
  FOR SELECT
  TO authenticated
  USING (is_household_member(household_id));

CREATE POLICY calendar_tags_admin_insert
  ON public.calendar_tags
  FOR INSERT
  TO authenticated
  WITH CHECK (is_household_admin(household_id));

CREATE POLICY calendar_tags_admin_update
  ON public.calendar_tags
  FOR UPDATE
  TO authenticated
  USING (is_household_admin(household_id))
  WITH CHECK (is_household_admin(household_id));

CREATE POLICY calendar_tags_admin_delete
  ON public.calendar_tags
  FOR DELETE
  TO authenticated
  USING (is_household_admin(household_id));
