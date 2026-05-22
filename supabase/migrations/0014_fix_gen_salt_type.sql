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
