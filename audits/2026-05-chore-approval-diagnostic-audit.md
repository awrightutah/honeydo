# Chore Approval Flow — Diagnostic Audit

Date: 2026-05-21
Branch: `fix/batch-4-shopping-display-and-kid-chores-2026-05-21` (read-only audit)
Reference: `audits/2026-05-batch-fix-4-outcome.md`, `audits/2026-05-pass-1a-flutter-v3.md`

## Summary

The "User is not a member of this household, code: P0001" error string lives in **exactly one place**: the original `award_points` (and `check_and_award_achievements`) RPCs in `supabase/migrations/0002_gamification_functions.sql` lines 25 and 157. The new RPCs introduced in `0011` raise a different string ("Member is not part of this household"). So the error the user is seeing is unambiguously coming from the **original adult RPC** — `award_points` or `check_and_award_achievements`.

The app code on this branch contains explicit kind-based branching that routes sub_profile chores to the new member_id RPCs. If the running binary on the iPhone reflects that branch, sub_profile chores should never hit the adult RPC.

**Most likely cause: the iPhone binary is not running the post-batch-4 code.** The commit `aba41f3` adds the kind branching; if Flutter hot-reload or hot-restart didn't pick it up cleanly (which happens with async closures sometimes), the device is still running the pre-batch-4 `_verifyChore` that always called the adult RPC.

The 4-verified-chores vs 2-point-transactions data pattern reinforces this: 2 chores succeeded (kid path, post-batch-4 code working) and 2 failed (adult path, pre-batch-4 code or stale binary). Mixed builds explain the half-and-half exactly.

## Phase 1 — `_verifyChore` code trace

Current state of `_verifyChore` in `apps/mobile/lib/screens/chore_dashboard_screen.dart` (lines 192-265):

```dart
  Future<void> _verifyChore(String choreId, bool approved) async {
    try {
      final chore = _pendingVerification.firstWhere((c) => c['id'] == choreId);
      final points = chore['point_value'] ?? 5;

      if (approved) {
        // Update chore status
        await Supabase.instance.client.from('chores').update({
          'status': 'verified',
          'verified_at': DateTime.now().toIso8601String(),
          'verified_by_member_id': _myMembership!['id'],
        }).eq('id', choreId);

        // Award points to the user who completed it.
        // Adults have a Supabase auth account (kind = 'adult_auth_user');
        // kids are sub_profiles with auth_user_id = NULL, so for kids we
        // call the member_id-based RPC variants (see 0011 migration).
        final assignedMemberId = chore['assigned_to_member_id'] as String;
        final assignedMember = await Supabase.instance.client
            .from('household_members')
            .select('id, kind, auth_user_id')
            .eq('id', assignedMemberId)
            .single();

        final totalPoints = points + (chore['bonus_points'] ?? 0);
        final isSubProfile = assignedMember['kind'] == 'sub_profile';

        if (isSubProfile) {
          await Supabase.instance.client.rpc('award_points_to_member', params: {
            'p_member_id': assignedMember['id'],
            'p_household_id': chore['household_id'],
            'p_points': totalPoints,
            'p_note': 'chore_completion',
            'p_source_table': 'chores',
            'p_source_id': choreId,
          });
          await Supabase.instance.client.rpc('check_and_award_achievements_for_member', params: {
            'p_member_id': assignedMember['id'],
            'p_household_id': chore['household_id'],
          });
        } else {
          await Supabase.instance.client.rpc('award_points', params: {
            'p_auth_user_id': assignedMember['auth_user_id'],
            'p_household_id': chore['household_id'],
            'p_points': totalPoints,
            'p_note': 'chore_completion',
            'p_source_table': 'chores',
            'p_source_id': choreId,
          });
          await Supabase.instance.client.rpc('check_and_award_achievements', params: {
            'p_auth_user_id': assignedMember['auth_user_id'],
            'p_household_id': chore['household_id'],
          });
        }

        // Create the next occurrence for recurring chores after approval.
        await _createNextRecurringChoreIfNeeded(chore);
      } else {
        // Reject - put chore back to assigned
        await Supabase.instance.client.from('chores').update({
          'status': 'assigned',
          'completed_at': null,
        }).eq('id', choreId);
      }

      _loadData();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update chore status: $e')),
        );
      }
    }
  }
```

Line-by-line read with what could go wrong:

| Line | Reads / Writes | Source | Failure modes |
|---|---|---|---|
| 194 | `chore` from `_pendingVerification` | in-memory list loaded at line 107-112 | If choreId no longer matches, `firstWhere` throws — different error |
| 195 | `chore['point_value']` | DB integer; fallback 5 | numeric, fine |
| 199-203 | UPDATE `chores` status='verified' | enum value 'verified' exists; RLS allows household member | Should succeed |
| 209 | `chore['assigned_to_member_id'] as String` | UUID string from DB | If null → cast throws "type 'Null' is not a subtype of type 'String'" (NOT our error) |
| 210-214 | SELECT `id, kind, auth_user_id` from `household_members` by id | RLS allows admin to read all member rows in household | If member missing → `.single()` throws (NOT our error) |
| 217 | `assignedMember['kind'] == 'sub_profile'` | dynamic comparison against string literal | If kind is not exactly 'sub_profile', `isSubProfile = false` → adult branch |
| 219-231 | If sub_profile, calls new RPCs | requires 0011 applied | If 0011 NOT applied → 404 "function does not exist" (NOT our error) |
| 232-244 | Else, calls adult RPCs with `auth_user_id` | adult RPC raises "User is not a member of this household" exactly when `auth_user_id IS NULL` is passed | **THIS is the only source of the user's error string** |
| 258-264 | catch shows snack bar with `$e` interpolated | catches any thrown exception | Now surfaces the actual Postgres message |

Conclusion: the user's error implies execution reached lines 232-244. Two ways that happens for a Randi-assigned chore:

(a) `assignedMember['kind']` ≠ `'sub_profile'` — Randi's row in the DB actually has a different kind, OR the chore is assigned to someone other than Randi.

(b) The running binary doesn't have the branching code — the user is running pre-batch-4 `_verifyChore` that unconditionally called `award_points` with auth_user_id (null for kids).

## Phase 2 — all chore status update sites

```
grep -rn "from('chores')\.update\|from('chores')\.insert" apps/mobile/lib/ --include="*.dart"
```

Six sites total:

| File | Line | Operation | Status value written | Calls a points RPC? |
|---|---|---|---|---|
| `chore_dashboard_screen.dart` | 132 | UPDATE | `'pending_verification'` (line 133) — user marks chore done | No |
| `chore_dashboard_screen.dart` | 189 | INSERT (recurring next occurrence) | inherited from previous chore; `'status'` field overridden to `'assigned'` at line 187 | No |
| `chore_dashboard_screen.dart` | 199 | UPDATE — `_verifyChore` approve branch | `'verified'` (line 200) | **Yes** — branched, lines 220/228/233/241 |
| `chore_dashboard_screen.dart` | 251 | UPDATE — `_verifyChore` reject branch | `'assigned'` (line 252) | No |
| `chore_dashboard_screen.dart` | 718 | INSERT — add chore sheet | `'assigned'` (line 726) | No |
| `chore_detail_screen.dart` | 194 | UPDATE — `_saveChore` (edit form Save) | dropdown value `_selectedStatus` (line 178) | No |
| `chore_detail_screen.dart` | 878 | UPDATE — `_quickUpdateStatus` action chip | parameter `newStatus` (line 874) | **No — silently skips points** |
| `chore_detail_screen.dart` | 946 | INSERT — `_createNextRecurringChoreIfNeeded` | `'assigned'` (line 943) | No |
| `chore_templates_screen.dart` | 130 | INSERT | `'assigned'` (line 138) | No |

All status literals are valid `chore_status` enum values: `'assigned'`, `'pending_verification'`, `'verified'`. No invalid `'completed'` literal anywhere. The reject branch at line 252 writes `'assigned'` (the brief flagged this as a non-bug; just sending back to assigned queue).

**Bug noticed but in scope of follow-ups:** `chore_detail_screen.dart:878` (`_quickUpdateStatus('verified')` when admin taps the "Verify" action chip) updates status to `'verified'` but **does not call any points RPC**. So if the admin uses the chore detail screen's Verify chip instead of the dashboard's Approve button, no points are awarded. Not the source of the current error (no error fires; points are silently skipped) but worth noting.

## Phase 3 — all RPC call sites for points/achievements

```
grep -rn "rpc('award_points'\|rpc(\"award_points\"\|rpc('check_and_award_achievements'\|rpc(\"check_and_award_achievements\"\|rpc('award_points_to_member'\|rpc(\"award_points_to_member\"\|rpc('check_and_award_achievements_for_member'\|rpc(\"check_and_award_achievements_for_member\"" apps/mobile/lib/ --include="*.dart"
```

Exactly four sites, all in `chore_dashboard_screen.dart`:

```
220:  await Supabase.instance.client.rpc('award_points_to_member', params: { ... 'p_member_id': assignedMember['id'], ... });
228:  await Supabase.instance.client.rpc('check_and_award_achievements_for_member', params: { ... 'p_member_id': assignedMember['id'], ... });
233:  await Supabase.instance.client.rpc('award_points', params: { ... 'p_auth_user_id': assignedMember['auth_user_id'], ... });
241:  await Supabase.instance.client.rpc('check_and_award_achievements', params: { ... 'p_auth_user_id': assignedMember['auth_user_id'], ... });
```

All four are nested inside the `if (isSubProfile) { ... } else { ... }` block. Both branches read from the same `assignedMember` row queried 6 lines above. No stray legacy call; no path that bypasses the branch.

If `isSubProfile == true` only lines 220/228 fire; if false, only 233/241. There is no third path that could fire an adult RPC for a sub_profile chore in the current code.

`'p_auth_user_id'` is sourced from `assignedMember['auth_user_id']`, which for a sub_profile is `null`. Passing `null` to `award_points` makes the WHERE clause at `0002_gamification_functions.sql:22` evaluate `auth_user_id = NULL` (always false in SQL), so no row matches, so line 24-25 raises the exact error string the user sees.

## Phase 4 — `chore_detail_screen.dart` and other approve affordances

**`chore_detail_screen.dart`** has approve-flavored affordances at:

- Line 178 — `_selectedStatus` dropdown writes whatever the user picks. If user picks "Verified" (display label) → writes `'verified'`. No points RPC follows.
- Line 514 (action chip) — `_buildActionChip('Verify', ..., () => _quickUpdateStatus('verified'))` → calls `_quickUpdateStatus`. That function (lines 871-893) writes the status and triggers next-recurrence-creation but **does not call any points RPC**.

So the chore detail screen's "Verify" path silently skips points. It does NOT throw "User is not a member of this household" because it never calls the adult RPC.

**Other screens.** `home_shell_screen.dart` has `_verifyAndSwitchToKid` — but that verifies a PIN for profile switching, not a chore. Unrelated. No other screen has chore approve/verify affordances.

The only path that calls a points RPC for chore approval is the **dashboard's Approve button** → `_verifyChore`. Confirmed.

## Phase 5 — database triggers on chores

```
grep -rn "trigger\|create.*function.*chore\|on chores" supabase/migrations/
```

Only one trigger touches `chores`:

```sql
-- supabase/migrations/0001_initial_schema.sql:443
create trigger set_chores_updated_at before update on public.chores
  for each row execute function public.set_updated_at();
```

Body of `set_updated_at` (lines 433-438):
```sql
create or replace function public.set_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;
```

This trigger only updates `updated_at`. **It does not call `award_points`** or any other side-effect function. No database-side path exists that auto-fires the adult RPC.

## Phase 6 — RLS policies on chores

```
grep -rn "policy.*chores\|on chores for" supabase/migrations/
```

Exactly one RLS policy on `chores`:

```sql
-- supabase/migrations/0001_initial_schema.sql:521
create policy household_scoped_chores on public.chores
  for all using (public.is_household_member(household_id));
```

`is_household_member` (lines 456-465) checks `auth_user_id = auth.uid() AND is_active = true`. The admin (auth user) is a household member, so this policy passes for any chore in their household. **No policy gates sub_profile chore status transitions**, and no policy could plausibly raise the user's error string.

## Diagnosis — best guess at which path is firing the error

**Ordered by likelihood:**

### 1. Stale iPhone binary (highest likelihood)

Evidence:
- The error string lives in exactly one place — `award_points` and `check_and_award_achievements` in `0002`.
- Current `_verifyChore` correctly branches and never calls those RPCs for sub_profiles.
- The 4-verified / 2-transactions split matches "some attempts ran old code, some ran new code."
- Flutter hot-reload sometimes preserves widget state but fails to recompile changes inside async function bodies that have been entered while the reload happens. The user may have hot-reloaded mid-debug.
- The user verified migrations exist; they have not similarly verified the device build matches commit `aba41f3`.

**Why this fits the data**: if the device shipped the pre-batch-4 code (which always called `award_points` with auth_user_id, ignoring kind), then approving any sub_profile chore would: (a) succeed at the status UPDATE because that's a separate statement, then (b) throw "User is not a member of this household" from the RPC. The UI catches the error and shows the toast. The chore is marked verified but no points are awarded. Repeat 4 times = 4 verified chores, 0 point_transactions for those.

Where do the 2 successful point_transactions come from then? Probably:
- 2 chores were approved AFTER batch 4 was correctly loaded on the device — kid branch ran, points awarded.
- The other 2 were approved BEFORE the new RPCs existed, or after a binary that lost the change.

Alternative consistent story: 2 chores approved when assignee was the adult (Wrights Home, auth_user_id valid → adult RPC succeeded for them), 2 with assignee Randi failed. That requires verifying which member each chore is assigned to.

### 2. `assignedMember['kind']` is not exactly `'sub_profile'`

Evidence:
- If the chore's `assigned_to_member_id` somehow points to a member whose `kind` is `'adult_auth_user'` but whose `auth_user_id` is null (or wrong), the adult branch fires and we get the exact error string.
- The user's data evidence does not actually verify which member each of the 4 chores is assigned to. They named Randi as the completer in a sentence, but the `assigned_to_member_id` could be different (the adult).

If the iPhone IS running the new branching code, and `kind` for the assigned member is `'adult_auth_user'` with `auth_user_id = null`, you'd see this error. PostgREST enum returns are strings, so the comparison `assignedMember['kind'] == 'sub_profile'` is reliable when the column value really is `'sub_profile'`.

### 3. Migration 0011 not actually applied (lowest likelihood, user said it's applied)

If 0011 didn't apply, calling `award_points_to_member` would return a PostgREST 404 / "function does not exist" error, NOT "User is not a member of this household." So this can be ruled out by the error string alone — but worth confirming with a direct query.

### Other paths ruled out

- No database trigger calls award_points (Phase 5).
- No RLS policy raises this error (Phase 6).
- chore_detail's Verify chip doesn't call any points RPC (Phase 4).
- Search/recipe/etc. screens don't touch chore status (Phase 2).

## Recommended fix — what code or schema change resolves the bug

**No code change first.** Confirm which scenario is firing before patching. In priority order:

### Step 1 — verify the iPhone is running batch 4 code (the likely cause)

Run a clean rebuild:
```
cd apps/mobile
flutter clean
flutter pub get
flutter run
```

Then approve another sub_profile chore. If it succeeds, the bug was a stale binary.

If you want a quick on-device check before rebuilding, add a temporary log just to the branch to confirm which path fires. **Diff to apply for diagnosis only** (revert before committing):

```diff
         final totalPoints = points + (chore['bonus_points'] ?? 0);
         final isSubProfile = assignedMember['kind'] == 'sub_profile';

+        debugPrint('VERIFY_CHORE: member=${assignedMember['id']} kind=${assignedMember['kind']} auth_user_id=${assignedMember['auth_user_id']} isSubProfile=$isSubProfile');
+
         if (isSubProfile) {
```

If after a fresh `flutter run` you see `isSubProfile=true` but the error still fires, then it's coming from the kid RPC (different error string would appear) or some other source. If you see `isSubProfile=false` for a chore assigned to Randi, then the chore's `assigned_to_member_id` is wrong (Step 2).

### Step 2 — if the binary is fresh and the error still fires, verify the database state

Run these one-shot SQL queries in Supabase Studio:

```sql
-- 2a. List all rows in household_members for Randi's household.
-- Look for: which row is Randi? what is her kind? what is her auth_user_id?
select id, display_name, kind, auth_user_id, is_active, points_balance
from household_members
where household_id = (select id from households where name = 'Wrights' limit 1)
order by created_at;

-- 2b. For each of the 4 verified chores assigned to Randi, confirm assigned_to_member_id.
-- If any chore is assigned to someone other than Randi, that's the row that fails.
select c.id, c.title, c.status, c.completed_at, c.assigned_to_member_id,
       hm.display_name as assigned_to_name,
       hm.kind as assigned_to_kind,
       hm.auth_user_id as assigned_to_auth_user_id
from chores c
join household_members hm on hm.id = c.assigned_to_member_id
where c.household_id = (select id from households where name = 'Wrights' limit 1)
  and c.status = 'verified'
order by c.completed_at desc;

-- 2c. Confirm both new RPCs exist with the right signature.
select n.nspname as schema, p.proname as function_name, pg_get_function_arguments(p.oid) as args
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where p.proname in ('award_points', 'award_points_to_member',
                    'check_and_award_achievements', 'check_and_award_achievements_for_member')
order by p.proname;
```

If 2a shows Randi with `kind = 'sub_profile'` and `auth_user_id IS NULL` — that matches the user's claim.
If 2b shows any verified chore where `assigned_to_kind != 'sub_profile'` but `assigned_to_auth_user_id IS NULL`, that chore would have triggered the adult RPC path with a null auth_user_id and produced the exact error. **That would mean an "adult" member row exists with no auth_user_id, which is a data-integrity issue not yet caught.**
If 2c lists all four functions, the RPCs are in place.

### Step 3 — if the chore is assigned to a wrong member, hardening fix

If Step 2b reveals that 2 of the 4 chores are assigned to a member whose `kind = 'adult_auth_user'` but `auth_user_id IS NULL`, the immediate question is "how did such a row get created?" The schema constraint `household_members_auth_required_for_adult` at `0001_initial_schema.sql:56-58` is:

```sql
constraint household_members_auth_required_for_adult check (
  (kind = 'adult_auth_user' and auth_user_id is not null) or (kind = 'sub_profile')
)
```

That check should prevent any adult row from having NULL auth_user_id at the schema level. If Step 2a finds such a row, the constraint may have been bypassed (e.g., during data migration) — investigate the offending row directly.

Defensive code fix in `_verifyChore` (don't apply yet — only if Step 2 confirms this is the problem):

```diff
         final isSubProfile = assignedMember['kind'] == 'sub_profile';
+        final missingAuthUser = assignedMember['auth_user_id'] == null;

         if (isSubProfile) {
           // ... kid branch ...
+        } else if (missingAuthUser) {
+          // Fallback: adult member with no auth_user_id (data integrity issue).
+          // Use the member_id RPC to avoid the null-auth_user_id failure.
+          await Supabase.instance.client.rpc('award_points_to_member', params: {
+            'p_member_id': assignedMember['id'],
+            // ... same as kid branch
+          });
+          // and check_and_award_achievements_for_member
         } else {
           // ... adult branch ...
         }
```

This is a fallback, not a fix. The real fix is repairing the data row.

### Step 4 — long-term, route ALL chore-completion through member_id

Once the data is verified clean, consider deprecating the `auth_user_id`-based RPCs entirely and having `_verifyChore` always use `award_points_to_member` (with the assignee's `member_id` regardless of kind). The adult member_id is valid in both worlds; the auth_user_id path is the source of every issue we've seen. This is the architectural cleanup deferred in the batch 4 brief, and it would eliminate the entire class of "kid vs adult" RPC bugs. Out of scope for the current debug pass.

### Followups identified (non-blocking)

1. `chore_detail_screen.dart:514` action chip `Verify` calls `_quickUpdateStatus('verified')` which writes the status but skips points. If the user verifies via this path, no points are ever awarded. Should also call `award_points_to_member` / `award_points` matched on kind. Mirroring `_verifyChore`'s branching logic in this affordance is the right fix. Not in scope here.
2. `chore_dashboard_screen.dart:147-190` `_createNextRecurringChoreIfNeeded` copies the previous chore's data forward — which means the duplicated chore's `assigned_to_member_id` matches the original. That's correct, but worth confirming it carries the right `kind` semantics for the next loop iteration.
3. The `set_chores_updated_at` trigger fires on every chore UPDATE including the `_verifyChore`'s status='verified' write. Benign — just updates updated_at.

## Branch & files

- Branch: `fix/batch-4-shopping-display-and-kid-chores-2026-05-21` (unchanged; read-only audit)
- New file: `audits/2026-05-chore-approval-diagnostic-audit.md` (this report)
- No code, schema, or migration changes made.
