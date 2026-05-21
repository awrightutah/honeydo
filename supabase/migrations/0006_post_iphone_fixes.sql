-- 0006_post_iphone_fixes.sql
--
-- Captures the four RLS policies that were added manually in the Supabase
-- Studio after first-time household setup failed on a physical iPhone.
-- These policies already exist in the live database — this file documents
-- what was done and lets a fresh environment reach the same state.
--
-- Background: 0001_initial_schema.sql defined SELECT/UPDATE/ALL policies
-- gated by `is_household_member` / `is_household_admin`, but did not define
-- INSERT policies for the bootstrap chain (profile -> household -> first
-- member). The household-create flow requires three INSERTs that the
-- original policies all rejected:
--
--   1) profile self-create (the row that household.owner_user_id FKs into)
--   2) household create (where the authed user becomes the owner)
--   3) self as first member (so subsequent is_household_member checks pass)
--
-- Additionally, the household SELECT policy was tightened so the owner can
-- read their own household even before their household_member row exists.
--
-- Each statement uses drop-if-exists + create to remain idempotent.

-- 1) profiles_self_insert -----------------------------------------------------
-- Allows an authenticated user to create their own profile row.
drop policy if exists profiles_self_insert on public.profiles;
create policy profiles_self_insert
  on public.profiles
  for insert
  to authenticated
  with check (id = auth.uid());


-- 2) households_authenticated_insert ----------------------------------------
-- Allows an authenticated user to create a household where they are the
-- owner. Owner uniqueness/cardinality is not enforced here — add a check
-- constraint or trigger if you want one-household-per-owner.
drop policy if exists households_authenticated_insert on public.households;
create policy households_authenticated_insert
  on public.households
  for insert
  to authenticated
  with check (owner_user_id = auth.uid());


-- 3) household_members_self_insert ------------------------------------------
-- Allows an authenticated user to either:
--   (a) create their own first household_member row in a household they own
--       (used during the create-household bootstrap), or
--   (b) create a member row in a household where they are already an admin
--       (used when admins add kid sub-profiles or new adult members).
--
-- The check distinguishes self-insert from admin-insert via auth_user_id.
drop policy if exists household_members_self_insert on public.household_members;
create policy household_members_self_insert
  on public.household_members
  for insert
  to authenticated
  with check (
    -- self-as-adult, inserting into a household they own
    (
      kind = 'adult_auth_user'
      and auth_user_id = auth.uid()
      and exists (
        select 1
        from public.households h
        where h.id = household_id
          and h.owner_user_id = auth.uid()
      )
    )
    or
    -- admin inserting any member (used for kid sub-profiles and invitations)
    public.is_household_admin(household_id)
  );


-- 4) households_member_or_owner_select --------------------------------------
-- Replaces the original `households_member_select` policy. The original
-- required `is_household_member(id)` to read the household, but during
-- bootstrap the owner has not yet inserted their household_members row
-- so the household creation succeeds and is then unreadable to the same
-- user a moment later. This policy adds the owner_user_id path.
drop policy if exists households_member_select on public.households;
drop policy if exists households_member_or_owner_select on public.households;
create policy households_member_or_owner_select
  on public.households
  for select
  to authenticated
  using (
    owner_user_id = auth.uid()
    or public.is_household_member(id)
  );
