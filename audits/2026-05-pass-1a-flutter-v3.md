# Audit Pass 1a (v3): Flutter App — Code Quality & Architecture
Date: 2026-05-21
Auditor: Claude Code
Scope: `apps/mobile/` only, branch `fix/critical-missing-features` at HEAD `6cef76d`

## Inventory (Phase 0)

`find apps/mobile/lib -type f -name "*.dart" | sort` → **45 files**:

```
lib/main.dart
lib/supabase_client.dart
lib/theme/app_theme.dart
lib/services/active_member_service.dart
lib/services/api_service.dart
lib/services/feature_tour_service.dart
lib/services/image_upload_service.dart
lib/services/notification_service.dart
lib/services/offline_service.dart
lib/services/rate_limit_service.dart
lib/services/realtime_service.dart
lib/widgets/app_a11y.dart
lib/widgets/app_error.dart
lib/widgets/error_boundary.dart
lib/widgets/offline_banner.dart
lib/screens/achievements_screen.dart
lib/screens/activity_feed_screen.dart
lib/screens/announcements_screen.dart
lib/screens/auth_screen.dart
lib/screens/calendar_screen.dart
lib/screens/chore_dashboard_screen.dart
lib/screens/chore_detail_screen.dart
lib/screens/chore_templates_screen.dart
lib/screens/data_export_screen.dart
lib/screens/feedback_screen.dart
lib/screens/home_shell_screen.dart
lib/screens/household_setup_screen.dart
lib/screens/household_stats_screen.dart
lib/screens/invite_management_screen.dart
lib/screens/meal_planner_screen.dart
lib/screens/member_profile_screen.dart
lib/screens/members_screen.dart
lib/screens/notification_preferences_screen.dart
lib/screens/onboarding_screen.dart
lib/screens/point_history_screen.dart
lib/screens/profile_screen.dart
lib/screens/recipe_detail_screen.dart
lib/screens/recipe_library_screen.dart
lib/screens/rewards_screen.dart
lib/screens/search_screen.dart
lib/screens/settings_screen.dart
lib/screens/shopping_category_screen.dart
lib/screens/shopping_list_screen.dart
lib/screens/splash_screen.dart
lib/screens/subscription_screen.dart
```

`wc -l` total: **20,751 lines**. Largest: `recipe_library_screen.dart` (1,405). Mean: 461.

- Total Dart files found: **45**
- Total lines: **20,751**
- Files actually read end-to-end: **45 / 45**

### Expected structure match: **Yes, with caveats.**

`lib/services/` has exactly the 7 files the brief described (active_member, api, feature_tour, image_upload, notification, offline, rate_limit, realtime — 8 actually; rate_limit_service was the brief's name but the file also exports `Debouncer`, `AsyncDebouncer`, `Throttler`, `RateLimiter`, `RateLimitExceededException`). `lib/widgets/` has the expected app_a11y / app_error / error_boundary / offline_banner. Screens are 30 (brief said "30+") and include all the named ones (chore_detail, settings, rewards, achievements, member_profile, data_export, announcements, point_history, splash, etc.). The structure the brief described **is** here.

## Executive Summary

The fix-branch app is a substantial Supabase-backed Flutter prototype with eight purpose-built services and four cross-cutting widgets, but its biggest problem is wiring: several of those services exist as code that nothing imports. Most prominently, `ApiService` (rate-limited, retrying, centralized Supabase wrapper) has zero callers anywhere in `lib/` — every screen still calls `Supabase.instance.client` directly, exactly as on `main`. `ErrorBoundary` has zero callers and, more importantly, its `_ErrorBoundaryState` never sets `_errorDetails`, so even if it were wrapped around something it would not catch any errors. `OfflineService`'s pending-operation queue, cache, and `performWrite` helper are not called from any screen — the only consumers are `main.dart` (init) and `OfflineBanner` (visualizing `isOnline`), so the "offline-first" claim is currently a UX banner with no underlying offline behavior. The `RealtimeService` is genuinely wired (six screens listen), the `ActiveMemberService` is genuinely wired (PIN-gated profile switching works end-to-end with SHA-256 hashes), and the recipe-API URL has been moved to `.env`. Outside the wiring story, the codebase has substantial schema drift across screens (three different table names for achievements, two for point-transaction column names, two for meal plans, two for shopping-item "purchased" field, two recipe table names) — several screen reads/writes target tables that other screens don't write to or read from, which strongly implies some features are broken at runtime. `analysis_options.yaml`, `test/`, `ios/`, and `android/` are still missing on this branch; the handoff doc says local `flutter analyze` reports 178 issues (all info/warning) and the project builds, which I cannot verify without the SDK.

## Codebase Snapshot

- **State management**: `setState` everywhere; `ValueNotifier`+`ValueListenableBuilder` for the theme toggle (`main.dart:39`), realtime version counters, and offline banner. Riverpod is in pubspec but **0 imports** (`grep -rln 'flutter_riverpod\|riverpod' apps/mobile/lib/` → empty).
- **Local storage**: `SharedPreferences` (used by `ActiveMemberService`, `FeatureTourService`, `OfflineService`, `main.dart` theme, `onboarding_screen.dart`, `settings_screen.dart`). No `Hive`/`Isar`/`sqflite`.
- **Realtime**: `RealtimeService` (in `lib/services/realtime_service.dart:8-162`) subscribes to one channel `household:$id` with eight `onPostgresChanges` callbacks that bump `ValueNotifier<int>` versions. Six screens listen: `home_shell_screen.dart`, `chore_dashboard_screen.dart`, `calendar_screen.dart`, `meal_planner_screen.dart`, `recipe_library_screen.dart`, `shopping_list_screen.dart`. All add/remove listeners correctly in `initState`/`dispose`.
- **Routing**: Direct `Navigator.push(MaterialPageRoute(...))` only; `go_router` declared but unused (0 imports).
- **Key declared dependencies, with usage status** (`grep -rln '<name>' apps/mobile/lib/`):
  - `supabase_flutter` → used in 34 files
  - `flutter_dotenv` → used in 2 (`main.dart`, `recipe_library_screen.dart`)
  - `http` → used in 1 (`recipe_library_screen.dart`)
  - `shared_preferences` → used in 6 (services + main + onboarding + settings)
  - `image_picker` → used in 3 (image_upload_service + profile + recipe_detail)
  - `connectivity_plus` → used in 1 (offline_service)
  - `crypto` → used in 2 (members_screen, home_shell_screen — PIN hashing)
  - `share_plus` → used in 1 (data_export)
  - `path_provider` → used in 1 (data_export)
  - `go_router: ^14.2.7` → **unused**
  - `flutter_riverpod: ^2.5.1` → **unused**
  - `intl: ^0.19.0` → **unused**
  - `url_launcher: ^6.3.0` → **unused**
  - `cupertino_icons` → indirect (no explicit import)
- **Test files**: **0**.
- **`analysis_options.yaml`**: absent.
- **`pubspec.lock`**: **present** on this branch (it was absent on `main`).
- **Platform folders (`ios/`, `android/`, `web/`)**: absent.
- **`.env`**: only `.env.example` is checked in. pubspec lists `.env` as an asset (`pubspec.yaml:29`), so the build will warn or fail without a local `.env`.

## Severity Legend
- **Critical** — blocks scaling, causes user-visible failures, or compounds debt fast
- **High** — fix before next major feature
- **Medium** — fix in normal cycle
- **Low** — nice-to-have / style

## Findings

### Architecture & Structure

**A1. `ApiService` (rate limiting + retry + centralized API) is fully implemented but never called** (Critical)
- Location: `lib/services/api_service.dart` (203 lines)
- Evidence: `grep -rn 'ApiService' apps/mobile/lib/` returns matches **only** inside `api_service.dart` itself. **Zero** screens or other services import it.
- Problem: The service defines a `query`/`insert`/`update`/`delete`/`rpc` API with shared read/write/auth `RateLimiter`s and a `_withRetry` helper. None of the ~70 `Supabase.instance.client.from(...)` call sites in screens go through it. The architecture diagram the brief described is present in code, but the screens bypass it.
- Why it matters: Rate limiting, retries, and "no client errors retried" logic are coded but unused, so the app gets none of those benefits. Every new screen that copies the existing pattern accumulates more bypass.
- Suggested fix: Pick one — either start routing screen calls through `ApiService.instance.query/insert/etc.` (start with the highest-frequency screens: chore_dashboard, calendar, shopping_list), or delete `api_service.dart` and stop claiming centralized API is a feature. If you keep it, it also needs a repository layer per domain so screens don't construct raw query maps inline.

**A2. `ErrorBoundary` is unused AND non-functional even if wrapped** (Critical)
- Location: `lib/widgets/error_boundary.dart:5-37`
- Evidence: `grep -rn 'ErrorBoundary' apps/mobile/lib/` → only the definition file. **Zero** wrap sites.
- The class's state stores `FlutterErrorDetails? _errorDetails` but **never assigns to it**. There is no `didCatchError`, no `try/catch` in `build`, no override of `Element.performRebuild`, no integration with `FlutterError.onError`. The retry callback sets it back to `null`, which is the only mutation. So even if some screen wrote `ErrorBoundary(child: ...)`, no error would ever flow into the boundary.
- Problem: Two failures stacked: (a) nothing uses it; (b) the implementation is decorative. Flutter widgets cannot catch build/render exceptions from their children without `FlutterError.onError` or `ErrorWidget.builder`; both are absent in this app (`grep -rn 'FlutterError.onError\|ErrorWidget.builder\|runZonedGuarded' apps/mobile/lib/` → no matches).
- Suggested fix: In `main.dart`, set `FlutterError.onError = (details) { logger.severe(..., details.exception, details.stack); }` and `ErrorWidget.builder = (details) => FriendlyError(details);`. Wrap `runApp` in `runZonedGuarded` for async exceptions. Then delete the existing `ErrorBoundary` widget or rewrite it to host those handlers locally for specific subtrees (which is rarely necessary).

**A3. `OfflineService`'s cache + outbox queue is fully implemented but no screen uses it** (Critical)
- Location: `lib/services/offline_service.dart` (390 lines)
- Evidence: `grep -rln 'OfflineService' apps/mobile/lib/` returns only `main.dart` (calls `init()` at startup) and `widgets/offline_banner.dart` (subscribes to `isOnline` and `pendingOperationsCount`). The methods that would deliver offline behavior — `fetchWithFallback`, `fetchListWithFallback`, `performWrite`, `queueOperation`, `cacheData`, `cacheList`, `getCachedList`, `syncPendingOperations` — are **never called** by any screen.
- Problem: A user toggling airplane mode sees the orange banner (because `OfflineBanner` listens to `isOnline`), but their next tap on "Mark Complete" will go to `Supabase.instance.client.from('chores').update(...)` directly and throw. The "Changes will sync when you reconnect" message in `offline_banner.dart:38` is not backed by code. `syncPendingOperations` will run when connectivity returns but there will be nothing in the queue because nothing writes to it.
- Why it matters: This is the largest gap between claimed feature and implemented behavior in the repo. The offline-first claim cannot be honestly made until at minimum chore-completion, shopping-item toggling, and meal-plan changes route through `OfflineService.performWrite`.
- Suggested fix: Wrap each mutation in `OfflineService.instance.performWrite(...)` and read paths in `OfflineService.instance.fetchListWithFallback(...)`. Start with shopping_list (the brief specifically calls out shopping-list offline support).

**A4. No service / repository / model layer; every screen calls Supabase directly with `Map<String, dynamic>`** (Critical)
- Location: every file in `lib/screens/`. Example concentrations:
  - `home_shell_screen.dart:84-131` reloads household membership + members + pinned announcement.
  - `chore_dashboard_screen.dart:52-126`, `calendar_screen.dart:49-119`, `meal_planner_screen.dart:52-94`, `shopping_list_screen.dart:100-194`, `recipe_library_screen.dart:56-111`, `members_screen.dart:30-61`, `chore_detail_screen.dart:67-162`, `member_profile_screen.dart:29-115`, `household_stats_screen.dart:43-152` — each independently loads `household_members + households` first.
- Evidence: `grep -rn 'Supabase.instance.client' apps/mobile/lib/` → 130+ matches across 27 files.
- Problem: Every column/table name is a string literal in widget code. Models are unsigned `Map<String, dynamic>`. Refactors are dangerous (see A6 for the consequences).
- Suggested fix: Introduce `lib/data/` with one repository per domain, each constructor-injectable. Provide a `currentMembershipProvider` (Riverpod is already in pubspec) so the home-shell loads once and every screen `ref.watch`es. Build immutable models (`Chore`, `Recipe`, `MealPlan`, `CalendarEvent`, `ShoppingItem`, `HouseholdMember`, `Reward`, `Announcement`) — `freezed` + `json_serializable` or hand-rolled — and have repositories return them.

**A5. Riverpod, go_router, intl, url_launcher are declared in `pubspec.yaml` but have zero imports** (High)
- Location: `pubspec.yaml:14-17`
- Evidence: see Codebase Snapshot.
- Suggested fix: Use them (Riverpod and go_router map directly to A1/A4 fixes; intl would replace ~10 hand-rolled `_formatDate` helpers; url_launcher is needed for source-URL links on recipes) or remove them.

**A6. Schema drift: at least seven cross-screen inconsistencies in table or column names** (Critical)

These look like real correctness bugs — different screens reference different table/column names for the same concept. Any RLS/migration that hasn't aliased them will surface as silent empty queries or runtime errors.

- **Achievements table**: three different references.
  - `achievements_screen.dart:58-63` → `.from('achievements')`
  - `activity_feed_screen.dart:77-81` → `.from('member_achievements')` with columns `badge_name`, `badge_icon`
  - `member_profile_screen.dart:73-77` → `.from('member_badges').select('*, badges(*)')`
- **Point-transactions type column**: two names.
  - `point_history_screen.dart:53-54`, `rewards_screen.dart:217-226`, `household_stats_screen.dart:71-74` → column `type`
  - `member_profile_screen.dart:55-58`, `activity_feed_screen.dart:99-102` → column `transaction_type`
- **Meal plan tables**: two names.
  - `meal_planner_screen.dart:79-90, 638-660` → `.from('meal_plans')`
  - `recipe_detail_screen.dart:343-349` → `.from('meal_plan_entries')` with column `meal_date` (vs. `planned_for` everywhere else)
- **Shopping-item purchased field**: two names.
  - everywhere else → `purchased`
  - `recipe_detail_screen.dart:266` → `'is_purchased': false`
- **Recipe table**: two names.
  - everywhere else → `household_recipes`
  - `data_export_screen.dart:165-168` → `.from('recipes')`
- **Reward redemption point cost field**: two names.
  - `rewards_screen.dart:202-208` → `point_cost`
  - `activity_feed_screen.dart:121-134` → `points_cost`
- **Reward name field**: denormalized vs. join.
  - `rewards_screen.dart:64` joins to `rewards(title, icon)`
  - `activity_feed_screen.dart:121-134` reads `reward_name` directly from `reward_redemptions`

Suggested fix: This is also a Pass-2 data-integrity issue, but the surface is in app code. Pick one canonical schema, then either (a) consolidate the screens onto it, or (b) introduce a repository (see A4) so the canonical names live in exactly one place. Either way, a quick `flutter run` smoke test of each screen that reads these tables/columns will surface which ones are currently broken at runtime.

**A7. Six+ screens redundantly load the same `household_members + households` row on init** (High)
- Location: same as A4. Every screen with a `_loadData` opens with:
  ```dart
  final memberships = await Supabase.instance.client
      .from('household_members')
      .select('*, households(*)')
      .eq('auth_user_id', user.id)
      .limit(1);
  ```
- Problem: First launch = a stack of duplicate queries. Worse, since each screen also subscribes to `RealtimeService.choresVersion` (etc.) and reloads on event, a single chore-completion triggers a full re-read across every subscribed screen — including `home_shell_screen.dart` whose `_onPointsChanged` listener calls `_loadHouseholdInfo()` which itself re-runs the membership + members + announcement reads.
- Suggested fix: A single `currentMembershipProvider` + `householdProvider` that everyone watches — covered in A4. Removes the duplicate `memberships[0]` reload on every realtime tick.

**A8. `home_shell_screen.dart:48,148` uses `late final List<Widget> _screens` that is reassigned on every reload** (High)
- Location: `home_shell_screen.dart:48` (`late final List<Widget> _screens;`) and `home_shell_screen.dart:148-156` (`void _buildScreens() { _screens = [...]; }`), called from the `finally` of every `_loadHouseholdInfo` invocation (line 137).
- Problem: `late final` allows exactly one assignment. `_loadHouseholdInfo` is called from `initState` **and** every time `RealtimeService.pointsVersion`, `RealtimeService.announcementsVersion`, or `ActiveMemberService.activeMemberId` changes (lines 55-65). Every reload therefore re-enters `_buildScreens`, which re-assigns `_screens` — and Dart throws `LateInitializationError: Field '_screens' has already been initialized.` on the second call.
- Evidence: The pattern is real. The fact that this hasn't been hit in testing suggests the realtime channels aren't actually firing during dev runs, or the test sessions are short enough that no points/announcement events occur. It will hit users quickly.
- Suggested fix: Drop `late final` — use `final List<Widget> _screens = [const ChoreDashboardScreen(), ...]` initialized at construction (the children are `const` widgets, no state depends on the household load). Remove `_buildScreens()` entirely.

**A9. Routing scattered across raw `MaterialPageRoute` calls; no auth/membership redirect** (Medium)
- Location: `main.dart:103-135` (`AppEntryGate` re-implements an auth+household gate with nested `StreamBuilder` + `FutureBuilder`). Direct `Navigator.push(MaterialPageRoute(...))` at 25+ call sites across `home_shell_screen.dart`, `onboarding_screen.dart`, `household_setup_screen.dart`, `chore_dashboard_screen.dart`, `meal_planner_screen.dart`, `recipe_library_screen.dart`, etc.
- Problem: No central route table; no deep-link support; auth/household gate is re-implemented inline in `main.dart`. Membership refetches on every auth-state event (`main.dart:114-119`).
- Suggested fix: Use `go_router` (already in pubspec) — define a single `GoRouter` with named routes and a `redirect:` callback for auth + household. The `AppEntryGate` then becomes a no-op.

**A10. `HoneydoSupabaseClient` wrapper class is unused** (Low)
- Location: `lib/supabase_client.dart`. Class was renamed from `SupabaseClient` to `HoneydoSupabaseClient` (resolves the type collision flagged earlier), but `grep -rn 'HoneydoSupabaseClient' apps/mobile/lib/` returns only the definition file. **Zero** call sites.
- Suggested fix: Either consolidate auth flows through it (would help with `currentUser!` proliferation) or delete the file.

### Code Quality

**CQ1. Predictable invite-code generators (two implementations, both broken)** (Critical — security-flavored)
- Location 1: `members_screen.dart:115-122`. Exact code:
  ```dart
  String _generateCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // No ambiguous chars
    final buffer = StringBuffer();
    for (int i = 0; i < 6; i++) {
      buffer.write(chars[DateTime.now().microsecond % chars.length]);
    }
    return buffer.toString();
  }
  ```
  All six iterations read `DateTime.now().microsecond` — typically the same value across a tight loop, so the produced "code" is six copies of the same character. Effective key-space ≈ 32, not 32⁶.

- Location 2: `invite_management_screen.dart:111-124`. Exact code:
  ```dart
  String _generateInviteCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final buffer = StringBuffer();
    for (int i = 0; i < 6; i++) {
      buffer.write(chars[DateTime.now().microsecondsSinceEpoch % chars.length]);
    }
    // Add some randomness
    final random = DateTime.now().millisecondsSinceEpoch;
    buffer.clear();
    for (int i = 0; i < 6; i++) {
      buffer.write(chars[(random + i * 7) % chars.length]);
    }
    return buffer.toString();
  }
  ```
  The first loop is dead code (`buffer.clear()` wipes it). The second loop uses one `millisecondsSinceEpoch` value, slightly varied by `i * 7` per character — so all six characters are deterministic from a single millisecond. Anyone who knows the approximate creation time can enumerate at most ~32 possibilities.

- Problem: Both code generators produce predictable / near-constant codes. An attacker who can observe creation time (or just brute-force ~1000 codes) can join the household.
- Suggested fix: Use `Random.secure()` once outside the loop:
  ```dart
  final r = Random.secure();
  for (int i = 0; i < 6; i++) buffer.write(chars[r.nextInt(chars.length)]);
  ```
  Better: generate server-side via an edge function or Postgres function so the client can't influence it. Consolidate the two duplicate functions.

**CQ2. PIN hashing is real but weak: SHA-256 with no salt over a 4–6 digit input** (Critical — security)
- Location: write path `members_screen.dart:430-443` (verbatim):
  ```dart
  // Hash the PIN with SHA-256 before storing
  final bytes = utf8.encode(pin);
  final pinHash = sha256.convert(bytes).toString();
  await Supabase.instance.client.from('household_members').insert({
    ...
    'pin_hash': pinHash,
    ...
  });
  ```
  Verify path `home_shell_screen.dart:531-540`:
  ```dart
  final pin = pinController.text.trim();
  final pinHash = sha256.convert(utf8.encode(pin)).toString();
  if (pinHash != member['pin_hash']) {
    // wrong PIN
  }
  ```
- Problem: The brief said PINs are hashed; that is **now true on this branch** (it was plaintext on `main`). However, SHA-256 with no salt over a 4-digit (≤ 10,000) or 6-digit (≤ 1,000,000) input is essentially recoverable. Anyone who can SELECT `pin_hash` from `household_members` can build a complete rainbow table in <1 second and recover every kid's PIN. The kid-profile UI (`pinController` at `home_shell_screen.dart:505`) is also not disposed when the dialog closes — minor leak but the bigger issue is the hash strength.
- Suggested fix: Move PIN verification to a server-side function (a Postgres `verify_kid_pin(p_member_id uuid, p_pin text)` SECURITY DEFINER function that does the hash comparison without exposing `pin_hash` to clients). Use a slow KDF with per-row salt — `pgcrypto.crypt(pin, gen_salt('bf'))` or scrypt. Then revoke client `SELECT` on the `pin_hash` column via RLS. This is a Pass-2 fix — flagging here because the previous audit was told the hashing was solved, and the in-code state shows it is half-solved.

**CQ3. Non-atomic point redemption: 3 separate DB writes with no transaction** (High)
- Location: `rewards_screen.dart:197-226` (verbatim):
  ```dart
  // Create redemption record
  await Supabase.instance.client.from('reward_redemptions').insert({ ... 'status': 'pending', ... });

  // Deduct points from member balance
  await Supabase.instance.client
      .from('household_members')
      .update({'points_balance': currentPoints - pointCost})
      .eq('id', memberId);

  // Create point transaction for the spending
  await Supabase.instance.client.from('point_transactions').insert({ ... 'amount': -pointCost, 'balance_after': currentPoints - pointCost, ... });
  ```
- Problem: Three failure modes — (a) any one fails after the previous one succeeded → inconsistent state (redemption exists but points not deducted, or points deducted but no transaction record). (b) Lost-update: `currentPoints - pointCost` is computed from in-memory cache; two simultaneous redemptions on different devices both see 100, both write back 50 — net result 50 when it should be 0. (c) The update is also unguarded — there is no `WHERE points_balance >= pointCost` clause, so a kid whose balance drops to negative between rendering and tap will go negative.
- Suggested fix: Move the entire redemption to a single Postgres RPC (`redeem_reward(p_reward_id uuid)`) that locks the member row, checks balance, deducts atomically, inserts redemption + transaction in one transaction, and returns success/failure. Same pattern for `award_points` (which is already an RPC — `chore_dashboard_screen.dart:127` calls it). Apply consistently.

**CQ4. 64 empty `catch (_)` blocks across 22 files silently swallow errors** (High)
- Evidence: `grep -rc 'catch (_)' apps/mobile/lib/ --include='*.dart'` summed → 64.
- Highest concentrations: `shopping_list_screen.dart` (8), `meal_planner_screen.dart` (4), `calendar_screen.dart` (6), `home_shell_screen.dart` (5), `chore_dashboard_screen.dart` (4), `members_screen.dart`, `chore_detail_screen.dart`, etc.
- Problem: No observability. There is also no `print()` (`grep -rn 'print(' apps/mobile/lib/` → 0), no `package:logging` usage (`grep -rn 'package:logging' apps/mobile/lib/` → 0), no Sentry/Crashlytics. Production failures will be invisible.
- Suggested fix: Add `package:logging` + APM SDK (Sentry, Crashlytics, PostHog). Wire `Logger.root.onRecord.listen` to forward severe records. Every `catch (e, st)` writes `_logger.severe('...', e, st)`. The `AppError.show` utility (see CQ5) should also log on the way out.

**CQ5. `AppError.show/showSuccess/showInfo`, `ErrorView`, `EmptyView`, `LoadingView`, `AsyncScreenBuilder`, `AsyncListBuilder` — all defined, all unused** (Medium)
- Location: `lib/widgets/app_error.dart`, `lib/widgets/error_boundary.dart`
- Evidence: `grep -rn 'AppError\.' apps/mobile/lib/` returns matches only in the definition file. `grep -rn 'AsyncScreenBuilder\|AsyncListBuilder' apps/mobile/lib/` → same. `grep -rn 'ErrorView\|EmptyView\|LoadingView' apps/mobile/lib/` → defined and self-referencing in `error_boundary.dart`, but **no screen consumes them**.
- Problem: ~380 lines of carefully-designed utility widgets sit unused. Every screen reimplements its own loading spinner, empty state, and SnackBar error pattern.
- Suggested fix: Replace inline `Center(child: CircularProgressIndicator())` with `LoadingView(message: 'Loading…')`, inline empty Cards with `EmptyView(...)`, and `ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')))` with `AppError.show(context, e.toString())`. The error message friendlification logic at `app_error.dart:67-100` is the single best version of this code in the repo; right now it's not protecting anyone.

**CQ6. `AppA11y.iconButton`, `AccessibleCard`, `AccessibleStatusChip` defined, all unused** (Low)
- Evidence: `grep -rn 'AppA11y\|AccessibleCard\|AccessibleStatusChip' apps/mobile/lib/` → only the definition file.
- The semantic-label helpers and contrast-ratio checker would help with accessibility, but no screen uses them. Several screens have decent ad-hoc semantics (`home_shell_screen.dart:167, 245` wrap with `Semantics`) but the widgets in `app_a11y.dart` are not the source.
- Suggested fix: When migrating IconButtons or status chips, swap to `AppA11y.iconButton(...)` and `AccessibleStatusChip(...)`. Or delete the unused helpers and standardize on inline `Semantics()` wrappers.

**CQ7. 118 unchecked `[...]` map lookups and 34 `currentUser!` force-unwraps** (High)
- Evidence: `grep -rln '!\[' apps/mobile/lib/ --include='*.dart'` count of lines → 118. `grep -rn 'currentUser!' apps/mobile/lib/` → 34.
- Problem: A row missing an expected field, or a token expiry mid-session, crashes the screen. The lack of error boundaries (A2) makes this a hard crash, not a soft error state.
- Suggested fix: Replace `Supabase.instance.client.auth.currentUser!` with a provider that returns nullable + short-circuits the route. Use model classes so `chore.title` is non-nullable at compile time.

**CQ8. `displayName[0].toUpperCase()` will crash if `display_name` is an empty string** (High)
- Location: `home_shell_screen.dart:474` (`Text(isKid ? '👶' : '👤')` is fine — but `settings_screen.dart:454-455`, `profile_screen.dart:193-195`, `member_profile_screen.dart:188`, `announcements_screen.dart:287`, `chore_detail_screen.dart:1026` all do `(name ?? '?')[0]` or similar without checking emptiness).
- Example, `settings_screen.dart:454-455`:
  ```dart
  child: Text(
    (_myMembership?['display_name'] as String? ?? '?')[0].toUpperCase(),
  ```
  If `display_name` is `''` (empty, not null), the `??` doesn't fire and `''[0]` throws `RangeError`.
- Suggested fix: `final name = (_myMembership?['display_name'] as String?)?.trim() ?? ''; final letter = name.isEmpty ? '?' : name[0].toUpperCase();` — applied everywhere this pattern occurs. Models with non-empty validation would fix it once.

**CQ9. Sequential default-tag / default-reward inserts in `for` loops are not transactional** (High)
- Location 1: `household_setup_screen.dart:114-119` (already flagged in v2, **still unchanged**):
  ```dart
  for (final tag in defaultTags) {
    await Supabase.instance.client.from('calendar_tags').insert({ 'household_id': householdId, ...tag });
  }
  ```
- Location 2: `rewards_screen.dart:444-453` (new pattern):
  ```dart
  for (final reward in defaultRewards) {
    await Supabase.instance.client.from('rewards').insert({ ... });
  }
  ```
- Problem: 6 sequential round-trips (tags) or 10 (default rewards). App killed mid-loop → partial state, no UI to repair.
- Suggested fix: Single batch insert `.insert([row1, row2, ...])`. Or move household creation to one edge function.

**CQ10. Many `TextEditingController`s created inside `showDialog` / `showModalBottomSheet` builder closures and never disposed** (Medium)
- Locations:
  - `home_shell_screen.dart:505` — `final pinController = TextEditingController();` in `_verifyAndSwitchToKid`. Never disposed.
  - `members_screen.dart` — Pin and confirm-PIN controllers inside `_AddSubProfileSheet` are disposed correctly; the dialog-only ones in `auth_screen.dart:257` are still leaks.
  - `settings_screen.dart:126` (`nameController`), `:201, :204` (`nameController`, `emojiController`), `:298-300` (`currentPasswordController`, `newPasswordController`, `confirmPasswordController`) — all created in sheet builders, never disposed.
  - `chore_templates_screen.dart:160-162` (`titleController`, `descController`, `pointsController`) — never disposed.
  - `chore_detail_screen.dart:30` — `_commentController` is created at state-class level but **not in `dispose()`** at lines 60-65; only `_titleController`, `_descriptionController`, `_pointsController` are disposed.
  - `rewards_screen.dart:278-281`, `announcements_screen.dart:68-69`, etc.
- Suggested fix: Either hoist each controller into a small `StatefulWidget` and dispose properly, or switch to `useTextEditingController()` via `flutter_hooks`, or pair every `final c = TextEditingController()` in a sheet body with `c.dispose()` after the `await showModalBottomSheet`. The `recipe_detail_screen.dart:1011, 1047` pattern (`controller.dispose()` after `await showDialog`) is the right idea but rarely applied elsewhere.

**CQ11. Inline `TextEditingController(text: ...)` inside `itemBuilder` lists creates fresh controllers on every rebuild** (Medium)
- Location: `recipe_library_screen.dart:518-535, 599, 805-822, 874-892`. Each ingredient/step row builds:
  ```dart
  TextField(
    controller: TextEditingController(text: ing['raw'] ?? ''),
    onChanged: (value) { ingredients[index]['raw'] = value; },
  )
  ```
- Problem: Every parent rebuild discards the controller and creates a new one. Cursor position and selection reset; typing into a field is interrupted whenever a sibling triggers `setSheetState`.
- Suggested fix: Hoist `List<TextEditingController>` into the parent state, mirror length to the data list, and dispose all controllers when the sheet closes.

**CQ12. `_updatePref` is typed `(String key, bool value)` but called with a `String` via `as dynamic` for quiet-hours times** (Medium)
- Location: `notification_preferences_screen.dart:321`:
  ```dart
  await _updatePref(key, timeStr as dynamic);
  ```
- Problem: `_updatePref(String key, bool value)` is declared with `bool value`. The cast `as dynamic` defeats type checking. At line 60 the screen does `_preferences?[key] = value;` — the map accepts the string, and the upstream `NotificationService.updatePreferences` takes `Map<String, dynamic>`, so it'll go to the database. But this is a type-system hole that will silently break if anyone tightens `_updatePref`'s signature later. Also note `notification_service.dart:87-88` uses `'21:00'`/`'07:00'` (24-hour) as defaults while this screen produces `'10:00 PM'`/`'7:00 AM'` (12-hour). They don't agree.
- Suggested fix: Overload `_updatePref` (split into `_updateBoolPref` / `_updateStringPref`) or change the signature to `(String key, dynamic value)`. Pick one time format (recommend ISO 24-hour) and use it everywhere; convert at the UI boundary.

**CQ13. Hardcoded production API URL still in source as fallback** (Medium)
- Location: `recipe_library_screen.dart:35`:
  ```dart
  String get _apiUrl => dotenv.env['API_URL'] ?? 'https://honeydo-production-743d.up.railway.app';
  ```
- Problem: Improved from v2 (env override exists), but the fallback URL is still hardcoded. If a developer forgets to set `API_URL`, the app silently talks to production. A safer default is null + a runtime error, or staging.
- Suggested fix: `String get _apiUrl => dotenv.env['API_URL'] ?? (throw StateError('API_URL not set in .env'));` — surfaces missing config at startup. Document `API_URL=` in `.env.example`.

**CQ14. Mixed and duplicated `_parseColor` / date-formatter / `_StatCard` helpers across files** (Medium)
- Examples:
  - `_parseColor` defined twice in the same file: `calendar_screen.dart:414-422` and `:535-543`.
  - Date helpers `_formatTimestamp`, `_formatDate` reimplemented in `announcements_screen.dart:361`, `activity_feed_screen.dart:420`, `feedback_screen.dart:359`, `point_history_screen.dart:348`, `subscription_screen.dart:471`, `member_profile_screen.dart` and `chore_detail_screen.dart:949` (slightly different rules in each).
  - `_StatCard` defined in `chore_dashboard_screen.dart:391-415`, `members_screen.dart:289-312`, and `household_stats_screen.dart:546-598` — three slight variants.
- Suggested fix: One shared `lib/shared/utils/date_format.dart`, one `lib/shared/utils/color_utils.dart`, one `lib/shared/widgets/stat_card.dart`. Reuse across screens.

**CQ15. Hardcoded badge list in `achievements_screen.dart` mirrors but does not load from `badges` table** (Medium)
- Location: `achievements_screen.dart:20-29`. 8 badges hardcoded. The comment says it "mirrors the check_and_award_achievements function" — i.e., changing badges requires updates in both the SQL function and this screen.
- Suggested fix: Read badges from the `badges` (or `member_badges`/`achievements`) tables — once the schema in A6 is consolidated.

**CQ16. Raw `e.toString()` exposed to users in many places** (Medium)
- Location: ~20+ matches across `chore_detail_screen.dart`, `recipe_library_screen.dart`, `recipe_detail_screen.dart`, `rewards_screen.dart`, `member_profile_screen.dart`, etc. Pattern: `SnackBar(content: Text('Error loading recipes: $e'))`.
- Problem: Raw exception (potentially including SQL fragments, RLS policy names, internal schema) reaches the user. The `AppError._friendlyMessage` (`app_error.dart:67-100`) would handle this, but no one calls it.
- Suggested fix: Use `AppError.show(context, e.toString())` instead. CQ5 fix solves this in one sweep.

**CQ17. `_dueDate` set in `_QuickAssignDialog` is never used in the resulting insert** (Low)
- Location: `chore_templates_screen.dart:763-775` lets user pick a due date in the dialog; the dialog returns only `_selectedMemberId` via `Navigator.pop(context, _selectedMemberId ?? 'unassigned')`. The dueDate is discarded. Then at lines 130-139, `_quickAddFromTemplate` inserts a chore with no `due_at`.
- Suggested fix: Return both values: `Navigator.pop(context, {'memberId': ..., 'dueDate': _dueDate})`, and use both at the insert site.

**CQ18. "Current password" field in change-password sheet is captured but never verified** (Low)
- Location: `settings_screen.dart:298, 320-328, 350-371`. The `currentPasswordController` collects a value but it is never used; `Supabase.auth.updateUser` doesn't take it. UI suggests confirmation is required, but in fact any logged-in user can change their own password without proving the old one.
- Suggested fix: Either remove the field (Supabase doesn't support this server-side without a re-auth flow) or implement re-auth: call `signInWithPassword(email: currentEmail, password: currentPassword)` first, then `updateUser`. Note this still doesn't protect against a stolen device.

**CQ19. Dead UI: Terms of Service / Privacy Policy / Help & Support list tiles have no `onTap`** (Low)
- Location: `settings_screen.dart:580-594`. Three `ListTile`s with `trailing: Icon(Icons.chevron_right)` but no handler.
- Suggested fix: Use `url_launcher` (declared but unused — see A5) to open the respective URLs.

**CQ20. Subscription screen is fully mocked** (Low — Pass 3)
- Location: `subscription_screen.dart:396-451`. Both "Upgrade" and "Cancel" just `ScaffoldMessenger`-show "simulated" snackbars. The text explicitly says "in a production environment, this would integrate with Authorize.net".
- Suggested fix: Either ship the integration, gate the screen behind a feature flag, or remove the menu entry until real.

**CQ21. Search uses raw query interpolation into PostgREST `.or(...)` filter** (Medium — security-flavored)
- Location: `search_screen.dart:74-97`:
  ```dart
  final pattern = '%${query.trim()}%';
  await Supabase.instance.client
      .from('chores')
      ...
      .or('title.ilike.$pattern,description.ilike.$pattern')
  ```
- Problem: `.or()` parses commas as logical separators. If user types a comma (or `column.eq.something`), the filter is reinterpreted. RLS prevents reading other households' rows, but within a household this could broaden a filter unexpectedly or cause errors.
- Suggested fix: Strip `,`, `(`, `)` from `query` before interpolation, or use `.textSearch()` / `.filter('title', 'ilike', pattern).or('description', 'ilike', pattern)` separately. PostgREST's `.or()` API doesn't support parameterized escapes.

**CQ22. Edge-function-plus-fallback in members `_generateInviteCode` is still confused** (Medium)
- Location: `members_screen.dart:63-113`. The function `invoke('generate-invite', ...)` and then unconditionally falls through to a client-side fallback that may also create a new invite. If both succeed, you get two invites.
- Suggested fix: Pick one. If the edge function exists, await it and surface its error; if not, delete the call.

### Flutter-Specific Concerns

**FS1. 126 `withOpacity` calls — deprecated in Flutter 3.27+** (Low)
- Evidence: `grep -rc 'withOpacity' apps/mobile/lib/ --include='*.dart'` summed → 126.
- Handoff doc confirms this is in the "remaining non-blocking cleanup" list.
- Suggested fix: Sweep replace with `.withValues(alpha: ...)`.

**FS2. `DropdownButtonFormField.value` deprecated** (Low)
- Per handoff: replace with `initialValue`. Affects ~20+ dropdowns across the screens.

**FS3. `IndexedStack` keeps 5 tab screens alive simultaneously, each subscribing to RealtimeService** (Medium)
- Location: `home_shell_screen.dart:198-203`
- Problem: All five feature screens are constructed at first build, and each subscribes to its `RealtimeService` ValueNotifier. A single chore change triggers `choresVersion` listeners in chore_dashboard AND calendar (which also subscribes to `choresVersion` at `calendar_screen.dart:36` — questionable, since the calendar shows events, not chores). So one chore update triggers 2 full reloads.
- Suggested fix: Calendar should subscribe to a `calendarEventsVersion` notifier (currently doesn't exist in `RealtimeService`). The realtime channel doesn't subscribe to `calendar_events` table at all — only chores/shopping/meal_plans/recipes/members/points/rewards/announcements. So calendar realtime is currently 100% broken; the screen reloads on chore changes for unrelated reasons.

**FS4. `use_build_context_synchronously` smells across post-await UI paths** (Medium)
- Examples without `mounted` guards:
  - `recipe_library_screen.dart:349, 361, 371` — `Navigator.pop(context)` after `await http.post(...)`.
  - `chore_dashboard_screen.dart:740-741, 850` (showDatePicker followed by `setState`).
  - `home_shell_screen.dart:486-491` — `ScaffoldMessenger.of(context).showSnackBar(...)` after `await ActiveMemberService.instance.switchTo(...)`.
  - `chore_templates_screen.dart:117` — uses `if (!mounted) return;` correctly (this is the right pattern).
- Suggested fix: An `analysis_options.yaml` with `use_build_context_synchronously: error` would surface every instance. See TT1.

**FS5. `Image.network` everywhere with no disk caching** (Medium)
- Location: `recipe_library_screen.dart:1163, 1298`, `recipe_detail_screen.dart:482-487`, `chore_detail_screen.dart:1023`, `members_screen.dart` and others — `Image.network` direct.
- Problem: Every app restart re-downloads recipe and avatar images. Avatars in particular re-fetch on every screen tab.
- Suggested fix: `cached_network_image` package.

**FS6. `'Nunito'` font declared in theme but no font asset declared in pubspec** (Low)
- Location: `app_theme.dart:29, 60`; `pubspec.yaml` has only `.env` under assets and no `fonts:` section.
- Problem: The font silently falls back to the platform default. The brand visual depends on a font that isn't loaded.
- Suggested fix: Use `google_fonts` package (`GoogleFonts.nunito()`) or declare the TTFs under `flutter.fonts:` in pubspec. Or remove `fontFamily: 'Nunito'`.

**FS7. `Color.value.toRadixString` deprecated** (Low)
- Location: `household_setup_screen.dart:75` (still unchanged from v2). `_selectedColor.value.toRadixString(16)` → use `.toARGB32()`.

**FS8. Two ~280-line near-identical recipe edit sheets in `recipe_library_screen.dart`** (Medium)
- Location: `_showImportedRecipeSheet` (392-684) and `_showManualRecipeSheet` (686-976). Structurally identical apart from initial values.
- Suggested fix: Extract a single `RecipeEditSheet({Recipe? initial, required Future<void> Function(Recipe) onSave})` and have both flows construct it.

### Cross-Cutting

**XC1. Offline support: banner shown but no behavior** (Critical)
- See A3. The `OfflineBanner` widget shows a banner and pending-count badge; nothing actually queues operations or reads cache. The "Changes will sync when you reconnect" text is aspirational.

**XC2. Realtime: implemented and wired in six screens; calendar wired wrong** (Medium)
- Six screens correctly listen to `RealtimeService.<x>Version` notifiers and dispose. `calendar_screen.dart:36` listens to `choresVersion` but should listen to a `calendarEventsVersion` (not defined). `realtime_service.dart:8-162` doesn't subscribe to the `calendar_events` table.
- Suggested fix: Add `calendar_events` to the realtime channel + add a `calendarEventsVersion` notifier. Update `calendar_screen.dart`.

**XC3. Error boundaries: not implemented** (Critical)
- See A2. `ErrorBoundary` is decorative; `FlutterError.onError` / `ErrorWidget.builder` are not set.

**XC4. Centralized API + rate limiting: implemented but not used** (Critical)
- See A1.

**XC5. Logging: zero** (High)
- See CQ4.

**XC6. Push notifications: device-token + preferences code exists but no FCM** (Medium)
- Location: `notification_service.dart:14-43` `registerDeviceToken` is invoked by … nothing. `grep -rn 'registerDeviceToken' apps/mobile/lib/` → only the definition. The file's own comment (line 4) says "In a full production app, this integrates with Firebase Cloud Messaging." That integration is not present (`grep -rn 'firebase_messaging\|firebase_core' apps/mobile/lib/` → empty; pubspec doesn't include `firebase_messaging`).
- Suggested fix: Either implement FCM (add `firebase_messaging` + `firebase_core`, call `FirebaseMessaging.instance.getToken()` and pass to `registerDeviceToken` in `main.dart`) or remove the device-token table writes since they accomplish nothing.

**XC7. Accessibility: scattered semantic labels, no `AppA11y` use** (Low)
- A few `Semantics` wrappers in `home_shell_screen.dart:167, 245`. Otherwise screens depend on default semantics. The good `AppA11y.iconButton` / `AccessibleCard` / `AccessibleStatusChip` widgets are unused (see CQ6).

**XC8. Localization: zero readiness** (Low)
- Hard-coded English everywhere. Days-of-week and month-name arrays hand-rolled in `meal_planner_screen.dart:283`, `calendar_screen.dart:275, 403-404`, `chore_detail_screen.dart`, etc. `intl` declared but unused.

### Testing & Tooling

**TT1. `analysis_options.yaml` is absent** (Critical)
- `find apps/mobile -name 'analysis_options.yaml'` → no matches.
- `flutter_lints` declared in dev-deps but never activated. Lints like `use_build_context_synchronously`, `unawaited_futures`, `avoid_print`, `prefer_const_constructors`, `require_trailing_commas` are not enforced.
- Handoff doc confirms 178 issues from local `flutter analyze` — most could be auto-fixed once enabled, and FS1/FS2/FS4 categories surface for free.
- Suggested fix:
  ```yaml
  include: package:flutter_lints/flutter.yaml
  analyzer:
    language: { strict-casts: true, strict-inference: true, strict-raw-types: true }
    errors: { use_build_context_synchronously: error, unawaited_futures: error }
  linter:
    rules: { prefer_const_constructors: true, require_trailing_commas: true }
  ```

**TT2. Platform folders (`ios/`, `android/`, `web/`) absent** (Critical)
- `find apps/mobile -maxdepth 2 -type d` returns only `lib/`, `lib/screens/`, `lib/services/`, `lib/widgets/`, `lib/theme/`, and the build cache `.dart_tool/`.
- Handoff doc says the user has `flutter analyze` running locally and 178 issues — implying they have local platform setup elsewhere or are running in a worktree. But the committed app cannot be built by a fresh clone.
- Suggested fix: `cd apps/mobile && flutter create --platforms=ios,android .` Commit the platform folders.

**TT3. Zero tests** (High)
- `find apps/mobile -type d -name 'test'` → no matches. `flutter_test` is in dev-deps unused.
- Suggested fix: Once repositories exist (A4), unit-test them with a fake Supabase client. Add at least one smoke widget test per screen.

**TT4. `pubspec.lock` is now present on this branch — good** (resolved since v2)

**TT5. `.env` is declared as an asset but only `.env.example` is checked in** (Low)
- Builders will warn unless they create `.env` locally. Mentioned in the handoff doc as cleanup item.
- Suggested fix: Document the requirement in `.env.example` (with a leading comment), or remove `.env` from `assets:` and use `mergeWith:` in `dotenv.load` for dev defaults.

### Performance Signals

**P1. `home_shell_screen.dart` reloads household membership + members list + pinned-announcement on every realtime event** (Medium)
- Location: `_onPointsChanged` and `_onAnnouncementChanged` both call `_loadHouseholdInfo()` (lines 69-78), which is `~50-line` 3-query load.
- Suggested fix: Targeted reloads (just update the points balance instead of refetching everything). Or move state to a provider that auto-derives.

**P2. Activity feed runs 5 sequential queries (chores, achievements, points, redemptions, members) and merges client-side** (Medium)
- Location: `activity_feed_screen.dart:48-156`. Each is wrapped in its own try/catch (so a bad table reference silently produces empty results — this is how the schema drift in A6 stays hidden).
- Suggested fix: Build a single `get_household_activity_feed(p_household_id uuid, p_limit int)` RPC that returns a unified, sorted feed from one Postgres query.

**P3. Recipe list, household_stats, activity feed all do unbounded `select(*)` with no pagination** (Medium)
- Examples: `household_stats_screen.dart:64-110` loads every chore, every point_transaction, every meal plan, every shopping_item. `member_profile_screen.dart` loads 20 chores. Most will be fine in early use; the stats screen will get slow on active households.
- Suggested fix: Move aggregations server-side via `get_household_stats(p_household_id)` RPC; paginate listing endpoints.

**P4. `Image.network` re-downloads on every screen** (Medium — see FS5)

**P5. `_calculateStreak` in `household_stats_screen.dart` builds a Set of DateTime, sorts it, iterates** (Low)
- Fine for the limit-30 case it's invoked with. Worth keeping an eye on if the limit grows.

## Patterns Done Well

- **`RealtimeService` is correctly designed and wired.** Single channel per household, fan-out via 8 `ValueNotifier<int>`s, listeners added in `initState` and removed in `dispose` across 6 screens. The `subscribe` method is idempotent (`realtime_service.dart:28`).
- **`ActiveMemberService` is small, focused, and correctly used.** PIN-verified profile switching between adult and kid is implemented end-to-end (`home_shell_screen.dart:504-548`), with SHA-256 comparison and SharedPreferences persistence.
- **`AutomaticKeepAliveClientMixin` on the 5 tab screens** (`chore_dashboard_screen.dart:16`, `meal_planner_screen.dart:17`, `shopping_list_screen.dart:32`, `calendar_screen.dart:16`, `recipe_library_screen.dart:20`) preserves tab state correctly in the `IndexedStack`.
- **`Future.wait` for parallel reads** in `calendar_screen.dart:69-81`, `meal_planner_screen.dart:73-85`, `shopping_list_screen.dart:120-136`, `household_stats_screen.dart:64-110`.
- **`mounted` checks** are present in most async-then-setState paths (with the exceptions noted in FS4).
- **`Dismissible` swipe-to-delete** consistent across shopping items, meal plans, calendar events.
- **Splash screen → auth gate → onboarding/home** transition is reasonable for a prototype.
- **`FeatureTourService` + `FeatureTourOverlay`** is a well-formed first-run experience and is actually wired (`home_shell_screen.dart:139-142, 312-322`).
- **Image upload service** (`image_upload_service.dart`) is small, focused, used in `profile_screen.dart` and `recipe_detail_screen.dart`. Size check, MIME detection, both gallery and camera. Good.
- **`pubspec.lock` is now committed** on this branch.

## Out of Scope but Urgent

Belongs to Pass 2 but worth surfacing now:

- **Invite-code generation predictability** (CQ1) — both implementations are server-side-able and trivially brute-forceable as written.
- **PIN hashing strength** (CQ2) — SHA-256 with no salt over 4-6 digit input is recoverable in milliseconds by anyone with SELECT on `pin_hash`.
- **Non-atomic reward redemption** (CQ3) — lost-update + partial-failure both possible.
- **PostgREST `.or()` filter injection in search** (CQ21) — within-household scope but worth fixing.
- **Schema drift across screens** (A6) — several reads/writes target tables other screens don't use; some are likely runtime errors masked by `catch (_) {}`.
- **`late final _screens` reassignment in `home_shell_screen.dart`** (A8) — will throw `LateInitializationError` once any realtime event fires after first load. Tested only because dev sessions probably don't exercise it long enough.
- **Brief vs. reality gap**: the brief described services that exist in code but are not consumed (A1, A2, A3, CQ5, CQ6). If anyone is being told the app has offline, rate-limited, error-bounded behavior, that needs correcting before Pass 3.

## Recommended Fix Order

Ranked by ROI (impact ÷ effort):

1. **Add `analysis_options.yaml` + `flutter_lints` strict; fix surfaced errors** (TT1). Cost: half-day to a day. Closes FS1/FS2/FS4 wholesale and gets the 178 analyzer issues under control.
2. **Fix `home_shell_screen.dart` `late final _screens` bug** (A8). Cost: minutes. Prevents a guaranteed crash once realtime events fire.
3. **Fix invite-code generators** (CQ1). Cost: 30 minutes. Closes a brute-force vector. Pick one shared `_generateInviteCode()` using `Random.secure()`.
4. **Move PIN verification to a Postgres function** (CQ2). Cost: half a day. Real security improvement and removes `pin_hash` from client SELECT.
5. **Make reward redemption atomic via RPC** (CQ3). Cost: half a day. Prevents lost-update and partial-failure.
6. **Audit and consolidate schema references** (A6). Cost: 1-2 days. Pick canonical names; grep + fix; verify each affected screen loads/saves. Several features likely become functional that aren't today.
7. **Wire `ApiService` into one feature end-to-end as a pilot** (A1). Cost: 1-2 days. Establish the pattern; migrate the rest incrementally.
8. **Wire `OfflineService.performWrite` into shopping-list mutations as a pilot** (A3). Cost: 1-2 days. Delivers the offline-first claim for at least one screen.
9. **Set `FlutterError.onError`, `ErrorWidget.builder`, and `runZonedGuarded` in `main.dart`; add a logger** (A2, CQ4, CQ5). Cost: half a day. Makes production diagnosable.
10. **Adopt `go_router` (or remove it from pubspec)** (A9, A5). Cost: half a day. Centralizes routing and auth gating.

## Metrics

- Findings by severity:
  - **Critical**: 9 (A1, A2, A3, A4, A6, CQ1, CQ2, TT1, TT2)
  - **High**: 8 (A5, A7, A8, CQ3, CQ4, CQ7, CQ8, CQ9, TT3, XC5)
  - **Medium**: 18 (A9, CQ5, CQ10, CQ11, CQ12, CQ13, CQ14, CQ15, CQ16, CQ22, FS3, FS4, FS5, FS8, XC2, XC6, P1, P2, P3, P4)
  - **Low**: 10 (A10, CQ6, CQ17, CQ18, CQ19, CQ20, FS1, FS2, FS6, FS7, XC7, XC8, TT5, P5)
- Files reviewed end-to-end: **45 / 45** (100%).
- Lines reviewed: **20,751 / 20,751**.
- Areas not assessed:
  - **Runtime behavior** — no Dart SDK in this environment; relying on the handoff's claim of 178 analyzer issues with no errors. Recommend a developer with the SDK run `flutter analyze` and `flutter build apk --debug` periodically — and especially test paths that exercise A8 (kill the app on a points/announcement realtime event after first load).
  - **RLS / Supabase policies / SQL** — explicitly out of scope (Pass 1b for `supabase/`, Pass 2 for security).
  - **iOS / Android platform code** — not present (TT2).
  - **`services/api/`, `apps/admin-dashboard/`** — Pass 1b.
