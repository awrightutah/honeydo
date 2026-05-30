# TestFlight Setup Plan — Clanquility — 2026-05-29

## Purpose

Plan tomorrow's Apple-side TestFlight setup for Clanquility. Bundle ID is locked (`com.clanquility.app`), Apple Developer Program membership is active, code rename is complete on `main`. This is a research-only doc — no actions taken in Apple's portals tonight. Goal: tomorrow morning starts with an executable checklist, not exploration.

Scope: getting from "code is on `main` with bundle ID committed" → "build is uploaded to TestFlight and the chosen testers can install it."

---

## Current state (from local artifacts)

**iOS project (`apps/mobile/ios/`) — already configured:**

| Item | Value | Source |
|---|---|---|
| Bundle ID (Runner) | `com.clanquility.app` | `Runner.xcodeproj/project.pbxproj` |
| Bundle ID (RunnerTests) | `com.clanquility.app.RunnerTests` | same |
| Development team | `CY86GH3PW4` | same |
| Code signing style | `Automatic` (Xcode-managed) | same |
| `CFBundleDisplayName` | `Clanquility` | `Info.plist` |
| `CFBundleName` | `clanquility` | `Info.plist` |
| Version (Flutter) | `0.1.0+1` | `pubspec.yaml` |
| `CFBundleShortVersionString` | `$(FLUTTER_BUILD_NAME)` → `0.1.0` | substitution |
| `CFBundleVersion` | `$(FLUTTER_BUILD_NUMBER)` → `1` | substitution |
| Camera permission string | Set, Clanquility-specific copy | `Info.plist` |
| Photo library permission string | Set, Clanquility-specific copy | `Info.plist` |
| App icon set | All 19 sizes populated (iPhone + iPad + 1024 marketing) | `Assets.xcassets/AppIcon.appiconset/` |
| 1024×1024 marketing icon | 8-bit RGB, **no alpha** ✓ | verified via `sips` |
| `.entitlements` files | None | (means no Apple Sign-in, no push notifications, no app groups — clean state) |
| `ExportOptions.plist` | None (Flutter generates at build time) | n/a |

**iOS project — missing / TODO:**

- `ITSAppUsesNonExemptEncryption = NO` in `Info.plist`. **Not present.** Without it, every uploaded build shows "Missing Compliance" in App Store Connect and testers can't receive it until manually answered for each build. Adding it once eliminates the per-build prompt forever. **Add before first archive.**
- `CFBundleIconName = AppIcon` in `Info.plist`. **Not present** as an explicit key, but Xcode 14+ with a populated asset-catalog AppIcon set usually auto-injects this at build time. Low risk; may surface as ITMS-90713 on first upload if Xcode doesn't inject it. **Verify the first archive log; add if needed.**

**Plugin permissions audit (pubspec.yaml plugins → iOS usage descriptions needed):**

| Plugin | Permission needed | Info.plist status |
|---|---|---|
| `image_picker` | Camera + Photos | Both present ✓ |
| `share_plus` | None | n/a |
| `url_launcher` | None (LSApplicationQueriesSchemes for music apps already set) | ✓ |
| `connectivity_plus` | None | n/a |
| `path_provider`, `shared_preferences`, `supabase_flutter`, `http`, `flutter_dotenv` | None | n/a |

**Conclusion:** permissions block is fully covered. Only the encryption-compliance flag is missing.

---

## What Apple requires us to do, in order

A numbered sequence from "code on `main`, bundle ID locked" to "TestFlight upload received by Apple."

### One-time setup (do this once, ever)

1. **Register the bundle ID in Apple Developer Portal as Explicit App ID.** developer.apple.com → Account → Certificates, IDs & Profiles → Identifiers → "+" → App IDs → App → Description "Clanquility", Bundle ID "Explicit: com.clanquility.app". (~5 min.) Why explicit pre-registration: Xcode automatic signing *can* auto-create identifiers, but it prefixes them with "XC" (e.g., `XC com.clanquility.app`), which then doesn't cleanly match the App Store Connect record. Pre-registering avoids that mismatch.
2. **Create App Store Connect record.** appstoreconnect.apple.com → My Apps → "+" → New App. Fields:
   - Platform: iOS
   - Name: `Clanquility` (App Store listing name; up to 30 chars; doesn't have to equal `CFBundleDisplayName` but aligning avoids reviewer confusion)
   - Primary Language: English (U.S.)
   - Bundle ID: select `com.clanquility.app` (Explicit) from the dropdown
   - SKU: `clanquility-ios` (internal-only Apple identifier; convention is an app slug; cannot be reused even if you delete the app record)
   - User Access: Full Access
   (~5 min.)
3. **Distribution certificate + App Store provisioning profile.** With `CODE_SIGN_STYLE=Automatic` already set, Xcode auto-creates both on first archive — no manual cert request needed. The first archive prompts for keychain access. Verify post-archive: Xcode → Settings → Accounts → Manage Certificates → should see "Apple Distribution" listed.

### Per-build steps (every TestFlight upload)

4. **Bump version in `pubspec.yaml`.** First-build recommendation: change `0.1.0+1` → `1.0.0+1` (rationale in decisions section below). Subsequent builds bump the `+N` build number monotonically.
5. **Build the IPA.** `cd apps/mobile && flutter build ipa` → produces `build/ios/ipa/clanquility.ipa` (and `.xcarchive` in `build/ios/archive/`).
6. **Upload the IPA.** Three options, pick one:
   - **Transporter.app** (Mac App Store, free): drag-drop the `.ipa`. Simplest.
   - **Xcode Organizer**: Window → Organizer → select archive → "Distribute App" → "App Store Connect" → "Upload". Validates as part of the flow.
   - **CLI**: `xcrun altool --upload-app --type ios -f build/ios/ipa/clanquility.ipa --apiKey ... --apiIssuer ...` (requires App Store Connect API key generation; deferrable to later automation).
7. **Wait for processing.** ~5–30 min after upload. App Store Connect → TestFlight tab → build appears in "Builds" once processed. Email notification on completion.

---

## Decision: Internal vs External testing

**Recommendation: Internal first, External for wider rollout.**

For the immediate cohort (Andrew + wife + friend's household + possibly daughter's household; ~4–6 people), the tradeoffs split cleanly:

| | Internal | External |
|---|---|---|
| Tester count cap | 100 | 10,000 |
| Beta App Review required | No | Yes (first build only is a full review; subsequent builds for the same version usually pass instantly) |
| Build available to testers | ~5–30 min after upload (just processing time) | Same processing + ~24h first-review delay |
| Tester setup friction | Must be added as App Store Connect users (Users and Access → invite by email with role Developer or App Manager). Each tester needs an Apple ID and accepts the email invite. | Anyone with an email; no ASC user creation. Public link option available. |
| Apple constraint | "Managed Apple Accounts created in reserved domains can't be used to test builds" | None on email type |
| Build availability window | 90 days | 90 days |

**Why Internal first for this cohort:** wife + daughter's household are family; adding them as App Store Connect Developer-role users is a one-time email invite they accept on their own Apple IDs. No Beta App Review wait, builds testable same-day. The "friend's household" is the only external-leaning case — defer them until after the first internal round shakes out the obvious bugs, then add as External for the broader testing phase.

**If you want zero ASC user setup overhead and don't mind the ~24h first-review wait:** External-only is also fine. Slightly more friction now for less friction later.

**Required steps for chosen path (Internal):**
- After build is uploaded and processed: App Store Connect → Users and Access → invite each tester by email with role "Developer" or "App Manager" (Developer is fine).
- Each tester receives email → clicks "Accept Invitation" → installs TestFlight app on iPhone → signs in with Apple ID → app appears in their TestFlight.
- In App Store Connect → TestFlight → Internal Testing → create a group (e.g., "Family") → add the invited users → assign the build to the group.

---

## Decision: Xcode-managed vs Manual signing

**Recommendation: Xcode-managed (Automatic).** Already configured (`CODE_SIGN_STYLE = Automatic` in pbxproj). No reason to switch.

For a solo developer:
- Xcode auto-creates and renews the Apple Distribution certificate.
- Xcode auto-creates and renews the App Store provisioning profile.
- No manual cert/profile downloads or keychain juggling.
- Manual signing is only worth the friction when (a) you have a CI/CD pipeline that signs without an interactive Xcode session, or (b) you're juggling multiple team identities. Neither applies here.

When CI gets added later (months away), revisit. For now, automatic is the right call.

---

## Decision: First-build version number

**Recommendation: bump `pubspec.yaml` from `0.1.0+1` to `1.0.0+1` before the first TestFlight upload.**

Reasoning:
- Apple does not require starting at 1.0.0. `0.1.0+1` would upload fine. This is purely cosmetic.
- TestFlight testers see "Version 0.1.0 (1)" vs "Version 1.0.0 (1)" in the TestFlight app. The latter reads as "the app, ready to test" rather than "a pre-release fragment."
- When you later transition from TestFlight → App Store submission, the public-facing version number carries over. Starting at `1.0.0` means the App Store launch is "1.0.0" not "0.1.0," which is the standard convention.
- iOS rule: `CFBundleVersion` (the `+N` part) must be unique and monotonically increasing **within a given `CFBundleShortVersionString` train**. Reset across trains is allowed (`1.0.0+5` → `1.0.1+1` is fine on iOS). So starting at `1.0.0+1` doesn't lock you out of anything.

**Operationally:** Edit `pubspec.yaml` line 4: `version: 0.1.0+1` → `version: 1.0.0+1`. Single one-line commit before the archive build.

---

## Top first-upload gotchas

Specific errors most-reported by first-time Flutter→TestFlight uploaders, with the fix. The "if X happens, do Y" entries that turn surprises into known events.

### 1. "Missing Compliance" warning on every build (export encryption)

**Symptom:** After upload completes, App Store Connect → TestFlight shows a warning icon and "Missing Compliance" status. Testers can't receive the build. Apple asks you to answer the export-compliance question for *every* new build.

**Root cause:** Flutter uses HTTPS by default, which triggers Apple's encryption-export classification. Without an explicit declaration, Apple flags every build for manual review.

**Fix:** Add this key to `apps/mobile/ios/Runner/Info.plist`:
```xml
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```
One-time fix. Suppresses the prompt forever. **This is currently missing from our Info.plist — add before first archive.**

### 2. ITMS-90683: Missing Purpose String in Info.plist

**Symptom:** Upload fails with "ITMS-90683: Missing Purpose String in Info.plist — Your app's code references one or more APIs that access sensitive user data. The app's `Info.plist` must contain an `NS<X>UsageDescription` key with a user-facing purpose string."

**Root cause:** A plugin (or transitive dependency) links against a privacy-guarded API and the matching `NSxUsageDescription` key isn't in Info.plist. The upload log names the specific key.

**Current state:** Our plugins (`image_picker`, etc.) need camera + photos. Both `NSCameraUsageDescription` and `NSPhotoLibraryUsageDescription` are already present and filled in. **Should not hit this on first upload, but if it surfaces, the email tells you which key — add it to Info.plist, re-archive, re-upload.**

### 3. ITMS-90704: Missing App Store Icon (1024×1024)

**Symptom:** Upload accepted, but Beta App Review rejected with "ITMS-90704: Missing App Store Icon" or "ITMS-90717: Invalid App Store Icon — alpha channel."

**Root cause:** The 1024×1024 slot in AppIcon is empty, OR the image has a transparency channel.

**Current state:** Our 1024×1024 marketing icon is present and confirmed alpha-free (verified with `sips -g hasAlpha` → `hasAlpha: no`). **Should not hit this. Skip.**

### 4. ITMS-90062: Invalid CFBundleVersion / build number not increasing

**Symptom:** Re-upload after a failed attempt rejected with "This bundle is invalid. The value for key CFBundleVersion [N] in the Info.plist file must contain a higher version than that of the previously approved version [N]."

**Root cause:** Even if a previous upload *failed validation*, Apple may have recorded the build number. Re-uploading with the same `+N` is rejected. Every upload attempt — successful or failed — should bump the build number.

**Fix:** `pubspec.yaml` bump the `+N` (e.g., `1.0.0+1` → `1.0.0+2`), OR use the build flag without editing pubspec: `flutter build ipa --build-number=2`.

### 5. CFBundleIconName missing (ITMS-90713)

**Symptom:** Upload rejected with "ITMS-90713: Missing Info.plist value — A value for the Info.plist key `CFBundleIconName` is missing in the bundle."

**Root cause:** Icons not in asset catalog (we're fine here), or `CFBundleIconName` key missing from Info.plist (we're missing this key).

**Current state:** Modern Xcode (14+) usually auto-injects `CFBundleIconName = AppIcon` at build time when an `AppIcon` asset-catalog set is present. We have the asset set. Probability this fires is low but non-zero.

**Fix if it surfaces:** Add to `Info.plist`:
```xml
<key>CFBundleIconName</key>
<string>AppIcon</string>
```

---

## Tomorrow's checklist

A clean ordered sequence for tomorrow morning. Execute top to bottom. Time estimates are wall-clock including waits.

### Phase A — Local Info.plist update (~5 min)

1. Open `apps/mobile/ios/Runner/Info.plist`.
2. Add the encryption-compliance key inside the top-level `<dict>`:
   ```xml
   <key>ITSAppUsesNonExemptEncryption</key>
   <false/>
   ```
3. Bump `pubspec.yaml` line 4: `version: 0.1.0+1` → `version: 1.0.0+1`.
4. Commit:
   ```
   git add apps/mobile/ios/Runner/Info.plist apps/mobile/pubspec.yaml
   git commit -m "ios: pre-TestFlight setup — encryption compliance flag + v1.0.0+1"
   git push origin main
   ```

### Phase B — Apple Developer Portal (~5 min)

5. Go to https://developer.apple.com/account/resources/identifiers/list
6. Click "+" → App IDs → Continue → App → Continue.
7. Description: `Clanquility`. Bundle ID: select "Explicit", enter `com.clanquility.app`.
8. Capabilities: leave defaults (no special capabilities — we have no .entitlements file).
9. Continue → Register.

### Phase C — App Store Connect record (~5 min)

10. Go to https://appstoreconnect.apple.com/apps
11. Click "+" → New App.
12. Fill:
    - Platforms: iOS
    - Name: `Clanquility`
    - Primary Language: English (U.S.)
    - Bundle ID: `com.clanquility.app` (should appear in dropdown from Phase B)
    - SKU: `clanquility-ios`
    - User Access: Full Access
13. Click Create.

### Phase D — Add internal testers as App Store Connect users (~5 min per tester)

14. Go to https://appstoreconnect.apple.com/access/users
15. Click "+" to invite each tester by email. Role: "Developer". They'll get an email; they accept on their own time.
16. Don't block on tester acceptance — proceed to build upload while they accept.

### Phase E — Archive + Upload (~15 min build + ~15 min processing)

17. `cd ~/honeydo/apps/mobile`
18. `flutter clean && flutter pub get`
19. `flutter build ipa` — produces `build/ios/ipa/clanquility.ipa`.
20. Open Transporter.app (or install from Mac App Store if needed).
21. Drag `clanquility.ipa` into Transporter → Deliver.
22. Wait for "Delivered successfully" toast (~2 min upload + ~10-30 min Apple processing).
23. Email arrives: "Your build [Clanquility 1.0.0 (1)] has been processed and is now available."

### Phase F — Set up TestFlight Internal group (~5 min)

24. App Store Connect → Apps → Clanquility → TestFlight tab.
25. If "Missing Compliance" warning appears despite the Info.plist flag: click the warning → answer "No" to "Does your app use encryption?" → save.
26. Internal Testing → "+" next to "Internal Testing" → Create group → name "Family".
27. Add testers to the group (only testers who've accepted the App Store Connect invite will be selectable; revisit Phase D for any still pending).
28. Assign the build (1.0.0 (1)) to the group.

### Phase G — Tester onboarding (~5 min per tester, async)

29. Tester receives "You're invited to test Clanquility" email.
30. Tester installs TestFlight app on iPhone (App Store).
31. Tester clicks the email link → opens TestFlight → "Accept" → "Install."
32. App appears on tester's home screen.

**Total active time: ~40 minutes** (mostly Phase A through E). Plus ~30 min of Apple processing wait. Plus async tester invite acceptance.

---

## Open questions for Andrew

Things this research can't answer — your decisions to make:

1. **Family testers' Apple IDs.** Do your wife and (if applicable) daughter / friend already have Apple IDs they want to use for testing, or do they need to set ones up? (Phase D requires this.)
2. **Internal vs External choice — confirm.** This doc recommends Internal-first for family + a friend's household once they're invited as ASC users. Are you comfortable adding family as App Store Connect "Developer" role users? (It's a read-only invite from their perspective — they see one app, don't get developer powers, but technically they appear as users on your team.) If not, default to External and accept the ~24h first-review delay.
3. **App Store listing name.** Doc assumes `Clanquility` for the App Store Connect "Name" field (up to 30 chars). Anything you'd prefer instead? Subtitle (up to 30 chars; optional) — what should it say? Not needed for first upload but worth pre-deciding so the App Store record is filled out cleanly.
4. **SKU.** Doc suggests `clanquility-ios`. Any reason to use a different convention? (It's internal-only, never user-facing, but cannot be reused once set.)
5. **Beta App Review encryption answer (if it ever asks).** Phase F step 25: answer "No" to "Does your app use encryption?" — confirm: Clanquility uses only standard HTTPS (Supabase, image upload), no custom crypto. If you're using anything beyond standard TLS, the answer changes and you may need to file an export-compliance document. (Strong default: standard HTTPS = "No, doesn't use encryption beyond what's exempt.")
6. **TestFlight description / "What to Test" text.** TestFlight lets you write release notes per build (what testers should focus on). Optional but useful. Worth a one-paragraph note for the first build pointing at the chore-photo + recipe-import flows?

Answer these and tomorrow's session is a pure execution sequence.

---

## References

- docs.flutter.dev/deployment/ios — canonical Flutter iOS deploy path
- developer.apple.com/help/account/identifiers/register-an-app-id/ — bundle ID registration
- developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/ — App Store Connect record creation
- developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/ — Internal testing
- developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers/ — External testing
- developer.apple.com/library/archive/technotes/tn2420/_index.html — Version Numbers and Build Numbers
- developer.apple.com/help/app-store-connect/test-a-beta-version/provide-export-compliance-information-for-beta-builds/ — ITSAppUsesNonExemptEncryption
- developer.apple.com/documentation/xcode/configuring-your-app-icon — Asset catalog AppIcon

Local audits referenced:
- `audits/2026-05-29-testflight-readiness-assessment.md` (prior session) — 9-day path overview
