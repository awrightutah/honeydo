# PIN error surface fix — outcome

Date: 2026-05-22
Branch: `fix/pin-hashing-pass-2-2026-05-22` (unchanged)
Scope: Fix 1 from `/audits/2026-05-pin-set-error-silent-diag.md` only — surface the silent catch in two places. Fix 2/3/4 deferred per user instruction.
Status: edits applied to working tree, **not committed**, no branch change.

## Summary

Both PIN-flow catch blocks now print the exception and surface it in the user-facing SnackBar. Whatever Postgres error fires on the next iPhone run will be visible in the Flutter terminal AND in the on-device SnackBar.

No other code touched. No commits. Analyzer delta zero.

## Diffs

### Edit 1 — `apps/mobile/lib/screens/home_shell_screen.dart` (around line 651, inside `_promptToSetMissingPin`)

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

### Edit 2 — `apps/mobile/lib/screens/members_screen.dart` (around line 445, inside `_createSubProfile`)

```diff
     } catch (e) {
+      debugPrint('create sub_profile failed: $e');
       if (mounted) {
         ScaffoldMessenger.of(context).showSnackBar(
-          const SnackBar(content: Text('Could not create kid profile. Please try again.')),
+          SnackBar(content: Text('Could not create kid profile: $e')),
         );
       }
     } finally {
```

## Analyzer deltas

| | Total | Errors |
|---|---|---|
| Baseline (pre-edit) | 333 | 1 (unrelated `MyApp` test) |
| After both edits | 333 | 1 (same one) |

Net: **0**. `debugPrint` is exported by `package:flutter/material.dart` (already imported in both files), so no new imports needed. The SnackBar widgets lose their `const` modifier because the message Text now interpolates a runtime value; the analyzer is fine with that.

## What changed in behavior

- The Set-PIN flow's silent `catch (_)` becomes `catch (e)` and now (a) prints `set_member_pin failed: <PostgrestException or other>` to the Flutter terminal via `debugPrint`, and (b) shows the same exception text in the on-device SnackBar.
- The Add-Kid-Profile flow's `catch (e)` (which already bound `e` but ignored it) now uses it the same way — terminal print + SnackBar interpolation.
- No business logic changed. No try-catch boundaries moved. The success paths are untouched.

## What this surfaces

After applying this, run the iPhone build and reproduce the path that triggered the silent SnackBar before. The next message will show one of:

- `PostgrestException(message: 'Only household admins can set member PINs', code: 'P0001', ...)` — my top suspect from the diagnostic. If so, the root cause is the calling adult's `role` not being `'owner'` or `'admin'` on `household_members`, and Fix 2 (deferred) would patch `household_setup_screen.dart`'s adult insert.
- `PostgrestException(message: 'PINs can only be set for sub_profile members', ...)` — the target's `kind` isn't `sub_profile`.
- `PostgrestException(message: 'PIN must be 4 to 6 digits', ...)` — input validation failed server-side (unlikely with client-side validation, but possible from autofill/paste).
- `PostgrestException(message: 'Member not found', ...)` — stale member list.
- Some unanticipated Postgres or transport error — diagnose from the text directly.

## Followups still open from the diagnostic (NOT applied here)

- **Fix 2**: address the actual root cause once we see the error.
- **Fix 3**: project-wide `catch (_)` cleanup in `offline_service.dart` (9 spots) and `home_shell_screen.dart:_loadHouseholdInfo` (3 spots).
- **Fix 4**: wrap the unguarded `has_member_pin` / `verify_member_pin` calls in `_verifyAndSwitchToKid`.

## What to do next

1. `flutter run -d Andrew` on the iPhone (`flutter clean` isn't needed for these edits since no native/pubspec/migration changes).
2. Repeat the path that triggered "Could not set PIN" (open profile switcher → tap kid → enter PIN → Set PIN).
3. Paste the new SnackBar text or terminal `debugPrint` line back here.
4. I'll write Fix 2 against the actual error.

## Git state

```
$ git status --short
M apps/mobile/lib/screens/home_shell_screen.dart
M apps/mobile/lib/screens/members_screen.dart
?? audits/2026-05-pin-error-surface-fix.md
?? audits/2026-05-pin-set-error-silent-diag.md
```

Diagnostic file from the previous step is also still untracked. Neither will be committed until you give the word.
