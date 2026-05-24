# PIN hashing fix — outcome (Pass 2)

Date: 2026-05-22
Branch: `fix/pin-hashing-pass-2-2026-05-22` (off `main` at `6306276`, post v0.1.0-baseline)
Migration introduced: `supabase/migrations/0013_pin_hashing_bcrypt.sql`
Resolves: CQ2 in `/audits/2026-05-pass-1a-flutter-v3.md`
Status: code complete, **migration not yet applied to Supabase, branch not merged, nothing committed**

> **See also:** /audits/supabase-patterns-learned.md for Supabase-specific patterns learned during this work.

## Security audit summary (before → after)

| Property | Before (v0.1.0-baseline) | After (this fix) |
|---|---|---|
| Hash algorithm | SHA-256, single pass, no salt | bcrypt (`gen_salt('bf', 8)`), per-row salt |
| Where hashing runs | Dart client (`package:crypto`) | Server-side, inside `SECURITY DEFINER` RPC |
| Where verification runs | Dart client comparing two hex strings | Server-side via `crypt()` constant-time-ish compare |
| Where the hash is stored | `household_members.pin_hash` (clients had SELECT) | `member_pin_secrets.pin_hash` (no client role has any privilege) |
| Where the hash can be read | Any authenticated client via `SELECT *` on household_members | Nowhere by any client — only the SECURITY DEFINER functions can read it |
| PIN format validation | `pin.length < 4` client-side only | `^[0-9]{4,6}$` enforced server-side (and client retains UX-level check) |
| Effective attack cost (single victim, focused brute force) | Microseconds against a precomputed SHA-256 PIN rainbow table — every kid's PIN recoverable in one query | ~17 minutes per victim at work=8 with per-row salt; no precomputation possible across victims |
| Data export leak | `data_export_screen.dart:173` did `.select('*')` on `household_members`, exporting `pin_hash` into the user's JSON/CSV export | Explicit column list — secrets never enter exports even if a future schema adds new ones |

## Branch

`fix/pin-hashing-pass-2-2026-05-22` — branched off `main@6306276` (one commit past the v0.1.0-baseline tag). Nothing committed yet on the branch; all changes are working-tree only.

## Modified files

| File | Net lines | Purpose |
|---|---|---|
| `apps/mobile/lib/screens/members_screen.dart` | +28 / −13 | Drop SHA-256 path. Insert kid row without `pin_hash`, capture inserted id, call `set_member_pin` RPC. Drop `dart:convert` and `package:crypto` imports. Update SECURITY DEBT comment to resolved-note. |
| `apps/mobile/lib/screens/home_shell_screen.dart` | +127 / −16 | Replace SHA-256 verify with `verify_member_pin` RPC (boolean return). Drop `dart:convert` and `package:crypto` imports. Gate `_verifyAndSwitchToKid` with `has_member_pin`; route admins to a new `_promptToSetMissingPin` set-pin dialog when no PIN exists, non-admins to an explanatory snackbar. |
| `apps/mobile/lib/screens/data_export_screen.dart` | +5 / −2 | Replace `.select('*')` on `household_members` with explicit column list omitting credentials. (Fixes the export leak independent of the column drop.) |
| `apps/mobile/pubspec.yaml` | −1 | Remove direct dependency on `crypto: ^3.0.3` (no longer imported anywhere in app code). |
| `apps/mobile/pubspec.lock` | −1 (net) | `flutter pub get` reclassified `crypto` from `direct main` to `transitive` (still pulled in by `http_parser` etc., just not directly). |

## New files

| File | Lines | Purpose |
|---|---|---|
| `supabase/migrations/0013_pin_hashing_bcrypt.sql` | 237 | The migration. See full SQL in the "SQL to apply" section below. |

## Per-phase summary

### Phase 1 — investigation

- Created branch off main.
- Captured analyzer baseline: **329 issues, 1 error** (the unrelated `MyApp` test).
- Found only **two screens** doing PIN logic: `members_screen.dart` (create kid) and `home_shell_screen.dart` (switch to kid). No PIN logic in services or other screens.
- Found **one real leak**: `data_export_screen.dart:173` exporting `pin_hash` into JSON/CSV.
- Found the broader blast radius: 24 `.select('*')` / empty-select call sites on `household_members` across 22 files would have broken under a column-level REVOKE.
- Surfaced architectural alternative (separate `member_pin_secrets` table); you picked Option B for the structural-prevention reasons.

### Phase 2 — migration

`supabase/migrations/0013_pin_hashing_bcrypt.sql`. Ordering matches your spec: extension → table → lockdown → RPCs → grants → drop column.

Key design points:

- `gen_salt('bf', 8)` — bcrypt work factor 8 (~256 key-schedule rounds, ~1ms per hash on commodity hardware). For 10⁴–10⁶ PIN keyspace, a focused single-victim brute force costs ~17 min; the per-row salt rules out cross-victim amortization.
- `INSERT … ON CONFLICT (member_id) DO UPDATE` — single RPC handles both initial set and later change. Caller never has to think about which case applies.
- All three RPCs are `SECURITY DEFINER` with `SET search_path = public` (prevents search-path attacks against the definer's elevated privileges).
- `member_pin_secrets` is locked three ways: REVOKE ALL from PUBLIC/anon/authenticated, ENABLE ROW LEVEL SECURITY with zero policies, FK ON DELETE CASCADE so an orphaned hash can't outlive the member. Even if a future migration accidentally grants SELECT, RLS still blocks reads.
- `has_member_pin` is restricted to household members so it can't be used as a generic enumeration oracle on member IDs from outside the household.
- Existing SHA-256 hashes are **not** migrated. The column drop wipes them and the app routes existing kids through the Set-PIN flow on first switch attempt (Phase 4).

### Phase 3 — app changes

#### `members_screen.dart` — _createSubProfile

```diff
- import 'dart:convert';
- import 'package:crypto/crypto.dart';

  try {
-   // SECURITY DEBT (CQ2 in audits/2026-05-pass-1a-flutter-v3.md):
-   // SHA-256 with no salt over a 4-6 digit PIN is recoverable in under
-   // one second via a complete rainbow table (key space <= 10^6) ...
-   final bytes = utf8.encode(pin);
-   final pinHash = sha256.convert(bytes).toString();
-   await Supabase.instance.client.from('household_members').insert({
-     'household_id': widget.householdId,
-     'kind': 'sub_profile',
-     'role': 'member',
-     'display_name': name,
-     'pin_hash': pinHash,
-     'points_balance': 0,
-     'is_active': true,
-     'created_by': Supabase.instance.client.auth.currentUser!.id,
-   });
+   // CQ2 resolved 2026-05-22: PIN is hashed server-side via the
+   // set_member_pin RPC (pgcrypto bcrypt, per-row salt). The hash
+   // lives in the locked-down member_pin_secrets table and never
+   // travels the wire. See supabase/migrations/0013_pin_hashing_bcrypt.sql.
+   final inserted = await Supabase.instance.client
+       .from('household_members')
+       .insert({
+         'household_id': widget.householdId,
+         'kind': 'sub_profile',
+         'role': 'member',
+         'display_name': name,
+         'points_balance': 0,
+         'is_active': true,
+         'created_by': Supabase.instance.client.auth.currentUser!.id,
+       })
+       .select('id')
+       .single();
+
+   await Supabase.instance.client.rpc('set_member_pin', params: {
+     'p_member_id': inserted['id'],
+     'p_pin': pin,
+   });
```

#### `home_shell_screen.dart` — _verifyAndSwitchToKid (Phase 3) + new _promptToSetMissingPin (Phase 4)

```diff
- import 'dart:convert';
- import 'package:crypto/crypto.dart';

  Future<void> _verifyAndSwitchToKid(Map<String, dynamic> member) async {
+   final hasPin = await Supabase.instance.client.rpc('has_member_pin', params: {
+     'p_member_id': member['id'],
+   }) as bool;
+   if (!mounted) return;
+   if (!hasPin) {
+     await _promptToSetMissingPin(member);
+     return;
+   }
+
    final pinController = TextEditingController();
    final verified = await showDialog<bool>( ... );

    if (verified != true) return;
    final pin = pinController.text.trim();
-   // SECURITY DEBT (CQ2 ...): SHA-256 with no salt ...
-   final pinHash = sha256.convert(utf8.encode(pin)).toString();
-   if (pinHash != member['pin_hash']) {
+   // CQ2 resolved 2026-05-22: PIN verification runs server-side via the
+   // verify_member_pin RPC ...
+   final ok = await Supabase.instance.client.rpc('verify_member_pin', params: {
+     'p_member_id': member['id'],
+     'p_pin': pin,
+   }) as bool;
+   if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Incorrect PIN. Please try again.')),
      );
      return;
    }
    await ActiveMemberService.instance.switchTo(member['id']);
  }

+ Future<void> _promptToSetMissingPin(Map<String, dynamic> member) async {
+   final role = _myMembership?['role'];
+   final isAdmin = role == 'owner' || role == 'admin';
+   if (!isAdmin) { /* snackbar: ask admin */ return; }
+   // Two-field "Set PIN" dialog → set_member_pin RPC.
+ }
```

#### `data_export_screen.dart` — _exportHousehold

```diff
  if (_sections['Household Members']!) {
-   data['members'] = await _supabase
-       .from('household_members')
-       .select('*')
+   // Explicit column list to avoid ever exporting auth secrets.
+   data['members'] = await _supabase
+       .from('household_members')
+       .select('id, household_id, kind, role, auth_user_id, display_name, avatar_url, points_balance, is_active, created_by, created_at, updated_at, current_streak, longest_streak, last_completion_date')
        .eq('household_id', householdId);
  }
```

#### `pubspec.yaml`

```diff
  connectivity_plus: ^6.1.0
- crypto: ^3.0.3
  share_plus: ^10.0.0
```

`flutter pub get` ran successfully and reclassified `crypto` from `direct main` → `transitive` in the lockfile (still pulled in via `http_parser` / `supabase_flutter`'s deps, just no longer a direct dependency).

### Phase 4 — handle existing data

Decision: the app does NOT currently allow a sub_profile to exist without a PIN (the create flow requires one). After migration 0013, every existing kid loses their PIN and the existing UI has no path to set a new one. The members screen only has an "Add Kid Profile" flow (creates), not a "Set/Change PIN" flow for existing kids.

Smallest change that closes the gap without refactoring outside the PIN flow: integrate the Set-PIN dialog into the kid switcher itself. The new flow in `_verifyAndSwitchToKid`:

1. Call `has_member_pin(member.id)`.
2. If true → existing "Enter PIN" dialog → `verify_member_pin` RPC → switch (no behavior change for kids with a PIN).
3. If false AND caller is owner/admin → "Set PIN" dialog (new pin + confirm) → `set_member_pin` RPC → confirmation snackbar. Admin then needs to tap the kid again to switch in via the PIN they just set.
4. If false AND caller is not admin → snackbar: "{kid name} needs a PIN. Ask an admin to set one."

This means **post-migration**, the user (an admin) opens the kid switcher, taps an existing kid, gets the Set-PIN dialog, sets a new PIN, and is back in business — no kid recreation needed, no points/history loss.

## Followups (spotted but not fixed in this batch)

1. **No rate limiting on `verify_member_pin`.** A determined authenticated attacker in the same household could brute-force a 4-digit PIN at ~1 attempt/ms server-side bcrypt cost — about 10 seconds for the full keyspace per kid. Add an `attempt_log` table + a function that locks for N minutes after K failures. Pass 2.1.
2. **No standalone "Change PIN" UI for existing kids in members management.** Today's only path is via the kid switcher's Set-PIN dialog, which only appears when no PIN is set. If an admin needs to rotate an existing kid's PIN, they currently can't (until we expose set_member_pin elsewhere). Suggested: add a "Change PIN" action to `member_profile_screen.dart` (admin-only, sub_profile-only). Pass 2.1.
3. **`_createSubProfile` is not transactional.** Two round trips (INSERT row, then RPC) — if the RPC call fails mid-flight, the kid exists without a PIN. The new Phase 4 UI handles this gracefully (admin will see Set-PIN dialog next time) but a combined `create_sub_profile_with_pin(household_id, name, pin)` RPC would be cleaner. Not pressing; mention in Pass 2.1.
4. **The 8 pre-existing `.rpc()` inference warnings** (in chore_dashboard, recipe_library, member_profile, api_service, and the existing get_leaderboard call) are now joined by 4 new ones from this work. None of them are errors; they reflect a codebase-wide convention of unparameterized `.rpc()` calls. Could be fixed in a separate cleanup pass with `.rpc<bool>(...)`, `.rpc<List<dynamic>>(...)` etc.
5. **PIN UX could borrow the keyboard pattern from other apps**: forced numeric pad, large round dots, no character preview. Current TextField with `obscureText: true` works but doesn't match what kids expect from a tablet PIN.

## Analyzer deltas

| | Total issues | Errors |
|---|---|---|
| Baseline (`main@6306276`) | 329 | 1 (pre-existing `MyApp` test class) |
| After Phase 3 (3 file edits) | 331 | 1 (unchanged) |
| After Phase 4 (added `_promptToSetMissingPin`) | 334 | 1 (unchanged), briefly +1 BuildContext error that I fixed with a `mounted` guard |
| **Final** | **333** | **1** (unchanged — same pre-existing error) |

Net delta: **+4 info-level warnings**, all `inference_failure_on_function_invocation` on the four new `.rpc()` calls (`set_member_pin` in members_screen, `has_member_pin` + `verify_member_pin` + `set_member_pin` in home_shell). The codebase already had 8 identical warnings on existing RPC calls (`award_points`, `get_leaderboard`, etc.) — the new ones follow the established convention. No new errors. No production-meaningful regressions.

## SQL to apply — copy-paste this into Supabase SQL Editor

```sql
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
CREATE TABLE IF NOT EXISTS public.member_pin_secrets (
  member_id  uuid PRIMARY KEY REFERENCES public.household_members(id) ON DELETE CASCADE,
  pin_hash   text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);


-- 3. Lock the table down --------------------------------------------------
REVOKE ALL ON TABLE public.member_pin_secrets FROM PUBLIC, anon, authenticated;
ALTER TABLE public.member_pin_secrets ENABLE ROW LEVEL SECURITY;


-- 4. RPCs -----------------------------------------------------------------

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
  IF p_pin IS NULL OR p_pin !~ '^[0-9]{4,6}$' THEN
    RAISE EXCEPTION 'PIN must be 4 to 6 digits';
  END IF;

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

  INSERT INTO public.member_pin_secrets (member_id, pin_hash, updated_at)
    VALUES (p_member_id, crypt(p_pin, gen_salt('bf', 8)), now())
    ON CONFLICT (member_id) DO UPDATE
      SET pin_hash   = EXCLUDED.pin_hash,
          updated_at = now();
END;
$$;


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

  RETURN crypt(p_pin, v_stored_hash) = v_stored_hash;
END;
$$;


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
REVOKE ALL ON FUNCTION public.set_member_pin(uuid, text)    FROM PUBLIC;
REVOKE ALL ON FUNCTION public.verify_member_pin(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.has_member_pin(uuid)          FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.set_member_pin(uuid, text)    TO authenticated;
GRANT EXECUTE ON FUNCTION public.verify_member_pin(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.has_member_pin(uuid)          TO authenticated;


-- 6. Drop the old broken pin_hash column ----------------------------------
ALTER TABLE public.household_members DROP COLUMN IF EXISTS pin_hash;
```

The migration is idempotent (`IF NOT EXISTS`, `OR REPLACE`, `DROP COLUMN IF EXISTS`) — safe to re-run.

## Re-test checklist

After applying the migration and pulling this branch, verify each path on the iPhone test build:

### Migration-applied verification (SQL editor)

1. `select extname from pg_extension where extname = 'pgcrypto';` → returns one row.
2. `select * from pg_tables where tablename = 'member_pin_secrets';` → returns one row.
3. `\d+ public.member_pin_secrets` (in psql) or the Supabase dashboard → confirm RLS enabled, no policies.
4. `select column_name from information_schema.columns where table_name = 'household_members' and column_name = 'pin_hash';` → returns zero rows (column dropped).
5. `select proname, prosecdef from pg_proc where proname in ('set_member_pin','verify_member_pin','has_member_pin');` → 3 rows, all with prosecdef=true.

### App paths (every existing kid should already need re-set)

| Path | Expected behavior |
|---|---|
| Sign in as adult owner, open profile switcher, tap an existing kid | `has_member_pin` returns false → "Set PIN" dialog appears |
| Set PIN dialog: enter `1234`, confirm `1234`, tap Set PIN | Snackbar "PIN set for {name}. They can switch in now." Dialog closes. |
| Re-tap the same kid in the switcher | `has_member_pin` returns true → "Enter PIN" dialog appears (same as the old flow) |
| Enter wrong PIN | Snackbar "Incorrect PIN. Please try again." No switch. |
| Enter correct PIN (`1234`) | Switches to kid; snackbar "Switched to {name}" |
| Sign in as a non-admin member (role=`member`), open switcher, tap a PIN-less kid | Snackbar tells them to ask an admin. No Set-PIN dialog shown. |
| Members screen → Add Kid Profile → name + PIN + confirm | Kid created; PIN immediately usable to switch (uses `set_member_pin` RPC under the hood) |
| Settings → Export household data → JSON | Check the exported file: `members` array should NOT contain a `pin_hash` field on any row |

### Edge cases worth poking

| Path | Expected behavior |
|---|---|
| Set PIN dialog: enter `12` (too short) | Snackbar "PIN must be 4 to 6 digits." Dialog stays, no RPC call. |
| Set PIN dialog: enter `abc1` (non-digit) | Snackbar "PIN must be 4 to 6 digits." |
| Set PIN dialog: PIN ≠ confirm | Snackbar "PINs do not match." |
| Call set_member_pin manually as non-admin (e.g., via Supabase REST while signed in as member-role user) | RPC raises "Only household admins can set member PINs." |
| Call verify_member_pin from a user in a different household | Returns false (caller-is-member check). |
| Delete a sub_profile with a PIN set, then verify member_pin_secrets row is gone | FK ON DELETE CASCADE should clean it up. |

## What's next

This branch is `fix/pin-hashing-pass-2-2026-05-22`, off `main@6306276`. Per the brief, **this is not yet merged**. The plan was: merge to main after kid permissions ships (the next workstream). In the meantime, the branch can be tested in isolation by checking it out.

When kid permissions lands and you're ready, the merge order will be:

```
main
 └─ fix/pin-hashing-pass-2-2026-05-22  ← this work
     └─ feat/kid-permissions-...        ← future workstream, branched off main, may need to rebase onto this fix
```

Pass 2 followups for a later batch:
- Rate limiting on `verify_member_pin` (followup 1 above).
- A standalone "Change PIN" UI in members management (followup 2 above).
- A combined `create_sub_profile_with_pin` RPC for atomicity (followup 3 above).
- The broader Pass 2 work: RLS lockdown, schema consistency audit (per `/audits/2026-05-baseline-merge-outcome.md`).
