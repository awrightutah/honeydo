# Kid perms — anon REVOKE hotfix (0018)

Date: 2026-05-22
Branch: `feat/kid-perms-rls-rpcs-batch-2-2026-05-22` (working-tree only; no commits)
Migrations touched: `0017_kid_perms_rls_rpcs.sql` (Section 8 amended in place), `0018_kid_perms_revoke_anon.sql` (new)
Status: code complete — **0018 not yet applied; nothing committed**

## Root cause

Migration 0017's Section 8 revoked default grants with `REVOKE ALL ON FUNCTION … FROM PUBLIC` and then explicitly granted EXECUTE to `authenticated`. Verification after applying revealed `anon` ALSO has EXECUTE on all six RPCs:

```
routine_privileges for approve_chore:
  postgres        EXECUTE
  anon            EXECUTE  <-- WRONG
  authenticated   EXECUTE
  service_role    EXECUTE  <-- OK (intentional)
```

The mistake: **Supabase default-grants EXECUTE to anon, authenticated, AND service_role on every function created in the public schema**, as explicit role grants — not as PUBLIC pseudo-role grants. `REVOKE FROM PUBLIC` does not remove explicit per-role grants.

The behavior is functionally safe today — every RPC starts by calling `is_household_admin` or `is_household_member`, both of which return `false` for anon (since `auth.uid()` is NULL → no membership row matches). But principle of least privilege says the function shouldn't even be callable by anon.

Same shape of Supabase-specific gotcha as the pgcrypto `extensions` schema issue in Pass 2 (migrations 0014, 0015): "REVOKE FROM PUBLIC" feels complete in vanilla Postgres but isn't enough on Supabase.

## Diff for 0017 (Section 8, amended in place)

```diff
- -- Default Postgres grants EXECUTE TO PUBLIC on new functions. Revoke that
- -- first, then grant explicitly to authenticated. anon (signed-out users)
- -- cannot call any of these.
- REVOKE ALL ON FUNCTION public.approve_chore(uuid, boolean, text) FROM PUBLIC;
- REVOKE ALL ON FUNCTION public.complete_chore_self(uuid, uuid) FROM PUBLIC;
- REVOKE ALL ON FUNCTION public.submit_kid_chore_with_photo(uuid, uuid, text) FROM PUBLIC;
- REVOKE ALL ON FUNCTION public.add_shopping_item(uuid, uuid, text, numeric, text, text, uuid, uuid) FROM PUBLIC;
- REVOKE ALL ON FUNCTION public.create_meal_request(uuid, uuid, uuid, date, meal_type) FROM PUBLIC;
- REVOKE ALL ON FUNCTION public.decide_meal_request(uuid, boolean, text, date, meal_type) FROM PUBLIC;
+ -- Revoke from PUBLIC (default Postgres) and from anon explicitly (Supabase
+ -- default-grants EXECUTE to anon, authenticated, AND service_role on every
+ -- function created in the public schema — REVOKE FROM PUBLIC alone does NOT
+ -- catch those explicit role grants). service_role's EXECUTE is intentional
+ -- (server-side access). Same Supabase-quirk pattern as the extensions
+ -- schema arc in Pass 2 (migrations 0014, 0015).
+ REVOKE ALL ON FUNCTION public.approve_chore(uuid, boolean, text) FROM PUBLIC, anon;
+ REVOKE ALL ON FUNCTION public.complete_chore_self(uuid, uuid) FROM PUBLIC, anon;
+ REVOKE ALL ON FUNCTION public.submit_kid_chore_with_photo(uuid, uuid, text) FROM PUBLIC, anon;
+ REVOKE ALL ON FUNCTION public.add_shopping_item(uuid, uuid, text, numeric, text, text, uuid, uuid) FROM PUBLIC, anon;
+ REVOKE ALL ON FUNCTION public.create_meal_request(uuid, uuid, uuid, date, meal_type) FROM PUBLIC, anon;
+ REVOKE ALL ON FUNCTION public.decide_meal_request(uuid, boolean, text, date, meal_type) FROM PUBLIC, anon;
```

The GRANT block immediately below is unchanged (still grants EXECUTE only to `authenticated`).

## Full SQL of 0018 (the hotfix to apply to the already-migrated database)

```sql
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
```

## Pattern to remember going forward

This is the third Supabase-specific REVOKE/extension-schema gotcha (after 0014's `'bf'::text` cast and 0015's `extensions.` prefix). The common shape: vanilla Postgres patterns don't fully account for Supabase's pre-configured role/schema setup.

Suggested addition to the standing checklist when writing new RPC migrations:

1. `SET search_path = public` on every SECURITY DEFINER function.
2. Fully qualify extension-schema calls (`extensions.crypt(...)`, etc.).
3. Explicit `::text` cast on overloaded function call arguments.
4. **`REVOKE ALL FROM PUBLIC, anon`** (not just `FROM PUBLIC`) on every RPC. Then `GRANT EXECUTE TO authenticated`. service_role's grant is preserved automatically. ← *new*
5. Verification should include `has_function_privilege('anon', …, 'execute') = false` ← already in 0017's verification block, but the user ran a different query (`routine_privileges`) which surfaced it. Worth running both styles.

This learned pattern can roll into the spec's general implementation notes or into a Supabase-specific cheatsheet alongside the existing Pass 2 lessons.

## What to do next

1. **Run 0018 in Supabase SQL editor.** Pure REVOKE statements; idempotent; safe.
2. **Re-run verification.** Both the `has_function_privilege` style and the `routine_privileges` style should show no anon EXECUTE on any of the 6 RPCs.
3. **Commit** when ready: 0017 amendment + 0018 + this report. The branch already has uncommitted Batch 2 work (migration 0017 + investigation + implementation reports); this hotfix folds in.
4. **Apply the pattern** in future RPC migrations (Batch 3 likely won't have new RPCs, but Batches 4-6 might).

## Git state (uncommitted)

```
$ git status --short
?? audits/2026-05-kid-perms-anon-revoke-fix.md
?? audits/2026-05-kid-perms-batch-2-implementation.md
?? audits/2026-05-kid-perms-batch-2-investigation.md
?? supabase/migrations/0017_kid_perms_rls_rpcs.sql
?? supabase/migrations/0018_kid_perms_revoke_anon.sql
```

0017 is shown as untracked because Batch 2 hasn't been committed yet — the amendment to its Section 8 lives in the same untracked file, not as a diff against a committed version. When this branch is committed, all 5 files land in a single commit (or two if you'd rather split Batch 2 main work from the anon hotfix). Working tree is otherwise clean on `feat/kid-perms-rls-rpcs-batch-2-2026-05-22`.
