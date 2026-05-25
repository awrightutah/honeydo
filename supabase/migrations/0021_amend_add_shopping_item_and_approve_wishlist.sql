-- 0021_amend_add_shopping_item_and_approve_wishlist.sql
--
-- Kid Permissions Workstream — Batch 5a: wishlist backend.
--
-- Closes two gaps the Batch 5 investigation surfaced
-- (/audits/2026-05-kid-perms-batch-5-investigation.md):
--
--   GAP 1 — add_shopping_item RPC was param-narrow vs the direct INSERT path.
--           Three columns the app writes (`source_recipe_id`,
--           `source_meal_plan_id`, `display_quantity`) were not accepted by
--           the RPC. Result: kid inserts via the RPC lost lineage. This
--           migration amends the RPC signature to accept all three as
--           optional params and pass them through to the INSERT.
--
--   GAP 2 — shopping_items UPDATE RLS was permissive (any household member).
--           A kid sharing their parent's JWT could flip `is_wishlist=false`
--           and self-approve. This migration adds (a) a new
--           `approve_wishlist_item` SECURITY DEFINER RPC for admin-only
--           approval, and (b) a BEFORE UPDATE trigger that raises if any
--           non-admin tries to change `is_wishlist`. The existing UPDATE
--           policy is left as-is (any household member can still tick
--           items off, edit qty, etc.) — the trigger adds the
--           wishlist-specific guard column.
--
-- WHY A TRIGGER, NOT RESTRUCTURED RLS
--   Postgres RLS doesn't natively expose OLD vs NEW in WITH CHECK clauses,
--   so column-level "this column must not change unless caller is admin"
--   is awkward to express purely in RLS. A BEFORE UPDATE trigger calling
--   the existing `is_household_admin(household_id)` helper is cleaner and
--   composes with all the other shopping_items mutation paths (manual
--   tick-off, qty edit, etc.) without disturbing them.
--
-- WHY DROP + CREATE FOR add_shopping_item (not CREATE OR REPLACE)
--   PostgreSQL CREATE OR REPLACE FUNCTION cannot change the parameter
--   list — the IN-param signature is part of the function's identity.
--   Adding three new params at the end requires DROP FUNCTION + CREATE
--   FUNCTION. The new params are all DEFAULT NULL, so existing callers
--   that pass only the original 8 params keep working unchanged.
--
-- REFERENCES
--   Investigation:    /audits/2026-05-kid-perms-batch-5-investigation.md
--   Implementation:   /audits/2026-05-kid-perms-batch-5a-implementation.md
--   Predecessor RPC:  supabase/migrations/0017_kid_perms_rls_rpcs.sql §5
--   Patterns:         /audits/supabase-patterns-learned.md (Pattern 1, Pattern 3)
--
-- IDEMPOTENCY
--   DROP FUNCTION IF EXISTS handles re-runs of the original signature.
--   CREATE OR REPLACE on the new function + trigger + approve RPC.
--   REVOKE/GRANT no-op when already in state.


-- ============================================================================
-- SECTION 1 — Amend add_shopping_item (Gap 1)
-- ============================================================================
-- Drop the original 8-arg signature, then create the 11-arg version with
-- three new optional trailing params. Validation logic is byte-for-byte
-- identical to migration 0017 §5; only the signature and the INSERT
-- column list change.

DROP FUNCTION IF EXISTS public.add_shopping_item(uuid, uuid, text, numeric, text, text, uuid, uuid);

CREATE FUNCTION public.add_shopping_item(
  p_household_id        uuid,
  p_member_id           uuid,
  p_name                text,
  p_quantity            numeric DEFAULT NULL,
  p_unit                text    DEFAULT NULL,
  p_category            text    DEFAULT NULL,
  p_store_id            uuid    DEFAULT NULL,
  p_shopping_list_id    uuid    DEFAULT NULL,
  p_source_recipe_id    uuid    DEFAULT NULL,
  p_source_meal_plan_id uuid    DEFAULT NULL,
  p_display_quantity    text    DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_member_kind       member_kind;
  v_member_active     boolean;
  v_resolved_list_id  uuid;
  v_is_wishlist       boolean;
  v_is_necessity      boolean;
  v_new_item_id       uuid;
BEGIN
  -- 1. Validate inputs
  IF p_name IS NULL OR length(trim(p_name)) = 0 THEN
    RAISE EXCEPTION 'Item name is required';
  END IF;

  -- 2. Calling adult JWT must be in the household
  IF NOT public.is_household_member(p_household_id) THEN
    RAISE EXCEPTION 'Caller is not a member of this household';
  END IF;

  -- 3. Member must exist in this household and be active
  SELECT kind, is_active
    INTO v_member_kind, v_member_active
    FROM public.household_members
   WHERE id = p_member_id
     AND household_id = p_household_id;

  IF v_member_kind IS NULL THEN
    RAISE EXCEPTION 'Member is not in this household';
  END IF;

  IF NOT v_member_active THEN
    RAISE EXCEPTION 'Member is not active';
  END IF;

  -- 4. Resolve shopping list (auto-pick oldest active if not specified)
  IF p_shopping_list_id IS NULL THEN
    SELECT id INTO v_resolved_list_id
      FROM public.shopping_lists
     WHERE household_id = p_household_id
       AND is_active = true
     ORDER BY created_at ASC
     LIMIT 1;

    IF v_resolved_list_id IS NULL THEN
      RAISE EXCEPTION 'No active shopping list found. Create one first.';
    END IF;
  ELSE
    SELECT id INTO v_resolved_list_id
      FROM public.shopping_lists
     WHERE id = p_shopping_list_id
       AND household_id = p_household_id;

    IF v_resolved_list_id IS NULL THEN
      RAISE EXCEPTION 'Shopping list not found in this household';
    END IF;
  END IF;

  -- 5. Determine is_wishlist by kind + necessity check
  IF v_member_kind = 'sub_profile' THEN
    SELECT EXISTS (
      SELECT 1
        FROM public.necessity_categories nc
       WHERE nc.household_id = p_household_id
         AND lower(nc.category) = lower(COALESCE(p_category, ''))
    ) INTO v_is_necessity;

    v_is_wishlist := NOT v_is_necessity;
  ELSE
    v_is_wishlist := false;
  END IF;

  -- 6. Insert the row (Gap 1 fix: 3 new columns appended)
  INSERT INTO public.shopping_items (
    household_id,
    shopping_list_id,
    name,
    quantity,
    unit,
    category,
    store_id,
    added_by_member_id,
    is_wishlist,
    source_recipe_id,
    source_meal_plan_id,
    display_quantity
  ) VALUES (
    p_household_id,
    v_resolved_list_id,
    trim(p_name),
    p_quantity,
    p_unit,
    p_category,
    p_store_id,
    p_member_id,
    v_is_wishlist,
    p_source_recipe_id,
    p_source_meal_plan_id,
    p_display_quantity
  )
  RETURNING id INTO v_new_item_id;

  RETURN v_new_item_id;
END;
$$;


-- ============================================================================
-- SECTION 2 — approve_wishlist_item RPC (Gap 2, half 1)
-- ============================================================================
-- Admin-only path to flip a wishlist item to is_wishlist=false. Mirrors
-- the kid-perms RPC pattern: validates inputs, checks authorization, does
-- the UPDATE atomically.
--
-- Validations (raise descriptively on each failure):
--   1. Item exists; load household_id + current is_wishlist
--   2. Item is currently is_wishlist=true (raise if already approved)
--   3. Calling user is admin in that household
--   4. Calling user's member_id resolves (for approved_by_member_id audit)
CREATE OR REPLACE FUNCTION public.approve_wishlist_item(
  p_item_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_household_id     uuid;
  v_current_wishlist boolean;
  v_admin_member_id  uuid;
BEGIN
  -- 1. Load item
  SELECT household_id, is_wishlist
    INTO v_household_id, v_current_wishlist
    FROM public.shopping_items
   WHERE id = p_item_id;

  IF v_household_id IS NULL THEN
    RAISE EXCEPTION 'Shopping item not found';
  END IF;

  -- 2. Must currently be a wishlist item
  IF NOT v_current_wishlist THEN
    RAISE EXCEPTION 'Item is already approved (not on the wishlist)';
  END IF;

  -- 3. Caller must be admin in this household
  IF NOT public.is_household_admin(v_household_id) THEN
    RAISE EXCEPTION 'Only household admins can approve wishlist items';
  END IF;

  -- 4. Resolve the admin's member_id for the approved_by_member_id audit trail
  SELECT id
    INTO v_admin_member_id
    FROM public.household_members
   WHERE auth_user_id = auth.uid()
     AND household_id = v_household_id
     AND is_active = true;

  -- 5. Flip the row
  UPDATE public.shopping_items
     SET is_wishlist           = false,
         approved_by_member_id = v_admin_member_id,
         approved_at           = now()
   WHERE id = p_item_id;
END;
$$;


-- ============================================================================
-- SECTION 3 — guard_shopping_items_wishlist_change trigger (Gap 2, half 2)
-- ============================================================================
-- BEFORE UPDATE trigger on shopping_items that blocks non-admin attempts to
-- change is_wishlist. The approve_wishlist_item RPC (Section 2) does the
-- admin check itself before issuing its UPDATE, and the trigger's
-- is_household_admin re-check is satisfied at trigger time because
-- auth.uid() reflects the original JWT caller regardless of SECURITY DEFINER
-- context. So the RPC path passes; direct UPDATE attempts by non-admin kids
-- (sharing the parent's JWT but with kid context) would fail — though in
-- practice the kid UI doesn't expose this affordance, defense-in-depth.
--
-- Non-wishlist field UPDATEs (qty, purchased, store_id, etc.) pass through
-- unaffected because the IF compares is_wishlist OLD vs NEW.
CREATE OR REPLACE FUNCTION public.guard_shopping_items_wishlist_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
BEGIN
  IF NEW.is_wishlist IS DISTINCT FROM OLD.is_wishlist THEN
    IF NOT public.is_household_admin(NEW.household_id) THEN
      RAISE EXCEPTION 'Only household admins can change wishlist status';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS guard_shopping_items_wishlist ON public.shopping_items;
CREATE TRIGGER guard_shopping_items_wishlist
  BEFORE UPDATE ON public.shopping_items
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_shopping_items_wishlist_change();


-- ============================================================================
-- SECTION 4 — REVOKE / GRANT (Pattern 3)
-- ============================================================================
-- Re-state the grants for the NEW signatures. The old 8-arg add_shopping_item
-- was dropped in Section 1, so its grants no longer exist; the new 11-arg
-- version inherits Supabase defaults at CREATE time and we lock them down.
-- approve_wishlist_item is new; same treatment. The trigger function itself
-- doesn't need an EXECUTE grant for end users — it's invoked by the trigger
-- mechanism, not directly callable.
REVOKE ALL ON FUNCTION public.add_shopping_item(uuid, uuid, text, numeric, text, text, uuid, uuid, uuid, uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.approve_wishlist_item(uuid) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.add_shopping_item(uuid, uuid, text, numeric, text, text, uuid, uuid, uuid, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.approve_wishlist_item(uuid) TO authenticated;


-- ============================================================================
-- VERIFICATION QUERIES — run after applying this migration. None mutate.
-- ============================================================================
--
-- A. Both functions exist with the expected signatures + SECURITY DEFINER:
--      SELECT proname, prosecdef, pronargs, pronargdefaults
--        FROM pg_proc p
--        JOIN pg_namespace n ON n.oid = p.pronamespace
--       WHERE n.nspname = 'public'
--         AND p.proname IN ('add_shopping_item', 'approve_wishlist_item')
--       ORDER BY proname;
--    Expected:
--      add_shopping_item:     prosecdef=true, pronargs=11, pronargdefaults=8
--      approve_wishlist_item: prosecdef=true, pronargs=1,  pronargdefaults=0
--
-- B. Role privileges:
--      SELECT p.proname,
--             has_function_privilege('authenticated', p.oid, 'execute') AS auth_can,
--             has_function_privilege('anon',          p.oid, 'execute') AS anon_can,
--             has_function_privilege('service_role',  p.oid, 'execute') AS svc_can
--        FROM pg_proc p
--        JOIN pg_namespace n ON n.oid = p.pronamespace
--       WHERE n.nspname = 'public'
--         AND p.proname IN ('add_shopping_item', 'approve_wishlist_item')
--       ORDER BY proname;
--    Expected: auth_can=true, anon_can=false, svc_can=true on both rows.
--
-- C. The 8-arg signature of add_shopping_item no longer exists:
--      SELECT count(*) AS old_sig_count
--        FROM pg_proc p
--        JOIN pg_namespace n ON n.oid = p.pronamespace
--       WHERE n.nspname = 'public'
--         AND p.proname = 'add_shopping_item'
--         AND pronargs = 8;
--    Expected: old_sig_count = 0.
--
-- D. Trigger is installed and enabled:
--      SELECT tgname, tgenabled, tgtype, pg_get_triggerdef(oid)
--        FROM pg_trigger
--       WHERE tgrelid = 'public.shopping_items'::regclass
--         AND tgname = 'guard_shopping_items_wishlist';
--    Expected: 1 row, tgenabled='O', BEFORE UPDATE FOR EACH ROW.
--
-- E. Functional smoke — Gap 2 enforcement (non-admin cannot flip is_wishlist):
--    Setup: insert a wishlist row as a kid (via add_shopping_item RPC with a
--    kid p_member_id and a non-necessity category). Then attempt direct
--    UPDATE as a non-admin user:
--
--      UPDATE public.shopping_items
--         SET is_wishlist = false
--       WHERE id = '<the wishlist row uuid>';
--      -- Expect: EXCEPTION 'Only household admins can change wishlist status'
--
--      -- Admin can do the same UPDATE directly:
--      UPDATE public.shopping_items
--         SET is_wishlist = false
--       WHERE id = '<the wishlist row uuid>';
--      -- Expect: 1 row updated.
--
-- F. Functional smoke — approve_wishlist_item happy path:
--      SELECT public.approve_wishlist_item(p_item_id := '<a wishlist row uuid>');
--    Expect: row's is_wishlist flips to false; approved_by_member_id set to
--    the admin's member_id; approved_at populated.
--
--      -- Calling on an already-approved item should raise:
--      SELECT public.approve_wishlist_item(p_item_id := '<same uuid>');
--    Expect: EXCEPTION 'Item is already approved (not on the wishlist)'
--
-- G. Gap 1 — add_shopping_item now accepts the lineage params:
--      SELECT public.add_shopping_item(
--        p_household_id     := '<wrights uuid>',
--        p_member_id        := '<a kid member uuid>',
--        p_name             := 'Spaghetti',
--        p_source_recipe_id := '<a recipe uuid>',
--        p_display_quantity := '2 boxes'
--      );
--    Expect: returns a uuid; the new shopping_items row has source_recipe_id
--    and display_quantity populated, is_wishlist=true (kid + no necessity
--    category match).
