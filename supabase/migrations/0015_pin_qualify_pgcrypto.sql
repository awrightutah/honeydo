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
