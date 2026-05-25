# Supabase patterns learned

This file collects Supabase-specific patterns discovered during development that aren't obvious from standard Postgres docs. Future migrations should follow these patterns or risk hitting the same gotchas.

## Pattern 1: Fully qualify pgcrypto functions

When using pgcrypto functions (crypt, gen_salt, digest, etc.) in migrations, always reference them with the `extensions.` schema prefix.

- Bad: `crypt(p_pin, gen_salt('bf', 8))`
- Good: `extensions.crypt(p_pin, extensions.gen_salt('bf'::text, 8))`

The Supabase project sets up pgcrypto in the `extensions` schema, not `public`. SECURITY DEFINER functions with `SET search_path = public` cannot find unqualified pgcrypto functions.

Discovered during: Pass 2 PIN security debugging (migrations 0014, 0015).

## Pattern 2: Explicit ::text casts on overloaded functions

When calling Postgres functions that have multiple overloads (like `gen_salt`), pass `::text` casts on string literals to disambiguate.

- Bad: `extensions.gen_salt('bf', 8)`
- Good: `extensions.gen_salt('bf'::text, 8)`

Without the cast, Postgres can pick the wrong overload signature and raise a type error at execution time.

Discovered during: Pass 2 PIN security debugging (migration 0014).

## Pattern 3: REVOKE EXECUTE FROM PUBLIC, anon (not just PUBLIC)

Supabase default-grants EXECUTE to `anon`, `authenticated`, AND `service_role` on every function created in the `public` schema. `REVOKE ALL ON FUNCTION ... FROM PUBLIC` does NOT catch the per-role grants.

For any SECURITY DEFINER RPC that should not be callable by signed-out users:

```sql
REVOKE ALL ON FUNCTION public.my_rpc(...) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_rpc(...) TO authenticated;
```

Verify via BOTH queries (they can disagree on what counts as revoked):

```sql
-- Check 1: has_function_privilege
SELECT proname,
       has_function_privilege('authenticated', oid, 'execute') AS auth_can,
       has_function_privilege('anon', oid, 'execute') AS anon_can
  FROM pg_proc
 WHERE proname = 'my_rpc';

-- Check 2: information_schema.routine_privileges
SELECT grantee, privilege_type
  FROM information_schema.routine_privileges
 WHERE routine_name = 'my_rpc';
```

Expected: `auth_can=true, anon_can=false`; no anon row in routine_privileges.

Discovered during: Pass 3 Batch 2 verification (migration 0018 hotfix).

## How to use this file

- Before writing any new SECURITY DEFINER RPC or pgcrypto-touching migration, read this file
- If a new pattern emerges, add it here with the same structure: bad/good example, rationale, discovered-during reference
- Cross-reference from feature spec docs rather than duplicating
