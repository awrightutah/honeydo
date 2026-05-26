# Batch 6c — iOS Push Notifications (Investigation)

Date: 2026-05-25
Branch: `feat/meals-batch-6c-2026-05-25`
Status: **READ-ONLY investigation** — no code, no migrations, no commits

## TL;DR (honest read)

**This is the biggest single batch in Pass 3 by a wide margin.** Push notifications need work in *four* different layers (Apple Developer Portal config, Xcode project, Flutter app, Supabase edge function), each with its own gotchas. Two of those layers (Apple Developer + Xcode) are things you have not touched before. Realistic estimate: **8–15 hours of work**, almost certainly across 2–3 work sessions, with at least 2–3 cycles of "why isn't this firing yet."

**Good news**: Phase 0 found that ~30% of the foundation is already in place — `device_tokens` and `notification_preferences` tables exist in migration 0001 with RLS policies, and there's a 126-LOC `notification_service.dart` with `registerDeviceToken()` / `unregisterDeviceToken()` already stubbed (though never called from anywhere yet). The existing `notification_preferences_screen` (386 LOC) renders the prefs UI.

**Less good news**: that existing UI writes to **columns that don't exist** in the schema (`push_enabled`, `chore_verification`, `meal_reminders` vs the DB's `verification_alerts`, `chore_reminders`, no `meal_reminders`) — silent-failure pre-existing bug. There is **zero** iOS native push wiring, **zero** Flutter push plugin in `pubspec.yaml`, **no** entitlements file, and **no** `supabase/functions/` directory.

**Strong recommendation**: split 6c into **four sub-batches**, each 2–4 hours. Detailed split at the end of Phase 7.

---

## Phase 0 — Inventory (what already exists)

### Existing infrastructure (already done)

| Layer | What exists | Where | Status |
|---|---|---|---|
| DB schema | `notification_preferences` table | migration `0001:358` | ✅ Created, has RLS policy |
| DB schema | `device_tokens` table | migration `0001:372` | ✅ Created, has RLS policy |
| App service | `NotificationService` singleton | `lib/services/notification_service.dart` (126 LOC) | ⚠️ Methods exist but `registerDeviceToken` is **never called** from anywhere; legacy `.eq('auth_user_id')` pattern |
| App UI | `NotificationPreferencesScreen` | `lib/screens/notification_preferences_screen.dart` (386 LOC) | ⚠️ Wired to NotificationService but writes to **non-existent DB columns** (see "Existing bugs" below) |
| App route | Settings → notification prefs entry | (likely in `home_shell` popup menu — confirm during impl) | ✅ Reachable |
| Bundle ID | `com.familytask.honeydoMobile` | `ios/Runner.xcodeproj/project.pbxproj:386` | ✅ Set; will need APNs enabled |

### `device_tokens` table schema

```sql
create table public.device_tokens (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references public.household_members(id) on delete cascade,
  platform text not null,
  token text not null unique,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);
```

RLS (0001:549): `device_tokens_member_all` — a row is accessible iff the caller is a member of the same household as the row's `member_id`. **Note**: this is permissive at the household level, not per-member. For dispatch we just need to look up tokens by `member_id`, so this is fine.

**What's missing vs spec needs:**
- No `is_active` flag (could `delete` on logout, or add this column)
- No `last_failure_at` column (would help auto-deactivate stale tokens that APNs rejects)
- No `(member_id, token)` composite unique — `token` alone is unique, which is technically tighter

Probably **fine as-is for 6c-i**. Add columns later if needed.

### `notification_preferences` table schema

```sql
create table public.notification_preferences (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references public.household_members(id) on delete cascade unique,
  morning_digest boolean not null default true,
  evening_recap boolean not null default true,
  chore_reminders boolean not null default true,
  verification_alerts boolean not null default true,
  gamification_alerts boolean not null default true,
  calendar_reminders boolean not null default true,
  quiet_hours_start time default '21:00',
  quiet_hours_end time default '07:00',
  updated_at timestamptz not null default now()
);
```

RLS (0001:546): `notification_preferences_member_read` — SELECT only (no INSERT/UPDATE policy?). This means the existing `NotificationService.updatePreferences()` may be failing silently against RLS. **Will need a fresh policy in the 6c migration.**

### Existing bugs surfaced

1. **DB-schema mismatch in `notification_preferences_screen.dart`**: writes to `push_enabled`, `chore_verification`, `meal_reminders`. The DB has `chore_reminders`, `verification_alerts`, NO `push_enabled`, NO `meal_reminders`. Net effect: every toggle in the existing UI silently fails. (`notification_service.dart:101-119` shows the .update() that would just do nothing.) **Must reconcile during 6c-iii or earlier.**
2. **`notification_preferences` has SELECT-only RLS** but the app tries to INSERT defaults (`notification_service.dart:90`) and UPDATE toggles. Needs additional RLS in the 6c migration.
3. **Both `notification_service.dart` and `notification_preferences_screen.dart` use legacy `.eq('auth_user_id', user.id)`** — same pre-existing pattern from the 7-screens list. Will need MembershipHelper migration during 6c-i.

### What does NOT exist

| Layer | What's missing |
|---|---|
| iOS Info.plist | No `UIBackgroundModes` entry. Need to add `remote-notification`. |
| iOS entitlements | **No `.entitlements` file at all.** Need to create `Runner.entitlements` with `aps-environment` key. |
| iOS AppDelegate | No `UNUserNotificationCenter.current().requestAuthorization` call. No `didRegisterForRemoteNotificationsWithDeviceToken`. The current `AppDelegate.swift` is 16 lines, totally bare. |
| pubspec.yaml | No push plugin. Options: `firebase_messaging` (heavyweight; needs Firebase project setup), `flutter_apns_only` (direct APNs, no FCM), or a hand-rolled MethodChannel. **Recommend `flutter_apns_only`** — minimal, no Firebase dependency, ~70 KB. |
| supabase/functions/ | **Directory does not exist.** No edge functions today. This is the first one. Means setting up Supabase CLI locally, running `supabase functions new`, configuring secrets, deploying. |
| Apple Developer Portal | APNs Authentication Key not generated (`.p8` file). Bundle ID may or may not have Push Notifications capability enabled (you'd need to log in to check). |
| Dispatch trigger | No code path in any RPC calls a push endpoint. `decide_meal_request`, `approve_chore`, `approve_wishlist_item` all just return JSONB and stop. |
| Permission flow UX | No "pre-permission" dialog before iOS's system prompt. No "you've blocked notifications, go to Settings" handoff. |
| Quiet hours respect | No code anywhere reads `quiet_hours_start` / `quiet_hours_end` to gate dispatch. The DB has the columns but they're unused. |
| Deep linking | No router config for "tap notification → open Approvals/recipe/chore detail". `go_router` is installed so it should be straightforward, but the routes are not wired today. |

### Migration history relevant to 6c

`0017_kid_perms_rls_rpcs.sql` shipped `decide_meal_request`, `approve_chore`, `approve_wishlist_item` — all without notification dispatch. `0021_amend_add_shopping_item_and_approve_wishlist.sql` amended `approve_wishlist_item` but still no dispatch.

---

## Phase 1 — Spec details on push

From `/audits/2026-05-kid-profile-permissions-spec.md`:

### What spec says explicitly

- **Line 16 (Q3)**: meal request decision → activity feed + recent-requests view + **iOS push notification (if push is enabled in the app)**.
- **Line 109**: "iOS push notification with the same message. Honors the user's `notification_preferences` (existing table) — if push is disabled, this channel is skipped silently; the activity feed entry and recent-requests view still appear."
- **Line 111**: "This is the first push-enabled feature in the app. Push infrastructure (APNs setup, device token registration via the existing `device_tokens` table, server-side dispatch) lands in Batch 6 and is designed to be reusable for chore-approval and wishlist-approval notifications in later passes."
- **Line 124**: "Includes APNs setup and device-token registration. **This is the first push-enabled feature; subsequent batches may retrofit push to chore approvals and wishlist approvals.**"

### What spec leaves open

- **Per-event-type toggles vs global push toggle**: spec just says "push is enabled in the app" (singular). Implies a global on/off. But the existing `notification_preferences` table has 6 boolean columns + the broken UI uses keys like `chore_verification` / `meal_reminders`. **Decision needed (Q8a).**
- **Quiet hours**: DB has the columns, spec doesn't mention enforcement. **Decision needed (Q8b).**
- **Admin direction**: spec only discusses kid being notified on decide. Does admin get notified when kid submits? **Spec is silent. Decision needed (Q8c).**
- **Group/digest**: nothing in spec. Default to per-event individual pushes.
- **Sound + badge**: no spec. Default to system default sound + bumping the app icon badge to match the pending-approvals count.
- **Deep link**: spec implicit ("tap to view"), no specific routing. Recommend tap → Approvals screen for admin pushes, tap → recipe_library "My Requests" tab for kid pushes.
- **Subsequent batches retrofit chore + wishlist**: spec line 124 explicitly defers these. So **for 6c MVP, only meal-decide notifications need to ship**. Other events come in 7+.

---

## Phase 2 — Apple Developer Portal setup (CRITICAL — first-time walkthrough)

You will need to do this **before** any of the code changes work end-to-end. It cannot be done from inside Claude Code; it's manual portal navigation.

### Prerequisites

- Active Apple Developer Program membership (paid, $99/yr — you said you have this).
- Access to your Apple ID with the Developer role on the team.
- Your bundle ID: **`com.familytask.honeydoMobile`** (confirmed from `ios/Runner.xcodeproj/project.pbxproj:386`).
- About **30–45 minutes** uninterrupted.

### Step 2.1 — Enable Push Notifications on the App ID

1. Go to <https://developer.apple.com/account/resources/identifiers/list>.
2. Find `com.familytask.honeydoMobile` in the App IDs list (or create it if missing — though it likely exists since you've been building to a real device).
3. Click it → scroll to "Capabilities" → check **Push Notifications**.
4. Click "Save" at the top right.
5. (If you don't see "Push Notifications" in capabilities, your account may not have rights — escalate to whoever owns the team membership.)

### Step 2.2 — Create an APNs Authentication Key (.p8)

Apple supports two ways to authenticate to APNs:
- **Legacy**: per-app SSL certificate (`.p12`), expires yearly, painful to rotate.
- **Modern (recommended)**: APNs Authentication Key (`.p8`), a single key that works for **all** apps on your team, doesn't expire.

**Use the modern way.**

1. Go to <https://developer.apple.com/account/resources/authkeys/list>.
2. Click the `+` button next to "Keys".
3. Name the key (e.g., "Honeydo APNs Key").
4. Check the box **Apple Push Notifications service (APNs)**.
5. Click "Continue" → "Register" → "Download".
6. **You can only download this file ONCE.** Save it somewhere permanent (e.g., 1Password / a secure folder). It will be named `AuthKey_XXXXXXXXXX.p8` where `XXXXXXXXXX` is your Key ID.
7. **Record three values you'll need for Supabase secrets:**
   - **Key ID** — the 10-character string in the filename (also shown in portal).
   - **Team ID** — your Apple Developer Team ID. Find it at <https://developer.apple.com/account/#MembershipDetailsCard> (10-character string).
   - **Bundle ID** — `com.familytask.honeydoMobile`.

### Step 2.3 — Confirm provisioning profile

For real-device testing, your provisioning profile must include the Push Notifications entitlement. Usually Xcode handles this automatically when you enable Push Notifications in the project. If Xcode complains during build, regenerate the profile.

### Common gotchas

- **`.p8` lost**: you'd have to revoke the old key and create a new one. Not the end of the world, but mildly annoying.
- **Wrong Team ID**: APNs will return 403 silently. Always verify in <https://developer.apple.com/account/#MembershipDetailsCard>.
- **Bundle ID typo**: APNs returns `BadDeviceToken`. Triple-check.
- **Sandbox vs production endpoint**: real device builds via Xcode use the **sandbox** APNs endpoint (`api.sandbox.push.apple.com`); TestFlight + App Store builds use **production** (`api.push.apple.com`). Edge function needs to pick the right one. **First-deploy bug** — almost always trips people up the first time.

### Time estimate

- ~30 minutes if everything goes smoothly.
- Add 30–60 minutes for back-and-forth if the bundle ID doesn't exist yet or the team membership lookup is fiddly.

---

## Phase 3 — Database design

### Existing tables (no schema changes needed for 6c-i)

`device_tokens` and `notification_preferences` exist with the right shape. The minor schema gaps (`is_active` flag, `last_failure_at`) are nice-to-have but not blocking.

### What 6c needs in a new migration

**Migration `0022_notifications_rls_and_dispatch.sql`** (~80–120 LOC):

1. **Add INSERT + UPDATE policies on `notification_preferences`** — currently SELECT-only. Members must be able to create their own row + toggle their own preferences.

2. **(Optional) Add `is_active` boolean to `device_tokens`** — defaults to true, set to false on logout or when APNs returns "Unregistered". Allows soft-delete instead of hard-delete (preserves history).

3. **(Optional) Add `last_failure_at timestamptz` to `device_tokens`** — for stale-token cleanup.

4. **New RPC `register_device_token(p_token text, p_platform text)`** — SECURITY DEFINER, sets search_path = public. Takes the FCM/APNs token, resolves the caller's active member id via `auth.uid()`, upserts on `(member_id, token)` conflict. This wraps what `notification_service.dart` does today, but properly active-member-aware (so kid registrations attribute to the kid sub_profile, not the parent admin). Adheres to the established `add_shopping_item` / `create_meal_request` SECURITY DEFINER pattern.

5. **(Optional, for dispatch)** A helper view or function that, given a `member_id`, returns active tokens for dispatch. The edge function will need this.

### Schema reconcile (must do during 6c-iii)

The existing `notification_preferences` columns are kind of generic (`chore_reminders`, `verification_alerts`, `gamification_alerts`, `calendar_reminders`, `morning_digest`, `evening_recap`). The spec implies a simpler "push_enabled" global toggle. **Recommend** adding a single `push_enabled boolean not null default true` column in 6c-iii and treating the existing booleans as "feature-area toggles" (where `verification_alerts` covers chore-approve, meal-decide, wishlist-decide collectively — one switch per *kind* of notification, not per *event*). Reconcile the UI to match the schema.

---

## Phase 4 — Edge function design (Supabase)

### Bootstrap (one-time)

Since `supabase/functions/` doesn't exist:

```bash
# Install Supabase CLI if not present:
brew install supabase/tap/supabase

# Login:
supabase login

# Link this repo to the remote project:
supabase link --project-ref <your-project-ref>

# Initialize functions dir + create first function:
supabase functions new send-push
```

This creates `supabase/functions/send-push/index.ts` plus a `_shared/` dir if you make helpers later. Deployment is via `supabase functions deploy send-push --no-verify-jwt` (for service-role invocation).

### Function shape

```typescript
// supabase/functions/send-push/index.ts
// Receives: { member_id, title, body, data, badge? }
// Looks up active tokens for that member_id
// For each token: signs JWT with .p8, POSTs to APNs HTTP/2
// On 410 / BadDeviceToken / Unregistered: mark token inactive
// Returns: { dispatched: N, failed: M, errors: [...] }
```

Roughly 200–350 LOC TypeScript including:
- JWT signing (use `jose` from npm via `npm:jose` import or Deno-native crypto)
- APNs HTTP/2 client (use `fetch` with the right headers + body)
- Token lookup (Supabase service-role client)
- Error handling + retries on transient failures
- Sandbox vs production endpoint selection (env var `APNS_USE_SANDBOX` — true on dev, false on prod)
- Telemetry logging

### Secrets needed (set via `supabase secrets set`)

| Secret | Value |
|---|---|
| `APNS_KEY_ID` | 10-char Key ID from .p8 filename |
| `APNS_TEAM_ID` | 10-char Team ID from Apple Developer |
| `APNS_BUNDLE_ID` | `com.familytask.honeydoMobile` |
| `APNS_PRIVATE_KEY` | Full .p8 file contents (including `-----BEGIN PRIVATE KEY-----` lines) |
| `APNS_USE_SANDBOX` | `true` for dev, `false` for prod (or detect from token-shape; sandbox tokens are ~64 bytes hex, but easier to just config) |

### Invocation (3 options — recommend Option A)

**Option A — `pg_net` from Postgres trigger** (recommended)

```sql
-- After UPDATE on meal_requests (status -> approved or denied):
CREATE FUNCTION trg_dispatch_meal_decision_push() ...
  PERFORM net.http_post(
    url := 'https://<project>.functions.supabase.co/send-push',
    headers := jsonb_build_object('Authorization', 'Bearer ' || current_setting('app.service_role_key')),
    body := jsonb_build_object(
      'member_id', NEW.requested_by_member_id,
      'title', CASE WHEN NEW.status='approved' THEN '✅ Meal approved!' ELSE '❌ Meal denied' END,
      'body', '<recipe title> ...',
      'data', jsonb_build_object('type', 'meal_decided', 'request_id', NEW.id)
    )
  );
END;
```

Pro: dispatch is automatic on any decision path (admin UI, future bulk-admin tool, anything that hits the RPC). No client involvement.
Con: introduces `pg_net` dependency. Needs `service_role_key` accessible to the trigger (via secrets or `app.settings`).
Pro: fire-and-forget, no blocking the RPC.

**Option B — Amend the RPC to dispatch**

Add `PERFORM net.http_post(...)` inside `decide_meal_request` after the UPDATE/INSERT. Same `pg_net` dependency. Slight risk of the RPC blocking on slow network. Less robust if future bulk-decision paths don't go through the RPC.

**Option C — Client-side dispatch**

App calls the function directly after the RPC returns. **Reject this**: kid could spoof notifications, and admin's app might be backgrounded during the decide flow.

### Time estimate

- First-time Supabase CLI + linking: ~30 min
- Edge function code: ~3–4 hours including iteration
- Secret config + deploy: ~15 min
- First-deploy debugging (sandbox endpoint, JWT mistakes, token format): ~2–3 hours realistic; this is where most of the pain lives.

---

## Phase 5 — App-side changes

### Plugin choice

**Recommend: `flutter_apns_only`** (~70 KB). No Firebase dependency. Direct APNs.

Alternatives considered:
- `firebase_messaging`: requires Firebase project, GoogleService-Info.plist, FCM relay setup. Overkill for iOS-only push. **Skip unless you plan Android push within 6 months.**
- `flutter_local_notifications`: only does local notifications (notifications scheduled from within the app for in-app reminders). **Not what we need.** Could be added later if we want background reminders.
- Hand-rolled MethodChannel: maximum control, ~3x the work. Not worth it for first push setup.

### Required code changes

**`pubspec.yaml`** (+1 LOC)
```yaml
flutter_apns_only: ^4.x.x
```

**`ios/Runner.entitlements`** (NEW FILE, ~10 LOC XML)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>aps-environment</key>
  <string>development</string>  <!-- "production" for App Store builds -->
</dict>
</plist>
```

Plus: in Xcode, drag the entitlements file into the Runner target → Build Settings → Code Signing Entitlements → `Runner/Runner.entitlements`. (Or edit `project.pbxproj` directly. Xcode UI is easier.)

**`ios/Runner/Info.plist`** (+5 LOC)
```xml
<key>UIBackgroundModes</key>
<array>
  <string>remote-notification</string>
</array>
```

**`ios/Runner/AppDelegate.swift`** (+30-50 LOC)

Override `application(_:didFinishLaunchingWithOptions:)` to:
1. Set `UNUserNotificationCenter.current().delegate = self`.
2. Call `application.registerForRemoteNotifications()` (after user grants permission).
3. Override `didRegisterForRemoteNotificationsWithDeviceToken` to forward the token to Flutter via MethodChannel.

**`lib/services/notification_service.dart`** — amend:
1. Migrate to `MembershipHelper.loadActiveMembership()` (fix legacy `.eq('auth_user_id')` pattern).
2. Add `Future<bool> requestPermissionAndRegister()` that:
   - Calls `flutter_apns_only`'s `requestNotificationPermissions()` → returns true if granted.
   - On grant, retrieves the APNs token via the plugin.
   - Calls the new `register_device_token` RPC (proper kid-attribution).
3. Add foreground-notification handling: on message received while app is foregrounded, surface as an in-app SnackBar or banner (Apple doesn't auto-show foreground notifications).
4. Add tap handler: route to the right screen based on `data.type` (e.g., `meal_decided` → push `RecipeLibraryScreen` then jump to "My Requests" tab).

**`lib/main.dart`** (~10 LOC)

Wire up an initial call to `NotificationService.requestPermissionAndRegister()` after successful auth + household_setup completion. Could be on home_shell init or on first foreground.

**Pre-permission dialog** (recommended UX, ~80 LOC)

Apple's permission dialog is one-shot — if user denies it once, the only way to re-prompt is to send them to Settings.app. To avoid pre-emptive denial, show a soft pre-permission dialog *first* ("We use notifications to let Randi know when her meal requests are approved..."). Only if they tap "OK" do we call the system permission API.

**Notification preferences screen** — fix:
1. Migrate to `MembershipHelper`.
2. Reconcile UI keys with DB schema (or amend the DB schema in the 6c-iii migration).
3. Add an "Open System Settings" handoff for users whose permission was denied.

### Deep links (Q8d)

- `meal_decided` → if kid, push to `RecipeLibraryScreen` with `_tabController.animateTo(2)` ("My Requests"). If admin (impossible for this event in 6c MVP), no-op.
- Future events:
  - `chore_approved` / `chore_rejected` → push `ChoreDetailScreen`.
  - `wishlist_approved` / `wishlist_denied` → push `ShoppingListScreen` and scroll to the item.
  - `chore_submitted_for_review` → push `ApprovalsScreen` (admin).

### Time estimate

- pubspec + entitlements + Info.plist tweaks: 30 min
- AppDelegate.swift + MethodChannel: 1–2 hours (first time)
- NotificationService amendments + integration: 1–2 hours
- Permission flow UX + pre-dialog: 1 hour
- Deep link routing: 1–2 hours
- Notification preferences reconcile: 1 hour
- iPhone smoke + debug cycle: 2–3 hours realistic

**Phase 5 subtotal: 7–11 hours.**

---

## Phase 6 — Event integration (which events get pushes)

### MVP set for 6c (recommend keeping tight)

**Only meal-decide pushes ship in 6c.** Aligns with spec line 124 ("subsequent batches may retrofit push to chore approvals and wishlist approvals"). Three triggers:

1. **Meal request approved** → notify the requesting kid.
   - Title: `✅ Meal approved!`
   - Body: `Your "<recipe title>" request was approved for <date> <meal_type>`
   - Deep link: My Requests tab
2. **Meal request denied** → notify the requesting kid.
   - Title: `❌ Meal denied`
   - Body: `Your "<recipe title>" request was denied${note ? '. "$note"' : ''}`
   - Deep link: My Requests tab

That's it for 6c. Two notification copies, one trigger point (`decide_meal_request` RPC → `pg_net` POST → edge function → APNs).

### Future batches (NOT in 6c)

Once 6c MVP proves the dispatch loop works end-to-end, retrofitting is mostly copy-paste of triggers + one new copy string per event:

| Event | Trigger | Recipient | Copy |
|---|---|---|---|
| Chore approved | `approve_chore` RPC | kid who submitted | "Your '<title>' chore was approved — +<X> points!" |
| Chore rejected | `approve_chore` (p_approved=false) | kid who submitted | "Your '<title>' chore was rejected. <reason>" |
| Wishlist approved | `approve_wishlist_item` RPC | kid who added | "Your '<item>' wishlist item was approved" |
| Wishlist denied | `approve_wishlist_item` (p_approved=false) | kid who added | "Your '<item>' wishlist item was denied. <reason>" |
| New chore assigned | `chores` INSERT trigger | assignee | "New chore: <title> (due <date>)" |
| Kid submits chore for review | `submit_kid_chore_with_photo` RPC | every admin | "Randi finished <chore>. Tap to review." |
| Kid submits meal request | `create_meal_request` RPC | every admin | "Randi wants <recipe> for <date>" |
| Kid adds wishlist item | `add_shopping_item` (is_wishlist=true) | every admin | "Randi added '<item>' to the wishlist" |

8 future trigger points, each ~15 LOC of trigger SQL + one copy string. Probably one polish batch (~3–4 hours) lands them all once the dispatch loop is proven.

---

## Phase 7 — Total scope estimate + recommended sub-batch split

### Honest total

| Phase | Estimate |
|---|---|
| Apple Developer Portal + Xcode config | 1–2 hours |
| Migration 0022 (RLS + RPC) | 1 hour |
| Supabase CLI + edge function scaffold | 1 hour |
| Edge function code + debugging | 4–6 hours |
| App-side (plugin + AppDelegate + NotificationService) | 4–6 hours |
| Pref screen reconcile | 1 hour |
| Smoke + iteration cycle | 2–3 hours |
| **Total** | **14–20 hours** |

**This cannot be done in a single session. Period.** Sleep-deprived debugging on first APNs setup is how lost weekends happen.

### Recommended split into 4 sub-batches

Each sub-batch should be a separate branch, separate commit, separate smoke test. Stop and verify before moving on.

#### **6c-i — Foundation** (2–3 hours)

Apple Developer setup walkthrough + device_tokens RLS hardening + permission request flow + token registration end-to-end. **No notifications actually sent.** Goal: verify a real iPhone successfully obtains an APNs token and stores it in `device_tokens` correctly attributed to the right `member_id` (including kid sub_profiles).

Deliverables:
- (Manual) Apple Developer: APNs key created, bundle ID has Push enabled.
- Migration 0022: RLS hardening on notification_preferences (INSERT + UPDATE policies) + new `register_device_token` RPC.
- `pubspec.yaml`: `flutter_apns_only` added.
- `ios/Runner.entitlements` (new file): `aps-environment = development`.
- `ios/Runner/Info.plist`: `UIBackgroundModes = ['remote-notification']`.
- `ios/Runner/AppDelegate.swift`: register for remote notifications + forward token to Flutter via MethodChannel.
- `lib/services/notification_service.dart`: MembershipHelper migration + `requestPermissionAndRegister()` method.
- `lib/main.dart` or `home_shell_screen.dart`: invoke `requestPermissionAndRegister()` after auth on app first-foreground.
- Pre-permission dialog widget.

**Smoke test**: run on iPhone, accept permission, verify SQL `select * from device_tokens` shows the right row attributed to the kid/admin's `member_id`.

#### **6c-ii — Dispatch loop** (3–5 hours)

Edge function + Postgres trigger + meal-decide pushes working end-to-end for **one event type only**. This is the hardest sub-batch — first .p8 / JWT / APNs / sandbox-endpoint debug cycle lives here.

Deliverables:
- `supabase/functions/send-push/index.ts` (new): JWT signing, APNs HTTP/2 POST, token lookup, error handling.
- `supabase secrets set`: `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, `APNS_PRIVATE_KEY`, `APNS_USE_SANDBOX`.
- Migration 0023 (or amend 0022): trigger on `meal_requests` UPDATE → `pg_net.http_post` → edge function for status change to approved/denied.
- Foreground handling in NotificationService: SnackBar/banner when app is foregrounded.
- Deep link wiring: `meal_decided` data type → push to RecipeLibraryScreen → animate to My Requests tab.

**Smoke test**: as admin, approve a meal request on Phone 1. Kid (on Phone 2) gets push. Tap → lands on My Requests tab. Then deny one with a reason — same flow.

#### **6c-iii — Preferences reconcile** (2 hours)

Fix the pre-existing UI/DB schema mismatch + wire up the `push_enabled` global toggle.

Deliverables:
- Migration: add `push_enabled boolean not null default true` to `notification_preferences`.
- Migration: rename mismatched columns OR amend the UI to use existing column names (whichever is cleaner — recommend latter, less churn).
- `notification_preferences_screen.dart`: MembershipHelper migration + UI rewire to actual schema + Open Settings handoff for denied-permission state.
- Edge function honors `push_enabled = false` (skips dispatch silently).
- (Stretch) Quiet hours respect: edge function checks `quiet_hours_start` / `quiet_hours_end` and skips if within window.

**Smoke test**: toggle off `push_enabled`, repeat the 6c-ii smoke test, verify the kid does NOT receive a push (but still gets the activity feed + recent-requests entry from 6b).

#### **6c-iv — Meal request auto-archive** (1–2 hours)

Spec line 143's 30-day hard-delete carryforward. Probably a `pg_cron` job or a Postgres function that runs nightly.

Deliverables:
- Migration: enable `pg_cron` extension (if not enabled).
- Migration: `schedule cron job` that DELETEs `meal_requests` rows older than 30 days WHERE status != 'pending' (or include pending — spec is ambiguous).
- Audit doc on what gets deleted + retention rationale.

**Smoke test**: insert a fake row with `created_at = now() - interval '31 days'`, run the cron job manually, verify deletion.

### Why this split

- **6c-i is independently shippable** — registers tokens, verifies setup, no dispatch loop. If we get partway through and need to ship, this isn't dead code.
- **6c-ii contains the highest-risk code** — first .p8 / APNs / sandbox-endpoint debugging. Isolating it means we can roll back cleanly if there are blockers.
- **6c-iii is independent polish** — fixes a pre-existing bug + adds the global toggle. Can ship anytime.
- **6c-iv is unrelated to push** — could even be a 6c-iv-or-7a slot. The 30-day archive doesn't depend on push wiring at all; it's just been bundled by the spec for convenience.

---

## Phase 8 — Open questions

1. **(a) Global push toggle vs per-event-type**: spec implies global. Recommend: `push_enabled` master toggle + the existing 6 booleans repurposed as "feature-area" toggles (one switch per *kind*, not per *event*).
2. **(b) Quiet hours enforcement**: implement in 6c-iii or defer? Recommend: implement minimal version (skip during window). DB has the columns; cheap to honor.
3. **(c) Admin notifications when kid submits**: yes/no? Recommend: **NO for 6c MVP** — only kid-direction notifications ship. Add admin-direction in a future batch if user wants.
4. **(d) Deep links — which screens**: recommend My Requests tab for `meal_decided`. Future events get their own routing.
5. **(e) App icon badge sync**: should the badge match the pending-approvals total for admin / unread-pushes count for kid? Recommend: **defer to later batch.** Badge logic is its own rabbit hole.
6. **(f) Sound**: default system sound; custom sounds need additional Apple Developer config. Recommend: default.
7. **(g) Group notifications**: if a kid submits 3 meal requests then admin denies all 3, send 3 separate pushes or 1 grouped? Apple's NotificationCenter auto-groups by app and recently by thread-identifier. Recommend: ship as separate, let iOS group them.
8. **(h) Pre-permission dialog timing**: ask on first app launch after auth, or wait until first action that would benefit (kid submits first meal request → "want to know when admin approves? Enable notifications")? Recommend: defer to first action. Less aggressive.
9. **(i) Foreground display**: in-app SnackBar vs auto-suppress vs native banner-from-foreground? Recommend: SnackBar (in-house style, matches rest of the app).
10. **(j) Notification copy authoring**: I drafted suggested copy above. User should review the kid copy (`✅ Meal approved!` etc.) for tone — too casual? Too formal? Use first name vs "you"?
11. **(k) Apple Developer + Xcode walkthrough**: do you want a guided session (call out each step, you click through, I confirm screenshots), or write-then-execute? Recommend: guided — first time setups have surprises.
12. **(l) `pg_net` extension**: needs to be enabled on the Supabase project. Free tier supports it AFAIK; verify in dashboard before designing around it.
13. **(m) Schema reconcile direction in 6c-iii**: amend UI to match DB (less work, columns are already there) or migrate DB to match UI (more honest column names)? Recommend: amend UI; DB is shipped, UI bug is one-sided.
14. **(n) 6c-iv (auto-archive) timing**: include in 6c arc or move to Batch 7? Recommend: include as 6c-iv since spec bundles it with this batch's deferrals; but it's the lowest-risk piece and could slip without harm.

---

## Phase 9 — Risk surface

Honest list of where things go wrong:

1. **First-time APNs setup almost always trips on sandbox vs production endpoint**. Real-device dev builds use `api.sandbox.push.apple.com:443`; production uses `api.push.apple.com:443`. Picking the wrong one results in silent 400s. The `APNS_USE_SANDBOX` secret needs to flip when shipping to TestFlight. Expect 30–60 minutes of "why isn't this working" the first time.
2. **JWT signing mistakes**: Apple wants ES256-signed JWTs with `iss=team_id`, `iat=now`, and a `kid` header. Off-by-one on the key format (PKCS8 vs raw), wrong header alg, missing iat → 403. Use `jose` library, follow Apple's docs precisely.
3. **Bundle ID typo in entitlements / `apns-topic` header**: APNs returns `BadDeviceToken`. Triple-check `com.familytask.honeydoMobile` everywhere.
4. **Token format mismatch**: APNs tokens from `flutter_apns_only` come as a hex string; some libs expect base64. Verify.
5. **Permission denial recovery**: if user taps "Don't Allow" once, the only way to re-prompt is via Settings.app. No in-app retry. Need to detect denied state and offer "Open Settings" handoff. **Common UX mistake** to forget.
6. **Token refresh**: APNs tokens can change (rare, but happens — usually after restore/reinstall). `flutter_apns_only` exposes a token-refresh stream; need to subscribe and re-upsert. Forgetting this → notifications stop working after some users restore.
7. **Real iPhone vs Simulator**: simulator does NOT receive remote pushes (Apple limitation). You MUST test on a real device — which is fine, the user said they will. But the first 6c-i smoke must be on the iPhone.
8. **TestFlight vs Development builds need different `aps-environment`**: `development` for Xcode-built; `production` for TestFlight + App Store. Wrong value → tokens are issued by the wrong APNs environment → mismatched dispatch → no notification. **Bury this in a single secret + a CI flag, or just remember to flip before TestFlight.**
9. **Edge function cold start**: Supabase edge functions take ~1–3s to cold-start. The kid won't notice (push is async) but on a debug session this can feel like the function isn't firing. Add good logging.
10. **`pg_net` async**: trigger fires `net.http_post` which is non-blocking. If the POST fails, the trigger has no idea — failure is logged in `net._http_response` table. Need to monitor that during debug.
11. **APNs rate limits**: not a concern at our scale (one household, ~5 users), but worth knowing. Apple throttles >1 push per second per token.
12. **Lost .p8 file**: only downloadable once. Lose it = revoke + regenerate. Annoying but recoverable.
13. **Notification flooded if both admin parents both approve simultaneously**: low likelihood, but the trigger fires on every UPDATE that crosses to approved/denied. If a row toggles twice quickly (unlikely given the RPC's idempotency check), double-push. Investigate during smoke if it shows up.
14. **Schema reconcile (6c-iii) interacts with notification_preferences UI** — the existing UI's broken state means we have no idea what users have toggled today. **Recommend treating defaults as authoritative on first encounter post-fix.**

---

## Phase 10 — Recommended next session approach

If you have ~2 hours: do **only 6c-i** (foundation, no dispatch yet). Verify a real iPhone successfully registers a token attributed to the right `member_id`. Stop, sleep on it, commit.

If you have ~4 hours: do **6c-ii** in the next session, with the .p8 + JWT debugging spread across that block. Plan on iterating.

**Critical mid-session decision points** to lock with me before starting implementation:
- Phase 8 Q(a), Q(c), Q(m) — schema + scope decisions
- Whether to do guided Apple Developer Portal walkthrough or write-and-execute (Q(k))
- Confirmation that `pg_net` is available on your Supabase project (check dashboard before 6c-ii)

---

## What this investigation deliberately did NOT do

- Did not start the Apple Developer Portal setup.
- Did not write any code, any migration, any edge function.
- Did not modify `notification_service.dart` (pre-existing bugs documented but not fixed).
- Did not commit anything.
- Did not download any Flutter plugins.
- Did not enable any iOS capabilities.
- Did not test any push flow.

All of those are 6c-i+ work, awaiting user kickoff.

---

## Summary for the user (the one-paragraph version)

Push notifications are the biggest single batch in Pass 3, but ~30% of the foundation is already in place (DB tables exist, app service stub exists, prefs UI exists). The remaining 70% spans four layers — Apple Developer Portal setup, Xcode native config, Flutter plugin + integration, and Supabase edge function. Realistic total: **14–20 hours across 2–3 sessions**, with mandatory debug cycles. **Strongly recommend splitting into 4 sub-batches**: 6c-i (foundation + token registration, no dispatch), 6c-ii (edge function + meal-decide pushes only), 6c-iii (prefs UI reconcile + global toggle + quiet hours), 6c-iv (30-day auto-archive carryforward from 6b). Start with 6c-i, verify a real iPhone gets a token, then stop and commit. Don't try to do this in one shot.
