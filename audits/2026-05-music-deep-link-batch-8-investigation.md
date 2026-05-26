# Batch 8 — Music App Deep Link (Investigation)

Date: 2026-05-25
Branch: `feat/music-deep-link-batch-8-2026-05-25`
Status: **READ-ONLY investigation** — no code, no migrations, no commits

## TL;DR

**This is genuinely small.** Spec is fully resolved on shape and storage. Column already exists (migration 0016). Plugin already in pubspec (`url_launcher: ^6.3.0`). The only "gotcha" is iOS requires registering external URL schemes via `LSApplicationQueriesSchemes` in Info.plist — currently absent — or `canLaunchUrl()` returns false and the button silently fails.

**Honest classification: shape B from the brief — "Small."** Probably 100–180 LOC across one migration-free implementation + one Info.plist tweak. **~1–2 hours of work.** Not a 30-minute drop-in (iOS gotcha + UX polish), but nowhere near the multi-hour effort feared.

---

## Phase 0 — Spec verbatim

From `/audits/2026-05-kid-profile-permissions-spec.md`:

**Line 17 (Q4 row)**:
> Music app preference storage — Per-kid via new `household_members.music_app_preference text` column. A kid switching devices keeps their choice.

**Line 43 (capability bullet)**:
> Open a music player app on the device. Settings or profile screen has a "Play music" button → opens the kid's preferred music app via URL scheme deep link (Spotify, Apple Music, YouTube Music). Doesn't play in-app — it just hands off to the system app the kid chose.

**Line 68 (schema detail)**:
> `household_members.music_app_preference text` — nullable. Examples: `'spotify'`, `'apple_music'`, `'youtube_music'`. The app maps the string to a launch URL.

**Line 101 (UI)**:
> Kid profile screen new "Play Music" button + a small picker for music app preference. Uses `url_launcher` (already in pubspec) for the deep link.

**Line 126 (Batch 8 row)**:
> | **8** | Music app deep link: new "Play Music" button on kid profile screen with app picker; `url_launcher` deep links; preference stored in `household_members.music_app_preference`. | **Low** (single screen + dep already in pubspec) | Batch 1 (column) | `feat/kid-perms-music` |

**Line 145**:
> Music app preference storage — Per-kid via `household_members.music_app_preference text` column. Survives device switches.

### What spec is firm on
- **Per-kid preference** in `household_members.music_app_preference` column. ✅ Schema already shipped.
- **3 apps**: Spotify, Apple Music, YouTube Music. ✅ String enum'd into the text column.
- **No in-app playback**. Just hands off via URL scheme.
- **`url_launcher`** as the mechanism. ✅ Already a dependency.
- **Location**: kid profile screen.

### What spec is silent on
- Default value (null? Apple Music as iOS default?). Recommend: null until kid picks.
- Whether the picker is on the kid's "My Profile" view, the admin's "view this kid" view, or both. Recommend: both — admin can set it from `member_profile_screen`, kid can override in `profile_screen`.
- Exact URL targets. Spec implies "open the app's home" — no specific song/album. Recommend: open the app generically (`spotify://` opens Spotify; `music://` opens Apple Music; `youtubemusic://` opens YouTube Music).
- Fallback behavior if the app isn't installed (e.g., kid has Spotify selected but doesn't have it installed). Recommend: open the App Store page for the app.
- Whether to show the picker only to kids or also to adults (less meaningful for adults — they have full app access anyway). Recommend: kid-gated UI.

---

## Phase 1 — Codebase inventory

| Question | Finding |
|---|---|
| `household_members.music_app_preference` column exists? | ✅ Migration 0016:147 — `ADD COLUMN IF NOT EXISTS music_app_preference text;` |
| `url_launcher` in pubspec? | ✅ `url_launcher: ^6.3.0` in `apps/mobile/pubspec.yaml` |
| Any existing `url_launcher` usage in lib/? | ❌ Zero call sites. The dependency was added but never used. |
| Any music/spotify/apple_music references in code? | ❌ Zero. |
| `LSApplicationQueriesSchemes` in `ios/Runner/Info.plist`? | ❌ **NOT PRESENT.** This is the iOS gotcha — see Phase 2. |
| Kid profile screens that could host the button? | Two candidates: `apps/mobile/lib/screens/profile_screen.dart` (428 LOC, "my profile" for current user) and `apps/mobile/lib/screens/member_profile_screen.dart` (401 LOC, admin viewing a specific member). Both are kid-aware (`kind == 'sub_profile'` checks already present). |

### Existing kid-aware code shape (already there)

**`profile_screen.dart:157, 188, 209`** branches on `kind == 'sub_profile'` to render kid-specific UI (kid emoji avatar, "Kid Profile" label). Perfect insertion point for a kid-only "Play Music" button.

**`member_profile_screen.dart:315`** branches on `_membership?['kind'] == 'sub_profile'` for the badge text. Also a fine spot for the admin-side picker.

---

## Phase 2 — Deep link interpretation

Per spec wording, this is **launcher-only, no playback**. The app hands off to whichever music app the kid chose.

### URL schemes (verified Apple-documented)

| App | URL scheme | Notes |
|---|---|---|
| Spotify | `spotify://` | Opens the app to whatever was last shown |
| Apple Music | `music://` | Opens Music app (iOS native) |
| YouTube Music | `youtubemusic://` | Opens the YouTube Music app |

The spec doesn't ask for song/album/playlist deep linking — just "open the app." That's the minimum viable.

### iOS gotcha — `LSApplicationQueriesSchemes` (CRITICAL)

Since iOS 9, the app must declare in `Info.plist` which URL schemes it will query before `canLaunchUrl()` will return `true`. Without this, the launcher silently returns false. Required addition to `ios/Runner/Info.plist`:

```xml
<key>LSApplicationQueriesSchemes</key>
<array>
  <string>spotify</string>
  <string>music</string>
  <string>youtubemusic</string>
</array>
```

This is the single non-obvious piece of Batch 8. Without it, the buttons will appear to do nothing on real devices.

### Fallback behavior (recommend)

If `canLaunchUrl` returns false (app not installed), open the App Store page instead. Each music app has a known App Store URL:

| App | App Store fallback URL |
|---|---|
| Spotify | `https://apps.apple.com/app/spotify-music/id324684580` |
| Apple Music | `https://apps.apple.com/app/apple-music/id1108187390` (rarely needed — preinstalled) |
| YouTube Music | `https://apps.apple.com/app/youtube-music/id1017492454` |

`url_launcher` handles https URLs the same way it handles custom schemes.

---

## Phase 3 — Scope estimate (honest)

Per the brief's three shapes:

- ❌ **A (Tiny — single hardcoded URL, ~10 LOC)**: misaligned with spec; spec requires picker + per-kid storage.
- ✅ **B (Small — picker + per-kid column + ~100 LOC)**: matches spec exactly. Column exists. Plugin exists.
- ❌ **C (Real feature — curated playlists)**: spec explicitly excludes this ("doesn't play in-app — it just hands off").

### LOC + file estimate (shape B)

| File | New / mod | Net LOC |
|---|---|---|
| `ios/Runner/Info.plist` | mod | +6 (the LSApplicationQueriesSchemes array) |
| `apps/mobile/lib/utils/music_apps.dart` (new) | new | ~50 — a small `MusicApp` enum + scheme/label/fallback mapping |
| `apps/mobile/lib/screens/profile_screen.dart` | mod | ~30 — kid-gated "Play Music" button + tap handler with launchUrl + canLaunchUrl fallback to App Store |
| `apps/mobile/lib/screens/member_profile_screen.dart` | mod | ~50 — admin picker (small bottom sheet or dropdown) that updates the kid's `music_app_preference` column |
| **Total** | | **~130–150 LOC** |

No migration needed (column already exists). No RPC needed (it's a member-row column update — RLS already permits admins to update kid rows). No new dependency.

### Time estimate

- ~30 min: utils + button + dropdown plumbing
- ~30 min: tap handler + canLaunchUrl + App Store fallback
- ~30 min: Info.plist + iPhone smoke test (verify all 3 deep links + the App-Store-fallback path work)
- ~15 min: audit doc + commit
- **Total: ~1.5–2 hours** for a clean ship.

Not a 30-minute drop-in (the iOS gotcha + App Store fallback UX + admin/kid split add real work). But genuinely small.

---

## Phase 4 — Open questions for the user

1. **Picker placement**:
   - Option A: admin-only on `member_profile_screen` (admin sets kid's preference); kid sees the resulting "Play Music" button but can't change it.
   - Option B: kid can change it themselves in their own `profile_screen`.
   - Option C: both.

   Recommend **C** — kid sees both their current selection and a "change app" affordance; admin can override from the kid's member row. Matches existing pattern where kids have some agency over their own profile (display name, emoji avatar).

2. **Default value**: when `music_app_preference` is null (which it is for everyone today), should the button:
   - Be hidden until kid picks?
   - Show a prompt "Choose your music app first"?
   - Default to Apple Music (preinstalled on every iPhone)?

   Recommend the **prompt** — cleaner discovery flow; one tap to pick.

3. **YouTube Music inclusion**: spec lists 3 apps. Confirm we want all 3? (Spotify + Apple Music covers ~90% of iOS users; YouTube Music is a longer-tail pick.) Recommend keep all 3 — trivial cost since we're already mapping.

4. **Adults**: should adults also get the picker? Spec says "Kid profile screen." Recommend kid-gated only.

5. **App Store fallback copy**: when the app isn't installed and we redirect to the App Store, show a SnackBar first ("Spotify isn't installed — opening App Store…")? Or silent redirect? Recommend SnackBar — explains the unexpected hop.

6. **Future Android**: the URL schemes mostly work on Android too (Spotify uses `spotify://`, YouTube Music uses `youtubemusic://`), but the Info.plist piece is iOS-specific (Android uses `<queries>` in AndroidManifest.xml). Out of scope for 6c-era iOS focus, but worth knowing the architecture extends cleanly.

7. **Button copy / icon**:
   - Suggested: `🎵 Play Music` (text + icon `Icons.music_note_rounded`)
   - Or: just the icon as a smaller affordance
   Recommend the text + icon button — kids notice text more than icons in our age range.

---

## Phase 5 — Risk surface (minimal)

1. **`LSApplicationQueriesSchemes` missing** → `canLaunchUrl()` silently returns false; button does nothing. **This is the #1 silent-failure mode.** Documented in Phase 2 above.
2. **Production-only scheme allowlist**: `LSApplicationQueriesSchemes` is read at app launch; changing it requires a clean rebuild on iPhone (not just hot reload).
3. **App Store URL drift**: Apple changes URLs occasionally. The App Store fallback URLs above were the canonical ones as of 2024. Worth re-verifying during smoke.
4. **Kid switches device, music app not installed**: handled by the App Store fallback. Re-verify on a device that doesn't have Spotify (e.g., admin's phone with only Apple Music).
5. **Edge: `music://` opens Apple Music to wherever it was last** — could be confusing if the kid expects "Music app open to home." This is iOS behavior, not under our control. Acceptable.

No risk on backend (column exists, RLS exists, no new RPC). No risk on RealtimeService. No risk on permissions (preferences are member-scoped).

---

## Honest answer to "30 min or more?"

**More — but not by much.** Realistic: **1.5–2 hours** for a clean ship including smoke test. The 30-min framing would miss:
- The iOS `LSApplicationQueriesSchemes` step (mandatory for the feature to work)
- App Store fallback UX (otherwise the kid sees nothing happen)
- Admin-side picker vs kid-side picker (Q1 above)

But it's still the smallest remaining batch in Pass 3 by a wide margin. Sensible to slot in between bigger 6c sub-batches as a context-switch palate cleanser, or as a quick finisher after 6c-iv ships.

## What this investigation deliberately did NOT do

- Did not write any code, migration, or Info.plist change.
- Did not modify either profile screen.
- Did not test url_launcher on a device.
- Did not commit anything.

All implementation work awaits user kickoff with the 7 open questions answered (or recommended defaults accepted).

## Recommended next step

User answers Q1–Q7 (or accepts recommended defaults), then a single implementation pass on this branch. Probably under 2 hours including smoke + commit.
