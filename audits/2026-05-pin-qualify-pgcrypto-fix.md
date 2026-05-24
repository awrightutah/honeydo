# PIN pgcrypto schema-qualification fix — outcome

Date: 2026-05-22
Branch: `fix/pin-hashing-pass-2-2026-05-22` (unchanged)
Migrations touched: `supabase/migrations/0013_pin_hashing_bcrypt.sql` (amended in place), `supabase/migrations/0015_pin_qualify_pgcrypto.sql` (new)
Status: working tree edits, **not committed**

> **See also:** /audits/supabase-patterns-learned.md for Supabase-specific patterns learned during this work.

## Root cause

After 0014 added the `::text` cast on `gen_salt`'s first argument, the next runtime error was:

```
PostgrestException(code: 42883, message: 'function gen_salt(text, integer) does not exist')
```

Now Postgres was resolving the type correctly but couldn't find the function at all — because pgcrypto's functions live in the `extensions` schema, not `public`, and `set_member_pin` / `verify_member_pin` both have `SET search_path = public` (a deliberate security choice to prevent search-path injection). With `extensions` not in the function's search path, `gen_salt` and `crypt` are invisible.

User's verification query confirmed:

| schema | function_name |
|---|---|
| extensions | crypt |
| extensions | gen_salt |
| extensions | gen_salt |

(Two `gen_salt` rows = the single-arg and two-arg overloads.)

## Why Option A (fully-qualify) over Option B (widen search_path)

We picked **Option A** — fully-qualify every pgcrypto call as `extensions.crypt(...)` and `extensions.gen_salt(...)`. Reasons:

1. **Explicit > implicit.** The function says exactly which schema's `crypt` and `gen_salt` it wants. Future readers don't have to know Supabase's extension layout to follow the code.
2. **Robust against shadowing.** With `search_path = public, extensions`, anyone who could create a function in `public` (say, a leaked DB-admin credential, or a future migration that gets careless) could shadow `gen_salt` and silently capture every PIN that gets hashed. Fully-qualified calls bypass search-path resolution entirely; they cannot be shadowed.
3. **Doesn't depend on schema name stability.** If Supabase ever reorganizes where extensions live (unlikely, but they have moved them before during version migrations), only one line of SQL needs to change rather than the entire function's security surface.
4. **The function's stated posture (`SET search_path = public`) is preserved.** We don't widen the search path; we just opt out of it for two specific calls.

## Diff for `supabase/migrations/0013_pin_hashing_bcrypt.sql`

Two changes inside this single file — one per function.

### Change 1 — inside `set_member_pin`

```diff
   INSERT INTO public.member_pin_secrets (member_id, pin_hash, updated_at)
-    VALUES (p_member_id, crypt(p_pin, gen_salt('bf'::text, 8)), now())
+    VALUES (p_member_id, extensions.crypt(p_pin, extensions.gen_salt('bf'::text, 8)), now())
     ON CONFLICT (member_id) DO UPDATE
       SET pin_hash   = EXCLUDED.pin_hash,
           updated_at = now();
```

### Change 2 — inside `verify_member_pin`

```diff
   -- bcrypt: crypt(plaintext, stored_hash) recomputes the same hash if
   -- the PIN matches, because the stored_hash carries its own salt + cost.
-  RETURN crypt(p_pin, v_stored_hash) = v_stored_hash;
+  RETURN extensions.crypt(p_pin, v_stored_hash) = v_stored_hash;
```

`has_member_pin` is untouched — it never calls pgcrypto.

## Full SQL for `supabase/migrations/0015_pin_qualify_pgcrypto.sql`

```sql
-- 0015_pin_qualify_pgcrypto.sql
--
-- Second hotfix for migration 0013. After 0014 added an explicit ::text
-- cast on gen_salt's first argument, the next runtime error was:
--
--   PostgrestException(code: 42883,
--     message: 'function gen_salt(text, integer) does not exist')
--
-- Root cause: pgcrypto's functions live in the `extensions` schema on
-- Supabase, not `public`. set_member_pin and verify_member_pin both have
-- SET search_path = public — a deliberate security choice that prevents
-- search-path injection but also makes extensions.gen_salt /
-- extensions.crypt invisible to the function body.
--
-- Verification query confirmed both functions are in `extensions`:
--   select n.nspname as schema, p.proname as function_name
--     from pg_proc p
--     join pg_namespace n on n.oid = p.pronamespace
--    where p.proname in ('gen_salt', 'crypt')
--    order by n.nspname, p.proname;
-- -> extensions | crypt
--    extensions | gen_salt   (one-arg)
--    extensions | gen_salt   (two-arg)
--
-- Fix: fully-qualify every pgcrypto call with the `extensions.` prefix.
-- This is strictly better than widening search_path to include extensions:
--   - Robust against future Supabase changes to the extensions schema name.
--   - Doesn't depend on search_path ordering, so it cannot be subverted by
--     someone creating a public.gen_salt that shadows the real one.
--   - The function's stated security posture (SET search_path = public)
--     still holds — extensions remains explicitly out of the search path.
--
-- 0013 has been amended in place so fresh databases see the corrected
-- SQL going forward. This file is the hotfix for databases that already
-- ran 0013 and (optionally) 0014.
--
-- has_member_pin does not call any pgcrypto function and is unchanged.


-- set_member_pin -----------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_member_pin(
  p_member_id uuid,
  p_pin       text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_target_kind         member_kind;
  v_target_household_id uuid;
  v_caller_is_admin     boolean;
BEGIN
  -- Validate PIN format: 4-6 digits, server-enforced.
  IF p_pin IS NULL OR p_pin !~ '^[0-9]{4,6}$' THEN
    RAISE EXCEPTION 'PIN must be 4 to 6 digits';
  END IF;

  -- Look up target member.
  SELECT kind, household_id
    INTO v_target_kind, v_target_household_id
    FROM public.household_members
    WHERE id = p_member_id;

  IF v_target_household_id IS NULL THEN
    RAISE EXCEPTION 'Member not found';
  END IF;

  IF v_target_kind <> 'sub_profile' THEN
    RAISE EXCEPTION 'PINs can only be set for sub_profile members';
  END IF;

  -- Caller must be an active owner/admin in the same household.
  SELECT EXISTS (
    SELECT 1
      FROM public.household_members
      WHERE auth_user_id = auth.uid()
        AND household_id = v_target_household_id
        AND role IN ('owner', 'admin')
        AND is_active = true
  ) INTO v_caller_is_admin;

  IF NOT v_caller_is_admin THEN
    RAISE EXCEPTION 'Only household admins can set member PINs';
  END IF;

  -- Hash and upsert. Fully-qualified pgcrypto calls because the function
  -- search_path is restricted to `public`.
  INSERT INTO public.member_pin_secrets (member_id, pin_hash, updated_at)
    VALUES (p_member_id, extensions.crypt(p_pin, extensions.gen_salt('bf'::text, 8)), now())
    ON CONFLICT (member_id) DO UPDATE
      SET pin_hash   = EXCLUDED.pin_hash,
          updated_at = now();
END;
$$;


-- verify_member_pin --------------------------------------------------------
CREATE OR REPLACE FUNCTION public.verify_member_pin(
  p_member_id uuid,
  p_pin       text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_target_household_id uuid;
  v_stored_hash         text;
  v_caller_is_member    boolean;
BEGIN
  IF p_pin IS NULL OR p_pin !~ '^[0-9]{4,6}$' THEN
    RETURN false;
  END IF;

  SELECT household_id
    INTO v_target_household_id
    FROM public.household_members
    WHERE id = p_member_id;

  IF v_target_household_id IS NULL THEN
    RETURN false;
  END IF;

  SELECT EXISTS (
    SELECT 1
      FROM public.household_members
      WHERE auth_user_id = auth.uid()
        AND household_id = v_target_household_id
        AND is_active = true
  ) INTO v_caller_is_member;

  IF NOT v_caller_is_member THEN
    RETURN false;
  END IF;

  SELECT pin_hash
    INTO v_stored_hash
    FROM public.member_pin_secrets
    WHERE member_id = p_member_id;

  IF v_stored_hash IS NULL THEN
    RETURN false;
  END IF;

  -- bcrypt: extensions.crypt(plaintext, stored_hash) recomputes the same
  -- hash if the PIN matches, because the stored_hash carries its own
  -- salt + cost. Fully-qualified because of the restricted search_path.
  RETURN extensions.crypt(p_pin, v_stored_hash) = v_stored_hash;
END;
$$;


-- Re-state grants (idempotent; CREATE OR REPLACE preserves grants in
-- modern Postgres but explicit is cheap).
REVOKE ALL ON FUNCTION public.set_member_pin(uuid, text)    FROM PUBLIC;
REVOKE ALL ON FUNCTION public.verify_member_pin(uuid, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.set_member_pin(uuid, text)    TO authenticated;
GRANT EXECUTE ON FUNCTION public.verify_member_pin(uuid, text) TO authenticated;
```

## Analyzer

| | Total | Errors |
|---|---|---|
| Before SQL edits | 333 | 1 (pre-existing `MyApp` test) |
| After SQL edits | 333 | 1 (same) |

Zero Dart code changed in this batch. Analyzer unchanged as expected.

## What to do next

1. In Supabase SQL editor: paste the full 0015 SQL and run it. `CREATE OR REPLACE` updates both functions in place; existing grants are preserved (the REVOKE/GRANT block re-states them idempotently).
2. On the iPhone: hot-restart Flutter (no rebuild needed since Dart is unchanged from the last reload).
3. Retry the Set-PIN flow: profile switcher → tap kid → enter new PIN → Set PIN. Expected outcome:
   - Success SnackBar: "PIN set for {name}. They can switch in now."
   - Tap the same kid again → "Enter PIN" dialog → enter same PIN → switches in.
4. If anything else surfaces, the Fix-1 catch surface from `/audits/2026-05-pin-error-surface-fix.md` is still active — the SnackBar will carry the full PostgrestException text directly.

## What this batch settles

This is the third (and hopefully final) iteration on migration 0013's pgcrypto integration. The sequence:

| Iteration | What it fixed | What surfaced next |
|---|---|---|
| 0013 (original) | First implementation | `gen_salt(unknown, integer) does not exist` — type ambiguity |
| 0014 | Added `'bf'::text` cast | `gen_salt(text, integer) does not exist` — schema invisibility |
| 0015 (this) | Fully-qualified `extensions.gen_salt` + `extensions.crypt` | — (expected: success) |

All three iterations are amendments to the same underlying RPC contract — no signature changes, no behavior changes for callers, just SQL-level resolution fixes. Existing rows in `member_pin_secrets` (if any) remain valid because the bcrypt hash format and `extensions.crypt(...) = stored_hash` check are the same operation regardless of qualification.

## Git state

```
$ git status --short
M apps/mobile/lib/screens/home_shell_screen.dart   (Fix 1, prior step)
M apps/mobile/lib/screens/members_screen.dart      (Fix 1, prior step)
M supabase/migrations/0013_pin_hashing_bcrypt.sql  (this step + prior 0014 amendments)
?? audits/2026-05-pin-error-surface-fix.md
?? audits/2026-05-pin-gen-salt-fix.md
?? audits/2026-05-pin-qualify-pgcrypto-fix.md
?? audits/2026-05-pin-set-error-silent-diag.md
?? supabase/migrations/0014_fix_gen_salt_type.sql
?? supabase/migrations/0015_pin_qualify_pgcrypto.sql
```

Nothing committed. Branch unchanged. Once you verify the PIN flow works on the iPhone, we can bundle this entire arc — Fix-1 catches, 0014, 0015, and the four new audit docs — into one or two follow-up commits on `fix/pin-hashing-pass-2-2026-05-22`, or rewrite history to fold them into the original `0904108` commit. Your call.
