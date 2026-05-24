# iOS image_picker permissions fix

Date: 2026-05-24
Branch: `fix/ios-image-picker-permissions-2026-05-24` (working-tree only; no commits)
Scope: add `NSCameraUsageDescription` + `NSPhotoLibraryUsageDescription` to iOS `Info.plist`
Status: code complete — **not committed**

## Summary

Adds two iOS privacy keys to `apps/mobile/ios/Runner/Info.plist` so the app stops crashing the moment any `image_picker` flow runs on a real iPhone. The keys' string values are the prompts iOS shows to the user when first asking for permission — written to cover all three current callers (chore submissions in Batch 4, profile avatars, recipe photos).

Pre-existing latent bug; not introduced by Batch 4 but would become a guaranteed crash once Batch 4's kid chore-photo flow shipped. Fix lands separately as a prerequisite.

## File modified

| File | Change |
|---|---|
| `apps/mobile/ios/Runner/Info.plist` | 2 new top-level keys inserted between `LSRequiresIPhoneOS` and `UIApplicationSceneManifest` (alphabetical placement: N falls between L and U) |

No other files touched. No Dart changes. No Android equivalent (Android handles runtime permissions via Dart, not via a manifest string).

## The two new keys

```xml
<key>NSCameraUsageDescription</key>
<string>Honeydo uses your camera to let kids submit photos when completing chores, and to take photos for profile avatars and recipes.</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>Honeydo uses your photo library to upload images for chore submissions, profile avatars, and recipes.</string>
```

Both strings cover all three current `image_picker` flows so a single prompt text is accurate for every site. iOS shows these strings the first time the user taps a control that triggers `ImageSource.camera` or `ImageSource.gallery`.

## Surrounding context (Info.plist lines 25-38 after the edit)

```xml
	<key>CFBundleVersion</key>
	<string>$(FLUTTER_BUILD_NUMBER)</string>
	<key>LSRequiresIPhoneOS</key>
	<true/>
	<key>NSCameraUsageDescription</key>
	<string>Honeydo uses your camera to let kids submit photos when completing chores, and to take photos for profile avatars and recipes.</string>
	<key>NSPhotoLibraryUsageDescription</key>
	<string>Honeydo uses your photo library to upload images for chore submissions, profile avatars, and recipes.</string>
	<key>UIApplicationSceneManifest</key>
	<dict>
		<key>UIApplicationSupportsMultipleScenes</key>
		<false/>
		<key>UISceneConfigurations</key>
		<dict>
```

Tab-indented to match the surrounding convention. No other Info.plist changes.

## Why this matters

iOS enforces privacy-prompt strings as a hard runtime requirement. If an app accesses the camera (`AVCaptureDevice` family) or photo library (`PHPhotoLibrary` family) without the matching usage-description key in `Info.plist`, iOS crashes the process with an immediate `EXC_BAD_INSTRUCTION` and a console message like:

> *** Terminating app due to uncaught exception 'NSInvalidArgumentException',
> reason: 'This app has crashed because it attempted to access privacy-sensitive
> data without a usage description. The app's Info.plist must contain an
> NSCameraUsageDescription key...'

Three current call sites would hit this:

| Caller | image_picker source | Site |
|---|---|---|
| Profile avatar upload | both gallery + camera (via `ImageUploadService.showImageSourceDialog`) | `profile_screen.dart` (around line 120 per the original brief) |
| Recipe photo upload | both gallery + camera (via the same dialog) | `recipe_detail_screen.dart` (around line 1063) |
| **Future**: kid chore submission | camera-primary | Batch 4a / 4b — would crash on first tap of "Mark complete" as a kid |

The reason this hasn't surfaced yet:
- The Wrights test household's adult owner hasn't tried to upload an avatar or recipe photo on the actual iPhone build (debug builds sometimes get more lenient error reporting; production-style behavior triggers the crash reliably).
- Or the crash happened once, was attributed to something else, and forgotten.

Either way, the kid chore-photo path in Batch 4 is camera-first by design — kids will hit this immediately. Better to fix as a prerequisite so Batch 4 isn't entangled with diagnosing an unrelated iOS crash.

## Verification checklist for iPhone

After this change lands and the app is hot-restarted (full rebuild required — Info.plist changes are bundled at build time, not hot-reloadable):

1. **Profile avatar via camera** — open profile screen → tap avatar → choose Camera. Expected: iOS shows a one-time permission prompt with the `NSCameraUsageDescription` string verbatim. Tap "Allow"; camera opens. Subsequent uses don't re-prompt.

2. **Profile avatar via gallery** — same flow, choose Gallery. Expected: prompt with `NSPhotoLibraryUsageDescription` string. Allow; gallery opens.

3. **Recipe photo via camera** — recipe detail → add/edit photo → camera. Expected: no second prompt (Camera permission is app-wide; already granted from step 1). Camera opens directly.

4. **Recipe photo via gallery** — same flow, gallery. Expected: no second prompt. Gallery opens.

5. **Decline the permission** (first-time scenarios only): tap "Don't Allow" on either prompt. Expected: `image_picker.pickImage` returns `null`. The app should handle this gracefully (the existing `ImageUploadService.pickAndUpload` checks `if (image == null) return null;` — confirmed handles cancellation).

Batch 4's kid chore-photo path will exercise the same camera flow and should work out of the box once this lands.

## Known followups

- **None.** This is a self-contained, fix-it commit. No new tests, no new audits, no dependencies on other batches.

## Git state (uncommitted)

```
$ git status --short
 M apps/mobile/ios/Runner/Info.plist
?? audits/2026-05-ios-image-picker-permissions-fix.md
```

1 modified file + 1 new audit doc. Branch otherwise clean. Ready for review + commit + push with `--set-upstream`.

## Next steps

1. **You verify** the strings read correctly. They'll be shown to every user the first time they tap a camera or gallery control, so tone matters.
2. **Build for iPhone** (full rebuild — Info.plist isn't hot-reloadable). Run through the 5-item verification checklist above.
3. **Commit** as a standalone fix. Push with `--set-upstream` on `fix/ios-image-picker-permissions-2026-05-24`.
4. Batch 4a (kid photo upload flow) becomes safe to start once this is merged or stacked under it.
