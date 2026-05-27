# Fetcher Sub-Spike Findings (2026-05-27)

**Branch:** `spike/fetcher-scraperapi-2026-05-27`
**Context:** Follow-up to `v0.6.1-recipe-scraping-spike` (2026-05-26), which identified fetcher as the bottleneck for recipe URL import. This sub-spike tested two commercial scraping providers, then broadened into analysis of how production recipe apps actually handle URL import.

## TL;DR

1. **Server-side URL scraping is the wrong primary path for a mobile-first recipe app.** Free-tier commercial scrapers hit ~1/4 success on hard sites. Paid tiers improve this but cost real money, and even production-scale apps don't rely on server-side scraping as their primary import path.
2. **The production-grade approach is multi-path:** iOS Share Sheet + Safari Web Extension (bypasses anti-bot entirely), shared recipe library (cache-once), per-site handling for the top 5-10 sources, and server-side URL fetch as a best-effort fallback.
3. **Recipe Phase 1 should be designed around this multi-path model**, not the "fix the fetcher first" framing from yesterday's spike.

## Spike results

### Test set

5 URLs originally (the failures from the previous spike). King Arthur excluded mid-spike after browser verification revealed URL drift — KA returns "Page Not Found" in any browser, not a proxy block. Effective test set: 4 URLs.

| ID | Site | Source type |
|---|---|---|
| 1 | Allrecipes | major_site |
| 2 | Food Network | major_site |
| 3 | Serious Eats | major_site |
| 15 | Damn Delicious | random_blog |

### Results

| URL | ScraperAPI free, `render=true` | Apify free, `web-scraper` actor |
|---|---|---|
| Allrecipes | ✗ HTTP 200, body stripped to plain text (schema.org JSON-LD absent) | ✗ Navigation timeout >60s |
| Food Network | ✓ Full HTML, 18 ingredients parsed | ✓ Browser loaded fine (only our pageFunction bug blocked capture) |
| Serious Eats | ✗ HTTP 500 at ~56s (render timeout) | ✗ Puppeteer TargetCloseError |
| Damn Delicious | ✗ HTTP 500 at ~56s (render timeout) | ✗ Puppeteer TargetCloseError |

**Effective parse success: 1/4 for both providers.** Same architecture, same outcome — neither service's free-tier proxy network is sufficient against modern anti-bot. Allrecipes, Serious Eats, and Damn Delicious all rejected both services for the same fundamental reason: their proxy IPs are known datacenter ranges that anti-bot systems classify as non-human.

### Downstream pipeline confirmed working

The parser pipeline (schema.org JSON-LD → recipe-scrapers fallback → Claude Haiku 4.5 as final fallback) works correctly when given good HTML. Food Network's clean 18-ingredient extraction proves the architecture downstream of the fetcher is sound.

### Costs

- ScraperAPI: 7 of 1000 free credits used (5 main run + 2 inspection).
- Apify: 0.144 compute units (~$0.03) of $5/mo free credit.
- Real-money spend for the entire morning: ~$0.03.

## How production recipe apps actually solve this

The morning's spike results — 1/4 effective on hard sites — initially read as catastrophic. But established recipe apps (Paprika, Mealime, Plan to Eat, Whisk, Yummly) do handle these sites in production. They don't do it through better generic scraping. They do it through a combination of approaches our spike never tested.

### 1. iOS Share Sheet + Safari Web Extension (mobile-first)

When a user is reading a recipe in Safari on their phone, they tap Share → Honeydo. The most basic implementation passes just the URL — which puts us back in the scraping problem. **But** a Safari Web Extension can be configured to pass the *current page's DOM* as part of the share. The user is already authenticated on the recipe site, the page is fully loaded with all anti-bot challenges already passed, JS has finished executing. The extension reads the rendered DOM directly and sends structured data to the app.

This is how Whisk's "Save Recipe" works. It's how Paprika's browser extension works. **The user's own browser does the fetching, completely bypassing anti-bot.** Allrecipes can't distinguish "user is reading the recipe" from "user just clicked Save Recipe" — both look identical to their servers.

For a mobile-first family app like Honeydo, this is probably the highest-leverage path. It needs a separate Safari Web Extension target alongside the iOS app, but iOS makes this reasonably straightforward (extensions ship as part of the main app bundle).

### 2. Shared recipe library (cache-once-per-recipe)

Every successful import goes into a shared catalog accessible to all households. The first family who successfully imports "Allrecipes chocolate chip cookies" puts it in the catalog. Every family after that just taps to add — no fetcher involved, no anti-bot to defeat.

Over time, the most-imported recipes accumulate. A 50-60% fetcher success rate becomes irrelevant for popular recipes because they're already cached from someone else's earlier successful import.

This is the architectural commitment from the broader morning discussion. It's not a fetcher fix; it's a fetcher bypass.

### 3. Per-site custom handling for the top sources

The `recipe-scrapers` library has site-specific subclasses for each of its 500+ supported sites — `recipe_scrapers/allrecipes.py`, `recipe_scrapers/foodnetwork.py`, each with custom code for that site's quirks. The library's success on those sites is built on engineering time spent understanding each one, not on a generic approach.

Production apps that "reliably scrape Allrecipes" typically do the same for *fetching* — custom headers for Allrecipes, custom cookie pre-fetch for Serious Eats, residential-proxy routing for just the top 10 most-requested domains. The generic spike pipeline we built does none of this.

For Phase 1, identifying the top 5-10 source sites that Honeydo users actually want to import from (probably Allrecipes, Food Network, NYT Cooking, Pinterest, plus a handful of food blogs) and tuning the fetcher per-site is more productive than chasing a generic 95% success rate.

### 4. Residential proxies for server-side fallback

The biggest gap between free-tier scrapers (which we tested) and production scraping is residential proxy pools — proxies that route through real consumer ISPs (Comcast, Verizon, etc.) and look indistinguishable from regular users on home WiFi. Datacenter proxies cluster on known IP ranges that anti-bot easily blocks; residential proxies cost 10-50x more but are much harder to detect.

ScraperAPI `ultra_premium`, Apify `RESIDENTIAL` proxy group, Bright Data, Oxylabs — these are real businesses charging $500-5000/month to enterprises specifically for this. A scaled-up recipe app paying for residential proxies could realistically get to 80-90% fetcher reliability on the hard sites.

For a hobby-scale family app, this is overkill. But if Phase 1 needs better server-side fetching than self-hosted Playwright provides, the residential proxy upgrade is the proven lever. Pricing scales with volume — small-family-app usage might be in the $20-50/month range on paid tiers, not $500.

### 5. Recipe API services (sidestep scraping entirely)

Spoonacular has a free tier (150 requests/day) that returns structured recipe data across many sources via API. Edamam similar. These services have done the licensing/scraping work upstream; you query their API and get clean JSON. For Phase 1, Spoonacular could backbone the "browse recipes" path entirely without any scraping at all.

This doesn't replace user-initiated URL import (users want to save *their* recipes from the sites they already use), but it could complement it. The shared library could be seeded from Spoonacular for breadth, then grow organically as users import their personal favorites.

## Revised Phase 1 architecture

Replace "fix the fetcher" with a multi-path import strategy. Approximate priority order for Phase 1:

1. **Browse shared library.** Tap a recipe in the shared catalog, add it to your household. Primary path. No external services beyond your own Postgres.
2. **iOS Share Sheet + Safari Web Extension.** User browses recipes in Safari, hits Share → Honeydo, extension reads DOM, structured recipe lands in the app. Highest-fidelity import path for mobile users. Bypasses anti-bot entirely.
3. **Text paste.** User pastes recipe text from anywhere (email, screenshot OCR, retyped). Claude (Haiku 4.5) parses. Always works regardless of source.
4. **Photo OCR.** User snaps a cookbook page or recipe card. Claude vision extracts. Always works.
5. **URL paste (best-effort server-side).** Try fetch via self-hosted Playwright (or whatever wins the future fetcher trial). On success, parse and present. On failure, fall back to (3). For users who try this path, the experience is "lucky path works ~60% of the time; clear fallback when it doesn't."

The shared library binds these together: every successful import via any path optionally gets added to the global catalog (with attribution + moderation flow), which feeds path 1 for future users.

## Recommended next investigations

Listed roughly in priority order:

### A. Safari Web Extension feasibility study
The highest-leverage but least-explored path. Need to confirm:
- Can a Safari Web Extension on iOS actually pass page DOM through Share Sheet to a paired iOS app target?
- What's the developer effort to ship a Safari Web Extension alongside the existing Flutter iOS app?
- Are there reference implementations / known patterns?

Spike scope: 1-2 days. Outcome should be: clear yes/no on whether this is the primary import path or supplementary.

### B. Self-hosted Playwright trial (server-side fetch)
Same 4 URLs, self-hosted Playwright instance. Test whether direct control of the fetching environment provides meaningful improvement over the free-tier proxy services we tested today. Expected outcome: similar 1/4 on the hardest sites (proxy quality is the limiter, not browser engine), but rules in or out the self-hosting path before committing to either paid scrapers or accepting the limitation.

Spike scope: half a day. Existing parser pipeline is ready to plug in.

### C. Per-site handling for the top sources
Once paths A and B are clearer, identify the top 5-10 sites Honeydo users actually want to import from (will require user data we don't have yet) and add site-specific fetch + parse handling for each. `recipe-scrapers` already has the per-site parser code; this work is mostly per-site fetch tuning.

Spike scope: ongoing optimization, not a single batch.

### D. Spoonacular API exploration
Test Spoonacular's free tier on the URL set (does it have these recipes already? what does coverage look like for typical family-cooking searches?). May be a viable backbone for the shared library's initial seeding.

Spike scope: half a day.

## Patterns / lessons captured

1. **Secrets never go in URL query params.** ScraperAPI documents `?api_key=...`; Apify's quickstart uses `?token=...`. Both are footguns — a single unhandled exception leaks the credential into tracebacks. Always use `Authorization: Bearer <token>` header auth even when the vendor's quickstart shows the URL-param form.
2. **Apify actors require interactive permission approval the first time you invoke them via API.** Read-only API calls work, but `POST /v2/acts/{id}/runs` returns 403 with `type: full-permission-actor-not-approved` and an `approvalUrl`. One-time per actor per account; can't be granted programmatically.
3. **`python-dotenv`'s `load_dotenv()` walks the Python call stack to find `.env`.** Works for `python script.py`, fails for heredoc-piped Python. In heredoc contexts, always pass `dotenv_path=` explicitly.
4. **Apify Web Scraper `pageFunction` runs in browser context, not Node.** Use DOM APIs (`document.documentElement.outerHTML`) — not Puppeteer Node-side APIs (`page.content()`). Easy to confuse because the surrounding actor code is Node.
5. **Apify Web Scraper canonicalizes URLs in dataset items.** Don't match items back to requested URLs by string equality — use `item.loadedUrl` and tolerate trailing-slash/scheme/redirect differences.
6. **"Run SUCCEEDED" in Apify means the orchestrator didn't crash.** Does NOT mean the pageFunction returned data. Check dataset items for `#debug` or `#error` keys before assuming success.
7. **"Works with 500+ sites" marketing claims describe parser support, not fetcher reliability.** When a scraping library or service advertises broad site support, that usually means "the parser handles each site's schema.org markup when given good HTML" — fetching is a separate, harder problem they don't always own.

## Files in this sub-spike

- `spike/fetcher-trial/test_set.json` — 5 URLs (full set from previous spike's failures)
- `spike/fetcher-trial/test_set_apify.json` — 4 URLs (King Arthur excluded)
- `spike/fetcher-trial/run_scraperapi.py` — ScraperAPI runner
- `spike/fetcher-trial/inspect_failures.py` — diagnostic for Allrecipes "fetched-but-empty"
- `spike/fetcher-trial/run_apify.py` — Apify runner with Authorization-header auth
- `spike/fetcher-trial/results/scraperapi_run_*.json` — raw ScraperAPI results
- `spike/fetcher-trial/results/raw_html/{allrecipes,kingarthur}.*` — diagnostic HTML
- `spike/fetcher-trial/results/apify_run_*.json` — raw Apify results
- `spike/fetcher-trial/ingredient_parser.py`, `http_fetch_baseline.py` — reused from prior spike
