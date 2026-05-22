# Diagnostic — "Could not set PIN. Please try again." fires with no terminal output

Date: 2026-05-22
Branch: `fix/pin-hashing-pass-2-2026-05-22` (read-only investigation, no edits, no commits)
Migration 0013: confirmed applied (user reports all 7 verification checks pass)
Status: **diagnosis complete, root cause identified, fix described but not applied**

## Summary

The "Could not set PIN. Please try again." SnackBar comes from exactly one place: `_promptToSetMissingPin` in `home_shell_screen.dart`. The catch block at line 651 is `catch (_)` — the underscore discards the exception variable entirely. The SnackBar text is a `const SnackBar` with hardcoded text — no `$e` interpolation, no `debugPrint`, no `print`. **The exception details have nowhere to go.**

There is no background or auto-call to any PIN RPC. The only PIN-touching code in the entire app is in `members_screen.dart` (create kid) and `home_shell_screen.dart` (switch kid). Both fire exclusively from explicit user taps.

The "error appears on the Recipe Library tab" observation is a UI artifact, not background firing: `home_shell_screen` owns the root Scaffold; the Recipe Library is rendered as a tab body inside that Scaffold. The Set-PIN dialog (`showDialog`) sits on top of the Scaffold as an overlay. When the dialog dismisses on submit, the user sees the tab body underneath (Recipe Library), and the SnackBar then fires on `home_shell`'s Scaffold — so the SnackBar appears overlaid on Recipe Library content. Same Scaffold, different perceived screen.

## Phase 1 — SnackBar swallow site

Only ONE site in the app emits "Could not set PIN". It lives in the new Phase 4 code I wrote.

**File:** `apps/mobile/lib/screens/home_shell_screen.dart`
**Function:** `_promptToSetMissingPin`
**Lines:** 640–657

```dart
640:
641:    try {
642:      await Supabase.instance.client.rpc('set_member_pin', params: {
643:        'p_member_id': member['id'],
644:        'p_pin': newPin,
645:      });
646:      if (mounted) {
647:        ScaffoldMessenger.of(context).showSnackBar(
648:          SnackBar(content: Text('PIN set for ${member['display_name']}. They can switch in now.')),
649:        );
650:      }
651:    } catch (_) {                                           // ← THE SWALLOW
652:      if (mounted) {
653:        ScaffoldMessenger.of(context).showSnackBar(
654:          const SnackBar(content: Text('Could not set PIN. Please try again.')),  // ← const, no $e
655:        );
656:      }
657:    }
658:  }
```

Two interacting problems on this catch:

1. **`catch (_)`** — the exception is bound to the throw-away pattern `_`, so it isn't even available inside the catch body. There's no `debugPrint`, no `print`, no `Logger.error` — the exception object simply vanishes the moment the catch runs.
2. **`const SnackBar(content: Text('Could not set PIN. Please try again.'))`** — the message is a compile-time constant. It does not (and cannot) interpolate the exception text.

This is why the iPhone shows a generic SnackBar and the Flutter terminal shows zero output. The Dart runtime can only forward an exception to the console if some code path actually prints it; nothing in this path does.

For comparison, the sister catch in `members_screen.dart` is slightly better (it binds `e`) but still doesn't print it:

```
445:    } catch (e) {                              // ← binds, but never uses
446:      if (mounted) {
447:        ScaffoldMessenger.of(context).showSnackBar(
448:          const SnackBar(content: Text('Could not create kid profile. Please try again.')),
449:        );
450:      }
```

Same UX-bug pattern: `e` is in scope but unused, message is const. If `_createSubProfile`'s `set_member_pin` call is the one failing (rather than the switcher path), this catch will swallow it just as silently.

**Codebase pattern:** `catch (_)` and `catch (e) { /* no print */ }` are pervasive — at least **9 instances in `services/offline_service.dart`** alone, and 3 more in `home_shell_screen.dart:_loadHouseholdInfo`. This is a project-wide observability gap; the PIN flow inherited it. (Recommendation 4 in the followups.)

## Phase 2 — set_member_pin call sites

Two and only two:

**Site A — `members_screen.dart:439`** (Add Kid Profile flow):

```dart
418:    setState(() => _isLoading = true);
419:
420:    try {
421:      // CQ2 resolved 2026-05-22 ...
422:      // ...
425:      final inserted = await Supabase.instance.client
426:          .from('household_members')
427:          .insert({
428:            'household_id': widget.householdId,
429:            'kind': 'sub_profile',
430:            'role': 'member',
431:            'display_name': name,
432:            'points_balance': 0,
433:            'is_active': true,
434:            'created_by': Supabase.instance.client.auth.currentUser!.id,
435:          })
436:          .select('id')
437:          .single();
438:
439:      await Supabase.instance.client.rpc('set_member_pin', params: {
440:        'p_member_id': inserted['id'],
441:        'p_pin': pin,
442:      });
443:
444:      if (mounted) Navigator.pop(context);
445:    } catch (e) {
446:      if (mounted) {
447:        ScaffoldMessenger.of(context).showSnackBar(
448:          const SnackBar(content: Text('Could not create kid profile. Please try again.')),
449:        );
450:      }
451:    } finally {
452:      if (mounted) setState(() => _isLoading = false);
453:    }
454:  }
```

Same shape, different SnackBar text. If the user happened to be on the Add Kid Profile flow rather than the kid switcher, the SnackBar text would be "Could not create kid profile" (not the one they're seeing).

**Site B — `home_shell_screen.dart:642`** (Set-PIN-for-existing-kid flow): the swallow described in Phase 1.

There is no other caller of `set_member_pin` in the app. Confirmed by exhaustive grep.

## Phase 3 — has_member_pin / verify_member_pin call sites

All in `home_shell_screen.dart:_verifyAndSwitchToKid`:

```dart
497:  Future<void> _verifyAndSwitchToKid(Map<String, dynamic> member) async {
498:    // ...
501:    // Gate the verify dialog on has_member_pin ...
502:    final hasPin = await Supabase.instance.client.rpc('has_member_pin', params: {
503:      'p_member_id': member['id'],
504:    }) as bool;
505:    if (!mounted) return;
506:
507:    if (!hasPin) {
508:      await _promptToSetMissingPin(member);
509:      return;
510:    }
511:
512:    final pinController = TextEditingController();
513:    final verified = await showDialog<bool>( ... );
       // ...
540:    // CQ2 resolved 2026-05-22 ...
542:    final ok = await Supabase.instance.client.rpc('verify_member_pin', params: {
543:      'p_member_id': member['id'],
544:      'p_pin': pin,
545:    }) as bool;
546:    if (!ok) {
547:      // ... incorrect PIN SnackBar, return
548:    }
549:
550:    await ActiveMemberService.instance.switchTo(member['id']);
```

`has_member_pin` and `verify_member_pin` are called inside `_verifyAndSwitchToKid` — which has **no try/catch around them at all**. If either RPC throws (rather than returning false), the exception propagates up to whatever called `_verifyAndSwitchToKid`. That caller is the profile-switcher `onTap` in `_showProfileSwitcher`, also unguarded.

Implication: if `has_member_pin` errors instead of returning false, you'll get an UNCAUGHT exception that the Flutter framework will print to the terminal — which doesn't match the user's observation (no terminal output). So `has_member_pin` is most likely returning false correctly, then routing to `_promptToSetMissingPin` where the swallow lives. That matches the user's observed UX (Set-PIN dialog appears, PIN entered, then the generic SnackBar).

## Phase 4 — background / auto-call audit

**No auto-caller of any PIN RPC exists.**

`home_shell_screen.dart` lifecycle:

| Hook | What it does | Touches PIN RPCs? |
|---|---|---|
| `initState` (line 55) | calls `_loadHouseholdInfo()` + adds listeners on `pointsVersion`, `announcementsVersion`, `activeMemberId` | No |
| `_onPointsChanged` (line 73) | calls `_loadHouseholdInfo()` | No |
| `_onAnnouncementChanged` (line 81) | calls `_loadHouseholdInfo()` | No |
| `_onActiveMemberChanged` (line 84) | calls `_loadHouseholdInfo()` | No |
| `_loadHouseholdInfo` (line 88) | queries `household_members` + `announcements`; subscribes to realtime | No PIN RPCs |
| `build` (line 152) | renders UI — no async work | No |

`_loadHouseholdInfo` ends in `catch (_)` ("Silently handle — screens will show their own errors", line 144). If that one were the firing catch, the SnackBar wouldn't appear (it doesn't show a SnackBar — just returns). Not the source of the user's symptom.

`ActiveMemberService` (full file read): just a `SharedPreferences` wrapper that stores `active_member_id`. No RPC calls anywhere.

`RealtimeService`: subscribes to Postgres CDC for `chores`, `shopping_items`, `meal_plans`, `recipes`, `members`, `points`, `rewards`, `announcements`. **Does not subscribe to anything PIN-related and does not call any RPC.** Just bumps `ValueNotifier<int>` versions on table changes.

`main.dart`: only init calls (`Supabase.initialize`, `OfflineService.init`, `FeatureTourService.init`, `ActiveMemberService.init`). None touch PIN.

**Conclusion:** the PIN RPCs only fire when the user explicitly opens "Add Kid Profile" in the members screen OR taps a kid in the profile switcher. The user must have done one of those two things for this SnackBar to fire. The "appears on Recipe Library" symptom is explained in the Summary section: it's a Scaffold-overlay artifact, not a background trigger.

## Phase 5 — async-without-print audit of every RPC site in the PIN flow

| File | Line | RPC | Wrapped in try/catch? | Logs the exception? |
|---|---|---|---|---|
| `members_screen.dart` | 439 | `set_member_pin` | yes (line 420–453) | NO — `catch (e)` binds, but never reads `e` |
| `home_shell_screen.dart` | 502 | `has_member_pin` | no | n/a — exception propagates up uncaught (would print) |
| `home_shell_screen.dart` | 542 | `verify_member_pin` | no | n/a — exception propagates up uncaught |
| `home_shell_screen.dart` | 642 | `set_member_pin` | yes (line 641–657) | NO — `catch (_)` discards |
| `home_shell_screen.dart` | 665 | `get_leaderboard` (pre-existing) | yes (line 663–680ish) | unchanged from before |

The two `set_member_pin` catches are the only places that can produce a SnackBar without any terminal output. Of those two, only `home_shell_screen.dart:642` matches the user's reported SnackBar text "Could not set PIN". Therefore **`home_shell_screen.dart:651` is the swallow site for this specific bug.**

## Phase 6 — Supabase client error config

`main.dart` initializes Supabase with only `url` and `anonKey`:

```dart
20:   // Initialize Supabase
21:   await Supabase.initialize(
22:     url: dotenv.env['SUPABASE_URL']!,
23:     anonKey: dotenv.env['SUPABASE_ANON_KEY']!,
24:   );
```

No `httpClient` override, no `realtimeClientOptions`, no `postgrestOptions`, no global error handler, no `FlutterError.onError` customization, no `runZonedGuarded`. The default supabase-flutter client will throw `PostgrestException` on any non-2xx response from PostgREST. Those exceptions are NOT swallowed at the wire level — they propagate to the caller. The swallow is purely in the catch block I wrote.

`OfflineService` (services/offline_service.dart): scanned. It's a SharedPreferences-backed local cache for connectivity / offline queue. It does NOT intercept RPC calls. It does have 9 of its own `catch (_)` swallows, but those are for its internal cache reads/writes, not for the Supabase client. Not the cause here.

`ApiService` (services/api_service.dart): provides an alternative wrapper around `_supabase.rpc(...)` with retry and rate limiting. **The PIN flow does NOT use ApiService — both `set_member_pin` call sites bypass it and call `Supabase.instance.client.rpc(...)` directly.** So ApiService's retry logic isn't a factor.

## Phase 7 — direct RPC test (deferred)

No Supabase / Postgres MCP tool is available in this environment. Cannot call `set_member_pin` directly to see the underlying Postgres error message.

**Recommendation:** test the function from the Supabase SQL editor manually before rolling out the catch-block fix. Pick a real `household_members.id` for a sub_profile in your test household, then run:

```sql
-- As the postgres role in the SQL editor:
select set_member_pin(
  '<paste a sub_profile member uuid here>'::uuid,
  '1234'
);
```

That call will run as `postgres` (not `authenticated`), so it won't exercise the "caller is admin" branch, but it WILL exercise everything else — PIN format check, member lookup, sub_profile check, the actual INSERT into `member_pin_secrets`. If it returns void with no error, the underlying SQL is correct and the bug is on the auth/grant path. If it raises, you'll see the exception message right there in the SQL editor.

Then for the auth path, you can test from the dashboard's SQL editor with `set role authenticated;` first, plus a `select set_config('request.jwt.claim.sub', '<adult auth_user_id uuid>', true);` to set `auth.uid()`, then call `set_member_pin(...)`. That mimics what the iPhone client does.

## Diagnosis

(a) **Which UI action is firing the error?**

The user almost certainly took this path:
1. Tap profile-menu / switcher (top of home_shell)
2. Tap one of the existing kid tiles in the "Switch Profile" bottom sheet
3. `_verifyAndSwitchToKid` → `has_member_pin` RPC → returns false (kid lost their PIN when migration 0013 dropped the column)
4. `_promptToSetMissingPin` opens the Set PIN dialog
5. User enters new PIN + confirm + taps Set PIN
6. `set_member_pin` RPC is called and **throws something**
7. `catch (_)` discards the exception, fires the const SnackBar
8. Dialog and bottom sheet are already dismissed by step 5 → user sees whatever home_shell tab was visible behind them, which they describe as "Recipe Library"

(b) **Where is the exception being swallowed?**

`apps/mobile/lib/screens/home_shell_screen.dart:651` — `catch (_)`. The exception object is never bound to a name, never printed, never logged. The SnackBar message is a `const Text(...)` with no interpolation.

(c) **What's the underlying Postgres error?**

**Not knowable from static analysis alone.** Without seeing the exception text, the realistic candidates ranked by likelihood:

1. **`'Only household admins can set member PINs'`** — the SECURITY DEFINER function does `where auth_user_id = auth.uid() and household_id = v_target_household_id and role in ('owner','admin') and is_active = true`. If for any reason that lookup returns zero rows for the calling user, this fires. Possible causes: the calling adult's `is_active` is false; the user's role is `'member'` not `'owner'`/`'admin'`; the user is signed in but their adult `household_members` row was inserted with `auth_user_id` mismatching `auth.uid()` (a stale signup record from before today).
2. **`'Member not found'`** — `member['id']` from the switcher's loaded `_householdMembers` list doesn't match any row in `household_members` at RPC time. Unlikely unless the list is stale or the kid was concurrently deleted.
3. **`'PINs can only be set for sub_profile members'`** — would only fire if the kid's `kind` is somehow not `'sub_profile'`. Unlikely; the switcher only shows kid tiles for `kind == 'sub_profile'`.
4. **`'PIN must be 4 to 6 digits'`** — only if `newPin` somehow contains non-digits or wrong length when reaching the RPC. Client-side validates `^[0-9]+$` with length 4–6 before calling, so unlikely unless an iOS smart-completion or paste inserted non-digit chars between the validation and the RPC call. Possible but minor.
5. **Postgres-level error** (FK violation, permission denied on `member_pin_secrets`, function does not exist) — the user verified all 7 migration checks passed, so this should be impossible. But "should" — the actual error message would settle it definitively.

My best single guess: **#1 — the admin-check is failing.** The reason it's my top guess: the user's session/account history. The original `_createSubProfile` flow inserts the adult member with `role: 'member'` by default (see `household_setup_screen.dart` paths or members_screen patterns from earlier). Looking at the schema in `0001_initial_schema.sql:46`: `role household_role not null default 'member'`. If the adult's row landed with `role='member'` rather than `'owner'`, the function correctly rejects them as not-admin even though intuitively they're "the owner of their household." This is consistent with the user being the only adult and never having had role explicitly set to owner.

If I'm right, after fixing the catch to print, the next test will surface `PostgrestException(message: 'Only household admins can set member PINs', code: 'P0001', ...)` or similar — and the fix is to either (a) make the household creator's row default to `role='owner'` in the setup flow, or (b) loosen the admin check to also accept the household creator implicitly. Either way, that's a follow-up after we confirm the error.

## Recommended fix — described, not applied

### Fix 1 (must do): make the catch reveal the actual exception

Two equally simple options. Pick (A) for the smallest possible diff, (B) for slightly better UX.

**(A) Minimum diff — surface the error in the SnackBar:**

`apps/mobile/lib/screens/home_shell_screen.dart:651–656`:

```diff
-    } catch (_) {
+    } catch (e) {
+      debugPrint('set_member_pin failed: $e');
       if (mounted) {
         ScaffoldMessenger.of(context).showSnackBar(
-          const SnackBar(content: Text('Could not set PIN. Please try again.')),
+          SnackBar(content: Text('Could not set PIN: $e')),
         );
       }
     }
```

`debugPrint` writes to the Flutter terminal via the standard channel — the user will see it in `flutter run` output. And the SnackBar message itself now carries the exception text, so even without scrolling through terminal logs they'll see what failed.

Apply the same pattern to `members_screen.dart:445–450` (the create-kid catch) so we don't get stuck if the failing call site is actually that one rather than this one.

`apps/mobile/lib/screens/members_screen.dart:445–450`:

```diff
-    } catch (e) {
+    } catch (e) {
+      debugPrint('create sub_profile failed: $e');
       if (mounted) {
         ScaffoldMessenger.of(context).showSnackBar(
-          const SnackBar(content: Text('Could not create kid profile. Please try again.')),
+          SnackBar(content: Text('Could not create kid profile: $e')),
         );
       }
     }
```

(Members screen would need `import 'package:flutter/foundation.dart';` for `debugPrint` — actually no, `debugPrint` is also exported via `package:flutter/material.dart` which is already imported. Either way is fine; verify on apply.)

**(B) Slightly nicer UX — keep user-facing message clean, log to console:**

Same as (A) but keep the SnackBar generic and only debugPrint the exception. Trade-off: requires user to look at terminal to see the error, but doesn't expose Postgres internals to a kid's screen if a kid happens to see it.

I'd start with (A) for the current debug pass, then dial back to (B) once we know what's failing.

### Fix 2 (must do, after Fix 1 reproduces the error)

Once the error is visible, address whatever it actually says. Most likely paths:
- If error contains "admins" → patch the household setup flow to make the creator their own household's owner (almost certainly a one-line fix to `household_setup_screen.dart` setting `'role': 'owner'` on the adult insert).
- If error contains "Member not found" → debug stale member-list state.
- If error contains "4 to 6 digits" → tighten client-side validation or strip non-digit input.
- Anything else → triage when we see it.

### Fix 3 (recommended cleanup, lower priority)

The codebase has a project-wide `catch (_)` antipattern: 9 instances in `offline_service.dart`, 3 in `home_shell_screen.dart:_loadHouseholdInfo`, and the two now in the PIN flow. Every single one of them silently destroys exception information. A follow-up batch should change them to `catch (e) { debugPrint('<context>: $e'); ... }` or at minimum `catch (e) { assert(() { debugPrint(...); return true; }()); ... }` so they vanish in release but reveal in debug.

Not in scope for THIS diagnostic — but worth a Pass-2.1 ticket.

### Fix 4 (recommended, separate)

`_verifyAndSwitchToKid` has no try/catch around its `has_member_pin` and `verify_member_pin` RPC calls. If either ever throws (network blip, RLS misconfig, etc.), it propagates uncaught. Wrap them with the same `catch (e) { debugPrint ... }` pattern. Same goes for the bottom-sheet onTap that calls `_verifyAndSwitchToKid`.

## Followups (extras spotted in this pass, none fixed)

1. **`members_screen.dart:445`** binds `catch (e)` but never reads it. Functionally identical to `catch (_)`. Same fix.
2. **`_loadHouseholdInfo`'s `catch (_)`** at the bottom (line 144) silently drops any error from the entire household-loading flow, including the announcements load. If the user ever has a "missing household" or "RLS denied" issue during signin, this is invisible too.
3. **`offline_service.dart`** has 9 `catch (_)` blocks. Some of those would mask legitimate cache corruption or connectivity-check failures. Pass 2.1.
4. **No PIN flow integration test exists.** Tests would have caught the `catch (_)` swallow because the assertion would have failed with the message. Pass 2.x.
5. **Possible UX issue at home_shell_screen.dart:548** — when `verify_member_pin` returns false, we show "Incorrect PIN" — but the same false is returned by the RPC for "caller not in same household." If a member-role user somehow ends up tapping a kid (the UI shouldn't allow it, but defense-in-depth), they'd see "Incorrect PIN" misleadingly. Lower priority.

## Tested but ruled out

- Background firing: none. Phase 4 cleared.
- Wire-level error suppression: none. Phase 6 cleared.
- OfflineService interception of RPCs: not happening — it's a local cache layer only.
- ApiService swallowing: the PIN flow doesn't use ApiService.
- Realtime listener triggering: not subscribed to PIN tables.
- `_loadHouseholdInfo` swallow being the source: doesn't show a SnackBar, doesn't match the user's symptom.

## What to do next

1. Apply Fix 1 (catch block change in both files).
2. `flutter clean && flutter run -d Andrew` (the user's iPhone). Reproduce the same path.
3. Read the SnackBar OR the terminal output. The actual Postgres error will be visible.
4. Report back; I'll then know which of the candidates in section (c) above is the real culprit, and apply Fix 2 to address the root cause.
