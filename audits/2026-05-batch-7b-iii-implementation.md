# Batch 7b-iii — Active Member Identity Indicator

Date: 2026-05-26
Branch: `feat/ui-hardening-batch-7b-2026-05-26`
Status: **changes uncommitted** — user reviews then commits

## Summary

Replaces the prior baby/switch-account IconButton on `home_shell_screen`'s AppBar with a richer **avatar + first-name indicator** that's always visible across all main tabs. Parent helping their kid can now tell at a glance which profile is operating — previously only the points-badge number changed when the active member switched, which was easy to miss. Avatar source priority: `household_members.avatar_url` if set, otherwise the first letter of `display_name` in a colored circle. Same tap handler as before (`_showProfileSwitcher`), so the profile-switcher menu is unchanged.

One file modified. No new dependencies, no migrations.

## Files modified

| File | Net LOC | What |
|---|---|---|
| `apps/mobile/lib/screens/home_shell_screen.dart` | +85 / -5 net **+80** | Removed baby IconButton; added `_buildActiveMemberIndicator()` widget + `_firstName()` + `_firstLetter()` helpers. |

## Per-phase highlights

### Phase 1 — Locate the prior baby icon

Found at `home_shell_screen.dart:329-333`:
```dart
IconButton(
  icon: Icon(_myMembership?['kind'] == 'sub_profile' ? Icons.child_care_rounded : Icons.switch_account_rounded),
  onPressed: _showProfileSwitcher,
  tooltip: 'Switch profile',
),
```

Conditional icon (baby vs switch-account) based on active member's `kind`. Tap → `_showProfileSwitcher`. That handler is reused unchanged.

### Phase 2 — New indicator widget

Replaced the IconButton with a single call to `_buildActiveMemberIndicator()`. The method renders:

```dart
InkWell(
  onTap: _showProfileSwitcher,
  borderRadius: BorderRadius.circular(20),
  child: Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      CircleAvatar(
        radius: 16,                                // 32px diameter
        backgroundColor: AppColors.honeyGold,
        backgroundImage: hasAvatar ? NetworkImage(avatarUrl) : null,
        child: hasAvatar ? null : Text(firstLetter, ...),  // initials fallback
      ),
      const SizedBox(width: 6),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 80),
        child: Text(
          firstName,
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
    ],
  ),
)
```

`maxWidth: 80` on the text constraint enforces ellipsis behavior on long first names so the indicator doesn't push the AppBar's title into an over-truncated state.

### Phase 3 — Helpers

Both are small, side-effect-free pure functions on the membership map:

- **`_firstName(membership)`**: splits `display_name` on whitespace, takes the first token. `'Andrew Wright'` → `'Andrew'`. Single-word names stay as-is. Empty/null → `'?'`.
- **`_firstLetter(membership)`**: first character of `display_name`, uppercased. `'andrew'` → `'A'`. Empty/null → `'?'`.

Both accept `Map<String, dynamic>?` so they're safe to call before `_myMembership` resolves on first frame.

### Phase 4 — Replace in actions array

Single-line replacement in the AppBar `actions` array preserved the surrounding widgets (points badge before, search icon after, approvals badge for admin after that, popup menu last). Position unchanged.

### Phase 5 — Space fit check

The new indicator is wider than the old IconButton (~88px max vs ~48px for the icon), so the actions strip grew by ~40px. On a 390px-wide iPhone (15 mainline):

| Actions side | Approx width |
|---|---|
| Points badge | ~60px |
| Active member indicator (this batch) | ~88px max (with `maxWidth: 80` on name) |
| Search icon | ~48px |
| Approvals badge (admin only) | ~48px |
| Popup menu | ~48px |
| **Total (admin)** | **~292px** |
| **Total (kid)** | **~244px** |

That leaves ~98–146px for the AppBar title ("🐝 Wrights"). The title already uses `overflow: TextOverflow.ellipsis` on the household name, so longer household names will ellipsis. For "Wrights" (7 chars + emoji) the title fits cleanly. **No drastic redesign needed.**

### Notes on the avatar URL edge case

`CircleAvatar.backgroundImage` doesn't have an inline error fallback — if `NetworkImage` fails to load (invalid URL, network error, 404), the circle renders honey-gold with no initials underneath. This is a known limitation of `CircleAvatar` and isn't fatal: the indicator stays tappable and the colored background still visually distinguishes profiles. For users whose avatar URL works, no problem. For users with invalid URLs, the visual is "plain honey-gold circle" rather than "initials" — odd but not broken. **Flagged as a polish followup** if it becomes annoying in practice.

A more robust pattern would wrap `Image.network` with an `errorBuilder` inside a `ClipOval`, but that's more LOC and the current behavior is acceptable for v1.

## Analyzer

| | Issues | Errors |
|---|---|---|
| Before (7b-ii baseline) | 229 | 1 (pre-existing `MyApp` test) |
| After | **229** | 1 (same) |
| **Net** | **0** | **0** |

Zero new info, warning, or error on the touched file. The new widget was written without `withOpacity` calls (uses the post-7b-ii pattern by default) and without untyped framework calls.

## iPhone smoke test checklist

1. **As admin (Andrew, no avatar set yet)**: AppBar shows honey-gold circle with white "A" + text "Andrew". Position to the right of the points badge, before the search icon.
2. **As Randi (kid sub_profile)**: AppBar shows whatever avatar she has (or 'R' initial in honey-gold circle) + text "Randi".
3. **As Sonny (or other kid with an `avatar_url`)**: AppBar shows the loaded avatar image + first name.
4. **Tap the indicator** → profile switcher opens (same modal as the prior baby icon). Tap a member to switch.
5. **Active member switch** → AppBar updates immediately (no need to leave the screen). Avatar swaps, name swaps, points badge also swaps (existing behavior).
6. **No-avatar member** → initials circle renders, not a broken-image placeholder.
7. **Long display name (e.g., "Christopher")** → text truncates to first ~8 chars with ellipsis, doesn't push other AppBar elements off-screen.
8. **Cross-tab consistency** → visit Chores / Meals / Shop / Recipes / Calendar tabs; the indicator stays in the AppBar across all (since AppBar lives on home_shell, not the tab body).

## Known followups

- **Avatar URL error fallback**: invalid/404 avatar URL leaves the circle visually "blank" (honey-gold with no initials). Polish item: wrap `Image.network` with `errorBuilder` inside `ClipOval` for true bullet-proof fallback. ~10 LOC. Defer.
- **Carry-forward**: settings_screen `nameController` leak, 6c-i/iii notifications, Batch 9 kid redemption requests.

## What this batch deliberately did NOT include

- No changes to `ActiveMemberService` (touched only the AppBar trigger UI).
- No changes to the profile switcher menu itself (`_showProfileSwitcher`).
- No `household_members` schema changes.
- No avatar upload flow changes.
- No abbreviation logic beyond the simple `split(' ').first` first-name extraction.
- No redesign of other AppBar elements (points badge, search, approvals, popup menu unchanged).

## Next steps (for the user)

1. Review `apps/mobile/lib/screens/home_shell_screen.dart`.
2. Rebuild iOS on this branch (hot restart suffices; no Info.plist or entitlements changes).
3. Run through the 8 smoke paths above. Particular attention to:
   - Path 5: active-member switch should swap avatar + name + points without leaving the screen (verifies the existing `ActiveMemberService` listener + `_loadHouseholdInfo` reload chain).
   - Path 7: long display name truncation works correctly.
   - Path 8: cross-tab visual consistency.
4. Commit on top of the uncommitted 7b-i + 7b-ii stack (either as a separate commit on `feat/ui-hardening-batch-7b-2026-05-26` for cleaner history, or fold into a combined 7b commit — user's choice).
5. Push when ready.
