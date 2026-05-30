# Day 7 TestFlight Bugs — Found 2026-05-29 evening / 2026-05-30 morning

## Source
First TestFlight install of build 1.0.0(1) on Andrew's iPhone (the developer's own device). No external testers invited yet.

## Bug 1: Calendar doesn't display meals

### Reproduction
1. Log into app
2. Navigate to calendar tab (Pass-3 calendar view)
3. Observe: meals that have been planned in the meal planning flow do not appear on the calendar

### Investigation needed
- Does the meal data exist in the database?
- Is the calendar fetching the right table / date range / household?
- Is meal data being saved to a different table than the calendar reads?

### Priority
Medium. Functional gap in a major Pass-3 feature, but does not block testing of other flows.

### Status
Documented. Not yet investigated.

## Bug 2: Recipe URL import fails catastrophically

### Reproduction
1. Log into app
2. Navigate to recipe library
3. Tap "Import from URL" (or whatever the entry point is — confirm during code investigation)
4. Enter URL: https://heygrillhey.com (or a specific recipe URL on heygrillhey.com)
5. Observe: app navigates to a new screen, screen goes blank/black, app becomes unresponsive
6. Workaround: hard-close app via app switcher, reopen, log back in

### Symptoms beyond the immediate failure
- App auth session was lost — required re-login after reopen. This is a separate concern from the import failure itself.

### Suspected scope
The recipe import flow currently uses the Railway-hosted fetcher (services/api/src/server.js → importRecipeFromUrl). The Day 5 spike showed a Flutter WebView fetcher won the comparison and was the recommended replacement, but that spike has NOT been merged into the production path. So the production path is still using the original fetcher.

Possible failure points:
- Fetcher times out or hangs on heygrillhey.com (HTML structure, JS-heavy page)
- Fetcher returns malformed/empty data that the UI doesn't handle
- Navigation transition fails or pushes a screen with no rendering state
- Auth session loss is likely a separate bug exposed by this code path

### Priority
HIGH. The recipe import flow is one of the headline differentiators of the app. Testers shouldn't be told "don't touch this" if it can be fixed quickly. Auth state loss is also concerning regardless of trigger.

### Status
Documented. Investigation starting morning of 2026-05-30.

## Bug 2 Investigation Findings (2026-05-30 morning, read-only)

### Code path: tap-to-failure walkthrough

Production flow (mobile → API → upstream site):

1. `apps/mobile/lib/screens/recipe_library_screen.dart:1164` — FAB "Add Recipe" opens menu sheet
2. `recipe_library_screen.dart:1175-1179` — "Import from URL" → pops menu, calls `_showImportUrlSheet()`
3. `recipe_library_screen.dart:358-407` — `_showImportUrlSheet` shows URL input bottom sheet
4. `recipe_library_screen.dart:404-406` — On Import tap → calls `_importRecipe(url)`
5. `recipe_library_screen.dart:409-463` — `_importRecipe`:
   - Line 412-416: `showDialog(barrierDismissible: false, ...)` — modal loading spinner that cannot be tapped away
   - Line 419-423: `http.post('$_apiUrl/recipes/import', ...)` — **no timeout specified** (Dart `package:http` default is no timeout)
   - Line 425: `Navigator.pop(context)` — closes loading dialog when response arrives
   - Line 427-454: success → `_showImportedRecipeSheet(...)`, non-200 → SnackBar with "Couldn't import…" copy
   - Line 455-462: exception → SnackBar with raw error
6. `apps/mobile/lib/screens/recipe_library_screen.dart:43` — `_apiUrl` falls back to `https://honeydo-production-743d.up.railway.app` when env is missing
7. Confirmed: `apps/mobile/.env` contains only Supabase keys, no `API_URL` → TestFlight build hits Railway production via the hardcoded fallback

Server flow:

8. `services/api/src/server.js:155-167` — `POST /recipes/import` handler:
   - Calls `importRecipeFromUrl(url)`
   - On throw → returns 422 with `{ok: false, error: error.message}`
9. `services/api/src/server.js:461-482` — `importRecipeFromUrl`:
   - Line 462: `fetch(url, { headers: { 'user-agent': 'ClanquilityRecipeImporter/0.1' } })` — **no fetch timeout**, identifies itself as a bot
   - Line 463: if not OK → `throw new Error('Failed to fetch recipe URL: ${response.status}')`
   - Line 466-481: parse HTML, look for JSON-LD Recipe — throw "No schema.org Recipe data found" if not present

### Curl test against production Railway endpoint

| URL | HTTP status | Body | Time |
|---|---|---|---|
| `https://heygrillhey.com` (bare) | 422 | `{"ok":false,"error":"No schema.org Recipe data found..."}` | 0.2s |
| `https://heygrillhey.com/the-best-bbq-pulled-pork-recipe/` | 422 | `{"ok":false,"error":"Failed to fetch recipe URL: 404"}` | 1.0s |
| `https://heygrillhey.com/the-best-smoked-brisket-recipe/` | 422 | `{"ok":false,"error":"Failed to fetch recipe URL: 404"}` | 0.8s |
| `https://www.allrecipes.com/recipe/16354/easy-meatloaf/` | 422 | `{"ok":false,"error":"Failed to fetch recipe URL: 402"}` | 0.5s |

**Pattern:** real recipe URLs return 404 / 402 from the upstream site, not from Railway. This is the upstream site blocking the `ClanquilityRecipeImporter/0.1` User-Agent — anti-bot defense. Bare-domain homepage returns 200 but no JSON-LD. **The Railway fetcher is broken for most real recipe sites in production.**

### Where the user-reported failure manifests

Two separate concerns:

**Concern A: The fetcher is fundamentally broken for the URL pattern the user tried.**
Even if everything else worked, the user would always see a "Couldn't import…" SnackBar for heygrillhey.com recipe URLs. The fetcher cannot bypass anti-bot from a datacenter IP with a bot-identifying User-Agent.

**Concern B: The reported symptom ("blank screen / app stuck / hard close + lost auth") doesn't match the 422→SnackBar code path.**
The clean 422 case (which our curl confirms) should produce: loading dialog closes (line 425) → SnackBar appears with "Couldn't import…" (line 433-441) → user dismisses → still in recipe library. Not a blank screen, not stuck, no crash.

The blank-screen-with-crash symptom probably arose from one of:
- The user's specific URL hit a different path (e.g., upstream returned 200 with malformed JSON-LD → success branch fired → `_showImportedRecipeSheet` opened with empty fields → looked blank)
- Network connectivity issue during the call → `http.post` hangs indefinitely (no timeout) → loading dialog (`barrierDismissible: false`) cannot be dismissed → user kills the app
- iOS memory or thread crash during the flow (large response body, render exception) → auth state lost on relaunch because the crash bypassed normal Supabase session persistence

Without device logs and the exact URL, we can't pin it more precisely. The defensive fixes below would mitigate all three scenarios.

### Auth-state-loss-on-relaunch

Searched for explicit auth-clearing in the import path: none. `signOut()` is only called from `settings_screen.dart` and `home_shell_screen.dart` (user-initiated). Auth loss on relaunch is a fingerprint of **app crash**, not code clearing the session. `supabase_flutter` persists sessions to SharedPreferences; only a crash that bypassed normal shutdown would lose them.

### WebView spike comparison

Day 5 WebView spike (commit `4b63696`, still on `refs/heads/spike/flutter-webview-fetcher-2026-05-27` on origin) is research-only — a standalone Flutter project at `spike/flutter-webview-trial/webview_fetcher_spike/` that proved the concept. **No production code was changed; the spike was never integrated into `apps/mobile/`.**

What the spike proved: loading recipe URLs in an in-app WKWebView (real browser fingerprint + user's residential IP) defeats anti-bot. 4/4 success including Datadome-protected Bon Appétit. The architecture decision doc `audits/2026-05-27-recipe-import-architecture-decision.md` proposed:

- URL paste → in-app WebView loads the page → extract `document.documentElement.outerHTML` via JS injection → parse JSON-LD on-device (or send to Railway/server for parsing, with the WebView-fetched HTML as the payload)
- This bypasses the bot-blocking problem because the WebView is a real browser on the user's residential IP

### Recommended fix approach (two-dimensional)

**Dimension 1: defensive UX (small, immediate).** Stop the catastrophic-failure UX even while the fetcher is broken.
- Add timeout to `http.post` (e.g., `.timeout(Duration(seconds: 20))`)
- Make the loading dialog dismissable (`barrierDismissible: true`) or replace with an in-place spinner the user can navigate away from
- On timeout/error, ensure the dialog is popped before the SnackBar fires
- Scope: ~30 minutes, touches one file (`recipe_library_screen.dart` `_importRecipe`)

**Dimension 2: strategic — actually fix the fetcher (medium, multi-day).** Implement the Day 5 architecture decision.
- Replace the `http.post → Railway → fetch` chain with an in-app WebView that loads the URL on the user's device
- Extract HTML via JS injection
- Parse JSON-LD client-side (or send the WebView-extracted HTML to Railway for parsing)
- Scope: 2–3 days. Touches: new screen for the WebView fetch flow, JSON-LD parser ported or kept server-side, recipe library screen integration. Major dependency: `webview_flutter` (or `flutter_inappwebview`) added to pubspec.

**Recommended sequence:**
1. Today/tomorrow: ship Dimension 1 as a `fix/import-defensive-ux` branch. Makes the bug visible-but-not-catastrophic for any existing tester who tries import.
2. Next sprint (Day 9+): implement Dimension 2 to actually make import work for real sites.

Auth-loss-on-relaunch is likely fixed as a side effect of Dimension 1 (no crash → no lost session). If it persists after Dimension 1, treat as a separate investigation.

### Estimated scope summary

- Dimension 1 (defensive UX): **small, ~30 min**, single-file change, ship same-day.
- Dimension 2 (strategic WebView fetcher): **medium-larger, 2–3 days**, new dependency + new screen + integration work.

## Bug 2 Fix Plan: WebView fetcher integration (Day 8+)

### Spike inventory (refs/heads/spike/flutter-webview-fetcher-2026-05-27)

- **Location:** `spike/flutter-webview-trial/webview_fetcher_spike/` (standalone Flutter project, separate from `apps/mobile/`)
- **Package used:** `webview_flutter: ^4.13.1` (Flutter team's official package; WKWebView on iOS, native WebView on Android)
- **Single Dart file with all logic:** `spike/flutter-webview-trial/webview_fetcher_spike/lib/main.dart` (~225 lines)
- **Approach summary:** The spike creates a `WebViewController` with `JavaScriptMode.unrestricted` and a **spoofed iOS Safari User-Agent** (`Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 ... Mobile/15E148 Safari/604.1`). It loads the URL via `loadRequest`, waits for `onPageFinished` via a `NavigationDelegate`, sleeps **2 seconds** to let dynamic JS populate, then calls `_controller.runJavaScriptReturningResult('document.documentElement.outerHTML')` to extract the rendered HTML. A regex extracts the first `"@type": "..."` token from JSON-LD as a diagnostic for Recipe vs CollectionPage (roundup) vs absent.
- **URLs verified working (4/4):** allrecipes.com (`/recipe/10813/best-chocolate-chip-cookies/`), foodnetwork.com (Ina Garten chocolate cake), damndelicious.net, bonappetit.com gallery (roundup edge case, JSON-LD present but `CollectionPage` type — *fetch* succeeded but recipe parsing wouldn't yield a Recipe object).
- **Failure handling:** `onWebResourceError` callback stores the error string; the extract method has a try/catch around `runJavaScriptReturningResult`. **No timeout.** The user manually decides when to give up by reading the on-screen status.

### Production path that needs to change

- Entry point: `apps/mobile/lib/screens/recipe_library_screen.dart:1175` (FAB → "Import from URL" menu item) → `_showImportUrlSheet()` at line 358
- Fetch call: `_importRecipe()` at line 409 — calls `http.post('$_apiUrl/recipes/import', ...)`
- Receiving screen: `_showImportedRecipeSheet()` at line 465 — expects keys: `title`, `description`, `servings`, `prep_time`, `cook_time`, `cuisine`, `difficulty`, `ingredients` (list of `{raw: string}`), `steps` (list of strings), `image_url`
- Server-side parser to potentially reuse: `services/api/src/server.js:461-524` (`importRecipeFromUrl`, `findRecipeJsonLd`, `normalizeRecipe`)
- Defensive gaps already documented above (no client timeout, `barrierDismissible: false`)

### Production-ready gaps in the spike

The spike validated the fetch approach but is missing everything around it:

- [ ] **No JSON-LD parsing in Dart.** The spike only detects presence + first `@type`. Production needs to (a) find all `<script type="application/ld+json">` blocks, (b) parse each, (c) recursively descend `@graph` to find the Recipe object, (d) normalize into the field set `_showImportedRecipeSheet` expects. Two options: port the server's `findRecipeJsonLd` + `normalizeRecipe` (~60 lines) to Dart, OR send the extracted HTML to Railway and let server parse it.
- [ ] **No `Future<T>` API.** Spike is purely UI; production needs a clean service: `Future<RecipeImportResult> fetchRecipeFromUrl(String url, {Duration timeout = const Duration(seconds: 30)})` with success / failure variants.
- [ ] **No timeout / cancellation.** WebView can hang indefinitely. Need: overall fetch timeout, ability to abort if user dismisses.
- [ ] **Manual "Extract HTML" button.** Production should auto-extract after `onPageFinished` + fixed delay (the spike's 2 seconds is a reasonable starting point).
- [ ] **Visible vs hidden WebView.** Spike shows a visible WebView in a Scaffold. Production UX decision: hide it (offscreen Container or transparent overlay) for an invisible fetch, OR show it briefly so the user understands "the app is loading the page." Lean: show it briefly with a "loading recipe from <site>..." overlay — gives the user feedback and helps debug failures visually.
- [ ] **No fallback for non-Recipe JSON-LD.** Roundup pages (Bon Appétit gallery) return `CollectionPage` or `ItemList` — spike just notes the type. Production needs to show "this page is a roundup, not a single recipe" rather than opening an empty edit sheet.
- [ ] **Error UX.** Clear messages for: invalid URL format, page won't load (DNS/connection), page loaded but no JSON-LD, page has JSON-LD but no Recipe object, JS extraction failed.
- [ ] **WebView lifecycle.** Spike keeps one WebView controller alive permanently. Production should create a fresh controller per fetch and dispose after — prevents memory accumulation across many imports.
- [ ] **iOS Info.plist.** The `webview_flutter` plugin uses WKWebView which works out-of-the-box for HTTPS. No ATS exceptions needed (most recipe sites are HTTPS-only). Verify no extra Info.plist keys required.
- [ ] **No share-sheet integration.** The Day 5 architecture decision mentioned iOS Share Sheet routing as path #3 (deferred — Day 9+ scope, not blocking).

### Recommended integration sequence (Day 8 plan)

**Phase A: Scaffolding (1-2 hours, this morning after this investigation)**
- Add `webview_flutter: ^4.13.1` to `apps/mobile/pubspec.yaml`
- Create `apps/mobile/lib/services/webview_recipe_fetcher.dart` with:
  - `class WebViewRecipeFetcher` — wraps the spike's controller logic
  - `Future<RecipeImportResult> fetchRecipeFromUrl(String url, {Duration timeout})` — public API
  - `RecipeImportResult` — sealed class with `Success(Map<String, dynamic> recipe)` / `Failure(String message, ImportFailureReason reason)` variants
- Port JSON-LD parsing from `services/api/src/server.js:484-524` to Dart. ~60 lines of straightforward translation.
- Internal: load URL → wait for `onPageFinished` → sleep 2s → extract HTML → parse JSON-LD → normalize → return.

**Phase B: Integration (2-4 hours, this afternoon or Day 9)**
- In `recipe_library_screen.dart`, replace `_importRecipe`'s `http.post` block with a call to the new service.
- Update loading UX: show a "Loading recipe from <hostname>..." overlay with a Cancel button. Make it dismissable. Apply Dimension-1 fixes (timeout, dismissible) as part of this — they're free given the rewrite.
- Adapt the success path to feed `RecipeImportResult.Success.recipe` (which uses the same field shape as the server response) into `_showImportedRecipeSheet` unchanged.
- Handle failure cases with specific SnackBar copy per `ImportFailureReason`.

**Phase C: Real-world testing (half-day, Day 9 or Day 10)**
- Test on iOS device against: heygrillhey.com (the original bug URL), allrecipes.com (works in spike), foodnetwork.com, NYT Cooking, BBC Good Food, Bon Appétit roundup (should fail gracefully), a known-bad URL (404).
- Iterate on failure modes that surface.
- Bump pubspec to `1.0.0+2` and upload TestFlight build.

**Decisions deferred:**
- **Railway fetcher fate:** keep as fallback, remove entirely, or leave dormant? Decision after WebView is verified working in production. Likely answer: leave the endpoint in place (no traffic to it from mobile after Phase B), revisit removal once we're confident.
- **Visible vs hidden WebView in production UX:** decide during Phase B after seeing how it feels with real recipe sites.
- **Share Sheet integration (iOS):** deferred to Day 9+. Not blocking TestFlight ramp.

### Estimated scope

- Phase A: **1-2 hours** (scaffold + parser port)
- Phase B: **2-4 hours** (integration + UX)
- Phase C: **half-day** (testing + TestFlight upload + iteration)

Total realistic time to next TestFlight build with working import: **2-3 days of focused work**, in line with the earlier Dimension-2 estimate.

## Bug 3: Invite redemption fails with "Invalid invite code"

### Reproduction (overnight, Andrew's wife)
1. Sign up with valid Apple ID
2. Onboarding "Join with invite code" path → enter code `MWEUEX`
3. Result: "Invalid invite code. Please check and try again."
4. Ground truth: row exists in `household_invites` with `code = 'MWEUEX'`, not expired, not revoked, use_count < max_uses. Confirmed via direct SQL.

### Root cause (from Supabase logs + SQL inspection)
The RLS policy `household_scoped_invites` on `public.household_invites` is `FOR ALL USING (public.is_household_admin(household_id))`. A user trying to join via invite code is **not yet** a member of the target household, so `is_household_admin(household_id)` is false. The lookup query returns `null` → code falls into the "Invalid invite code" branch.

### Code-path investigation (2026-05-30, read-only)

**Entry point + join handler:** `apps/mobile/lib/screens/household_setup_screen.dart`
- Line 290: "Join with invite code" button
- Line 459: button onPressed → `_joinHousehold`
- Line 133: `Future<void> _joinHousehold() async`

**Exact Supabase queries the redemption flow makes:**

1. **Invite lookup** (line 152-156) — the RLS-blocked query:
   ```dart
   await Supabase.instance.client
       .from('household_invites')
       .select()
       .eq('code', code)
       .maybeSingle();
   ```
   Returns null for non-admins → line 158 fires "Invalid invite code".

2. **Client-side validation gates** (lines 164-179) — checks `expires_at`, `revoked_at`, `use_count >= max_uses`. All client-side; all depend on the lookup succeeding. None reached when RLS blocks.

3. **Already-member check** (line 184-189):
   ```dart
   await Supabase.instance.client
       .from('household_members')
       .select()
       .eq('household_id', householdId)
       .eq('auth_user_id', user.id)
       .maybeSingle();
   ```
   Hits `household_members_select` policy: `is_household_member(household_id)`. Non-members get null back — which is the semantically correct answer at this step (they're not a member yet, so falling through to INSERT is right). Not a blocker.

4. **Member INSERT** (line 197-206) — **second RLS blocker**:
   ```dart
   await Supabase.instance.client.from('household_members').insert({
     'household_id': householdId,
     'auth_user_id': user.id,
     'role': 'member',
     'kind': 'adult_auth_user',
     'display_name': ...,
     'points_balance': 0,
     'is_active': true,
     'created_by': user.id,
   });
   ```
   Hits `household_members_admin_all` policy: `FOR ALL USING is_household_admin(household_id)`. The joining user is not an admin, so INSERT is blocked.

5. **Use-count update** (line 209-212):
   ```dart
   await Supabase.instance.client
       .from('household_invites')
       .update({'use_count': (invite['use_count'] ?? 0) + 1})
       .eq('id', invite['id']);
   ```
   Same `household_scoped_invites` policy blocks UPDATE for non-admins. Third RLS blocker.

**Implication:** the join flow has **three RLS gates** the joining user can't pass, not just the lookup. Fixing only the SELECT on `household_invites` would let the user past line 158 but they'd still fail at the INSERT on line 197 and the UPDATE on line 209. **A complete fix needs to address all three operations atomically.**

### Existing RLS policies (from `supabase/migrations/0001_initial_schema.sql:512-519`)

Inline source-of-truth (matches what we'd expect to see in `pg_policies`):

```sql
create policy households_member_select on public.households
  for select using (public.is_household_member(id));
create policy households_admin_update on public.households
  for update using (public.is_household_admin(id));

create policy household_members_select on public.household_members
  for select using (public.is_household_member(household_id));
create policy household_members_admin_all on public.household_members
  for all using (public.is_household_admin(household_id));

create policy household_scoped_invites on public.household_invites
  for all using (public.is_household_admin(household_id));
```

Plus the policy summary comment in the migration (line 511): *"Initial RLS policies. These are broad household-scoped policies for scaffold; tighten by action in later migrations."* — implying this was scaffolding never refined for the join-by-invite case.

### SQL for Andrew to confirm in Supabase SQL Editor

The migration is the source-of-truth, but live policies can drift from migrations. Run these to confirm what Postgres actually enforces:

```sql
-- All RLS policies on household_members
SELECT policyname, cmd, qual, with_check
FROM pg_policies
WHERE tablename = 'household_members';

-- All RLS policies on households
SELECT policyname, cmd, qual, with_check
FROM pg_policies
WHERE tablename = 'households';

-- All RLS policies on household_invites
SELECT policyname, cmd, qual, with_check
FROM pg_policies
WHERE tablename = 'household_invites';

-- Any SECURITY DEFINER functions related to invites/joining
SELECT proname, pg_get_function_arguments(oid) as args, prosecdef
FROM pg_proc
WHERE proname LIKE '%invite%' OR proname LIKE '%join%' OR proname LIKE '%household%';
```

### SECURITY DEFINER RPC search

**No invite-redemption or household-join RPC exists.** Searched all of `supabase/migrations/` for `invite`, `join_household`, `redeem`, `claim`. Findings:

- `supabase/migrations/0001_initial_schema.sql` is the only file that mentions invites — defines the table and the (over-restrictive) RLS policy. No helper function.
- SECURITY DEFINER RPCs exist for *other* features and demonstrate the pattern: `redo_chore`, `delete_chore_photo`, `set_member_pin`, `add_shopping_item`, `approve_wishlist_item`, `approve_chore`, `complete_chore_self`, `submit_kid_chore_with_photo`, `create_meal_request`. None handle invite redemption.

The codebase has a clear `SECURITY DEFINER` pattern (see migration `0017_kid_perms_rls_rpcs.sql` for the canonical shape) — invite redemption is a missing instance of that same pattern.

## Bug 3b: "Could not generate invite code" (subsidiary, from yesterday)

### Code path

`apps/mobile/lib/screens/members_screen.dart:81-131` — `_generateInviteCode()`.

The function calls a Supabase Edge Function:
```dart
final response = await Supabase.instance.client.functions.invoke(
  'generate-invite',
  body: {'household_id': _household!['id']},
);
```

The `response` is **assigned but never used** — the code unconditionally proceeds into a comment-labeled "Fallback: create invite directly" block that does the actual work (direct INSERT to `household_invites` at line 110-117).

### Why it fails

**The `generate-invite` Edge Function does not exist.** `supabase/functions/` directory is absent from the repo. The `functions.invoke('generate-invite', ...)` call throws (or returns an error response that the supabase-flutter client surfaces as a throw, depending on client version). The throw is caught at line 123 → SnackBar "Could not generate invite code." (line 127).

### Comparison to the working path

`apps/mobile/lib/screens/invite_management_screen.dart:97-127` (the dropdown "Invite Codes" path that works) does NOT call the Edge function. It generates the code client-side via `generateInviteCode()` and directly INSERTs to `household_invites`. Same INSERT, no Edge function, no failure.

### Likely fix scope (preview only — not designing yet)

Two minimal options:
- **Remove the dead `functions.invoke` call** in `members_screen.dart:85-88`. The "fallback" is the actual implementation. Single-file, ~4-line deletion.
- **Or unify both screens** to use the same helper. Slightly bigger but cleaner.

Defer scope decision until we agree on a Bug 3 fix shape — both bugs touch invite code generation/redemption and may share a SECURITY DEFINER RPC.

## Bug 2b: "Could not generate invite code" investigation findings (deep dive, 2026-05-30 after Bug 3 RPC fix)

Supersedes the earlier "Bug 3b" sketch section. Same bug, deeper read.

### members_screen.dart broken function

`apps/mobile/lib/screens/members_screen.dart:81-131` — `_generateInviteCode()`. Triggered from the "Generate invite code" / "Get new code" button at line 266 (`onPressed: _generateInviteCode`).

Full body:
```dart
Future<void> _generateInviteCode() async {
  setState(() => _isLoading = true);

  try {
    final response = await Supabase.instance.client.functions.invoke(
      'generate-invite',
      body: {'household_id': _household!['id']},
    );

    // Fallback: create invite directly
    final user = Supabase.instance.client.auth.currentUser!;
    final existingInvites = await Supabase.instance.client
        .from('household_invites')
        .select()
        .eq('household_id', _household!['id'])
        .isFilter('revoked_at', null)
        .gt('expires_at', DateTime.now().toIso8601String())
        .limit(1);

    if (existingInvites.isNotEmpty) {
      setState(() {
        _inviteCode = existingInvites[0]['code'];
        _isLoading = false;
      });
      return;
    }

    // Generate a new code
    final code = generateInviteCode();
    await Supabase.instance.client.from('household_invites').insert({
      'household_id': _household!['id'],
      'code': code,
      'max_uses': 5,
      'use_count': 0,
      'created_by': user.id,
      'expires_at': DateTime.now().add(const Duration(days: 7)).toIso8601String(),
    });

    setState(() {
      _inviteCode = code;
      _isLoading = false;
    });
  } catch (e) {
    setState(() => _isLoading = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not generate invite code.')),
      );
    }
  }
}
```

### Edge function called

- **Name:** `generate-invite`
- **Invocation:** `Supabase.instance.client.functions.invoke('generate-invite', body: {'household_id': _household!['id']})` (line 85-88)
- **Response variable:** assigned to `final response` (line 85) but **never read or branched on** anywhere in the function
- **Exists in `supabase/functions/`:** **No.** The directory itself does not exist (`ls supabase/functions` → "No such file or directory")
- **Other Edge function invocations in `apps/mobile/lib/`:** zero. The only `functions.invoke` callsite in the entire mobile codebase is this one.

### Catch block that produces the user-facing error

Lines 123-130. Triggered by the throw from the nonexistent Edge function call, which the supabase-flutter client surfaces as a Dart exception (the underlying transport returns a 4xx that the client converts to a throw). The catch resets `_isLoading` and shows SnackBar `"Could not generate invite code."`.

### Working invite generation path

`apps/mobile/lib/screens/invite_management_screen.dart:82-128` — `_createInvite()`. Triggered from the "Create Invite Code" button on the dedicated Invite Codes screen (the one accessed via the home shell dropdown menu).

Full body (relevant portion):
```dart
Future<void> _createInvite() async {
  if (_household == null) return;
  // ... configurable dialog for max_uses + expiry_days ...

  try {
    final code = generateInviteCode();
    final expiresAt = DateTime.now().add(Duration(days: expiryDays));

    final user = Supabase.instance.client.auth.currentUser!;
    final profile = await Supabase.instance.client
        .from('profiles')
        .select('id')
        .eq('id', user.id)
        .single();

    await Supabase.instance.client.from('household_invites').insert({
      'household_id': _household!['id'],
      'code': code,
      'expires_at': expiresAt.toIso8601String(),
      'max_uses': maxUses,
      'use_count': 0,
      'created_by': profile['id'],
    });

    _loadData();
  } catch (e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not create invite code.')),
      );
    }
  }
}
```

### Working path's exact INSERT

```dart
await Supabase.instance.client.from('household_invites').insert({
  'household_id': _household!['id'],
  'code': code,              // from generateInviteCode() shared helper
  'expires_at': expiresAt.toIso8601String(),
  'max_uses': maxUses,       // from dialog (user-configurable, default 1)
  'use_count': 0,
  'created_by': profile['id'],  // looked up from profiles table
});
```

RLS context: the calling user is the household admin (`_isAdmin` check at line 80 via `Permissions.canInviteMembers`). The `household_scoped_invites` policy (`FOR ALL USING is_household_admin(household_id)`) permits the INSERT. Works as confirmed by the actual codes existing in the database (`MWEUEX`, `S7QC7L`).

### Compared shape (A / B / C)

**Shape C: the Edge function call is dead code with a complete working fallback.**

Reasoning:
- The "fallback" code block at lines 91-117 is a self-contained, working invite-generation implementation (look-up-existing OR generate-new + INSERT).
- The `final response = ...` variable is assigned but never read or branched on. The code unconditionally executes the "fallback" after the invoke completes.
- There is no scenario where the Edge function's response would change behavior — if invoke succeeds, we still run the "fallback" code; if invoke throws, we go to catch.
- The two members_screen and invite_management_screen flows are intentionally different by design: members_screen is "simple, one-button, reuse-existing-if-present, hardcoded 5 uses / 7 days"; invite_management_screen is "configurable max_uses + expiry, always create new." Both share the `generateInviteCode()` helper for code generation. They should NOT share a common implementation — they're for different user scenarios.
- The Edge function name `generate-invite` was likely an early-design intention that got superseded by client-side direct INSERT but the dead call was left in. There's no other Edge function invocation in the mobile codebase to suggest the team is committed to server-side invite generation.

Shape A (route members_screen through invite_management_screen's path) is wrong: the two have intentionally different UX (one-tap-reuse vs configurable-create).

Shape B (create the Edge function) is wrong: there's no server-side requirement that the client can't already meet (RLS already permits admins to INSERT; randomness from Dart's `Random.secure()` via `generateInviteCode()` is fine; no audit logging is implied; existing path proves direct INSERT works).

### Recommended fix

**Remove lines 85-90** — the `final response = await Supabase.instance.client.functions.invoke(...)` block plus the misleading `// Fallback: create invite directly` comment. The remaining 27 lines of the function (the "fallback" block) become the actual implementation. Net change: ~6 lines deleted, zero lines added.

After fix, `_generateInviteCode()` becomes:
```dart
Future<void> _generateInviteCode() async {
  setState(() => _isLoading = true);

  try {
    final user = Supabase.instance.client.auth.currentUser!;
    final existingInvites = await Supabase.instance.client
        .from('household_invites')
        .select()
        .eq('household_id', _household!['id'])
        .isFilter('revoked_at', null)
        .gt('expires_at', DateTime.now().toIso8601String())
        .limit(1);

    if (existingInvites.isNotEmpty) {
      setState(() {
        _inviteCode = existingInvites[0]['code'];
        _isLoading = false;
      });
      return;
    }

    final code = generateInviteCode();
    await Supabase.instance.client.from('household_invites').insert({
      'household_id': _household!['id'],
      'code': code,
      'max_uses': 5,
      'use_count': 0,
      'created_by': user.id,
      'expires_at': DateTime.now().add(const Duration(days: 7)).toIso8601String(),
    });

    setState(() {
      _inviteCode = code;
      _isLoading = false;
    });
  } catch (e) {
    setState(() => _isLoading = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not generate invite code.')),
      );
    }
  }
}
```

### Optional follow-up considerations (not in initial fix)

- `created_by: user.id` vs `profile['id']` consistency: the working path looks up `profile['id']` defensively; this path uses `user.id` directly. Both resolve to the same UUID in practice (profiles.id = auth user id). Worth aligning to one pattern across both files eventually, but not blocking.
- `_generateInviteCode` is RLS-permitted only for household admins per `household_scoped_invites`. The button at line 266 should already be gated by admin permission via the screen context — verify before fix.

### Estimated fix time

**~5 minutes.** Single-file 6-line deletion, branch + commit + merge in the usual flow. Verified via `flutter analyze` (expect 232 baseline unchanged) and ideally manual smoke test (tap the button, see a code appear in the UI, confirm row in `household_invites`).

## Bug 1: Calendar doesn't display planned meals — investigation findings (2026-05-30)

### Meal write path

- **File:** `apps/mobile/lib/screens/meal_planner_screen.dart:662`
- **Table:** `public.meal_plans`
- **Insert columns:**
  ```dart
  await Supabase.instance.client.from('meal_plans').insert({
    'household_id': widget.householdId,
    'planned_for': widget.day.toIso8601String().substring(0, 10),  // YYYY-MM-DD
    'meal_type': _mealType,
    'recipe_id': _selectedRecipeId,            // FK to household_recipes
    'custom_title': customTitle.isEmpty ? null : customTitle,
    'assigned_cook_member_id': _assignedCookId,
    'servings': int.tryParse(_servingsController.text.trim()),
    'notes': _notesController.text.trim().isEmpty ? null : _notesController.text.trim(),
    'created_by_member_id': widget.myMemberId,
  }).select().single();
  ```
- **Second write path:** `apps/mobile/lib/screens/recipe_detail_screen.dart:448` (recipe → meal plan flow). Same table.

### `meal_plans` schema (from `supabase/migrations/0001_initial_schema.sql:282`)

```sql
create table public.meal_plans (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  planned_for date not null,
  meal_type meal_type not null,
  recipe_id uuid references public.household_recipes(id) on delete set null,
  -- ... (rest of columns elided)
);
```

Key column for calendar matching: **`planned_for` (date, not timestamp)**. Indexed by `idx_meal_plans_household_date on (household_id, planned_for)` (line 427) — fast for the calendar's monthly fetch.

### `meal_plans` RLS (from same migration, line 531)

```sql
create policy household_scoped_meal_plans on public.meal_plans
  for all using (public.is_household_member(household_id));
```

Standard household-scoped. Any household member can read/write. **Not a bug source.**

### Calendar fetch path

- **File:** `apps/mobile/lib/screens/calendar_screen.dart` (790 lines)
- **Tables queried:** `calendar_tags`, `household_members`, `calendar_events`, `calendar_event_members`
- **`_loadEvents()` at line 102-129** fetches only `calendar_events`:
  ```dart
  var query = Supabase.instance.client
      .from('calendar_events')
      .select('*, tag:calendar_tags(name, color, emoji), creator:household_members!created_by_member_id(display_name)')
      .eq('household_id', _household!['id'])
      .gte('starts_at', monthStart.toIso8601String())
      .lte('starts_at', monthEnd.toIso8601String());
  ```
- **Day-cell selector** `_eventsForDay(day)` at line 131-137 filters `_events` by matching `starts_at` to the day. Calendar render uses this list.

### Does the calendar query the meal table?

**No.** `grep -nE "meal|plan" calendar_screen.dart` returns zero hits across all 790 lines. No fetch, no state, no render path for meals. The calendar was simply never wired to display them.

### Date filter comparison

Events use timestamp filter (`starts_at gte/lte` ISO timestamp). Meals would need date-string filter (`planned_for gte/lte` `'YYYY-MM-DD'`) because `planned_for` is a `date`, not `timestamptz`. The Day-of-month matching in Dart would compare the date string directly instead of parsing a DateTime.

### Column-name match check

N/A — no query is being made, so there's no mismatch to check. Column-name issues would only matter once the fetch is added.

### Diagnosis

**A. Calendar doesn't query the meal table at all.** No RLS issue (B/D ruled out). No render bug (C ruled out — there's nothing to render because there's no fetch). No schema drift (E ruled out — schema is clean and meal planner writes data fine, as confirmed by data_export's working read on the same table).

### SQL for Andrew to confirm in Supabase SQL Editor

```sql
-- 1. Verify meal_plans rows exist for the household (substitute household_id if needed)
SELECT id, planned_for, meal_type, recipe_id, custom_title, created_by_member_id, created_at
FROM public.meal_plans
WHERE household_id = 'a36cf652-d58a-4a62-a09e-f01d74a57ef9'
ORDER BY planned_for DESC, created_at DESC
LIMIT 20;

-- 2. RLS policies on meal_plans (confirm only household_scoped_meal_plans is enforced)
SELECT policyname, cmd, qual, with_check
FROM pg_policies
WHERE tablename = 'meal_plans';
```

Expected: query 1 returns the meals that the meal planner UI has saved. Query 2 returns one row: `household_scoped_meal_plans` with `qual = public.is_household_member(household_id)`.

### Recommended fix scope

**Medium — single file, ~50-80 lines added.** Touches only `calendar_screen.dart`.

Required changes:
1. **Parallel fetch in `_loadEvents()` (or rename to `_loadCalendarData()`):** add a second `meal_plans` query alongside the `calendar_events` query, filtered by `household_id` + `planned_for` in the focused month's date range. Optionally `.select('*, recipe:household_recipes(title)')` to get the recipe name when `recipe_id` is set.
2. **New state list `_mealPlans`** alongside `_events`.
3. **New helper `_mealPlansForDay(day)`** mirroring `_eventsForDay` but matching on `planned_for` (date string) instead of `starts_at` (timestamp).
4. **Day-cell render update** — add a section per day for meals (probably a fork-and-knife icon + meal_type + recipe.title or custom_title). Visually distinct from events.

UX decisions to make before/during the fix:
- Whether the existing tag filter should hide meals (probably no — meals don't have tags)
- Whether tapping a meal navigates somewhere (meal_planner_screen for edit? recipe_detail for the recipe? read-only display?)
- Whether to show all meal types or filter by meal_type in some way

### Estimated fix time

**1-2 hours** of focused work, plus 30 minutes of manual smoke testing on iOS. Net change ~50-80 lines in one file. The data path is straightforward; UX polish (visual treatment, tap behavior) is the variable.

## Bug 1: Calendar scope investigation findings — full feature spec (2026-05-30, after Andrew's product clarification)

Andrew's stated product intent: *"The calendar should show everything from meals and users entered activities. Also chores as well. When the user clicks on a day it is supposed to open a dialog that shows the days outlook."*

### Current state recap

- **Calendar currently fetches:** `calendar_tags`, `household_members`, `calendar_events` (events only), plus `calendar_event_members` on insert.
- **Calendar currently does NOT fetch:** `meal_plans`, `chores` (or `chore_history`), `meal_requests`.
- **Day cell rendering** (`calendar_screen.dart:314-360`):
  - Shows day number with selected/today highlighting
  - Up to 3 small colored dots at the bottom of the cell, each colored by event tag (`tag.color` or `color_override`). Only events contribute dots; no meals/chores indicator.
- **Day-cell tap behavior** (line 322): `onTap: () => setState(() => _selectedDay = day)` — just selects the day; **does NOT open any dialog.**
- **Inline panel below the grid** (`calendar_screen.dart:283 + _buildDayEvents() at line 375`):
  - When a day is selected: renders a `ListView.builder` of `_EventCard` widgets, one per event
  - Empty state: "No events" with 📋 emoji
  - **Inline panel, not a dialog** — Andrew's spec changes this to a modal.
- **Day-detail dialog exists in code:** **No.** `grep -rln "DayDetail|DayOutlook|day_detail|dayOutlook|showDayDetails|_showDay|_openDay"` returns zero hits. No stub, no widget, no scaffolding. **This will be built from scratch.**

### Tables to incorporate

#### 1. `meal_plans` (already covered in the prior Bug 1 findings section above)

- **Date column:** `planned_for` (date, NOT NULL). YYYY-MM-DD string after Supabase serialization.
- **Key display fields:** `meal_type` (enum: breakfast/lunch/dinner/snack), `recipe_id` (FK to `household_recipes` — join for title) OR `custom_title`, `assigned_cook_member_id` (join to `household_members.display_name`).
- **RLS:** `household_scoped_meal_plans for all using is_household_member(household_id)` — clean, any member reads.
- **Existing fetch pattern to follow:** `data_export_screen.dart:154` (`.from('meal_plans').select('*').eq('household_id', ...)`). For the calendar add `.gte('planned_for', monthStartDate).lte('planned_for', monthEndDate)`.
- **Visual treatment hint:** Fork-and-knife icon 🍴, color family neutral/warm (consider `AppColors.honeyGold` variant for consistency with rewards), grouped under "Meals" header in the day-detail dialog.

#### 2. `chores`

- **Date columns:** Two — `due_at` (timestamptz, nullable) is primary; `chore_of_day_date` (date, nullable) is secondary for the "chore of the day" feature. For the calendar, use `due_at` (most chores will have it; recurrence-rule chores generate per-occurrence rows with `due_at` set).
- **Schema highlights (`0001_initial_schema.sql:88`):**
  - `id`, `household_id`, `title`, `description`
  - `assigned_to_member_id` (FK to `household_members`)
  - `created_by_member_id`
  - `point_value`, `bonus_points`, `difficulty` (easy/medium/hard enum)
  - `due_at` (timestamptz), `chore_of_day_date` (date), `recurrence_rule`
  - `status` (assigned / in_progress / completed / verified / rejected — enum)
  - `requires_photo`, `started_at`, `completed_at`, `verified_at`, `verified_by_member_id`, `rejected_reason`, `auto_verify_at`
- **Key display fields:** `title`, `assignee.display_name` (joined), `point_value`, `status`, `due_at` for time-of-day if applicable.
- **RLS:** `household_scoped_chores for all using is_household_member(household_id)` (line 521) — clean.
- **Existing fetch pattern to follow:** `chore_dashboard_screen.dart:90` shows `.from('chores').select().eq('household_id', ...).eq('assigned_to_member_id', myMemberId).inFilter('status', ['assigned', 'in_progress', 'rejected'])`. **The calendar's variant should NOT filter by assignee** (show all household chores) and **probably should NOT filter out completed status** initially (so the calendar reflects accurate history). Decision deferred to Andrew (see Open Questions).
- **Visual treatment hint:** Broom icon 🧹 or checkbox icon ✅, color family green for assigned / amber for in_progress / grey for completed. Grouped under "Chores" header in the day-detail dialog.

#### 3. `calendar_events` (already fetched today)

- **Date columns:** `starts_at` (timestamptz, NOT NULL), `ends_at` (timestamptz, nullable), `all_day` boolean (line 199-214).
- **Key display fields:** `title`, `description`, `tag` (joined for color/emoji/name), `creator.display_name`, `all_day`, `starts_at`/`ends_at` for time range, `reminder_minutes_before`.
- **RLS:** `household_scoped_calendar_events for all using is_household_member(household_id)` (line 529) — already working.
- **Existing fetch pattern in calendar:** `calendar_screen.dart:109-114` — already correct. Reuse as-is in Phase 3.
- **Visual treatment:** Existing `_EventCard` pattern. Tag-colored chip, group under "Activities" header.

#### 4. `meal_requests` (optional, flagged for Andrew)

- **Date column:** `requested_for_date` (date, nullable) — `0016_kid_perms_schema.sql:161`
- **Purpose:** Kid-initiated meal requests pending admin approval. When approved, become `meal_plans`. While pending, they have no entry on the calendar yet.
- **Should they appear on the calendar?** Andrew didn't mention them. Possible UX: pending requests shown as ghost/pending-styled entries on the requested date, with a "tap to approve" action for admins. Defer decision (see Open Questions).
- **Other than this and the three above, no other time-bound entities exist in the schema** (verified by scanning all migrations for date/timestamp columns relevant to a family-calendar surface).

### Day-detail dialog

- **Existing code:** **none.** No stub, no widget. Net new build.
- **Proposed shape** (one modal showModalBottomSheet or AlertDialog per day-cell tap):
  - **Header:** day-of-week + date (e.g., "Friday, May 30")
  - **Section: Meals** — list of meals planned for this day, grouped by `meal_type` (breakfast → lunch → dinner → snack). Each item: meal_type label, recipe title (or `custom_title`), assigned cook. Tap a meal → ??? (see Open Questions).
  - **Section: Chores** — list of chores due this day. Each item: title, assignee avatar/name, point value, status indicator. Tap a chore → ??? (see Open Questions).
  - **Section: Activities** — list of calendar_events for this day. Each item: existing `_EventCard` shape (title, tag, time range, description). Tap an event → existing edit/delete flow.
  - **Empty state per section:** small placeholder text ("No meals planned" / "No chores due" / "No activities").
  - **Empty overall:** if all three are empty, single placeholder: "Nothing scheduled for this day. Tap + to add an event, plan a meal, or assign a chore."
  - **Add buttons in the dialog header:** + Activity (existing flow), + Meal (navigate to meal_planner for this day), + Chore (navigate to chore_dashboard or chore-creation flow for this day). Each pre-fills the date.

### Open questions for Andrew (consolidated)

1. **Day-cell visual treatment.** Currently shows up to 3 colored dots (events only). Should this change to:
   - One dot per source type (e.g., yellow=meals, blue=events, green=chores)? Aggregate count badge ("3" in the corner)? Both?
   - Or leave dots as event-only and rely on the dialog for the full picture?
2. **Tap behavior on items inside the day-detail dialog:**
   - **Meal tap:** navigate to `meal_planner_screen` for edit? Or to the recipe detail screen? Or read-only display?
   - **Chore tap:** navigate to `chore_detail_screen`? Or quick-mark-complete inline? Or just read-only?
   - **Event tap:** keep existing _EventCard delete-on-swipe + presumably some edit flow (the existing inline panel handles this — confirm we preserve in the dialog)?
3. **Status filter for chores.** Should the calendar show:
   - Only `assigned` / `in_progress` (active chores)
   - All statuses including `completed` / `verified` (full historical accuracy)
   - Or default to active + opt-in toggle for completed
4. **All-day events.** They have `starts_at` and possibly `ends_at` but `all_day = true`. Show time in the day-detail dialog? Show as "All day" badge? (Currently the inline `_EventCard` already handles this — confirm same behavior in dialog.)
5. **`meal_requests`** (kid-initiated, pending admin approval). Should pending requests appear on the calendar? If yes:
   - Visually distinct from approved meal_plans (ghost / dashed border / amber color)
   - Admin-only? Or visible to kids too?
   - Tap to approve from the dialog?
6. **Spanning events.** `calendar_events.ends_at` may extend across multiple days. Currently `_eventsForDay` only matches `starts_at` to the day — multi-day events appear only on the start date. Same shape for the dialog, or expand to show on every day in the range?
7. **Past completed chores.** A chore with `due_at` two weeks ago that was completed: should it appear on the calendar's view of that historical day, or be filtered out as "not interesting anymore"?

### Fix plan (three phases)

#### Phase 1 — add `meal_plans` fetch + render (original Bug 1 scope)
- Parallel fetch in `_loadEvents()` (rename to `_loadCalendarData()`)
- New state `_mealPlans`, new helper `_mealPlansForDay(day)`
- Render meals in the existing inline panel below the grid (keep current UX for now — dialog comes in Phase 3)
- Day-cell dots updated to optionally include meal-color
- **Scope:** medium, ~50-80 lines added to `calendar_screen.dart`. **Time: 1-2 hours + 30 min smoke test.**

#### Phase 2 — add `chores` fetch + render
- Add a third parallel fetch in `_loadCalendarData()` for `chores` filtered by `due_at` in the focused month, joined with `assignee:household_members(display_name)`
- New state `_chores`, new helper `_choresForDay(day)`
- Add chore display section in the same inline panel
- **Scope:** medium, ~60-90 lines. **Time: 1-2 hours + 30 min smoke test.**

#### Phase 3 — day-detail dialog
- Build a new `_DayDetailDialog` widget (or `showModalBottomSheet`-based sheet)
- Move the existing inline-panel content into the dialog
- Three sections: Meals / Chores / Activities, each with its own _MealCard, _ChoreCard, existing _EventCard
- Update day-cell `onTap` to call `_showDayDetail(day)` (which still sets `_selectedDay` + shows the dialog)
- Add the three contextual "+" buttons in the dialog header for quick add (each routes to its respective creation flow with the date pre-filled)
- **Scope:** larger — ~150-250 lines (new widget + sections + integration). **Time: 3-4 hours + 1 hour smoke test.**

**Phase total:** 5-9 hours focused work + ~2 hours testing. Realistic span: **1.5-2 working days.**

**Phase ordering rationale:** Phase 1 alone closes the Bug 1 ticket as filed. Phase 2 expands to chores per Andrew's clarified intent. Phase 3 introduces the dialog UX shift. Each phase ships independently — you can stop after Phase 1 if priorities change, or ship Phases 1+2 with the existing inline panel before committing to the dialog redesign.

### SQL queries for Andrew to run in Supabase SQL Editor

```sql
-- A. List of chore-related tables
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public' AND table_name LIKE '%chore%';

-- B. Sample chore data for the household
SELECT id, title, assigned_to_member_id, due_at, chore_of_day_date,
       status, point_value, recurrence_rule, created_at
FROM public.chores
WHERE household_id = 'a36cf652-d58a-4a62-a09e-f01d74a57ef9'
ORDER BY due_at DESC NULLS LAST
LIMIT 10;

-- C. RLS policies on chore tables
SELECT tablename, policyname, cmd, qual, with_check
FROM pg_policies
WHERE tablename LIKE '%chore%';

-- D. Sample calendar_events for the household
SELECT id, title, starts_at, ends_at, all_day, tag_id, color_override,
       recurrence_rule, created_by_member_id
FROM public.calendar_events
WHERE household_id = 'a36cf652-d58a-4a62-a09e-f01d74a57ef9'
ORDER BY starts_at DESC
LIMIT 10;

-- E. RLS policies on calendar_events
SELECT policyname, cmd, qual, with_check
FROM pg_policies
WHERE tablename = 'calendar_events';
```

Query A confirms no chore-instance tables I missed (expected: `chores`, `chore_templates`, `chore_verification_photos`, `chore_history`, `chore_comments`). B confirms chores actually have `due_at` set in production (the design might be that chores only get `due_at` for specific cases, with template-based recurrence handled differently — worth verifying). C confirms RLS is just the one `household_scoped_chores` policy. D + E confirm calendar_events live state.

## Other findings
None yet. More bugs will likely surface as additional testers are invited.
