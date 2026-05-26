# Batch 8 — Music App Deep Link Implementation Report

Date: 2026-05-25
Branch: `feat/music-deep-link-batch-8-2026-05-25`
Status: **changes uncommitted** — user reviews then commits

## Summary

Ships the kid music app deep-link feature end-to-end. New `MusicAppInfo` utility maps the 3 supported apps (Spotify, Apple Music, YouTube Music) to URL schemes, App Store fallback URLs, and DB column values. Kid profile screen gets a Music section with picker + "🎵 Play Music" launch button; admin gets the picker (no launcher) when viewing a kid via `member_profile_screen`. iOS `Info.plist` updated with `LSApplicationQueriesSchemes` so `canLaunchUrl()` works on real devices. Pre-existing `.eq('auth_user_id', user.id)` legacy pattern on `profile_screen` migrated to `MembershipHelper` — required to make the kid gate work (without it, a kid session resolves to the parent admin row and the Music section never renders).

No migration (column shipped in `0016`), no RPC, no new dependency (`url_launcher: ^6.3.0` already in pubspec). All 7 decisions locked.

## Files modified / created

| File | Type | Net LOC | Purpose |
|---|---|---|---|
| `apps/mobile/lib/utils/music_apps.dart` | **new** | +75 | `MusicApp` enum + `MusicAppInfo` immutable value class with `allApps` list and `fromDbValue()` lookup. Encodes label, db value, URL scheme, App Store fallback URL, and emoji per app. |
| `apps/mobile/ios/Runner/Info.plist` | modified | +6 | `LSApplicationQueriesSchemes` array with `spotify`, `music`, `youtubemusic`. **Required for `canLaunchUrl()` to return true on iOS 9+.** Requires clean rebuild (not hot reload) to take effect. |
| `apps/mobile/lib/screens/profile_screen.dart` | modified | +185 | (1) MembershipHelper migration in `_loadData` + `ActiveMemberService` listener. (2) New `_playMusic` handler with canLaunchUrl + App Store fallback. (3) New `_pickMusicApp` bottom-sheet picker. (4) New `_musicAppRow` widget. (5) Kid-gated Music section in `build()` between Household and Stats. |
| `apps/mobile/lib/screens/member_profile_screen.dart` | modified | +110 | Same picker (no launch button), kid-gated, slotted between Stats and Badges. Picker UPDATEs the viewed kid's row, not the admin's. |
| **Total** | | **~+376 LOC** | About 2x the investigation's 130–150 estimate; the investigation didn't account for the necessary MembershipHelper migration on `profile_screen` (~30 LOC) nor the duplicated picker UI between the two screens (~80 LOC each since they're standalone classes). |

## Phase 1 — `music_apps.dart` (new utility)

`MusicApp` enum + `MusicAppInfo` class (immutable, `@immutable` annotated). Static `allApps` list ordered Spotify → YouTube Music → Apple Music (Apple Music last because it's preinstalled — kid is less likely to "pick" it intentionally first). `fromDbValue(String?)` returns `null` for unknown/null inputs (legacy/typo strings or kid hasn't picked yet).

Per-app metadata:
- **Spotify**: label `Spotify`, db `spotify`, scheme `spotify://`, App Store URL `…/id324684580`, emoji 🟢
- **YouTube Music**: label `YouTube Music`, db `youtube_music`, scheme `youtubemusic://`, App Store URL `…/id1017492454`, emoji 🔴
- **Apple Music**: label `Apple Music`, db `apple_music`, scheme `music://`, App Store URL `…/id1108187390`, emoji 🍎

Emojis chosen over MaterialIcons because (a) brand colors are unmistakable, (b) age-appropriate kid-friendly visual cue, (c) avoids the Material vs Cupertino consistency choice.

## Phase 2 — `Info.plist`

```xml
<key>LSApplicationQueriesSchemes</key>
<array>
  <string>spotify</string>
  <string>music</string>
  <string>youtubemusic</string>
</array>
```

Slotted right after the camera/photo library usage description blocks. **iOS reads this at app launch only** — if you hot-reload after editing, `canLaunchUrl()` won't pick up the new schemes. Clean build required.

## Phase 3 — `profile_screen.dart` (kid's own profile)

### MembershipHelper migration (required for kid gate)

Old `_loadData`:
```dart
final memberships = await Supabase.instance.client
    .from('household_members')
    .select('*, households(*)')
    .eq('auth_user_id', user.id)
    .eq('is_active', true)
    .limit(1);
```

New:
```dart
final membership = await MembershipHelper.loadActiveMembership(
  includeHouseholdJoin: true,
);
```

Plus `ActiveMemberService.instance.activeMemberId.addListener(_onActiveMemberChanged)` in `initState` and matching tear-down in `dispose`. Without this migration, a kid session would resolve `_membership` to the parent admin's row and `Permissions.isKid(_membership)` would always return false — the Music section would never render. (One of the 7 remaining legacy-pattern screens from the Batch 7 followups list. Down to 6.)

### `_playMusic` handler

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
  try {
    final uri = Uri.parse(info.urlScheme);
    final canLaunch = await canLaunchUrl(uri);
    if (canLaunch) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("${info.label} isn't installed — opening App Store"),
      ),
    );
    await launchUrl(
      Uri.parse(info.appStoreUrl),
      mode: LaunchMode.externalApplication,
    );
  } catch (e) {
    debugPrint('play music failed: $e');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't open music app: $e")),
      );
    }
  }
}
```

Null preference → prompt SnackBar + auto-open picker. Installed app → launch. Not installed → SnackBar explaining the redirect + open App Store URL.

### `_pickMusicApp` bottom sheet

Bottom sheet with the 3 apps as `ListTile`s, `ValueKey(info.dbValue)` per Q9. On tap, pops with the selected `MusicAppInfo`. Caller UPDATEs `household_members` row and updates local state. Pass 2 error pattern throughout (`try/catch` → `debugPrint` → SnackBar with `$e`).

### Music section in `build()`

Slotted between Household and Stats sections:
```dart
if (Permissions.isKid(_membership)) ...[
  Text('MUSIC', ...),
  _musicAppRow(),  // tappable current pick
  FilledButton.icon(
    onPressed: _playMusic,
    icon: const Text('🎵', style: TextStyle(fontSize: 18)),
    label: const Text('Play Music'),
    style: FilledButton.styleFrom(
      backgroundColor: AppColors.honeyGold,
      minimumSize: const Size.fromHeight(48),
      ...
    ),
  ),
],
```

Adults see nothing here — no section header, no row, no button.

### `_musicAppRow` widget

Card with InkWell → opens the picker. Shows the current pick's emoji + label, or "Not set yet — tap to choose" when null. Chevron right indicates tappability.

## Phase 4 — `member_profile_screen.dart` (admin's view of a kid)

`MemberProfileScreen` takes `memberId` via constructor and loads that member's row directly via `.eq('id', widget.memberId)` — no legacy `.eq('auth_user_id')` pattern, no migration needed.

Music section slotted between Stats and Badges. Gated on `_member!['kind'] == 'sub_profile'` — admin viewing another adult sees nothing here. **No `_playMusic` handler and no Play Music button** — admin is configuring, not using.

`_pickMusicApp` UPDATE writes to `widget.memberId`, not the admin's own. RLS already permits this since the kid is in the admin's household.

The two screens duplicate ~80 LOC of picker UI (sheet + row widget). Considered factoring into a shared widget; decided against it for 6b-pace shipping — DRY is nice but the two screens have slightly different concerns (one launches, one only picks) and consolidating now would add a parameter object + a callback. Acceptable duplication for now; harmonize in a future polish pass if more screens need the picker.

## Analyzer

| | Issues | Errors |
|---|---|---|
| Before | 368 | 1 (pre-existing `MyApp` test) |
| After | **368** | 1 (same) |
| **Net** | **0** | **0** |

Zero new info, warning, or error. Cleaner than the investigation's predicted +1–2 infos — no `withOpacity` calls in new code, no `rpc<T>()` calls (we use direct UPDATEs).

## iPhone smoke test checklist (needs real device)

Music app deep links only work on real iPhone — simulator doesn't have the music apps installed, and `canLaunchUrl` returns true only when the system has registered handlers.

1. **As Randi (kid active), open My Profile** → see Music section between Household and Stats. Row shows "Not set yet — tap to choose" with 🎵 placeholder emoji. Button "🎵 Play Music" visible in honey-gold.
2. **Tap "Play Music" with no preference set** → SnackBar "Choose your music app first" + picker bottom sheet opens automatically.
3. **Tap "Spotify" in picker** → sheet closes. Music app row updates to 🟢 + "Spotify". SnackBar "Music app set to Spotify".
4. **SQL verify**: `select id, display_name, music_app_preference from household_members where id = <randi_id>` shows `music_app_preference = 'spotify'`.
5. **Tap "Play Music"** → Spotify opens (if installed) OR SnackBar "Spotify isn't installed — opening App Store" then Safari/App Store opens to Spotify's listing.
6. **Tap the music row to change** → picker opens. Pick Apple Music → sheet closes, row shows 🍎 + "Apple Music".
7. **Tap "Play Music"** → Apple Music opens (always installed on iPhone).
8. **Pick YouTube Music** → same flow; YouTube Music opens if installed, App Store fallback otherwise.
9. **As admin (active member is adult), open My Profile** → NO Music section at all (no header, no row, no button).
10. **As admin, open Members screen → tap Randi → MemberProfileScreen opens** → Music section visible between Stats and Badges. Row shows current pick (whatever step 6 set). Tap row → picker opens. Pick different app → row updates. No Play Music button visible on this screen.
11. **As admin, open Members → tap another adult member → MemberProfileScreen** → NO Music section.
12. **Mid-session profile switch (admin → Randi)** → profile screen reloads automatically (ActiveMemberService listener), Music section now appears. Switch back (Randi → admin) → Music section disappears.
13. **Verify `LSApplicationQueriesSchemes` is read**: do a `flutter run` (not hot reload — clean install) on iPhone after the Info.plist change. If canLaunchUrl still returns false in step 5 even with Spotify installed, the Info.plist change didn't make it into the binary.

## Known followups

- **Android in-app handoff**: AndroidManifest.xml needs a `<queries>` block listing the same 3 schemes for Android 11+. Out of scope for this batch (iOS-only ship), but mentioned in spec.
- **Per-chore music**: future enhancement — different chore types could launch different playlists. Would require deep-link URLs that include playlist/track IDs and a way for admin to configure per-chore.
- **Specific track/playlist deep linking**: Spotify supports `spotify:track:[id]` and `spotify:playlist:[id]`; Apple Music supports `music://music.apple.com/album/...` URLs. Future enhancement.
- **Shared picker widget**: harmonize the duplicated ~80 LOC picker between `profile_screen` and `member_profile_screen` into a single `MusicAppPickerSheet.show()` helper.
- **Batch 7 UI hardening**: the `MembershipHelper` migration on `profile_screen` consumes one of the 7 legacy-pattern screens. Down to 6.
- **No-music-pick UX**: kid first-time experience is "tap Play Music → SnackBar + picker opens." Could also auto-prompt on profile load when kid is the active member and `music_app_preference` is null. Lighter touch first.

## What this batch deliberately did NOT include

- No new dependency (`url_launcher` already in pubspec).
- No migration (column shipped in `0016`).
- No RPC (UPDATE on `household_members` directly).
- No new RLS (existing household-member-update policies cover this).
- No Android config.
- No in-app playback.
- No custom track/playlist deep links.
- No `withOpacity` deprecation sweep (codebase pattern stays consistent).
- No StatefulWidget dialogs (no TextEditingController — picker uses Navigator.pop with the selected item).

## Next steps (for the user)

1. Review the 4 files (1 new + 3 modified).
2. Rebuild iOS **clean** (not hot reload) on a real iPhone — required for `LSApplicationQueriesSchemes` to take effect.
3. Run through the 13 smoke paths.
4. Commit as a single commit on `feat/music-deep-link-batch-8-2026-05-25`.
5. Push and merge when ready.
