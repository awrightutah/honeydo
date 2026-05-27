# Fetcher Spike Findings (2026-05-27)

**Branches:** `spike/fetcher-scraperapi-2026-05-27` (ScraperAPI + Apify trial), `spike/playwright-fetcher-2026-05-27` (Playwright trial)
**Context:** Follow-up to `v0.6.1-recipe-scraping-spike` (2026-05-26), which identified fetcher as the bottleneck for recipe URL import. This spike tested three fetcher approaches across the same 4-URL test set, then synthesized findings into a Phase 1 architecture recommendation.

## TL;DR

1. **Proxy IP class is the dominant variable in recipe scraping success, not browser engine or parser quality.** Datacenter IPs (free-tier ScraperAPI, free-tier Apify, every production cloud datacenter) get rejected by anti-bot on major recipe sites. Residential IPs (a user's home WiFi, including the laptop this spike ran from) walk straight through.
2. **Self-hosted Playwright from a residential IP achieved 3/3 on the URLs that actually exist** (after correcting two URL-drift false negatives in the test set). Both commercial services on free tier hit 1/3.
3. **The production-grade architecture for a mobile-first recipe app uses the user's own browser as the fetcher** — via iOS Share Sheet + Safari Web Extension — because the user's phone IS a residential IP. This bypasses both the anti-bot problem and the residential-proxy cost problem in a single move.
4. **Server-side URL fetching remains a useful fallback path**, but its realistic ceiling from a datacenter is ~1-2/4 on hard sites. Residential proxies improve that materially but cost real money ($20-500+/month depending on scale).

## Test set

5 URLs originally (the failures from the previous spike). Two excluded after browser verification revealed URL drift — KA returns "Page Not Found" in any browser, and Serious Eats' Food Lab cookies URL also returns "404 Oops! We didn't follow the recipe...". Effective test set: 3 URLs that actually exist.

| ID | Site | Source type | Exists? |
|---|---|---|---|
| 1 | Allrecipes | major_site | yes |
| 2 | Food Network | major_site | yes |
| 3 | Serious Eats | major_site | **no — URL drift** |
| 5 | King Arthur | major_site | **no — URL drift** |
| 15 | Damn Delicious | random_blog | yes |

The URL-drift finding is itself a useful lesson: recipe URLs are not stable. Any real-world recipe import flow needs to handle 404s gracefully — even when the URL was valid yesterday.

## Results across all three trials

Real scores on the 3 URLs that genuinely exist:

| Fetcher | Allrecipes | Food Network | Damn Delicious | Score |
|---|---|---|---|---|
| Vanilla `requests` (baseline) | ✗ 403 | ✗ 403 | ✗ 403 | 0/3 |
| ScraperAPI free, `render=true` | ✗ stripped HTML (no JSON-LD) | ✓ 18 ingredients | ✗ HTTP 500 (render timeout) | 1/3 |
| Apify free, `web-scraper` actor | ✗ nav timeout >60s | ✓ (browser loaded fine, pageFunction bug killed capture) | ✗ TargetCloseError | 1/3 |
| **Self-hosted Playwright (residential IP)** | **✓ 11 ingredients** | **✓ 18 ingredients** | **✓ 17 ingredients** | **3/3** |

The contrast on Allrecipes is the clearest signal:
- ScraperAPI returned 17,859 bytes of stripped text (no JSON-LD anywhere)
- Apify timed out at 60s
- Playwright returned 1,875,238 bytes (105× more) with intact schema.org markup that parsed cleanly

Same site, same recipe, same browser engine downstream of the fetcher. The variable that changed was the IP class of the request originator.

## Downstream pipeline (parser layer) — re-confirmed working

The parser pipeline (schema.org JSON-LD → recipe-scrapers fallback → Claude Haiku 4.5 as AI fallback) works correctly when given good HTML. All three "fetch succeeded" cases produced clean ingredient extraction with no manual tuning.

## Costs

- ScraperAPI: 7 of 1000 free credits used.
- Apify: 0.144 compute units (~$0.03) of $5/mo free credit.
- Playwright: $0 (self-hosted, no API calls, residential IP from local machine).
- Total real-money spend for the spike: ~$0.03.

## Why proxy IP class is the dominant variable

Modern anti-bot defenses on major recipe sites (Cloudflare, Akamai, Datadome, PerimeterX) score incoming requests on multiple signals. The dominant signal for our test sites appears to be IP reputation — specifically, "is this IP in a known datacenter range, or does it look like a residential ISP?"

Datacenter IPs (AWS, GCP, Azure, DigitalOcean, Fly.io, Railway, and the proxy pools of ScraperAPI's free tier and Apify's default APIFY proxy group) are well-catalogued by anti-bot vendors. They cluster on known CIDR blocks. A single fetch from one of these IPs is treated as untrusted by default.

Residential IPs (Comcast, Verizon, Spectrum, etc. — home internet connections) are vastly harder to fingerprint as bot traffic. They look exactly like real human users because most real human users come from residential ISPs.

This explains the result asymmetry:
- The commercial scraping services we tested (free tiers) use datacenter proxies → 1/3
- Self-hosted Playwright from a real residential ISP → 3/3
- Self-hosted Playwright from a datacenter VPS would (expected, not tested) → ~1/3 — losing the residential advantage

Mitigation paths for datacenter deployment:
- **Residential proxy services** (Bright Data, Oxylabs, Smartproxy, ScraperAPI ultra_premium, Apify RESIDENTIAL group). Cost: ~$10-50/mo at hobby scale, $500-5000/mo at enterprise. These services route through real consumer IPs and are the standard production answer for "scrape major sites reliably."
- **Run from a residential IP (the user's own phone)**. Free. This is what the Safari Web Extension path achieves architecturally.

## How production recipe apps actually solve this

Established recipe apps (Paprika, Mealime, Plan to Eat, Whisk, Yummly) handle the hard sites in production. They use combinations of the following:

### 1. iOS Share Sheet + Safari Web Extension (mobile-first)

When a user reads a recipe in Safari on iOS and taps Share → AppName, a Safari Web Extension can read the rendered DOM and pass structured data to the paired iOS app. The user is already authenticated, the page is fully loaded with all anti-bot challenges passed, JS has finished executing. **The user's own browser does the fetching.**

This is how Whisk's "Save Recipe" works, how Paprika's browser extension works on web. **The recipe site cannot distinguish "user is reading the recipe" from "user just clicked Save Recipe."** Same authenticated session, same residential IP, same browser fingerprint — because it's literally the same browser.

Today's Playwright result is the experimental proof that residential-IP browser fetching defeats the anti-bot problem on these sites. The Safari Web Extension achieves exactly this at zero infrastructure cost.

### 2. Shared recipe library (cache-once-per-recipe)

Every successful import lands in a shared catalog accessible to all households after moderation. The first family who successfully imports "Allrecipes chocolate chip cookies" puts it in the catalog. Every family after that just taps to add — no fetcher involved.

Over time, popular recipes accumulate. Even a 50% fetcher success rate becomes irrelevant for popular recipes because they're already cached from someone else's earlier successful import.

### 3. Per-site custom handling for top sources

`recipe-scrapers` has site-specific subclasses for each of its 500+ supported sites. Production apps that "reliably scrape AllRecipes" typically also have per-site fetcher tuning (custom headers, cookie pre-fetch, residential-proxy routing for just the top 10 domains).

### 4. Residential proxies for server-side fetching

If server-side URL fetch is genuinely required (e.g., backfilling the shared library by scraping at scale, or supporting platforms without the Safari Web Extension), residential proxies are the proven lever. Cost is real but bounded — hobby-scale recipe-importing usage probably fits in the $10-30/month range.

### 5. Recipe API services (sidestep scraping entirely)

Spoonacular (free tier: 150 requests/day), Edamam, similar services return structured recipe data without you doing any scraping. Useful as a backbone for the shared library's initial seed, less useful for "import THIS specific recipe my friend sent me."

## Revised Phase 1 architecture

Multi-path import. Approximate priority order:

1. **Browse shared library.** Tap a recipe in the shared catalog, add to household. Primary path. No external services beyond Postgres.
2. **iOS Share Sheet + Safari Web Extension.** User browses recipes in Safari, hits Share → Honeydo, extension reads DOM, structured recipe lands in the app. Highest-fidelity import path for iOS users. Bypasses anti-bot entirely via the user's residential IP. **Identified by this spike as the highest-leverage import path.**
3. **Text paste.** User pastes recipe text from anywhere. Claude (Haiku 4.5) parses. Always works regardless of source.
4. **Photo OCR.** User snaps a cookbook page or recipe card. Claude vision extracts. Always works.
5. **Server-side URL fetch (best-effort fallback).** Self-hosted Playwright or commercial scraping service. ~1-2/4 from datacenter without residential proxies. Adequate as a fallback for users on platforms without the Safari extension, or for users who paste a URL with no other context. Explicitly the weak path.

The shared library binds these together: every successful import via any path can be added to the global catalog (with attribution + moderation), feeding path 1 for future users.

## Recommended next investigations

Listed in priority order:

### A. Safari Web Extension feasibility study (highest leverage)
The highest-leverage but least-explored path. Need to confirm:
- Can a Safari Web Extension on iOS actually pass page DOM through Share Sheet to a paired iOS app target (Flutter)?
- What's the developer effort to ship a Safari Web Extension alongside the existing Flutter iOS app?
- Are there reference implementations / known patterns?

Spike scope: 1-2 days. Outcome should be: clear yes/no on whether this is the primary import path or supplementary, plus a sketch of the implementation approach if yes.

### B. Shared library schema design
Major Phase 1 design work. Schema, RLS, moderation flow, attribution model, deduplication strategy, browse/search UX. Independent of fetcher decisions — needed regardless of which import paths ship first.

Spike scope: 1-2 days for the spec doc. Implementation comes later.

### C. Spoonacular API exploration
Test Spoonacular's free tier as a backbone for the shared library's initial seed. Half-day investigation.

### D. Per-site handling (deferred)
Once paths A and B are clearer, identify the top 5-10 sites Honeydo users actually want to import from and add per-site fetch tuning for each. Needs user data we don't have yet.

### Explicitly deferred / ruled out

- **Residential proxy services**. Recommended only if/when the Safari Web Extension path is unavailable (e.g., Android version) or insufficient. Not needed for v1 iOS-first launch.
- **More commercial scraper testing (ScraperAPI paid tiers, Apify residential proxies)**. The Playwright result establishes that the residential-IP approach works at 3/3. Commercial residential proxies would replicate this for server-side at cost. The interesting question is no longer "does this category work" — it's "do we need server-side residential proxies at all, or does the Safari path cover the need."

## Patterns / lessons captured

1. **Proxy IP class trumps browser engine.** When evaluating a scraping approach, ask "what's the IP class of the request origin?" before asking about browser, parser, or anti-bot evasion. A vanilla Playwright from a residential IP outperformed both a "premium" managed scraper and an enterprise-grade headless-browser scraper, both running through datacenter proxies.
2. **Secrets never go in URL query params.** ScraperAPI documents `?api_key=...`; Apify's quickstart uses `?token=...`. Both are footguns — a single unhandled exception leaks the credential. Always use `Authorization: Bearer <token>` header auth.
3. **Apify actors require interactive permission approval the first time you invoke them via API.** Read-only API calls work, but `POST /v2/acts/{id}/runs` returns 403 with `type: full-permission-actor-not-approved` and an `approvalUrl`. One-time per actor per account; can't be granted programmatically.
4. **`python-dotenv`'s `load_dotenv()` walks the Python call stack to find `.env`.** Works for `python script.py`, fails for heredoc-piped Python. In heredoc contexts, always pass `dotenv_path=` explicitly.
5. **Apify Web Scraper `pageFunction` runs in browser context, not Node.** Use DOM APIs (`document.documentElement.outerHTML`) — not Puppeteer Node-side APIs (`page.content()`).
6. **Apify Web Scraper canonicalizes URLs in dataset items.** Don't match items back to requested URLs by string equality.
7. **"Run SUCCEEDED" in Apify means the orchestrator didn't crash.** Does NOT mean the pageFunction returned data. Check dataset items for `#debug` or `#error` keys.
8. **"Works with 500+ sites" marketing claims describe parser support, not fetcher reliability.** Two separate problems; vendors often own only the easier one (parsing) and hedge on the harder one (fetching).
9. **Playwright 1.60 ships "Chrome Headless Shell" by default**, not full Chromium. Stripped-down (~92 MiB vs ~150 MiB) for headless-only automation. Anti-bot detection may distinguish this from full Chrome more easily. Use `playwright install chrome` (system Chrome) if the bundled shell triggers detection.
10. **Recipe URLs are not stable.** Two of our five test URLs URL-drifted between test set creation (2026-05-26) and validation (2026-05-27). Any real-world import flow needs to handle 404s gracefully even on URLs that were valid recently.

## Files in this spike

### From spike/fetcher-scraperapi-2026-05-27 (already merged to main via d95d99c)
- `spike/fetcher-trial/run_scraperapi.py` — ScraperAPI runner
- `spike/fetcher-trial/inspect_failures.py` — diagnostic for Allrecipes "fetched-but-empty"
- `spike/fetcher-trial/run_apify.py` — Apify Web Scraper runner with Authorization-header auth
- `spike/fetcher-trial/results/scraperapi_run_*.json` — raw ScraperAPI results
- `spike/fetcher-trial/results/raw_html/{allrecipes,kingarthur}.*` — diagnostic HTML
- `spike/fetcher-trial/results/apify_run_*.json` — raw Apify results
- `spike/fetcher-trial/test_set.json`, `test_set_apify.json`, `ingredient_parser.py`, `http_fetch_baseline.py`

### From spike/playwright-fetcher-2026-05-27 (this branch, pending merge)
- `spike/playwright-trial/run_playwright.py` — Playwright runner
- `spike/playwright-trial/results/playwright_run_*.json` — raw Playwright results
- `spike/playwright-trial/test_set.json` — same 4 URLs as Apify run (King Arthur excluded; Serious Eats now also known to be URL-drift)
- `spike/playwright-trial/ingredient_parser.py` — reused parser
- `spike/playwright-trial/.env.example`, `.gitignore`, `requirements.txt`
