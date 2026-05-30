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

## Other findings
None yet. More bugs will likely surface as additional testers are invited.
