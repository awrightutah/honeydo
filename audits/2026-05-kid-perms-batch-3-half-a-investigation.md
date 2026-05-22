# Kid Permissions Batch 3 Half A — Investigation

Date: 2026-05-22
Branch: `feat/kid-perms-rls-rpcs-batch-2-2026-05-22` (read-only; no edits, no commits)
Scope: Half A of Batch 3 — new `permissions.dart` helper + refactor existing role gates + `'admin'` → `'owner'` flip in `household_setup_screen.dart`
Status: investigation complete; **2 open questions** for user before implementation

## Summary

Half A is a low-risk mechanical refactor. The existing codebase already has 11 functional role gates across 9 screens — all of them inline `_myMembership?['role'] == 'admin'` (or the slightly-broader `('owner','admin')`) style. Centralizing them behind `permissions.dart` is a clear win:

- **Consistency**: 6 sites currently check only `'admin'`; 4 check `('owner','admin')`. After this refactor, all gates uniformly accept either, matching the spec's resolved Q9/Q10.
- **Defense in depth**: every action helper internally rejects `kind == 'sub_profile'` first, so even a misconfigured kid row with `role='admin'` (shouldn't happen, but the schema doesn't prevent it) can't pass any permission check.
- **Future-proof**: when "edit household" semantics change in some future pass, we change one line in `permissions.dart` rather than grepping the app.

The one **non-refactor** change is at `household_setup_screen.dart:96`: today the household creator is inserted with `role: 'admin'`; per Q9 decision, going forward creators get `role: 'owner'`. One-line flip. Migration 0016 already backfilled existing rows.

**5 sites that READ role for display labels** (e.g., the "👑 Owner / ⭐ Admin / Member" badge) are **NOT touched** — they're conditional rendering on the actual role value, not authorization checks. Refactoring them would lose information.

Two open questions to settle before implementation:
- File location: `lib/utils/permissions.dart` (per spec) vs `lib/shared/utils/permissions.dart` (matches existing `invite_code.dart`)
- Helper style: static methods on a class, top-level functions, or extension on Map

## Phase 1 — Permissions helper class proposal

Per Q3 (deny by default): every helper returns `false` if membership is `null` or missing required fields. Per Q10 (augment): every action helper combines `kind != 'sub_profile'` (defense in depth) with `role in ('owner','admin')`.

Proposed `apps/mobile/lib/utils/permissions.dart`:

```dart
/// Permission helpers for household member-level authorization.
///
/// Every action helper takes a `Map<String, dynamic>?` membership row
/// (matching the codebase's universal pattern — there's no Membership
/// type) and returns a bool. Null or missing-field membership returns
/// false (deny by default).
///
/// Action helpers internally combine:
///   - kind != 'sub_profile' (defense in depth — kids never pass even
///     if their row had an unexpected role)
///   - role in ('owner', 'admin')
///
/// All action helpers are equivalent today (they all return isAdmin).
/// The named helpers exist to document intent at call sites and to
/// future-proof against per-action permission changes — e.g., if
/// "edit household" later requires owner-only, we change one line here
/// instead of grepping the app.
///
/// Counterpart RLS / RPC enforcement lives in migrations 0017 and 0018.
class Permissions {
  Permissions._();

  // --- Identity checks ---

  /// True if the member exists and is a sub_profile (kid).
  static bool isKid(Map<String, dynamic>? m) {
    if (m == null) return false;
    return m['kind'] == 'sub_profile';
  }

  /// True if the member exists, is NOT a kid, and has role 'owner' or 'admin'.
  /// This is the single underlying check that every can* helper delegates to.
  static bool isAdmin(Map<String, dynamic>? m) {
    if (m == null) return false;
    if (m['kind'] == 'sub_profile') return false;
    final role = m['role'];
    return role == 'owner' || role == 'admin';
  }

  /// True if the member exists, is NOT a kid, and has role 'owner' specifically.
  /// Owners and admins are equivalent for permission purposes today
  /// (see isAdmin); isOwner is for display use (badge, "the household creator")
  /// rather than authorization gates.
  static bool isOwner(Map<String, dynamic>? m) {
    if (m == null) return false;
    if (m['kind'] == 'sub_profile') return false;
    return m['role'] == 'owner';
  }

  // --- Action helpers ---
  //
  // All equivalent to isAdmin(m) today. Keep them named so call sites
  // document what they're gating, and so we can tighten one without
  // touching the others.

  /// Can edit household-level settings (name, theme, emoji, subscription).
  /// Disallowed Action #1 from spec.
  static bool canEditHousehold(Map<String, dynamic>? m) => isAdmin(m);

  /// Can approve/reject chores in pending_verification state.
  /// Disallowed Action #2.
  static bool canVerifyChores(Map<String, dynamic>? m) => isAdmin(m);

  /// Can edit any chore in the household (not just chores assigned to self).
  /// Today this is the admin-only chore-edit gate at chore_detail_screen:345.
  static bool canEditAnyChore(Map<String, dynamic>? m) => isAdmin(m);

  /// Can add or remove household members, edit other members' profiles,
  /// set or change a kid's PIN. Disallowed Action #3.
  static bool canManageMembers(Map<String, dynamic>? m) => isAdmin(m);

  /// Can generate / revoke household invites. Disallowed Action #9.
  static bool canInviteMembers(Map<String, dynamic>? m) => isAdmin(m);

  /// Can create, edit, or delete reward definitions; also approve or
  /// deny pending redemptions. Disallowed Action #4.
  static bool canManageRewards(Map<String, dynamic>? m) => isAdmin(m);

  /// Can decide pending meal requests and (later) pending wishlist
  /// items. Disallowed Action #5 (subset: kids can't approve their
  /// own requests; the RPC also enforces this).
  static bool canDecideRequests(Map<String, dynamic>? m) => isAdmin(m);

  /// Can edit the household's necessity_categories list (the bypass
  /// list for kid wishlist routing). Disallowed Action #6 (the
  /// category-management part).
  static bool canManageNecessityCategories(Map<String, dynamic>? m) => isAdmin(m);

  /// Can view billing / subscription / authorize.net details.
  /// Disallowed Action #7.
  static bool canManageBilling(Map<String, dynamic>? m) => isAdmin(m);

  /// Can create / edit / delete announcements. Pre-existing gate
  /// (announcements_screen) — not in the spec's Disallowed list but
  /// follows the same admin-only pattern.
  static bool canManageAnnouncements(Map<String, dynamic>? m) => isAdmin(m);
}
```

**Notes on shape:**

- Static methods on a class (vs top-level functions or extensions). Reason: discoverability via `Permissions.` autocomplete; doesn't pollute the global namespace; greppable as `Permissions.canX`. Extensions on `Map<String, dynamic>?` would be cleaner syntactically (`membership.canEditHousehold`) but harder to grep, and a Map-typed receiver is a fuzzy match — many maps in the app aren't memberships.
- Private constructor (`Permissions._()`) so it can't be instantiated.
- Lives at `apps/mobile/lib/utils/permissions.dart` per spec. See Open Q1 below — there's an existing `apps/mobile/lib/shared/utils/invite_code.dart` so the location is debatable.

## Phase 2 — Existing role gate audit

**Universal type:** every screen declares the membership row as `Map<String, dynamic>? _myMembership` or `Map<String, dynamic>? _householdMember`. Confirmed at 15 declaration sites (every screen that loads member data). No `Membership` class exists. The helper signatures match this pattern.

### Functional gates (refactor — these become helper calls)

11 functional gates across 9 screens. Grouping by purpose:

| File:line | Current check | Owner+admin? | What it gates | Proposed helper |
|---|---|---|---|---|
| `announcements_screen.dart:42` | `_isAdmin = role == 'owner' \|\| role == 'admin'` | ✓ | FAB + edit/delete affordances at lines 205, 226, 316 | `Permissions.canManageAnnouncements(_myMembership)` |
| `chore_detail_screen.dart:345` | `isAdmin = role == 'admin'` | ✗ admin only | `canEdit = isAdmin \|\| isAssignedToMe` (consumed line 347) — admin-or-assignee chore edit | `Permissions.canEditAnyChore(_householdMember) \|\| isAssignedToMe` |
| `chore_detail_screen.dart:380` | `isAdmin = role == 'admin'` | ✗ admin only | Verify-affordance gate at line 515 (`status == 'pending_verification' && isAdmin`) | `Permissions.canVerifyChores(_householdMember)` (consumed by line 515 verify button) |
| `chore_dashboard_screen.dart:106` | `if (_myMembership!['role'] == 'admin')` | ✗ admin only | Loads `_pendingVerification` list only for admins | `if (Permissions.canVerifyChores(_myMembership))` |
| `chore_dashboard_screen.dart:281` | `isAdmin = role == 'admin'` | ✗ admin only | Feeds lines 331+347 — gates "Pending Verification" UI section | `Permissions.canVerifyChores(_myMembership)` |
| `settings_screen.dart:441` | `isAdmin = role == 'admin'` | ✗ admin only | "Edit household" trailing icon + onTap (lines 489-490); also feeds display label at 468 | `Permissions.canEditHousehold(_myMembership)` |
| `rewards_screen.dart:833` | `isPending && role == 'admin'` | ✗ admin only | "Approve" button on pending redemption | `isPending && Permissions.canManageRewards(_myMembership)` |
| `members_screen.dart:127` | `isAdmin = role == 'admin'` | ✗ admin only | "Invite Others" section + Add Kid Profile FAB (line 190) | `Permissions.canManageMembers(_myMembership)` |
| `invite_management_screen.dart:62` | `_isAdmin = role == 'admin' \|\| role == 'owner'` | ✓ | Invite FAB at line 383 | `Permissions.canInviteMembers(_myMembership)` |
| `home_shell_screen.dart:565` | `isAdmin = role == 'owner' \|\| role == 'admin'` | ✓ | Set-PIN dialog gate for kids without PIN (`_promptToSetMissingPin`) — Pass 2 work | `Permissions.canManageMembers(_myMembership)` |
| `household_setup_screen.dart:96` | INSERT `'role': 'admin'` | — | Sets the household creator's role at signup | NOT a gate — change to `'owner'` per Q9 (see Phase 3) |

**Inconsistency confirmed:** 6 sites check only `'admin'`; 4 (highlighted ✓) check `('owner','admin')`. Today the database has no `'owner'` rows yet — the owner-role backfill in migration 0016 changed that for the Wrights household, and the `household_setup_screen.dart:96` flip will produce them for new households. So after Half A lands, the 6 admin-only sites would silently fail to grant permission to a household owner. **Standardizing all gates via `isAdmin(m)` (which accepts both) fixes this latent bug.**

### Display-only sites (DO NOT refactor)

5 sites read `role` directly for visual rendering. These are NOT gates — they show different labels/styling for different role values, which the helper would lose:

| File:line | Use | Why keep direct read |
|---|---|---|
| `profile_screen.dart:418-420` | `case 'owner':` / `case 'admin':` switch for display name | Switch differentiates owner vs admin labels |
| `member_profile_screen.dart:221` | "👑 Owner" / "⭐ Admin" / "Member" badge | Three-way label, helper would collapse |
| `members_screen.dart:350` | Color: `role == 'admin' ? coral : grey` | Conditional styling |
| `members_screen.dart:354` | "Kid" / "Admin" / "Member" label text | Three-way label |
| `members_screen.dart:358` | Text color matching :350 | Same conditional |

A separate cleanup pass later could centralize "role to display label/color" into a `RoleDisplay` helper or similar, but it's out of scope for Half A.

### One semi-display, semi-gate site

`settings_screen.dart:468` reads the local `isAdmin` (computed at line 441) to render the "Adult · Admin/Member" label. After the helper refactor, line 441's local goes away. Two options:

1. Keep a local `final isAdmin = Permissions.isAdmin(_myMembership);` at the top of the build method and use it both at 468 (display) and 489-490 (gate). Reads cleanly.
2. Inline `Permissions.canEditHousehold(_myMembership)` at 489-490 and use `Permissions.isAdmin(_myMembership)` separately at 468.

Recommend option 1 — clearer and less repetition.

## Phase 3 — household_setup change

Single line change at `apps/mobile/lib/screens/household_setup_screen.dart:96`. Current code (lines 92-101 for context):

```dart
final householdId = household['id'];

// Add current user as admin member (adult_auth_user kind)
await Supabase.instance.client.from('household_members').insert({
  'household_id': householdId,
  'auth_user_id': user.id,
  'role': 'admin',                              // ← LINE 96
  'kind': 'adult_auth_user',
  'display_name': user.userMetadata?['display_name'] ?? user.email?.split('@').first ?? 'Admin',
  'points_balance': 0,
  'is_active': true,
  'created_by': user.id,
});
```

Proposed change: `'role': 'admin'` → `'role': 'owner'`. Also update the preceding comment line 95 from `// Add current user as admin member` → `// Add current user as owner of the new household`.

No other code in `household_setup_screen.dart` needs touching. The 4 other places it touches household_members (lines 185, 197) are unrelated (invite-redemption flow, not creator insert).

## Phase 4 — Files touched

**Total: 1 new file + 9 modified files = 10 files**

| File | Type | Sites | Changes |
|---|---|---|---|
| `apps/mobile/lib/utils/permissions.dart` | **NEW** | — | New Permissions class (~80 LOC + comments) |
| `apps/mobile/lib/screens/household_setup_screen.dart` | Modified | 1 | Line 96: `'admin'` → `'owner'` + comment update at 95 |
| `apps/mobile/lib/screens/announcements_screen.dart` | Modified | 1 | Line 42: assignment to `_isAdmin` becomes `Permissions.canManageAnnouncements(_myMembership)`. Lines 205, 226, 316 unchanged (still read `_isAdmin` local). |
| `apps/mobile/lib/screens/chore_detail_screen.dart` | Modified | 2 | Lines 345 and 380: local `isAdmin` computations → `Permissions.canEditAnyChore(_householdMember)` and `Permissions.canVerifyChores(_householdMember)` respectively |
| `apps/mobile/lib/screens/chore_dashboard_screen.dart` | Modified | 2 | Line 106 (load gate) → `Permissions.canVerifyChores(_myMembership)`. Line 281 (build gate) → same. |
| `apps/mobile/lib/screens/settings_screen.dart` | Modified | 1 | Line 441: local `isAdmin` → `Permissions.canEditHousehold(_myMembership)` (consumed at 468, 489-490; recommend keeping the local var for readability — see Phase 2 semi-display note) |
| `apps/mobile/lib/screens/rewards_screen.dart` | Modified | 1 | Line 833: inline check → `Permissions.canManageRewards(_myMembership)` |
| `apps/mobile/lib/screens/members_screen.dart` | Modified | 1 | Line 127: local `isAdmin` → `Permissions.canManageMembers(_myMembership)`. (Lines 350, 354, 358 are display-only — leave alone.) |
| `apps/mobile/lib/screens/invite_management_screen.dart` | Modified | 1 | Line 62: `_isAdmin` getter → `Permissions.canInviteMembers(_myMembership)` |
| `apps/mobile/lib/screens/home_shell_screen.dart` | Modified | 1 | Lines 565-567: local `isAdmin` → `Permissions.canManageMembers(_myMembership)` |

Total functional gate refactors: **11 across 9 screens**. Plus the 1 non-refactor change in household_setup. New file = 1.

Each modified screen needs `import '../utils/permissions.dart';` added at the top.

## Phase 5 — Open questions

### Q1. File location: `lib/utils/permissions.dart` (per spec) or `lib/shared/utils/permissions.dart` (codebase convention)?

Spec resolution Q10 says `apps/mobile/lib/utils/permissions.dart`. Codebase has one existing helper at `apps/mobile/lib/shared/utils/invite_code.dart` (a single top-level function). Two utils dirs would be confusing; pick one.

- **Follow spec** (`lib/utils/`): consistent with the spec wording; suggests `utils/` is the canonical "app-level utilities" directory and `shared/utils/` is for utilities shared with other apps (web, future).
- **Follow codebase** (`lib/shared/utils/`): only existing precedent; would just collocate the helpers. Doesn't conflict with anything.

Recommend **follow spec**. If `shared/utils/invite_code.dart` is really shared with another app, leave it; otherwise this is a good moment to move it to `lib/utils/` too (separate cleanup, not in Half A scope).

### Q2. Helper style: static methods on `Permissions` class, top-level functions, or extension on `Map<String, dynamic>?`?

Three options:

- **Static methods (proposed in Phase 1):** `Permissions.canEditHousehold(membership)`. Discoverable via autocomplete; clear namespace; greppable.
- **Top-level functions:** `canEditHousehold(membership)`. Slightly shorter; risk of name collision with screen-local methods.
- **Extension on Map:** `membership.canEditHousehold`. Elegant; but `Map<String, dynamic>` is too generic — every map in the app would gain these methods, and the helpers don't make sense on non-membership maps.

Recommend **static methods on class** (option in Phase 1). If you'd rather have the elegance of `membership.canEditHousehold`, we'd need to introduce a `Membership` wrapper type — out of scope for Half A.

### Q3 (no decision needed but worth confirming). Null/missing behavior: deny by default.

Every helper returns `false` if membership is `null` or `kind`/`role` are missing. This matches the spec's principle of least privilege and the existing code (which uses `?.` and falls through to `false` on missing role). Confirming this is the intended behavior.

### Q4 (no decision needed but worth flagging). Semantic widening — 6 sites become "owner OR admin"

6 sites that currently check only `'admin'` will, after this refactor, accept either `'owner'` or `'admin'`. This is a **deliberate widening per Q9/Q10** — the spec says owners and admins are equivalent for permission purposes. Just calling out that 6 gates will technically grant new permissions to owners that they didn't have before, even though owners didn't exist in practice yet (the migration 0016 backfill is the first time the Wrights household has an owner row).

No action needed — flagging in case you want to audit each one as you review the refactor.

## Next steps

1. **You answer the 2 open questions** (Q1 location, Q2 helper style). Q3 and Q4 are confirmations, not decisions.
2. **I write** `apps/mobile/lib/utils/permissions.dart` + the 9 refactor edits + the `'admin'` → `'owner'` flip on a fresh branch (`feat/kid-perms-helper-batch-3-half-a-...` off this branch or off main — your call given the stacked-branch question from Batch 2).
3. **Analyzer check**: run `flutter analyze apps/mobile/` before and after; expect zero new issues (refactor is type-stable; null safety is preserved; new file uses only `dart:core` types).
4. **Manual test**: launch app, sign in as the Wrights creator (now `role='owner'`), verify all 11 sites still gate correctly — admin actions still visible, etc.
5. **Commit** as one batch on the Half A branch.

Half B (migrating `_verifyChore` to `approve_chore` RPC, `_completeChore` to `complete_chore_self`) is a separate investigation later — it touches actual behavior, not just call sites, and needs more care around the kid/adult branching that today lives in `_verifyChore` and is now encapsulated in the RPC.
