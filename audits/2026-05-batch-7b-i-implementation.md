# Batch 7b-i — Polish Bundle (4 Tiny Fixes)

Date: 2026-05-26
Branch: `feat/ui-hardening-batch-7b-2026-05-26`
Status: **changes uncommitted** — user reviews then commits

## Summary

Four independent bug fixes / UI-honesty improvements surfaced during 7a + 8.1 smoke tests, bundled because each is too small to warrant its own commit. (1) A latent `TextEditingController` dispose-after-pop crash in `shopping_category_screen.dart`'s "Add Category" dialog — same pattern as the `reject_reason_dialog` fix from Batch 5b-i. (2) A mid-sheet race in `settings_screen.dart`'s edit-profile flow that would write to whichever member was active *at Save time* rather than at sheet-open time. (3) The Chore Templates entry in `home_shell`'s popup menu was visible to kids even though the screen rejects their writes. (4) The Add Chore affordances on `chore_dashboard_screen.dart` (both the AppBar action and the bottom-right FAB) were visible to kids even though RLS rejects kid INSERTs.

No migrations, no RPCs, no new dependencies. Net **~+49 LOC** (most of which is the new `_AddCategoryDialog` StatefulWidget extracted from inline `showDialog`).

## Files modified

| File | Net LOC | Fix |
|---|---|---|
| `apps/mobile/lib/screens/shopping_category_screen.dart` | +49 | Extract dialog body to new `_AddCategoryDialog` StatefulWidget; State owns controller lifecycle. |
| `apps/mobile/lib/screens/settings_screen.dart` | +9 | Capture `member_id` as closure variable on sheet open; Save handler reads captured value instead of live `_myMembership`. |
| `apps/mobile/lib/screens/home_shell_screen.dart` | +5 | Wrap the `'templates'` PopupMenuItem in `if (Permissions.isAdmin(_myMembership))`. |
| `apps/mobile/lib/screens/chore_dashboard_screen.dart` | +6 | Both the AppBar add-chore IconButton and the bottom-right `FloatingActionButton.extended` now gated on `Permissions.isAdmin(_myMembership)`. |
| **Total** | **~+49 LOC net** | |

## Phase 1 — `shopping_category_screen.dart` dispose bug

### Root cause

`_addCustomCategory` (pre-fix lines 99-128) created a `TextEditingController` as a local variable, opened a `showDialog` using it, then called `controller.dispose()` synchronously right after `await showDialog(...)` returned:

```dart
Future<void> _addCustomCategory() async {
  final controller = TextEditingController();
  final result = await showDialog<String>(...);   // returns when Navigator.pop fires
  controller.dispose();                            // BUG: runs before dismissal animation completes
  if (result != null && result.isNotEmpty) {
    ...
  }
}
```

`showDialog` returns when `Navigator.pop` is called — but the dismissal animation is still running at that moment. The `TextFormField` continues to rebuild against the now-disposed controller during the animation frame, throwing `TextEditingController used after being disposed` and cascading into a `_dependents.isEmpty` assertion. Same exact bug pattern as `reject_reason_dialog` had pre-Batch-5b-i.

### Fix

Extracted the AlertDialog body into a new private `_AddCategoryDialog extends StatefulWidget` at the bottom of the file. The State class owns the controller and disposes it in its own `dispose()` — which fires *after* the widget tree fully unmounts (post-animation), so the TextField never rebuilds against a disposed controller.

The call site shrinks from 30 LOC to 6:

```dart
final result = await showDialog<String>(
  context: context,
  builder: (_) => const _AddCategoryDialog(),
);
if (result != null && result.isNotEmpty) {
  ...
}
```

New `_AddCategoryDialog` widget (52 LOC) at the bottom of the file, mirrors the structure of `reject_reason_dialog.dart`'s `_RejectReasonDialog`. Returns the trimmed text via `Navigator.pop(context, _controller.text.trim())` on Add tap; `null` on Cancel.

### LOC delta

`shopping_category_screen.dart`: +49 LOC net (added ~52 in new widget; removed ~3 from inline controller management). The dialog UX is identical — only the lifecycle is corrected.

## Phase 2 — `settings_screen.dart` edit-profile sheet race

### Root cause

`_showEditProfileSheet` at line 152 created a local `nameController` from `_myMembership?['display_name']` at sheet-open time, then the Save handler at line 192 (pre-fix) read `_myMembership!['id']` again *at save time*:

```dart
.eq('id', _myMembership!['id']);
```

If the active member changed between open and Save (admin opens edit-profile sheet → switches to Randi via the baby-icon profile-switcher → returns to sheet → taps Save), the `.eq('id', _myMembership!['id'])` would resolve to Randi's id, writing the admin's typed display name to Randi's row.

This race was masked pre-7a-i because `_myMembership` always coerced to the parent admin (legacy `.eq('auth_user_id')` bug). After the 7a-i MembershipHelper migration, `_myMembership` correctly reflects the active member — exposing this race.

### Fix

Capture `_myMembership['id']` as a closure variable when the sheet opens. The Save handler reads the captured id instead of the live `_myMembership`:

```dart
Future<void> _showEditProfileSheet() async {
  // Capture at sheet-open time, NOT at Save time.
  final capturedMemberId = _myMembership!['id'] as String;
  final nameController = TextEditingController(text: _myMembership?['display_name'] ?? '');
  // ... showModalBottomSheet with Save handler using `capturedMemberId`:
  //     .eq('id', capturedMemberId);
}
```

The fix is 2 added LOC (the capture variable) + 1 changed LOC (the `.eq` argument). Plus a comment explaining the race.

### Known followup (not in scope here)

`nameController` is created locally in `_showEditProfileSheet` but never disposed — same class of latent bug as Phase 1 above, applied to the bottom sheet flow. Not crashing today (no dispose call, so no "used after disposed" — but the controller does leak per sheet open). Lower priority than the data-corruption race fixed here; flag for a future polish item.

### LOC delta

`settings_screen.dart`: +9 LOC net (capture + comment + the trivial `.eq` swap).

## Phase 3 — Chore Templates menu entry admin gate

### Root cause

`home_shell_screen.dart:374` (pre-fix) declared the `'templates'` PopupMenuItem unconditionally in `itemBuilder`:

```dart
const PopupMenuItem(value: 'templates', child: ...),
```

Kids saw "Chore Templates" in the household popup menu. Tapping it would land them on `ChoreTemplatesScreen` — which, post-7a-i migration, is correctly admin-aware on its own, but the menu entry itself was still visible. UI dishonesty: showing an affordance that the kid can navigate to but not productively use.

### Fix

Wrap the menu item in a collection-`if`:

```dart
if (Permissions.isAdmin(_myMembership))
  const PopupMenuItem(value: 'templates', child: ...),
```

The list returned from `itemBuilder` isn't const (it's a runtime list), so the collection-if works fine. The PopupMenuItem itself stays `const`. The `_handleMenuAction` `case 'templates':` handler is left in place as defense-in-depth.

### LOC delta

`home_shell_screen.dart`: +5 LOC (the `if` line + a 3-line comment explaining the gate).

## Phase 4 — Add Chore FAB admin gate on `chore_dashboard`

### Root cause

Two affordances on the Chores tab let kids initiate chore creation:

1. **AppBar IconButton** (line 292-296 pre-fix): a `Icons.add_circle_outline_rounded` action gated only on `_household != null` — visible to kids.
2. **Bottom-right `FloatingActionButton.extended`** (line 390-396 pre-fix): same `_household != null` gate — visible to kids.

RLS catches kid INSERTs to the `chores` table, but the affordances shouldn't be visible at all. Same UI-honesty principle as the chore_templates menu fix.

The bottom-left music FAB (added in Batch 8.1) is kid-gated and unaffected by this change.

### Fix

Both affordances now also gate on `Permissions.isAdmin(_myMembership)`:

```dart
// AppBar action:
if (_household != null && Permissions.isAdmin(_myMembership))
  IconButton(...)

// Bottom-right FAB:
floatingActionButton:
    (_household != null && Permissions.isAdmin(_myMembership))
        ? FloatingActionButton.extended(...)
        : null,
```

`Permissions` is already imported in this file (line 10 from earlier work).

### LOC delta

`chore_dashboard_screen.dart`: +6 LOC net (the conditional + comment lines).

## Analyzer

| | Issues | Errors |
|---|---|---|
| Before | 367 | 1 (pre-existing `MyApp` test) |
| After | **367** | 1 (same) |
| **Net** | **0** | **0** |

Zero new info / warning / error across all 4 touched files. The new `_AddCategoryDialog` widget was written without any `withOpacity` or untyped `.rpc()` calls.

## iPhone smoke test checklist (4 paths, one per fix)

1. **shopping_category_screen dispose bug**: open shopping list → tap a category to open `ShoppingCategoryScreen` → tap "Add custom category" → dialog opens → type some text → tap Cancel **OR** tap Add. Dialog dismisses smoothly. No "TextEditingController used after being disposed" assertion. No `_dependents.isEmpty` crash. Open the dialog several times in succession — no controller-leak / no crash.

2. **settings_screen edit-profile sheet race**: as admin, open Settings → tap "Edit Profile" → bottom sheet opens with admin's name pre-filled → **without closing the sheet**, switch active profile to Randi via the household popup menu's "Switch Profile" (or the baby icon on home_shell if there is one) → return to the still-open sheet → type a new display name → tap Save. **SQL verify**: `select display_name from household_members where id = <admin_id>` → contains the new name. Randi's row unchanged.

3. **chore_templates menu entry**: as Randi (kid active), open the household popup menu (`⋯` icon top-right of home_shell) → scroll the menu. "Chore Templates" should NOT appear. Switch to admin → reopen the menu. "Chore Templates" visible. Tap → opens the screen.

4. **Add Chore FAB**: as Randi on the Chores tab → no AppBar `+` action, no bottom-right "Add Chore" FAB. Bottom-left music FAB still visible (Batch 8.1, kid-gated separately). Switch to admin → both Add Chore affordances reappear; music FAB disappears.

## Known followups (carried forward + 1 new)

- **`settings_screen` `nameController` lifecycle** (new this batch): the bottom-sheet's controller is never disposed. Same class of bug as the shopping_category dispose issue but on a sheet instead of a dialog. Not crashing today (no `.dispose()` call means no "used after disposed"); just leaks one controller per sheet open. Lower priority than the race fixed here. Future polish.
- **Codebase-wide `withOpacity` → `withValues` sweep** (carry-forward 7b-ii candidate).
- **Active-member identity indicator** (carry-forward 7b-iii candidate).
- **Batch 6c-i**: notification_service.dart + APNs foundation.
- **Batch 6c-iii**: notification_preferences_screen.dart + schema reconcile.
- **Batch 9** (new from 7a-i): kid redemption requests via Approvals dashboard.

## What this batch deliberately did NOT include

- No `withOpacity` deprecation sweeps (7b-ii territory).
- No active-member identity indicator (7b-iii territory).
- No `settings_screen.dart` controller-dispose refactor (flagged above for future).
- No new RPCs or migrations.
- No widget extraction beyond what Phase 1 required.

## Next steps (for the user)

1. Review the 4 modified files.
2. Rebuild iOS on this branch (hot restart suffices; no Info.plist change).
3. Run through the 4 smoke paths above. Particular attention to:
   - Path 1: open the Add Category dialog several times in succession — confirm no crash.
   - Path 2: SQL cross-check on admin's row vs Randi's.
4. Commit as a single commit on `feat/ui-hardening-batch-7b-2026-05-26`.
5. Push when ready.
