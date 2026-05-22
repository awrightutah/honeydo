-- 0018_kid_perms_revoke_anon.sql
--
-- Hotfix for migration 0017: explicit REVOKE EXECUTE from anon on all
-- six kid-perms RPCs.
--
-- BACKGROUND
--   0017's Section 8 used `REVOKE ALL ON FUNCTION … FROM PUBLIC` only,
--   under the assumption that this catches all default grants. On
--   Supabase, it does not: Supabase default-grants EXECUTE to anon,
--   authenticated, AND service_role on every function created in the
--   public schema. PUBLIC is a separate (pseudo-)role; revoking from
--   PUBLIC does not revoke from the explicitly-granted roles.
--
--   Verification after 0017 applied showed:
--     routine_privileges for approve_chore (example):
--       postgres        EXECUTE
--       anon            EXECUTE  <-- WRONG
--       authenticated   EXECUTE
--       service_role    EXECUTE  <-- OK (intentional)
--
--   anon (signed-out callers) should not be able to invoke any of these
--   RPCs. While the internal is_household_admin / is_household_member
--   checks in each RPC raise on anon (auth.uid() is NULL → membership
--   check fails), principle of least privilege says the RPC shouldn't
--   even be callable. Same Supabase-quirk pattern as the pgcrypto
--   extensions schema arc in Pass 2 (0014, 0015).
--
-- FIX
--   Explicit REVOKE EXECUTE FROM anon on all six RPCs. 0017 has been
--   amended in place so fresh databases see the corrected SQL going
--   forward; this file is the hotfix for any database that ran 0017
--   in its broken state.
--
--   service_role's EXECUTE is preserved (server-side access path is
--   intentional). authenticated's EXECUTE is preserved (the only
--   client-callable role).
--
-- IDEMPOTENCY
--   REVOKE is a no-op if the privilege is already absent. Safe to re-run.


REVOKE EXECUTE ON FUNCTION public.approve_chore(uuid, boolean, text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.complete_chore_self(uuid, uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.submit_kid_chore_with_photo(uuid, uuid, text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.add_shopping_item(uuid, uuid, text, numeric, text, text, uuid, uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.create_meal_request(uuid, uuid, uuid, date, meal_type) FROM anon;
REVOKE EXECUTE ON FUNCTION public.decide_meal_request(uuid, boolean, text, date, meal_type) FROM anon;


-- ============================================================================
-- VERIFICATION — confirm anon no longer has EXECUTE; authenticated still does.
-- ============================================================================
-- Run after applying:
--
--   SELECT p.proname,
--          has_function_privilege('authenticated', p.oid, 'execute') AS auth_can,
--          has_function_privilege('anon',          p.oid, 'execute') AS anon_can,
--          has_function_privilege('service_role',  p.oid, 'execute') AS service_can
--     FROM pg_proc p
--     JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname = 'public'
--      AND p.proname IN (
--        'approve_chore','complete_chore_self','submit_kid_chore_with_photo',
--        'add_shopping_item','create_meal_request','decide_meal_request'
--      )
--    ORDER BY p.proname;
--
-- Expected: 6 rows. auth_can=true, anon_can=false, service_can=true on every row.
--
-- Alternative check via information_schema.routine_privileges (matches the
-- query that surfaced the original miss):
--
--   SELECT routine_name, grantee, privilege_type
--     FROM information_schema.routine_privileges
--    WHERE routine_schema = 'public'
--      AND routine_name IN (
--        'approve_chore','complete_chore_self','submit_kid_chore_with_photo',
--        'add_shopping_item','create_meal_request','decide_meal_request'
--      )
--    ORDER BY routine_name, grantee;
--
-- Expected: NO rows where grantee='anon'. Per-routine rows for postgres,
-- authenticated, and service_role only.
