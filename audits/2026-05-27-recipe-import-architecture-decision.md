# Recipe Import Architecture Decision (2026-05-27)

**Status:** Committed for Phase 1 implementation. Supersedes the morning's "Safari Web Extension as primary path" framing in `audits/2026-05-27-fetcher-spike-findings.md`.

**Decision in one sentence:** Recipe URLs are imported by loading them in an in-app WebView (WKWebView on iOS, native WebView on Android) and extracting the rendered HTML via JavaScript, then parsing with schema.org + recipe-scrapers + Claude Haiku 4.5 as fallback. The user's phone provides the residential-IP advantage that defeats anti-bot at no infrastructure cost.

## Why this architecture (the short version)

Four fetcher approaches were tested today against the same URL set:

| Approach | Score | IP class |
|---|---|---|
| Vanilla `requests` | 0/3 | datacenter (laptop, no proxy) |
| ScraperAPI free, `render=true` | 1/3 | datacenter proxy pool |
| Apify free, `web-scraper` actor | 1/3 | datacenter proxy pool |
| Self-hosted Playwright | 3/3 | residential (laptop's home ISP) |
| **In-app Flutter WKWebView** | **4/4** | **residential (phone's mobile data / home WiFi)** |

The fourth approach matched the Playwright result on the original three URLs *and* added Bon Appétit (Datadome anti-bot) as a 4th success. The defining variable across all five approaches is proxy IP class. The user's phone is a residential IP. Mobile WebViews on a phone get the residential-IP advantage for free, with no proxy fees, no server infrastructure, no extra app target.

## The full path inventory

Phase 1 supports multiple import paths. Each handles a different user situation:

### 1. Browse shared library (top priority)
Tap a recipe already in the shared catalog → add to household. No fetcher involved. Cache hit. Free, fast, always works.

### 2. URL paste → in-app WebView fetch (primary fetch path)
User pastes a recipe URL into Honeydo. The app loads it in an in-app WebView, waits for render, extracts HTML via `document.documentElement.outerHTML`, runs it through schema.org + recipe-scrapers parsers, and presents the structured recipe for confirmation before save.

Cross-platform: same Flutter code, native WebView on each platform.

### 3. iOS Share Sheet → routes into path 2
User reads a recipe in Safari, taps Share → Honeydo. The app receives the URL and routes it into the same in-app WebView fetcher used by path 2. From the user's perspective, it's a one-tap import; from the architecture's perspective, it's identical to URL paste.

Android equivalent: Android's standard "Share via" intent. Same routing.

### 4. Text paste (fallback)
User pastes recipe text from anywhere (email, screenshot, retyped). Claude Haiku 4.5 parses into structured form. Always works regardless of source.

### 5. Photo OCR (fallback)
User snaps a cookbook page or recipe card. Claude vision extracts text, parses. Always works.

### 6. Server-side URL fetch (deferred / contingent)
For platforms where in-app WebView is unavailable (a hypothetical future web client, etc.), server-side Playwright would fetch from a datacenter. ~1-2/4 effective without residential proxies; ~3-4/4 with residential proxies at ~$10-30/month at hobby scale.

Not needed for v1 iOS+Android launch. Deferred.

## What the spike did NOT cover

The in-app WebView spike proved that the *HTML fetch + parse* works. It explicitly did not exercise:

1. **Interactive interruptions.** Recipe sites often show overlays — cookie banners (GDPR consent), newsletter signup modals, paywalls, age gates, "subscribe to view" gates. The WebView renders all of these the same way the user's normal browser does. For some, the user can dismiss; for others (paywalls), the recipe content may never become visible. The fetcher will return whatever the page exposed at extraction time. Phase 1 UX needs to handle: user sees overlay in the WebView, dismisses it, then taps "extract" — that workflow is genuinely user-facing, not silent server-side.

2. **Login walls.** Some sites (NYT Cooking, certain food blogs with patrons-only content) require login. The WebView can carry the user's actual cookies/login if they sign in once — that's a feature, not a bug — but Phase 1 UX needs to surface this clearly. "Want to see the recipe? Sign in to NYT Cooking right here in the import flow."

3. **The Allrecipes "stripped HTML" anomaly.** ScraperAPI's stripped-text response from earlier today (17 KB instead of 1.8 MB) was specific to ScraperAPI's render mode and never explained. Not relevant to the chosen architecture, but documented in the spike findings as an open puzzle.

4. **Roundup / list pages.** The Bon Appétit "best pasta recipes" URL fetched cleanly but its JSON-LD describes a `NewsArticle` listing, not individual recipes. Phase 1 UX needs to handle the "this URL is a list, not a single recipe — here are the recipes it contains, pick one" case. Architectural support: the parser already distinguishes Recipe vs other @types; UX layer needs to interpret "no Recipe found" as a routing decision, not always a failure.

5. **Recipe URLs that 404.** Two of our five test URLs URL-drifted in less than 24 hours (King Arthur, Serious Eats). The WebView will receive the site's 404 page and the parser will find no Recipe schema. UX needs to handle this clearly: "We couldn't find a recipe at this URL — it may have moved. Try copy-pasting the recipe text instead."

## What "in-app WebView fetch" actually requires to ship

Engineering checklist for Phase 1's URL paste flow:

1. **Add `webview_flutter` to Honeydo's `pubspec.yaml`** (proven in spike, version 4.13.1 worked cleanly).
2. **Build the import screen UI:** URL input field, "Import" button, full-screen WebView area where the page renders, "Extract" button (or auto-extract on page finish), confirmation screen showing parsed recipe.
3. **Port the parsing logic** (schema.org JSON-LD + recipe-scrapers + Claude Haiku fallback) from the Python spike into Dart, OR call it via a Supabase Edge Function that takes HTML in and returns structured JSON out. The Edge Function approach is cheaper to build and easier to update.
4. **Define the `recipes` table schema** (covered separately in the shared library schema spec — pending).
5. **Handle the failure modes documented above** as explicit UX states.
6. **iOS Share Sheet receiver** that routes the URL into the same flow.
7. **Android intent receiver** for `ACTION_SEND` / `ACTION_VIEW`.

Steps 1-2 + the iOS receiver are likely Sub-batch A. Step 3 is Sub-batch B. Steps 4-6 wait on the shared library schema spec and aren't blocked by the WebView decision.

## What we ruled out (and why)

- **Server-side Playwright.** Would need residential proxies ($10-30/mo+) to match the in-app WebView's performance. In-app WebView achieves the same result for free.
- **ScraperAPI / Apify paid tiers.** Same conclusion — would cost money to match what the in-app WebView achieves for free.
- **Safari Web Extension.** Compelling on iOS but iOS-only. The in-app WebView covers both platforms with one codebase. Safari Web Extension may still be added later as an iOS-only convenience (read DOM from user's already-loaded Safari tab, no re-fetch needed), but it's no longer the primary path.
- **"Just type the recipe in" / "pick from our static catalog."** Friction-killer. Real users won't type recipes from blogs they want to save.

## What's now unblocked

With the import architecture decided, the next investigations can proceed in parallel:

- **Shared library schema design** (~1-2 days for the spec) — defines `recipes` (global) + `household_recipes` (join) + moderation/attribution model. Independent of WebView decision.
- **Spoonacular API exploration** (~½ day) — could seed the shared library with initial breadth.
- **In-app WebView implementation as Phase 1 Sub-batch A** — production-quality version of the spike code, integrated into Honeydo's existing import screen patterns.

## References

- `audits/2026-05-27-fetcher-spike-findings.md` — empirical results from today's three fetcher spikes (ScraperAPI + Apify + Playwright + WebView).
- `spike/flutter-webview-trial/webview_fetcher_spike/lib/main.dart` — proof-of-concept spike code, reference for the production implementation.
- `spike/fetcher-trial/`, `spike/playwright-trial/` — earlier-spike artifacts on main.
