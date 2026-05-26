# Batch 8.1 — Music Polish: Floating Shortcut + Pandora + Amazon Music

Date: 2026-05-25
Branch: `feat/music-deep-link-batch-8-2026-05-25` (2nd commit slot, following `da1392a` Batch 8)
Status: **changes uncommitted** — user reviews then commits

## Summary

Two-part follow-up to Batch 8: (1) a bottom-left floating music shortcut on `chore_dashboard_screen` so kids can launch music in one tap from the Chores tab (instead of the 3-tap profile-switch → profile → Play Music flow); (2) Pandora + Amazon Music added to the music app list (now 5 supported apps). Adding the chore_dashboard caller triggered the long-flagged extraction of the picker + launcher logic into shared helpers (`lib/widgets/music_picker_sheet.dart` + `lib/utils/music_launcher.dart`) — `profile_screen` and `member_profile_screen` were refactored to use the shared pieces, eliminating ~150 LOC of duplication.

No migration, no RPC, no new package. All 5 locked decisions honored.

## Files modified / created

| File | Type | Net LOC | Purpose |
|---|---|---|---|
| `apps/mobile/lib/utils/music_apps.dart` | modified | +24 | Added `MusicApp.pandora` + `MusicApp.amazonMusic` enum values and matching `MusicAppInfo` entries in `allApps`. Pandora's emoji 🔵 (brand blue); Amazon Music's 🟦. Comment flags the Amazon Music scheme as `amazonmusic://` (most-common modern citation) with a fallback note about `amzn-mobile-music://` to try if the default doesn't fire on a real device. |
| `apps/mobile/ios/Runner/Info.plist` | modified | +2 | Added `pandora` and `amazonmusic` strings to `LSApplicationQueriesSchemes` (5 schemes total now). Clean rebuild required after this change — iOS reads Info.plist at app launch only. |
| `apps/mobile/lib/widgets/music_picker_sheet.dart` | **new** | +52 | Stateless `MusicPickerSheet` widget exposing static `show(BuildContext)` that returns `Future<MusicAppInfo?>`. Pure picker UI — caller persists the result. `ValueKey(info.dbValue)` per Q9 carryforward. |
| `apps/mobile/lib/utils/music_launcher.dart` | **new** | +73 | Two top-level helpers: `launchMusicApp(context, info)` (canLaunchUrl + URL scheme launch + App Store fallback + Pass 2 error pattern); `pickAndSaveMusicApp(context, memberId)` (show sheet → UPDATE household_members.music_app_preference → SnackBar confirm). Both `context.mounted` guarded post-await. |
| `apps/mobile/lib/screens/profile_screen.dart` | modified | -90 / +18 | Refactored to use the new helpers. Local `_playMusic` shrinks from ~40 LOC to 12 LOC (just the null-preference prompt + delegate to `launchMusicApp`). Local `_pickMusicApp` shrinks from ~60 LOC to 8 LOC. The `_musicAppRow` widget and Music section UI are unchanged (screen-specific UX). Removed direct `url_launcher` import — now goes through the launcher helper. |
| `apps/mobile/lib/screens/member_profile_screen.dart` | modified | -55 / +9 | `_pickMusicApp` shrinks from ~55 LOC to 8 LOC via `pickAndSaveMusicApp`. The `_buildMusicAppRow` widget unchanged. |
| `apps/mobile/lib/screens/chore_dashboard_screen.dart` | modified | +50 | Imports for `music_apps` + `music_launcher`. New `_playMusic` orchestration (mirrors profile_screen's pattern). Body wrapped in `Stack` so the bottom-left music FAB can live alongside the existing bottom-right "Add Chore" extended FAB. `Positioned(left: 16, bottom: 16)` with `SafeArea` ensures the FAB respects the device's bottom inset. Kid-gated via `Permissions.isKid(_myMembership)`. |

**Net: ~+85 LOC** (the two new shared files add ~125 LOC; refactoring profile/member_profile screens removes ~145 LOC of duplication; chore_dashboard adds ~50 LOC).

## Phase 1 — Pandora + Amazon Music

`MusicApp` enum extended from 3 to 5 values:

```dart
enum MusicApp { spotify, appleMusic, youtubeMusic, pandora, amazonMusic }
```

Two new `MusicAppInfo` entries appended to `allApps` (kept Apple Music last as before — added Pandora before Apple Music sandwich would have broken UX continuity, so I appended Pandora + Amazon after Apple Music — picker now shows 🟢 Spotify → 🔴 YouTube Music → 🍎 Apple Music → 🔵 Pandora → 🟦 Amazon Music).

**Amazon Music URL scheme caveat**: Apple's iOS deep-link documentation doesn't surface a single canonical scheme for Amazon Music; community references cite both `amazonmusic://` (most common, modern) and `amzn-mobile-music://` (older, possibly deprecated). I went with **`amazonmusic://`** and added an inline comment in `music_apps.dart` noting that if `canLaunchUrl` returns false on a real device with Amazon Music installed, swap to `amzn-mobile-music://` in both `music_apps.dart` AND `Info.plist`. This is the only documented uncertainty in the batch.

## Phase 2 — Info.plist

```xml
<key>LSApplicationQueriesSchemes</key>
<array>
  <string>spotify</string>
  <string>music</string>
  <string>youtubemusic</string>
  <string>pandora</string>
  <string>amazonmusic</string>
</array>
```

5 schemes total. **Clean rebuild required** (same as Batch 8 — iOS reads Info.plist at app launch only; hot reload won't pick up these additions).

## Phase 3 — Shared extraction (Option B from the brief)

Adding `chore_dashboard` as the 3rd music caller was the trigger to extract — the Batch 8 implementation report had flagged this as "the trigger to extract" if a third caller emerged.

### New file: `widgets/music_picker_sheet.dart` (52 LOC)

`MusicPickerSheet` stateless widget. Private constructor. Static `show(BuildContext)` returns `Future<MusicAppInfo?>` via `showModalBottomSheet`. Identical UX to the previously-duplicated implementations — `SafeArea` + `Column` + per-app `ListTile` with `ValueKey(info.dbValue)`. Pure UI, no persistence concerns.

### New file: `utils/music_launcher.dart` (73 LOC)

Two top-level helpers (no class — these are stateless utilities):

```dart
Future<void> launchMusicApp(BuildContext, MusicAppInfo);
Future<MusicAppInfo?> pickAndSaveMusicApp(BuildContext, {required String memberId});
```

`launchMusicApp` does the canLaunchUrl check, launches the URL scheme on success, falls back to the App Store URL with a SnackBar warning on failure. Pass 2 error pattern around the whole thing. Every post-await SnackBar guards on `context.mounted`.

`pickAndSaveMusicApp` orchestrates the full flow: show sheet → if selection → UPDATE `household_members.music_app_preference` for the given member → SnackBar confirm. Returns the selected `MusicAppInfo` on success, null on cancel-or-failure. Caller is responsible for any local state mutation (the State classes still need `setState` to mirror the new value).

### Refactored: `profile_screen.dart`

`_playMusic` (was ~40 LOC) is now:

```dart
Future<void> _playMusic() async {
  final info = MusicAppInfo.fromDbValue(
    _membership?['music_app_preference'] as String?,
  );
  if (info == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Choose your music app first')),
    );
    await _pickMusicApp();
    return;
  }
  await launchMusicApp(context, info);
}
```

`_pickMusicApp` (was ~60 LOC) is now:

```dart
Future<void> _pickMusicApp() async {
  final memberId = _membership?['id'] as String?;
  if (memberId == null) return;
  final picked = await pickAndSaveMusicApp(context, memberId: memberId);
  if (picked == null || !mounted) return;
  setState(() {
    _membership = {
      ..._membership!,
      'music_app_preference': picked.dbValue,
    };
  });
}
```

The `_musicAppRow` widget (screen-specific layout) stays in the State class — extracting that would force a callback parameter for the picker open behavior, which is more friction than the duplication relieves.

### Refactored: `member_profile_screen.dart`

`_pickMusicApp` (was ~55 LOC) is now 8 LOC delegating to `pickAndSaveMusicApp`. The `_buildMusicAppRow` widget stays in the State class for the same reason as above.

### What's still duplicated (acceptable)

- `_musicAppRow` (profile_screen) vs `_buildMusicAppRow` (member_profile_screen) — ~50 LOC each. They have nearly-identical layouts but the call site context (own `_membership` vs viewed-member `_member`) and the picker entry point ("open my picker" vs "open admin picker") differ. Could be extracted as a `MusicAppRow` widget taking a `Map<String, dynamic>?` and an `onTap` callback, but the gain is modest (~80 LOC saved across both screens) and the indirection adds friction. Worth doing in a future polish pass; not a blocker now.

## Phase 4 — chore_dashboard floating shortcut

### FAB layout

The existing `Scaffold.floatingActionButton` slot is already in use for the admin "Add Chore" extended FAB. I deliberately did not consolidate the two FABs into a single Row in the FAB slot — would have required changing `floatingActionButtonLocation` and reasoning about both FABs' shared lifecycle. Instead, I wrapped the body in a `Stack` and added a `Positioned(left: 16, bottom: 16)` with the music FAB. `SafeArea` keeps it above the device's bottom inset / iPhone home-bar.

Result:
- Adult Chores tab: bottom-right "Add Chore" FAB only (existing behavior unchanged).
- Kid Chores tab: bottom-right "Add Chore" FAB + bottom-left music FAB.
- Other tabs (Meals / Shop / Calendar / Recipes): unchanged — no music FAB.

(Sidebar note: the "Add Chore" FAB is currently visible to kids too. That's a pre-existing concern from before Batch 8.1 and orthogonal to this work; flagged for Batch 7 polish.)

### `_playMusic` orchestration

Mirrors profile_screen's pattern but skips the "Choose your music app first" SnackBar — the floating button itself is the launcher entry, so when there's no preference the picker opens directly (the sheet is the prompt, per Q3). On preference set, delegates to `launchMusicApp`.

```dart
Future<void> _playMusic() async {
  final memberId = _myMembership?['id'] as String?;
  if (memberId == null) return;
  final info = MusicAppInfo.fromDbValue(
    _myMembership?['music_app_preference'] as String?,
  );
  if (info == null) {
    final picked = await pickAndSaveMusicApp(context, memberId: memberId);
    if (picked == null || !mounted) return;
    setState(() {
      _myMembership = {
        ..._myMembership!,
        'music_app_preference': picked.dbValue,
      };
    });
    return;
  }
  await launchMusicApp(context, info);
}
```

### Music FAB markup

```dart
if (Permissions.isKid(_myMembership))
  Positioned(
    left: 16,
    bottom: 16,
    child: SafeArea(
      child: FloatingActionButton.small(
        heroTag: 'chores-music-fab',
        onPressed: _playMusic,
        backgroundColor: AppColors.honeyGold,
        tooltip: 'Play music',
        child: const Icon(Icons.music_note, color: Colors.white),
      ),
    ),
  ),
```

Unique `heroTag: 'chores-music-fab'` so it doesn't conflict with `'chores-fab'` (the Add Chore FAB) or `'recipes-fab'` (recipe library's FAB).

## Analyzer

| | Issues | Errors |
|---|---|---|
| Before | 368 | 1 (pre-existing `MyApp` test) |
| After | **368** | 1 (same) |
| **Net** | **0** | **0** |

Zero new info, warning, or error. Even cleaner than Batch 8 — the extraction reduced overall LOC (and therefore potential warning surface) in the State classes; the new helper files were written with no `withOpacity` calls and no untyped `.rpc()` calls.

## iPhone smoke test (8 paths, **needs real device, clean rebuild required**)

Info.plist changed → `flutter clean` + `flutter run` mandatory before testing.

1. **As Randi on Chores tab** → bottom-left honey-gold music FAB visible. Bottom-right "Add Chore" FAB also visible.
2. **As admin on Chores tab** → only "Add Chore" FAB visible; NO music FAB.
3. **As Randi on Meals / Shop / Calendar / Recipes tabs** → NO music FAB anywhere (only on Chores tab per Q1).
4. **As Randi with no music preference** → tap music FAB → picker opens directly. **No "Choose your music app first" SnackBar** (per Q3 — sheet is the prompt).
5. **Pick Pandora** → SQL verify: `select music_app_preference from household_members where id = randi_id` → `pandora`. SnackBar "Music app set to Pandora".
6. **Tap music FAB again** → Pandora opens (if installed) OR SnackBar "Pandora isn't installed — opening App Store" + App Store opens.
7. **Pick Amazon Music** → repeat step 6 with `amazonmusic://`. **If canLaunchUrl returns false even when Amazon Music is installed**, swap `amazonmusic://` → `amzn-mobile-music://` in `music_apps.dart` AND update Info.plist accordingly. Clean rebuild again.
8. **Mid-session profile switch (admin → Randi)** on the Chores tab → music FAB appears live. Switch back (Randi → admin) → music FAB disappears live. (Same `_myMembership` reload pattern as the rest of chore_dashboard.)

## Known followups

- **Android in-app handoff**: `<queries>` block in `AndroidManifest.xml` listing the 5 schemes when Android comes into scope.
- **`_musicAppRow` / `_buildMusicAppRow` widget extraction**: ~80 LOC still duplicated between `profile_screen` and `member_profile_screen`. Extract as a reusable `MusicAppRow` widget in a future polish pass.
- **Amazon Music scheme verification**: confirm `amazonmusic://` works on real device with Amazon Music installed. If not, swap to `amzn-mobile-music://` (both files + clean rebuild).
- **Add-Chore FAB admin-gate**: orthogonal pre-existing concern — kids currently see the "Add Chore" FAB. Move to Batch 7 polish.
- **Specific track/playlist deep links**: `spotify:track:[id]`, Apple Music album URLs, Pandora station URLs — future enhancement.
- **Per-chore music**: different songs for different chore types — future enhancement.
- **Batch 7 UI hardening**: 6 remaining screens on legacy `.eq('auth_user_id', user.id)` pattern (down from 7 after Batch 8's profile_screen migration; unchanged this batch).

## What this batch deliberately did NOT include

- No migration (column shipped in 0016 era).
- No RPC.
- No new dependency.
- No Android config.
- No in-app playback.
- No music FAB on other tabs (Q1 locked: Chores only).
- No regular-sized `FloatingActionButton` (Q5 locked: `.small`).
- No "are you sure" confirm dialog before launch.
- No extraction of `_musicAppRow` widgets (deferred — see followups).

## Next steps (for the user)

1. Review the 4 modified + 2 new files.
2. `flutter clean && flutter run` on real iPhone (mandatory after Info.plist change).
3. Run through the 8 smoke paths. Particular attention to:
   - Path 4: picker opens directly when no preference (no pre-SnackBar).
   - Path 7: verify Amazon Music scheme — flag if `amazonmusic://` doesn't work.
   - Path 8: kid-gating live-reload on profile switch.
4. Commit as a 2nd commit on this branch (after `da1392a` Batch 8).
5. Push when ready.
