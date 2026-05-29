# TestFlight Readiness Assessment — 2026-05-29

## Purpose

Identify gaps in the user journey for 2-3 trusted-household testers, targeting TestFlight distribution by the weekend of 2026-06-06/07 (~9 days). Journey-oriented, not surface-oriented. Filter: would a stranger-tester hit this in their first 30 minutes? Would it make them give up in week 1?

State at capture: `main @ eeae301`, working tree clean.

---

## The 8 flows audited

### A. First-time app open / onboarding — **SHIP AS-IS**

`apps/mobile/lib/main.dart:AppEntryGate` shows a 2s splash (`splash_screen.dart`, 133 lines, animated), then runs a `StreamBuilder<AuthState>` on `Supabase.auth.onAuthStateChange`:
- no session → `AuthScreen`
- session + has household → `HomeShellScreen`
- session + no household → `OnboardingScreen` → `HouseholdSetupScreen`

Routing is sound. Onboarding (435 lines) is animated and ends at household setup.

### B. Account creation / login — **MUST FIX (one item)**

`auth_screen.dart` (329 lines): toggleable signup/sign-in form, email + password + display name, friendly error mapping for "already registered" and "Invalid login" (lines 67-68), "Forgot password?" → password-reset email dialog (line 257+). No OAuth, no magic-link.

**The risk:** `auth_screen.dart` has **zero references to email-confirmation handling** (verified via grep). If the Supabase project has "Confirm email" enabled in Auth settings, `signUp()` returns silently, no session arrives, and the user sees nothing — they tap Sign Up, get bounced back to the same screen, and conclude it's broken. The `AppEntryGate` has no "check your email" branch either.

Severity: **MUST FIX** (TestFlight blocker). Either disable email confirmation in Supabase Auth settings (1-min config change) or add a check-your-email screen (~half day). The config change is the right call for the TestFlight cohort of 2-3 known households — re-enable before any public launch.

### C. Joining/creating a household (invite flow) — **SHIP AS-IS**

`household_setup_screen.dart` (467 lines) has both paths:
- Create: `_createHousehold()` at line 57, INSERTs into `households` + creator's `household_members` row
- Join: `_joinHousehold()` at line 133 — takes a 6-char uppercase code, looks up in `household_invites`, validates expiry/revocation/use count, INSERTs the joining user's `household_members` row

Notable: this is all **direct Supabase INSERTs**. The Railway service's `/households/join` and `/households/:id/invites` endpoints exist (server.js:269, 329) but are **never called** by the mobile app — orphan code. The direct-Supabase path is what testers will hit. Not a blocker; the working path works.

Invite code share UX is wired (`invite_management_screen.dart`, 723 lines): generate code, share text (with prefilled message), copy to clipboard, revoke. Good.

### D. Adding a member / setting up kids — **SHIP AS-IS**

`members_screen.dart` (565 lines):
- Adults invited via invite codes from step C (no "add adult" button — they self-join)
- Kids added via `_showAddSubProfileSheet` → `_createSubProfile` (line 419): INSERTs into `household_members` with `kind='sub_profile'`, then immediately calls `set_member_pin` RPC for the PIN. PIN is **required at kid-creation time** (form validation in the sheet).
- Max 6 members per household (line 286 enforces this client-side)

For your friend's family (wife + 3 kids): wife joins via invite, then admin adds each kid with a PIN. Works.

### E. Home screen / first impression — **SHIP AS-IS**

`home_shell_screen.dart` is the post-login shell with 5-tab bottom nav (Chores / Meals / Shop / Calendar / Recipes) and a profile-switcher accessible via avatar tap. Empty states are surfaced thoughtfully across most screens:
- Chores: "No pending chores right now."
- Recipes (My Recipes tab): "No recipes yet — Import from a URL or create your own"
- Shopping: 🛒 "Your list is empty — Add items manually or import from a recipe"
- Activity feed: "No activity yet"
- Rewards, points, announcements, invites: all have explicit "No X yet" handling

The seed (`supabase/seed.sql`) provides 3 approved master_recipes (Taco Tuesday, Lemon Chicken, Spaghetti) + 15 system chore templates. **A brand-new household won't be totally blank** — they'll see those in Browse Library / chore-template picker.

### F. The four obvious first actions — **SHIP AS-IS**

All four core screens have discoverable "add" affordances:

| Screen | Add affordance |
|---|---|
| Chore Dashboard | FAB `_showAddChoreSheet` (line 297, 397) |
| Shopping List | FAB `_showAddItemSheet` (line 526) + "Add from Recipe" sub-action |
| Recipe Library | `FloatingActionButton.extended` (line 1155) + "Import from URL" + "Browse Library" tab |
| Meal Planner | Tap-day-in-grid → `_AddMealPlanSheet` (no FAB; calendar grid is the primary affordance) |

Meal Planner's affordance is the least discoverable — testers will see an empty grid and might not realize each cell is tappable. SHOULD FIX caliber but not a blocker.

### G. Recipe URL import — **KNOWN LIMITATION (set expectations up front)**

`recipe_library_screen.dart:419` POSTs to `${API_URL}/recipes/import` (Railway). Measured success rate: **1/3** on the known-good test set (datacenter IP, no proxy, no JS render — documented in `2026-05-27-recipe-code-inventory.md`).

On 2 of 3 attempts, testers see a SnackBar with the upstream error text — currently shows "Import failed" verbatim (line 433). For sites Cloudflare/Datadome-blocks, that means: paste URL, tap Import, see "Import failed" with no path forward.

The Phase 1 architecture decision committed to in-app WebView (4/4 success) as the replacement, but that's multi-day work — not viable in the 9-day window.

Severity: **KNOWN LIMITATION** for TestFlight. Two SHOULD-FIX adjustments to soften it:
1. Better failure copy: *"Couldn't read this recipe from the URL. Try copying the recipe text in manually instead."* (1-line string change)
2. Document in the tester briefing: "URL import works for ~30% of sites today. Manual entry always works."

### H. Kid permissions and sub-profile usage — **SHIP AS-IS**

`home_shell_screen.dart:_showProfileSwitcher` (line 610) lists eligible profiles, kid selection → PIN entry dialog → `verify_member_pin` RPC (line 714, bcrypt server-side). If a kid has no PIN, admin gets a "Set PIN" flow (line 754+); non-admin sees *"Ask an admin to set one."*

`ActiveMemberService` (one-screen service file) persists `active_member_id` in SharedPreferences so the switch survives app restarts. `MembershipHelper.loadActiveMembership()` (the helper the recipe-surface audit covered) resolves to the active kid's row when one is selected.

7 screens have `Permissions.isKid` gates: chore_dashboard, chore_detail, meal_planner, profile, recipe_detail, recipe_library, shopping_list. Coverage looks consistent with the kid-permissions audits from earlier days.

---

## Cross-cutting concerns

### Error handling

try/catch density is healthy. Top screens by handler count: chore_detail (15), recipe_library (10), shopping_list (9), recipe_detail (9), chore_dashboard (8). The Pass 2 error pattern (`try { ... } catch (e) { SnackBar(content: Text('Error: $e'))... }`) is consistently applied — testers will see human-readable errors on most failures, not silent freezes.

Two specific gotchas:
- The data-export "Recipes" section reads `.from('recipes')` — **a table that doesn't exist** (`data_export_screen.dart:160`). Either silently 404s or throws; either way it breaks the export flow for any tester who ticks the Recipes checkbox.
- Recipe import error copy is the upstream text "Import failed," not user-friendly.

### Loading states

20 screens use `CircularProgressIndicator` and/or `_isLoading` state. Shopping (20 refs), members (17), meal_planner (15), calendar (14), chore_dashboard (13). Reasonable coverage; users should rarely see frozen UI.

---

## The MUST FIX list (TestFlight blockers)

| # | Item | Where | Size | Why blocker |
|---|---|---|---|---|
| 1 | **Confirm Supabase email-confirmation setting** | Supabase Dashboard → Auth | S (1 min) | If on, every signup silently fails for testers. Disable for TestFlight; re-enable before public launch. |
| 2 | **`data_export_screen.dart:160` reads non-existent `recipes` table** | 1-line change to `household_recipes` | S | Breaks data export silently for any tester who ticks Recipes |
| 3 | **App name + bundle ID decision (TestFlight prereq)** | iOS project settings + App Store Connect | M | Apple Developer Portal needs final app name + bundle ID before TestFlight build can be uploaded. CFBundleDisplayName is currently "Honeydo Mobile"; bundle ID is a Build Variable. Roadmap has flagged this as blocking 6c push; same blocker for TestFlight itself. |
| 4 | **TestFlight build + upload + tester invite plumbing** | App Store Connect, Xcode build, TestFlight settings | M-L | Walkthrough work; not code. Apple Developer account, app record, signing cert, IPA build, internal/external testing group, invite emails. |

Total MUST FIX: 4 items, ~1 day code work + Apple-side setup time.

---

## The SHOULD FIX list

| # | Item | Where | Size |
|---|---|---|---|
| 1 | Recipe import failure copy | `recipe_library_screen.dart:433-444` — replace "Import failed" with "Couldn't read this recipe from the URL. Try copying the recipe text in manually instead." | S |
| 2 | Meal Planner add-affordance discoverability | `meal_planner_screen.dart` — consider adding a FAB or visible "+ Add meal" hint on first run | S-M |
| 3 | NetworkImage error fallback for active-member indicator | Per roadmap handoff — falls back to initials in colored circle. Cosmetic but obvious if it hits | S |
| 4 | `settings_screen.dart` nameController dispose leak | Per roadmap handoff. Tiny lifecycle bug, not crashing | S |
| 5 | Test recipe cleanup SQL (still pending from Day 6) | Supabase Dashboard SQL Editor — pre-prepared in yesterday's closeout response | S |
| 6 | Branch cleanup — 6 merged-and-stale local/remote branches | `git branch -d` × 4 spike branches + 2 from yesterday | S |

---

## The KNOWN LIMITATIONS list (document in tester briefing)

Tell testers these up front; they'll accept what they expect, complain about what surprises them:

1. **URL recipe import works ~30% of the time today.** Major sites (Allrecipes, food blogs with Cloudflare) often refuse. Manual entry always works. Better fetcher is the next major work item.
2. **No push notifications yet** (Batch 6c parked). All updates require opening the app.
3. **Kids can only switch profiles via PIN — no biometric, no kid-friendly login.** PIN entry is a 4-6 digit dialog.
4. **No "My Submissions" view for shared-library recipe submissions.** Submitter sees a confirmation SnackBar; the row is visible to them via direct DB only until approved/rejected. (Stage 3 shipped yesterday; the management UI is deferred per thinnest-v1.)
5. **Recipe Library "My Recipes" tab will be empty for new households** until they create/import one. Browse Library has 3 seeded recipes to start.
6. **No data persistence across uninstalls** — TestFlight builds get a fresh app sandbox on reinstall, but the Supabase data stays. Users would need to manually sign in again.
7. **No deep links / iOS Share Sheet support** — testers can't share a URL from Safari → into the app. They have to copy the URL and paste into the import dialog.

---

## Suggested sequencing for the 9-day window

Roughly 15-18 work blocks (2-4 hrs each) available. Front-load MUST FIX, back-load Apple-side setup.

### Days 1-2 (2026-05-29 — 2026-05-30)

- **Code**: fix data_export `'recipes'` → `'household_recipes'` (15 min, 1 PR)
- **Config**: verify Supabase email-confirmation setting; disable if on (5 min, Supabase dashboard)
- **Decide**: app name. This is the actual gate. Once decided, it unblocks Days 3-4.
- **SQL housekeeping**: run the test-recipe cleanup from yesterday's Day 6 closeout
- **Housekeeping**: delete 6 merged branches

### Days 3-4 (2026-05-31 — 2026-06-01)

- Apple-side: register bundle ID with the decided name, sign in to App Store Connect, create app record
- Update `apps/mobile/ios/Runner/Info.plist` CFBundleDisplayName, plus iOS bundle ID in the Xcode project
- Update splash/auth-screen branding if app name changes from "Honeydo"
- SHOULD FIX: recipe-import failure copy
- SHOULD FIX: Meal Planner add-affordance hint
- Internal smoke test: install on Andrew's phone, walk the 8 flows above end-to-end as a brand-new user

### Days 5-6 (2026-06-02 — 2026-06-03)

- Build release IPA via Xcode (`flutter build ipa`)
- Upload to App Store Connect, wait for processing (~30 min)
- Configure TestFlight internal testing group (Andrew first)
- Submit for Beta App Review if any external testers (24-48 hr Apple review window for external; not required for internal-only)
- Resolve any rejection-from-review issues if external

### Days 7-9 (2026-06-04 — 2026-06-07)

- Buffer for review-and-fix cycles
- Invite 2-3 trusted households to the testing group
- Send the "known limitations" briefing
- Watch for early bug reports; triage same-day
- Weekend (2026-06-06/07): testers actually start using

If something slips, the natural compress point is Days 7-9 (which were buffer). If Days 1-2 slip, Apple's external-review SLA eats the rest.

---

## Open product/UX questions (Andrew's judgment, not code-derivable)

1. **App name.** Roadmap has called this out since Day 5. Still open. Single biggest gate.
2. **Tester briefing format.** Email? Notion doc? README in TestFlight invite? The "known limitations" list above is the content; format is your call.
3. **What's the test goal?** "Does our family flow work end-to-end" vs "Validate the shared-library approval loop" vs "Multi-kid + multi-adult coordination." Pick one or two so testers know what to focus on; otherwise they'll wander.
4. **TestFlight access model.** Internal-only (no Apple review, faster) means testers must be added as users on the Apple Developer team. External (1-2 day review, easier to add) is simpler logistically. For 2-3 trusted households, external is probably the better choice.
5. **Feedback channel.** TestFlight's built-in feedback? A Google Form? A shared text thread? Pre-decide before invites go out.
6. **What happens if a tester gets stuck on email confirmation despite disabling?** Have a clear "DM Andrew, he'll fix it" fallback ready. Testing-cohort hand-holding is fine and expected at this size.
7. **Crash + analytics telemetry.** No Sentry / Crashlytics / Bugsnag visible in the repo. For 2-3 households this is acceptable; they'll DM you when something breaks. For wider launches, this becomes essential.
