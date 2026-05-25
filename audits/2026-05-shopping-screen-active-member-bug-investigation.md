# Shopping screen active-member bug — investigation

Date: 2026-05-25
Branch: `feat/kid-perms-wishlist-2026-05-25` (read-only investigation; no code changes)
Status: investigation complete — **bug confirmed**; **broader audit found 1 additional affected screen** (chore_detail); **recommend Option B (centralized helper) over Option A (per-screen fix)**.

## Summary

The bug is real and the diagnosis in your brief is correct.

- `_myMembership` (or equivalent state field) on shopping_list_screen, meal_planner_screen, and recipe_detail_screen is loaded via `.from('household_members').eq('auth_user_id', user.id)` — which always returns the **JWT holder's row** (the parent admin). It never consults `ActiveMemberService`, so it can't resolve to the kid.
- The kid sub_profile's `auth_user_id` is **NULL** (sub_profiles never hold a JWT — they're guarded by PIN under the parent's session, per Pass 2 architecture). So even iterating "who am I" by JWT can never resolve to a kid; the lookup must be done by the **active member id** the profile switcher stored.
- `chore_dashboard_screen` gets this right by overlaying the JWT-derived adult membership with the `ActiveMemberService.instance.activeMemberId.value` when set.

**Surprise finding**: `chore_detail_screen.dart:70-88` uses the **same broken pattern** as the shopping screens. That suggests Batch 4's chore flow might be partly broken too — specifically the kid path inside `chore_detail`'s `_quickUpdateStatus` would silently fall through to the adult path (`complete_chore_self`) when the kid taps Complete from the detail view, because `Permissions.isKid(_householdMember)` returns false. The dashboard's Mark Complete works because chore_dashboard loads `_myMembership` correctly via ActiveMemberService. **Worth confirming with a smoke-test on iPhone.**

A broader audit (Phase 5) finds **9 other screens** also using the broken pattern, but their use of the membership is read-only (display, gating) — not write-with-member_id — so they wouldn't manifest as a kid-attribution bug, just as a "kid sees admin-flavored gating" UX inconsistency.

Recommended fix: **Option B — centralized helper** (a `_loadActiveMembership(BuildContext)` utility or a `MembershipService` returning the correct overlaid row). ~60 LOC for the helper + ~5 LOC per affected screen. Touches 4 critical screens (shopping_list, meal_planner, recipe_detail, chore_detail) for the bug fix; the other 9 screens can migrate opportunistically.

## Phase 1 — Bug shape confirmed

Setup:
- Adult `Andrew` is signed in via Supabase auth (his `auth_user_id` = his JWT subject).
- His household has a kid sub_profile `Randi` with `kind='sub_profile'`, `auth_user_id IS NULL`, `is_active=true`.
- Andrew uses the profile switcher (in `home_shell_screen`) to "operate as Randi" — that calls `ActiveMemberService.instance.switchTo(randi_member_id)`, which persists `randi_member_id` to SharedPreferences and updates the `ValueNotifier<String?> activeMemberId`.

What screens see when they call `Supabase.instance.client.auth.currentUser`:
- Returns Andrew's `User` (his JWT). Switching to Randi **does not change the JWT** — Supabase auth has no concept of sub_profiles. The session is still Andrew's.

So `.eq('auth_user_id', user.id)` will ALWAYS return Andrew's row, never Randi's. To get Randi, the screen must query by Randi's `id` (which the switcher stored in SharedPreferences).

`Permissions.isKid(_myMembership)` then evaluates `_myMembership['kind'] == 'sub_profile'`. With Andrew's row loaded, `kind == 'adult_auth_user'`, so it returns false. The kid branch never fires, the item lands via direct INSERT with `added_by_member_id = andrew_member_id` and `is_wishlist = false`.

## Phase 2 — How profile switching works

### `ActiveMemberService` (apps/mobile/lib/services/active_member_service.dart)

Tiny singleton (~35 LOC). State:
```dart
final ValueNotifier<String?> activeMemberId = ValueNotifier<String?>(null);
```
Backed by SharedPreferences under key `'active_member_id'`. Three operations:
- `init()` — reads from SharedPreferences into the notifier (called at app startup).
- `switchTo(memberId)` — sets notifier + persists.
- `clear()` — resets to null + removes from SharedPreferences (used on logout).

The notifier is broadcast: any screen that registers a listener gets called when the active member changes. Today only `home_shell_screen` and `chore_dashboard_screen` register listeners.

### Switcher UI (home_shell_screen.dart)

Three call sites for `switchTo` (lines 117, 480, 556):
- **Line 117**: bootstrap — if there's no active member on init, switch to the adult.
- **Line 480** / **Line 556**: user taps a member in the profile switcher UI; after PIN verification (for kids), `switchTo(member['id'])` is called.

One `clear()` site (line 801) — logout path.

### The "active member" overlay pattern (home_shell_screen.dart:89-118)

```dart
final user = Supabase.instance.client.auth.currentUser!;
final memberships = await Supabase.instance.client
    .from('household_members')
    .select('*, households(*)')
    .eq('auth_user_id', user.id)
    .limit(1);

if (memberships.isNotEmpty) {
  final adultMembership = Map<String, dynamic>.from(memberships[0]);
  _household = adultMembership['households'];

  final members = await Supabase.instance.client
      .from('household_members')
      .select()
      .eq('household_id', _household!['id'])
      .eq('is_active', true)
      .order('created_at');
  _householdMembers = List<Map<String, dynamic>>.from(members);

  final requestedActiveId = ActiveMemberService.instance.activeMemberId.value;
  final activeMember = _householdMembers.firstWhere(
    (m) => m['id'] == requestedActiveId,
    orElse: () => adultMembership,
  );
  _myMembership = activeMember;
  if (requestedActiveId == null || activeMember['id'] != requestedActiveId) {
    await ActiveMemberService.instance.switchTo(adultMembership['id']);
  }
  ...
}
```

This is the canonical correct pattern: load the adult to get household context → load all members → overlay with the requested active member id from the service → fall back to adult if the stored id no longer resolves.

## Phase 3 — How chore_dashboard gets this right

`chore_dashboard_screen.dart:55-96`:

```dart
Future<void> _loadData() async {
  // ...
  final user = Supabase.instance.client.auth.currentUser!;
  final userId = user.id;

  // Get user's household membership (the adult row)
  final memberships = await Supabase.instance.client
      .from('household_members')
      .select('*, households(*)')
      .eq('auth_user_id', userId)
      .limit(1);

  if (memberships.isEmpty) { ... return; }

  final adultMembership = Map<String, dynamic>.from(memberships[0]);
  _household = adultMembership['households'];
  final householdId = _household!['id'];

  // OVERLAY: consult ActiveMemberService and load the active member's row
  final activeMemberId = ActiveMemberService.instance.activeMemberId.value;
  if (activeMemberId != null && activeMemberId != adultMembership['id']) {
    final activeRows = await Supabase.instance.client
        .from('household_members')
        .select()
        .eq('id', activeMemberId)
        .eq('household_id', householdId)
        .eq('is_active', true)
        .limit(1);
    _myMembership = activeRows.isNotEmpty ? activeRows[0] : adultMembership;
  } else {
    _myMembership = adultMembership;
  }
  // ...
}
```

Plus listener registration in `initState`:

```dart
ActiveMemberService.instance.activeMemberId.addListener(_onActiveMemberChanged);
```

and a corresponding `_onActiveMemberChanged() → _loadData()` so the screen reloads when the user switches profiles mid-session.

So `chore_dashboard` correctly resolves to Randi's row when she's active, and `Permissions.isKid(_myMembership)` returns true. The kid branch fires; submissions go via `submit_kid_chore_with_photo` with `randi_member_id`.

## Phase 4 — How shopping_list_screen does it wrong

`shopping_list_screen.dart:104-117`:

```dart
final user = Supabase.instance.client.auth.currentUser!;
final memberships = await Supabase.instance.client
    .from('household_members')
    .select('*, households(*)')
    .eq('auth_user_id', user.id)
    .limit(1);

if (memberships.isEmpty) {
  setState(() => _isLoading = false);
  return;
}

_myMembership = memberships[0];
_household = memberships[0]['households'];
```

No `ActiveMemberService` consultation. Always loads the adult row. The Phase 2 overlay step is missing entirely.

Same pattern at `meal_planner_screen.dart:56-69`:

```dart
final user = Supabase.instance.client.auth.currentUser!;
final memberships = await Supabase.instance.client
    .from('household_members')
    .select('*, households(*)')
    .eq('auth_user_id', user.id)
    .limit(1);
// ...
_myMembership = memberships[0];
_household = memberships[0]['households'];
```

Same pattern at `recipe_detail_screen.dart:70-85`:

```dart
final user = Supabase.instance.client.auth.currentUser!;
final memberships = await Supabase.instance.client
    .from('household_members')
    .select('*, households(*)')
    .eq('auth_user_id', user.id)
    .limit(1);
// ...
_householdMember = memberships[0];
final householdId = _householdMember!['household_id'];
```

Same pattern at `chore_detail_screen.dart:70-88` (surprise — Batch 4's detail screen also has the bug):

```dart
final user = Supabase.instance.client.auth.currentUser!;
final memberships = await Supabase.instance.client
    .from('household_members')
    .select('*, households(*)')
    .eq('auth_user_id', user.id)
    .limit(1);
// ...
_householdMember = memberships[0];
final householdId = _householdMember!['household_id'];
```

**Diff vs the correct pattern**: ~15 lines missing in each of these 4 screens — the overlay step that loads the active member's row when `activeMemberId != null`.

None of these 4 screens register an `ActiveMemberService.instance.activeMemberId` listener either, so even if the user switches profiles while a shopping screen is mounted, the screen doesn't reload — the kid path stays cold.

## Phase 5 — Broader audit

A grep for `.eq('auth_user_id', user.id)` across `apps/mobile/lib/screens/` returns **13 screens** using the broken pattern (excluding `home_shell_screen` which uses it as part of the correct overlay):

| Screen | Uses membership for | Severity |
|---|---|---|
| **shopping_list_screen.dart** | Permissions.isKid check + `added_by_member_id` writes | 🚨 **bug** |
| **meal_planner_screen.dart** | `added_by_member_id` writes + meal_plan creator | 🚨 **bug** |
| **recipe_detail_screen.dart** | Permissions.isKid check + `added_by_member_id` writes | 🚨 **bug** |
| **chore_detail_screen.dart** | Permissions.isKid check (kid Complete chip routing) | 🚨 **bug — Batch 4 chore_detail kid path is broken** |
| profile_screen.dart | Displays the JWT holder's profile (not active member) | OK by design (it's the adult's profile screen) |
| settings_screen.dart | Admin gates + display | low — display only; gating returns same adult |
| data_export_screen.dart | Admin gate | low — gating only |
| announcements_screen.dart | Admin gate + author tagging | medium — author would always be adult |
| calendar_screen.dart | `created_by_member_id` writes | medium — events would always show adult author |
| activity_feed_screen.dart | Display of "your activity" | medium — would show adult's, not kid's |
| household_stats_screen.dart | Stats by member | low |
| chore_templates_screen.dart | Admin gate | low |
| recipe_library_screen.dart | Display + admin gate | low |
| invite_management_screen.dart | Admin gate | low |
| member_profile_screen.dart | Specific member by id (not by JWT) | OK |
| members_screen.dart | List view | low |
| notification_preferences_screen.dart | Preferences for JWT holder | OK by design |
| search_screen.dart | Display | low |
| subscription_screen.dart | Admin gate | low |
| achievements_screen.dart | Member-scoped achievements | medium |

**4 confirmed bugs** (shopping_list, meal_planner, recipe_detail, chore_detail). The other 9 candidates are either correct-by-design (profile_screen, notification_preferences_screen) or wouldn't manifest as a kid-attribution data bug — at worst they'd show the adult's perspective when the kid is active. Some of those medium-severity ones (calendar, activity_feed, achievements) are worth fixing in a polish pass for UX correctness, but they aren't write-attribution bugs.

## Phase 5 — Three fix options

### Option A — Per-screen fix

Apply the overlay pattern to each of the 4 affected screens individually. ~15 LOC per screen + 4 LOC per screen for the `addListener`/`removeListener` registration in `initState`/`dispose`.

**Pros**: minimal new abstraction, no shared dependency. Stays close to the existing chore_dashboard pattern.
**Cons**: duplicated logic across 4 screens. Any future change to the overlay (e.g., to handle "active member was deleted while you were on this screen") must be applied 4+ times. The 9 medium-severity candidates would each need their own ~20 LOC if we ever address them.

**Scope**: ~80 LOC across 4 files (excluding 9 medium candidates).

### Option B — Centralized helper (recommended)

New utility — either a static method on a new `MembershipService` (apps/mobile/lib/services/membership_service.dart) or a top-level function in `apps/mobile/lib/utils/membership.dart`. Signature:

```dart
/// Loads the household membership row for the currently active member.
/// If ActiveMemberService has a stored active_member_id, returns that
/// member's row (typically a kid sub_profile). Otherwise returns the
/// JWT-holder's (adult's) row.
///
/// Returns null only if the JWT-holder isn't in any household (the
/// "no membership yet" empty state).
///
/// Also returns the resolved household record alongside the membership
/// so callers don't double-load.
class ActiveMembership {
  final Map<String, dynamic> membership;
  final Map<String, dynamic> household;
  final Map<String, dynamic> adultMembership; // always the JWT holder's row
  const ActiveMembership({...});
}

Future<ActiveMembership?> loadActiveMembership() async { ... }
```

Plus a `useActiveMemberListener(VoidCallback onChange)` helper to wrap the addListener/removeListener boilerplate.

Each affected screen replaces its custom load with:

```dart
@override
void initState() {
  super.initState();
  ActiveMemberService.instance.activeMemberId.addListener(_onActiveMemberChanged);
  _loadData();
}

@override
void dispose() {
  ActiveMemberService.instance.activeMemberId.removeListener(_onActiveMemberChanged);
  super.dispose();
}

void _onActiveMemberChanged() { if (mounted) _loadData(); }

Future<void> _loadData() async {
  final result = await loadActiveMembership();
  if (result == null) { /* not in household */ return; }
  _myMembership = result.membership;
  _household = result.household;
  // ...
}
```

**Pros**: single source of truth; correct-by-default for any new screen; eliminates the 4-way drift. Easier to extend later (e.g., add a "active member kind" cache, or auto-recover if the stored active_member_id was deleted).
**Cons**: new file/service to maintain. Slightly more initial work.

**Scope**:
- Helper file: ~60 LOC (the `ActiveMembership` class + `loadActiveMembership` function + tests, if any).
- Per-screen migration: ~5-10 LOC net change per screen (replace custom load).
- Total for the 4 bug-affected screens: ~60 + 4 × 8 = **~92 LOC**.
- Optional: opportunistically migrate the 9 medium-severity candidates in the same PR or a followup. ~9 × 5 = ~45 more LOC.

### Option C — Audit-and-fix-all-at-once

Same as Option A but applied to all 13 screens at once. ~250 LOC across 13 files. Heavy diff, hard to review.

**Not recommended.** Either commit to centralizing (Option B) or fix the 4 critical bugs (Option A) and treat the rest as polish.

### Recommendation

**Option B**, scoped tightly: ship the helper + migrate the 4 buggy screens. Defer the 9 medium-severity screens to a polish followup (Batch 5b or a dedicated audit pass — many of them have other Batch 7 "kind-based UI hardening" work that would touch them anyway).

Estimated implementation: **~92 LOC across 5 files** (1 new helper + 4 modified screens) + analyzer baseline before/after.

## Phase 6 — Additional findings worth flagging

### "Batch 4 chore flow works" claim needs caveat

The user's brief says "Batch 4 (chore flow) doesn't have this bug. The chore flow uses a different active-member pattern." That's true for the **dashboard's** Mark Complete button (chore_dashboard uses ActiveMemberService correctly). But:

- **chore_detail_screen's `_quickUpdateStatus` kid branch** depends on `Permissions.isKid(_householdMember)`. With the broken `_loadData` pattern, `_householdMember` is always the adult. So tapping **Complete** on a chore from the **detail screen** while operating as a kid would fall through to `complete_chore_self` (adult RPC) — which would then fail server-side because the adult isn't the chore's assignee, OR succeed and create an adult-attributed completion (depending on the chore's current assignee).
- Similarly, the **Re-do chip** rendered when `status == 'rejected' && Permissions.isKid(_householdMember) && _chore['assigned_to_member_id'] == _householdMember['id']` would NEVER render for the kid via chore_detail (only via chore_dashboard's `_ChoreCard`'s Re-do button).

Worth iPhone smoke-testing both paths before declaring Batch 4 complete: dashboard Mark Complete (works) vs detail-screen Complete (likely broken for kids).

### Realtime + offline edge cases

The `_loadData()` pattern in the broken screens runs once on init and on realtime updates (where wired). It does NOT register an `ActiveMemberService.instance.activeMemberId.addListener`, so if the user switches profiles while a shopping/meal/recipe screen is mounted, the screen keeps stale state until something else triggers a reload. Option B's helper should include the listener wiring as part of the migration.

### Why this bug shipped in 4a smoke-test if it was always broken

The Batch 4a investigation said "the user is admin in their household. The kid path will only fire in production for sub_profile sessions (Randi, in Wrights household)." That's where the assumption broke: the implementation correctly added the `Permissions.isKid` branching, but `_myMembership` resolution was already broken before Batch 5a touched it — Batch 5a inherited the bug. The chore work shipped successfully because it tested from chore_dashboard (which already had the correct pattern).

## Next steps (suggested)

1. **User confirms iPhone smoke-test of the chore_detail kid path** (Mark Complete + Re-do chip rendering when operating as Randi). If broken as expected, this becomes the fifth screen to fix.
2. **User picks Option A vs B**. Recommend B.
3. **I write the fix** (read-only constraint released):
   - Helper file (~60 LOC) at `apps/mobile/lib/utils/membership.dart` or `services/membership_service.dart`
   - 4 (or 5, including chore_detail) screen migrations replacing the custom load + adding the listener
   - Analyzer baseline before/after; 0 net new errors expected
4. **Commit + push** on `feat/kid-perms-wishlist-2026-05-25` (probably as a hotfix before the 5a Dart changes go to main, or as a follow-up commit on the same branch).
5. **iPhone smoke-test** all 4-5 affected paths while operating as Randi.

## Read-only constraint honored

No code, no migrations, no commits. Only this audit file written.
