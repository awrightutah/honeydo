-- 0013_pin_hashing_bcrypt.sql
--
-- Pass 2 (security) — proper PIN hashing for sub_profile authentication.
--
-- Replaces the broken SHA-256-no-salt client-side hashing scheme with
-- bcrypt server-side hashing via pgcrypto. The hash lives in a separate
-- table that no client role can read or write — all access goes through
-- the SECURITY DEFINER RPCs in this file. The old pin_hash column on
-- household_members is dropped at the end of the migration.
--
-- Existing SHA-256 pin_hash values cannot be recovered to original PIN,
-- so we do not migrate them. After this migration runs, every sub_profile
-- whose PIN was previously set will need an admin to re-set it via the
-- new set_member_pin RPC (the app shows "Set PIN" instead of "Verify
-- PIN" via has_member_pin()).
--
-- Resolves CQ2 from /audits/2026-05-pass-1a-flutter-v3.md.


-- 1. pgcrypto for crypt() and gen_salt('bf', ...) -------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;


-- 2. member_pin_secrets table ---------------------------------------------
-- One row per sub_profile with a PIN set. Bcrypt hash includes per-row
-- salt (no separate salt column needed — bcrypt format embeds it).
CREATE TABLE IF NOT EXISTS public.member_pin_secrets (
  member_id  uuid PRIMARY KEY REFERENCES public.household_members(id) ON DELETE CASCADE,
  pin_hash   text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);


-- 3. Lock the table down --------------------------------------------------
-- Belt-and-suspenders: revoke all grants AND enable RLS with no
-- policies. After this, no client role can SELECT/INSERT/UPDATE/DELETE
-- directly. The SECURITY DEFINER functions below bypass RLS by virtue
-- of running as the function owner (postgres).
REVOKE ALL ON TABLE public.member_pin_secrets FROM PUBLIC, anon, authenticated;
ALTER TABLE public.member_pin_secrets ENABLE ROW LEVEL SECURITY;


-- 4. RPCs -----------------------------------------------------------------

-- set_member_pin(p_member_id, p_pin)
--   Admin-only. Hashes server-side with bcrypt (work factor 8) and
--   upserts into member_pin_secrets. Raises on invalid PIN format,
--   unknown member, non-sub_profile target, or non-admin caller.
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

  -- Hash and upsert.
  INSERT INTO public.member_pin_secrets (member_id, pin_hash, updated_at)
    VALUES (p_member_id, crypt(p_pin, gen_salt('bf', 8)), now())
    ON CONFLICT (member_id) DO UPDATE
      SET pin_hash   = EXCLUDED.pin_hash,
          updated_at = now();
END;
$$;


-- verify_member_pin(p_member_id, p_pin) -> boolean
--   Returns true if the supplied PIN matches the stored bcrypt hash for
--   the target member, false on any failure (no PIN set, malformed
--   input, caller not in household, mismatch). Never returns or logs
--   any hash material.
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
  -- Reject malformed PINs without leaking any reason.
  IF p_pin IS NULL OR p_pin !~ '^[0-9]{4,6}$' THEN
    RETURN false;
  END IF;

  -- Look up target's household.
  SELECT household_id
    INTO v_target_household_id
    FROM public.household_members
    WHERE id = p_member_id;

  IF v_target_household_id IS NULL THEN
    RETURN false;
  END IF;

  -- Caller must be an active member of the same household (any role).
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

  -- Load the stored hash.
  SELECT pin_hash
    INTO v_stored_hash
    FROM public.member_pin_secrets
    WHERE member_id = p_member_id;

  IF v_stored_hash IS NULL THEN
    RETURN false;
  END IF;

  -- bcrypt: crypt(plaintext, stored_hash) recomputes the same hash if
  -- the PIN matches, because the stored_hash carries its own salt + cost.
  RETURN crypt(p_pin, v_stored_hash) = v_stored_hash;
END;
$$;


-- has_member_pin(p_member_id) -> boolean
--   Lets the app decide between "Set PIN" and "Verify PIN" UI without
--   reading hash material. Restricted to callers who are members of
--   the target's household, to avoid being a generic enumeration oracle.
CREATE OR REPLACE FUNCTION public.has_member_pin(
  p_member_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_target_household_id uuid;
  v_caller_is_member    boolean;
  v_has                 boolean;
BEGIN
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

  SELECT EXISTS (
    SELECT 1
      FROM public.member_pin_secrets
      WHERE member_id = p_member_id
  ) INTO v_has;

  RETURN v_has;
END;
$$;


-- 5. Grant execute to authenticated only ----------------------------------
-- Default Postgres grants EXECUTE TO PUBLIC on new functions; revoke
-- that first, then grant explicitly to authenticated. anon (signed-out
-- users) cannot call these.
REVOKE ALL ON FUNCTION public.set_member_pin(uuid, text)    FROM PUBLIC;
REVOKE ALL ON FUNCTION public.verify_member_pin(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.has_member_pin(uuid)          FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.set_member_pin(uuid, text)    TO authenticated;
GRANT EXECUTE ON FUNCTION public.verify_member_pin(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.has_member_pin(uuid)          TO authenticated;


-- 6. Drop the old broken pin_hash column ----------------------------------
-- Existing SHA-256 hashes cannot be recovered to original PIN, so we
-- drop the column instead of migrating values. Sub_profile members
-- whose PIN previously worked will need an admin to re-set the PIN.
-- The app handles "no PIN set" via has_member_pin() (Phase 3 wires this).
ALTER TABLE public.household_members DROP COLUMN IF EXISTS pin_hash;
