# PIN gen_salt type-cast fix — outcome

Date: 2026-05-22
Branch: `fix/pin-hashing-pass-2-2026-05-22` (unchanged)
Migrations touched: `supabase/migrations/0013_pin_hashing_bcrypt.sql` (amended in place), `supabase/migrations/0014_fix_gen_salt_type.sql` (new)
Status: working tree edits, **not committed**

> **See also:** /audits/supabase-patterns-learned.md for Supabase-specific patterns learned during this work.

## Root cause

When `set_member_pin` was called from the iPhone, Postgres raised:

```
PostgrestException(
  code: 42883,
  message: 'function gen_salt(unknown, integer) does not exist',
  hint: 'No function matches the given name and argument types.
         You might need to add explicit type casts.'
)
```

`gen_salt('bf', 8)` — the unquoted string literal `'bf'` is typed as `unknown` until the planner resolves it. Under Supabase's schema layout, pgcrypto lives in the `extensions` schema, not `public`. The overload resolver, working from a function with `SET search_path = public`, cannot bridge from `gen_salt(unknown, integer)` to the available `extensions.gen_salt(text, integer)`. The fix is an explicit cast — `gen_salt('bf'::text, 8)` — which lets the resolver match the overload directly.

Earlier guess in `/audits/2026-05-pin-set-error-silent-diag.md` (Diagnosis section) was wrong: I had "Only household admins can set member PINs" as the top suspect. Once Fix 1 surfaced the actual exception, the real cause turned out to be this type-resolution issue, which I should have caught in the migration review. Lesson logged: when calling pgcrypto from a function with a restricted `search_path` on Supabase, always cast literal arguments explicitly.

## Diff for 0013 (canonical fix, for fresh databases)

`supabase/migrations/0013_pin_hashing_bcrypt.sql`, inside `set_member_pin`:

```diff
   INSERT INTO public.member_pin_secrets (member_id, pin_hash, updated_at)
-    VALUES (p_member_id, crypt(p_pin, gen_salt('bf', 8)), now())
+    VALUES (p_member_id, crypt(p_pin, gen_salt('bf'::text, 8)), now())
     ON CONFLICT (member_id) DO UPDATE
       SET pin_hash   = EXCLUDED.pin_hash,
           updated_at = now();
```

One-line change inside the `set_member_pin` function body. Nothing else in 0013 needed adjustment — `verify_member_pin` and `has_member_pin` don't call `gen_salt`.

## Full SQL for 0014 (hotfix for the already-migrated database)

`supabase/migrations/0014_fix_gen_salt_type.sql`:

```sql
-- 0014_fix_gen_salt_type.sql
--
-- Hotfix for migration 0013: gen_salt('bf', 8) failed at runtime with
--   PostgrestException(code: 42883,
--     message: 'function gen_salt(unknown, integer) does not exist',
--     hint: 'No function matches the given name and argument types.
--            You might need to add explicit type casts.')
--
-- Postgres treats the unquoted string literal 'bf' as type `unknown` and,
-- under Supabase's schema layout (pgcrypto lives in the `extensions`
-- schema, not `public`), the overload resolver cannot bridge from
-- `gen_salt(unknown, integer)` to the available `gen_salt(text, integer)`.
-- The fix is an explicit `::text` cast on the algorithm argument.
--
-- 0013 has been amended in place so that fresh databases see the
-- corrected SQL going forward. This file is what gets applied to any
-- database that already ran 0013 successfully but ended up with the
-- broken set_member_pin function.
--
-- Only set_member_pin needs replacing: verify_member_pin and
-- has_member_pin do not call gen_salt and are unaffected.


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

  -- Hash and upsert. Note 'bf'::text — without the explicit cast,
  -- Postgres treats the literal as `unknown` and the gen_salt overload
  -- cannot be resolved (this was the original bug in 0013).
  INSERT INTO public.member_pin_secrets (member_id, pin_hash, updated_at)
    VALUES (p_member_id, crypt(p_pin, gen_salt('bf'::text, 8)), now())
    ON CONFLICT (member_id) DO UPDATE
      SET pin_hash   = EXCLUDED.pin_hash,
          updated_at = now();
END;
$$;


-- Re-grant execute. CREATE OR REPLACE preserves existing grants in
-- modern Postgres, but stating them explicitly is cheap and idempotent.
REVOKE ALL ON FUNCTION public.set_member_pin(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_member_pin(uuid, text) TO authenticated;
```

The migration is idempotent (`CREATE OR REPLACE`, plus REVOKE+GRANT are no-op-safe). Safe to re-run.

## Analyzer

| | Total | Errors |
|---|---|---|
| Before SQL edits | 333 | 1 (pre-existing `MyApp` test) |
| After SQL edits | 333 | 1 (same) |

Zero Dart code changed in this batch — both edits are SQL only. Analyzer unchanged as expected.

## What to do next

1. Paste the SQL from `supabase/migrations/0014_fix_gen_salt_type.sql` into the Supabase SQL editor and run it. The `CREATE OR REPLACE` replaces the broken `set_member_pin` in place; no need to drop anything first.
2. On the iPhone (no rebuild needed — Dart code is unchanged from the last hot reload), retry the Set-PIN flow: profile switcher → tap kid → enter new PIN → Set PIN.
3. Expected: the success SnackBar "PIN set for {name}. They can switch in now." Then tap the same kid again, enter the same PIN, and verify the switch lands.
4. If anything else surfaces, the surface-fix from `/audits/2026-05-pin-error-surface-fix.md` is still in place — the SnackBar will carry the real PostgrestException text.

## Git state

```
$ git status --short
M apps/mobile/lib/screens/home_shell_screen.dart    (Fix 1 from prior step)
M apps/mobile/lib/screens/members_screen.dart       (Fix 1 from prior step)
M supabase/migrations/0013_pin_hashing_bcrypt.sql   (this step: 'bf'::text)
?? audits/2026-05-pin-error-surface-fix.md
?? audits/2026-05-pin-gen-salt-fix.md
?? audits/2026-05-pin-set-error-silent-diag.md
?? supabase/migrations/0014_fix_gen_salt_type.sql
```

Nothing committed. Branch unchanged. When you've verified the fix works on iPhone, we can either bundle this into the existing `fix/pin-hashing-pass-2-2026-05-22` branch as one or two follow-up commits, or amend the original commit `0904108` — your call.
