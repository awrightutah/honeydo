-- 0016_kid_perms_schema.sql
--
-- Kid Permissions Workstream — Batch 1 (schema only).
--
-- Adds the database scaffolding needed for the kid-permissions feature
-- batches that follow. This migration is intentionally schema-only:
-- no RLS policies, no SECURITY DEFINER RPCs, no app code changes.
-- Those land in Batch 2 (migration 0017) and later batches.
--
-- Reference spec: /audits/2026-05-kid-profile-permissions-spec.md
-- Reference investigation: /audits/2026-05-kid-perms-batch-1-investigation.md
--
-- WHAT THIS MIGRATION DOES
--   1. New table: necessity_categories (per-household admin-configurable
--      list of shopping categories that bypass the wishlist for kids).
--      Seeded with 4 defaults (Hygiene, School Supplies, Basic Groceries,
--      Medication) for new households via trigger, and for any existing
--      households via a one-time backfill insert.
--   2. shopping_items gains three columns: is_wishlist (kid-add pending
--      approval), approved_by_member_id, approved_at. A partial index
--      supports the "Pending Wishlist" admin view.
--   3. household_members gains music_app_preference (per-kid music app
--      choice for the kid profile deep link in Batch 8).
--   4. New table: meal_requests (kid asks for a recipe; admin approves
--      or denies; approve becomes a meal_plans row in Batch 6 via RPC).
--   5. Owner-role backfill: any household_members row that represents the
--      household creator (auth_user_id matches households.owner_user_id)
--      and is currently role='admin' becomes role='owner'. Going forward,
--      the household-setup flow (Batch 3) will insert creators as 'owner'
--      directly, but legacy rows need this one-time fix.
--
-- DELIBERATELY OMITTED FROM THIS BATCH
--   • is_household_kid() RLS helper.
--     The spec called for a helper mirroring is_household_member /
--     is_household_admin. Investigation found that sub_profiles have
--     auth_user_id IS NULL, so a helper filtering by
--     "auth_user_id = auth.uid() AND kind = 'sub_profile'" can never
--     match — kids do not hold JWTs. RLS architecturally cannot detect
--     "the calling user is a kid." The realistic shape (taking a
--     p_member_id parameter and used inside SECURITY DEFINER RPCs) will
--     be added in Batch 2 if the RPCs need it.
--
--   • chore_verification_photos.rejected_reason text.
--     The spec called for this column but chores.rejected_reason already
--     exists (initial_schema.sql:107). Adding it on the photos table
--     creates two sources of truth for one piece of state. Batch 2's
--     reject flow will use the existing chores.rejected_reason.
--
--   • pg_cron 30-day photo retention job.
--     pg_cron is not yet enabled on the project (no migration references
--     it). Confirming availability AND designing the storage-object
--     cleanup (the DB row delete alone leaves orphaned files in the
--     chore-photos bucket) deserve their own pass. The chore-photo flow
--     does not ship until Batch 4, and no photos exist yet, so we have
--     30+ days of runway after Batch 4 before cleanup is needed.
--     A separate small migration adds the cron job after both blockers
--     are resolved.
--
-- IDEMPOTENCY
--   All CREATE TABLE use IF NOT EXISTS, all CREATE OR REPLACE on the
--   function, DROP TRIGGER IF EXISTS before re-creating triggers, all
--   ALTER TABLE ADD COLUMN use IF NOT EXISTS, all CREATE INDEX use
--   IF NOT EXISTS, the seed INSERT uses ON CONFLICT DO NOTHING, and the
--   role-backfill UPDATE only affects rows where role is still 'admin'
--   (running again is a no-op once they're 'owner'). Safe to re-run.


-- 1. necessity_categories table -------------------------------------------
-- Per-household admin-configurable list of shopping categories that
-- bypass the wishlist for kid inserts. Composite PK on (household_id,
-- category) — no surrogate id needed; the natural key is unique.
-- Comparison against shopping_items.category is case-insensitive via
-- lower() in the Batch-2 RPC (we store as user-typed for display).
CREATE TABLE IF NOT EXISTS public.necessity_categories (
  household_id uuid NOT NULL REFERENCES public.households(id) ON DELETE CASCADE,
  category     text NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (household_id, category)
);

-- Defense in depth: lock down by default. Batch 2 adds policies (member
-- SELECT to know the bypass list; admin INSERT/UPDATE/DELETE to manage).
ALTER TABLE public.necessity_categories ENABLE ROW LEVEL SECURITY;


-- 2. Default-seed trigger -------------------------------------------------
-- Ships 4 default categories every time a new household is created.
-- Admins can edit/delete per household from the Batch 5 UI.
CREATE OR REPLACE FUNCTION public.seed_default_necessity_categories()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO public.necessity_categories (household_id, category) VALUES
    (NEW.id, 'Hygiene'),
    (NEW.id, 'School Supplies'),
    (NEW.id, 'Basic Groceries'),
    (NEW.id, 'Medication')
  ON CONFLICT DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS seed_necessity_categories_on_household ON public.households;
CREATE TRIGGER seed_necessity_categories_on_household
  AFTER INSERT ON public.households
  FOR EACH ROW
  EXECUTE FUNCTION public.seed_default_necessity_categories();


-- 3. Backfill defaults for existing households ----------------------------
-- Picks up the Wrights household and anything else already in the table
-- when this migration runs. ON CONFLICT DO NOTHING means re-running is
-- safe (the trigger above will have populated future households).
INSERT INTO public.necessity_categories (household_id, category)
SELECT h.id, c.category
  FROM public.households h
  CROSS JOIN (VALUES ('Hygiene'), ('School Supplies'), ('Basic Groceries'), ('Medication')) AS c(category)
ON CONFLICT DO NOTHING;


-- 4. shopping_items: wishlist columns + partial index ---------------------
-- is_wishlist=true means "kid added it, pending admin approval."
-- approved_by / approved_at are populated by the Batch-2 approve RPC,
-- which flips is_wishlist=false. The active shopping list view filters
-- WHERE is_wishlist = false, so an approved item appears automatically.
-- Existing items default to is_wishlist=false (i.e., on the active list).
ALTER TABLE public.shopping_items
  ADD COLUMN IF NOT EXISTS is_wishlist boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS approved_by_member_id uuid REFERENCES public.household_members(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS approved_at timestamptz;

-- Partial index — most rows are is_wishlist=false; only the admin
-- "Pending Wishlist" view scans for is_wishlist=true. Saves space and
-- write amplification vs a full index.
CREATE INDEX IF NOT EXISTS idx_shopping_items_wishlist
  ON public.shopping_items(household_id, is_wishlist)
  WHERE is_wishlist = true;


-- 5. household_members.music_app_preference -------------------------------
-- Per-kid music app choice for the Batch-8 deep-link button. Free text;
-- the app validates against a known list (e.g., 'spotify', 'apple_music',
-- 'youtube_music'). No CHECK constraint here — adding a new app should
-- not require a DB migration.
ALTER TABLE public.household_members
  ADD COLUMN IF NOT EXISTS music_app_preference text;


-- 6. meal_requests table + indexes ----------------------------------------
-- Kid taps "Request this meal" on a recipe (Batch 6); a row is inserted
-- here. Admin reviews from the unified Pending Requests dashboard and
-- approves (Batch 2 RPC creates the matching meal_plans row) or denies
-- (status='denied' + optional decided_note). Auto-archive after 30 days
-- is enforced by app-side cleanup or a follow-up cron job.
CREATE TABLE IF NOT EXISTS public.meal_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id uuid NOT NULL REFERENCES public.households(id) ON DELETE CASCADE,
  requested_by_member_id uuid NOT NULL REFERENCES public.household_members(id) ON DELETE CASCADE,
  recipe_id uuid NOT NULL REFERENCES public.household_recipes(id) ON DELETE CASCADE,
  requested_for_date date,
  meal_type meal_type,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'approved', 'denied')),
  decided_by_member_id uuid REFERENCES public.household_members(id) ON DELETE SET NULL,
  decided_at timestamptz,
  decided_note text,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Index for the admin "Pending Meal Requests" dashboard query
-- (filters by household_id + status).
CREATE INDEX IF NOT EXISTS idx_meal_requests_household_status
  ON public.meal_requests(household_id, status);

-- Index for the kid's "My recent requests" view
-- (filters by requested_by_member_id).
CREATE INDEX IF NOT EXISTS idx_meal_requests_requested_by
  ON public.meal_requests(requested_by_member_id);

-- Same defense-in-depth pattern as necessity_categories.
ALTER TABLE public.meal_requests ENABLE ROW LEVEL SECURITY;


-- 7. Owner-role backfill --------------------------------------------------
-- Generalized — affects every household whose creator's household_members
-- row currently says role='admin'. Going forward, household_setup_screen
-- (Batch 3) inserts creators as 'owner' directly, so this is a one-time
-- fix for legacy rows. Today this likely matches one household (Wrights),
-- but the generic form catches anything else and is no-op on subsequent
-- runs once everyone is 'owner'.
--
-- The set_household_members_updated_at trigger (0001:442) will update
-- updated_at automatically, but we also set it explicitly for clarity.
UPDATE public.household_members hm
   SET role = 'owner',
       updated_at = now()
  FROM public.households h
 WHERE hm.household_id = h.id
   AND hm.auth_user_id = h.owner_user_id
   AND hm.role = 'admin';


-- ============================================================================
-- VERIFICATION QUERIES — run these in the Supabase SQL editor after
-- applying this migration. None of them mutate state.
-- ============================================================================
--
-- A. necessity_categories has 4 rows for every household (and at least
--    one household should be present — the Wrights):
--      SELECT h.name AS household,
--             count(nc.*) AS necessity_count
--        FROM public.households h
--        LEFT JOIN public.necessity_categories nc ON nc.household_id = h.id
--       GROUP BY h.name;
--    Expected: every row has necessity_count = 4.
--
-- B. shopping_items has the three new columns:
--      SELECT column_name, data_type, is_nullable, column_default
--        FROM information_schema.columns
--       WHERE table_schema = 'public'
--         AND table_name = 'shopping_items'
--         AND column_name IN ('is_wishlist', 'approved_by_member_id', 'approved_at');
--    Expected: 3 rows. is_wishlist is_nullable=NO default=false; the other two NO default and nullable.
--
-- C. household_members has music_app_preference:
--      SELECT column_name, data_type, is_nullable
--        FROM information_schema.columns
--       WHERE table_schema = 'public'
--         AND table_name = 'household_members'
--         AND column_name = 'music_app_preference';
--    Expected: 1 row, text, is_nullable=YES.
--
-- D. meal_requests table exists with RLS enabled and zero policies:
--      SELECT relname, relrowsecurity
--        FROM pg_class
--       WHERE relnamespace = 'public'::regnamespace
--         AND relname = 'meal_requests';
--      -- expected: 1 row, relrowsecurity = true
--
--      SELECT count(*) AS policy_count
--        FROM pg_policies
--       WHERE schemaname = 'public'
--         AND tablename = 'meal_requests';
--      -- expected: policy_count = 0 (Batch 2 will add policies)
--
-- E. Owner-role backfill landed:
--      SELECT h.name, hm.display_name, hm.role, hm.kind
--        FROM public.household_members hm
--        JOIN public.households h ON h.id = hm.household_id
--       WHERE hm.auth_user_id = h.owner_user_id;
--    Expected: every row has role='owner'. (Before this migration, these
--    would have said role='admin' instead.)
--
-- F. seed_default_necessity_categories trigger exists on households:
--      SELECT tgname, tgenabled
--        FROM pg_trigger
--       WHERE tgrelid = 'public.households'::regclass
--         AND tgname = 'seed_necessity_categories_on_household';
--    Expected: 1 row, tgenabled='O' (enabled, origin).
