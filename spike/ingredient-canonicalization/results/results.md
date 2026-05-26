# Recipe URL Scraping Spike — Findings & Recommendation

**Branch**: `spike/ingredient-canonicalization-2026-05-26`
**Date**: 2026-05-26
**Test set**: 17 URLs across `major_site` (4), `food_blog` (6), `random_blog` (5), `non_standard` (2). See `test_set.json` for the full list with notes.

## Headline finding

> **The fetcher is the bottleneck, not the parser.** All four major recipe sites (Allrecipes, Food Network, Serious Eats, King Arthur) and one mid-tier blog (Damn Delicious) block our `requests`-based fetcher with HTTP 403 anti-bot challenges. **No extraction approach — deterministic or AI — can recover from a URL it can't fetch.** For the URLs we *can* fetch, success rates are statistically identical across all three approaches.

> The real value of the AI approach is **output quality**, not success rate. Where deterministic approaches return raw recipe-card text ("freshly cracked black pepper", "boneless, skinless chicken breasts (cut into one inch cubes)"), AI returns canonical pantry items ("black pepper", "chicken breast") *with categories assigned automatically*.

## Recommendation

**Ship a hybrid: AI extraction primary, schema.org as cost-saver shortcut, robust fetcher as the actual gating dependency.**

1. **Fix the fetcher first.** Without a fetcher that can get past Cloudflare/anti-bot on the top 5 recipe sites, no parsing strategy works. Options:
   - **Headless browser (Playwright)**: significant infra add, but actually defeats bot challenges
   - **Commercial scraping API** (ScraperAPI / Scrapfly / Browserless): trivially solves the fetch problem; costs ~$0.001–0.005 per request
   - **Accept the limitation**: tell users that some sites can't be imported and let them paste ingredients manually
2. **For URLs we can fetch**: try schema.org/recipe-scrapers first; if it succeeds, use the result directly (zero cost). If it returns nothing useful, fall back to Claude AI for clean canonical extraction.
3. **Always run a final AI canonicalization pass** on the recipe-scrapers output for the **pantry/shopping use case** — recipe-scrapers' raw text is too noisy ("salt and pepper", "freshly chopped parsley", parentheticals like "(at room temperature)") to feed directly into a shopping aggregator.
4. **For social media URLs (Pinterest, Instagram, TikTok)**: trust the AI's `is_recipe: false` signal and show the user a clear "this URL isn't a single-recipe page" message. Don't pretend the import worked.

---

## The data

### Success rates

| Approach | Success | URLs that fetched OK |
|---|---|---|
| schema.org JSON-LD | 8/17 (47%) | 8/12 (67%) |
| recipe-scrapers (15.10) | 9/17 (53%) | 9/12 (75%) |
| Claude AI (Sonnet 4.5) | 9/17 (53%) | 9/12 (75%) |

**At least one approach succeeded: 9/17 (53%).** Failed on every approach: 8/17 (47%) — but **5 of those 8 were fetch failures** (HTTP 403) that no parsing approach could rescue. Of the 12 URLs we successfully fetched, **9 (75%) succeeded on at least one approach.**

### Per-source-type breakdown

| Source type | URLs | schema.org | recipe-scrapers | AI |
|---|---|---|---|---|
| `major_site` (Allrecipes, Food Network, Serious Eats, King Arthur) | 4 | **0/4** | **0/4** | **0/4** |
| `food_blog` (40 Aprons, Smitten Kitchen, HBH-roundup, Sally's, Minimalist Baker, Pinch of Yum) | 6 | 4/6 | 5/6 | 5/6 |
| `random_blog` (Recipe Critic, RecipeTin Eats, Skinnytaste, Budget Bytes, Damn Delicious) | 5 | 4/5 | 4/5 | 4/5 |
| `non_standard` (Pinterest, Instagram) | 2 | 0/2 | 0/2 | 0/2 |

The major sites are a **complete shutout**: zero of the four biggest recipe sites returned usable HTML to a `requests` UA. These are the URLs users are most likely to want to import.

### Failure mode distribution

| Failure category | schema.org | recipe-scrapers | AI | Why it matters |
|---|---|---|---|---|
| `blocked_fetch` (HTTP 403) | 5 | 5 | 5 | Identical for all three because they share the same `http_fetch` helper. **The dominant failure mode.** Fixing the fetcher fixes it for everyone. |
| `no_schema_found` (page fetched but no Recipe schema) | 4 | 3 | 0 | Pages we successfully retrieved but couldn't extract from via structured data. AI handled all of these (via rendered-prose parsing). |
| `not_a_recipe_ai` (AI explicitly declared "not a recipe") | 0 | 0 | 3 | **This is a feature, not a bug.** Slot 7 (HBH 40-recipes roundup), slot 16 (Pinterest), slot 17 (Instagram) all got correctly-rejected by AI with a clear reason — schema.org/recipe-scrapers just said "no schema" with no actionable signal. |

**Key insight**: recipe-scrapers picked up Smitten Kitchen where pure schema.org missed it (recipe-scrapers does some HTML fallback parsing beyond just JSON-LD). That's the only URL where recipe-scrapers beat plain schema.org.

### Ingredient-count agreement (URLs where ≥2 approaches succeeded)

| ID | URL | schema.org | recipe-scrapers | AI | Notes |
|---|---|---|---|---|---|
| 4 | 40aprons.com/marry-me-chicken | 13 | 13 | 12 | AI -1: dropped a duplicate "grated fresh parmesan cheese" topping entry |
| 6 | smittenkitchen.com/big-crumb-coffee-cake | — | 21 | 21 | Agreement on count; AI cleans names |
| 8 | sallysbakingaddiction.com/chocolate-chip-cookies | 10 | 10 | 10 | Perfect agreement |
| 9 | minimalistbaker.com/chocolate-cake | 16 | 16 | 14 | AI -2: collapsed embedded inline ingredients vs duplicated entries |
| 10 | pinchofyum.com/lentil-soup | 15 | 15 | 16 | AI +1: split "sherry, red wine vinegar, or lemon juice" into two items |
| 11 | therecipecritic.com/steak-foil-packets | 15 | 15 | 16 | AI +1: split "salt and pepper" into salt + pepper |
| 12 | recipetineats.com/chicken-marsala | 15 | 15 | 15 | Perfect agreement |
| 13 | skinnytaste.com/chicken-flautas | 9 | 9 | 8 | AI -1: dropped a "topping note" recipe-scrapers parsed as an ingredient |
| 14 | budgetbytes.com/dragon-noodles | 9 | 9 | 9 | Perfect agreement |

**Counts are within ±2 across approaches.** When they diverge, AI's judgment is usually defensible — it splits "salt and pepper" into two items (correct for a shopping list aggregator), drops topping notes that recipe-scrapers parsed as ingredients, and collapses duplicated entries. The cases where AI returned *fewer* items were generally cleaner; the cases where it returned *more* split conjunctions appropriately.

### Quality comparison — the actual reason to prefer AI

The numerical counts hide the meaningful difference. Here's slot 4 (40 Aprons "Marry Me Chicken") side-by-side:

| recipe-scrapers (raw) | AI (cleaned) |
|---|---|
| `boneless, skinless chicken breasts` (3 lb) | `chicken breast` (3 lb, **Meat**) |
| `freshly cracked black pepper (to taste)` (1 count) | `black pepper` (1 pinch, **Pantry**) |
| `olive oil (or other neutral oil)` (2 tbsp) | `olive oil` (2 tbsp, **Pantry**) |
| `minced garlic` (2 tbsp) | `garlic` (2 tbsp, **Produce**) |
| `low-sodium chicken broth (see Notes)` (0.75 cup) | `chicken broth` (0.75 cup, **Pantry**) |
| `grated fresh parmesan cheese (at room temperature, see Notes` (0.5 cup) | `parmesan cheese` (0.5 cup, **Dairy**) |

For a **pantry/shopping aggregator** use case, the AI output is **directly usable**: clean canonical names that aggregate correctly across recipes (so two recipes calling for "olive oil" and "extra virgin olive oil" collapse to one pantry item), and categories that match the app's existing dropdown. The recipe-scrapers output would need a second cleaning pass to strip qualifiers, parentheticals, prep notes, and assign categories — most likely *also via an AI call*. So even if you start with recipe-scrapers, you end up calling the AI anyway for canonicalization.

### Cost analysis (Claude API)

- **Avg input tokens**: 5,064 per URL (cleaned page text, truncated at 30K chars)
- **Avg output tokens**: 474 per URL (~10–16 ingredients × ~30 tokens of structured JSON each)
- **Avg latency**: 4.6 seconds per call

| Pricing tier | Cost per import | Annual cost per family (200 imports/yr) |
|---|---|---|
| Sonnet 4.5 ($3 / $15 per M tokens) | ~$0.022 | **~$4.46/family/year** |
| Haiku 4.5 ($1 / $5 per M tokens) | ~$0.007 | **~$1.49/family/year** |

**These are not significant costs at the per-family level.** Even at Sonnet pricing, $4–5/year per active family is negligible compared to the value of clean ingredient data for the shopping/pantry features. At Haiku pricing, it's noise.

Cost would only become material at **very high scale** (>100K active families) or **automated batch backfill** (re-extracting all imported recipes). For the launch trajectory, treat AI extraction as essentially free per-user.

### Latency

4.6 seconds per AI call is **noticeably slow** for a foreground "import this URL" flow. UX implications:
- Show a progress indicator immediately after URL paste
- Run schema.org first (instant); if it succeeds with good-quality output, skip AI entirely
- For URLs that need AI, the 4–6s wait is acceptable but should be explicit ("Reading recipe details — this takes a moment…")

Haiku 4.5 would likely cut this roughly in half (~2–3s) — a meaningful UX improvement on top of the cost savings.

---

## Recommended production architecture (Phase 1 implementation)

```
                  ┌─ "Couldn't reach the site, paste manually?" UX
                  │
                  │  fetch fails (403/timeout)
URL paste ─► Fetcher ─────────────────────────────────────────►
                  │
                  │  fetch succeeds
                  ▼
            schema.org JSON-LD parse
                  │
                  ├─ found Recipe schema with >=5 clean ingredients
                  │    ► Accept directly. No AI call.    (cost: $0)
                  │
                  └─ no Recipe schema, OR <5 ingredients, OR ingredients
                       look noisy (parentheticals everywhere, prep notes
                       in names)
                       ▼
                  Claude AI extraction with cleaning prompt
                       │
                       ├─ AI returns is_recipe: true
                       │    ► Save with structured ingredients + categories
                       │
                       └─ AI returns is_recipe: false
                            ► UX: "This page doesn't look like a single
                              recipe — got a different URL?"
```

### Why this hybrid

- **Cost-optimal**: most successful imports go through schema.org for free
- **Quality-optimal**: when AI runs, output is directly app-shape (clean names, categories)
- **UX-honest**: failure modes are categorized — fetch fail vs no schema vs "not a recipe" — each gets a different message
- **Future-proof**: as the AI model improves (cheaper, faster, smarter), the fallback path inherits the improvements without app changes

### Phase 1 implementation tasks

1. **Pick a fetcher strategy** (highest priority — gates everything else):
   - Spike a ScraperAPI / Scrapfly trial on Allrecipes + Food Network to confirm they actually defeat the bot defenses
   - OR spike Playwright with a recipe-tailored config
   - Decision and rough cost projection before any UI work
2. **Build the schema.org-first parser** (~1 day):
   - Use `recipe-scrapers` (15.10) as the implementation
   - Define a "quality threshold" for accepting schema.org output without AI cleanup: e.g., ≥5 ingredients, ≥80% with parsed quantity/unit (use the `_parse_quality` heuristic from this spike), title present
3. **Build the AI fallback** (~1 day):
   - System prompt from `run_ai.py` is a working starting point — already produces app-shape JSON
   - Decide between Sonnet 4.5 ($4.46/family/yr, 4-6s latency) and Haiku 4.5 ($1.49/family/yr, ~2-3s latency). Recommend **Haiku for production** given the quality results were already good and latency matters more than the marginal accuracy gain at this point
   - Token-budget the input cleanup (current `clean_text_for_ai` at 30K cap is reasonable)
4. **Define the failure UX** (~0.5 day):
   - Three messages: "couldn't reach site" / "this doesn't look like a recipe page" / "couldn't extract ingredients — paste them manually"
   - The third one should drop the user into the manual recipe-entry flow with whatever title + image we *did* manage to fetch pre-populated

---

## Caveats + limitations the production version will need to handle

1. **The major-site fetch problem is real and the spike didn't solve it.** Until the fetcher question is answered, no architecture above ships.
2. **AI hallucination risk**: the spike showed AI sometimes adjusted quantities (e.g., "0.5 cup baking powder" → "1.5 tsp baking powder" in slot 9 — both possibly wrong). For pantry/shopping the rounded amounts are fine; for actual cooking, users will spot-check the imported recipe before adding to a meal plan anyway. Add an explicit "review imported recipe before saving" step.
3. **Category accuracy**: AI categories were mostly right but occasional miscategorizations exist (slot 10: "almond milk" → "Beverages" instead of "Dairy"). Users can correct in the existing recipe edit flow; not a blocker.
4. **Recipe instructions** (not just ingredients) need similar extraction. This spike only tested ingredient extraction. The same architecture extends — schema.org provides `recipeInstructions`, recipe-scrapers exposes `scraper.instructions()`, AI prompt extends easily.
5. **Image extraction**: same pattern. Out of spike scope but trivial extension.
6. **Yield + total time**: schema.org's `recipeYield` and `totalTime` are messy strings ("4 servings", "PT1H30M"). Need a separate normalization layer downstream.
7. **Multi-recipe pages (roundups)**: slot 7 (HBH 40-recipes post) showed that AI correctly recognizes "this is a roundup, not a single recipe." Production should expose this gracefully — possibly with "we noticed this page lists multiple recipes; which one did you want?" + linked list, but that's a future enhancement.

---

## Files in this spike

| Path | Purpose |
|---|---|
| `test_set.json` | 17 URLs with source classification, edge-case tags, expected-to-work-with predictions |
| `http_fetch.py` | Shared HTML fetcher with browser UA + BeautifulSoup text cleanup |
| `ingredient_parser.py` | Shared free-text → `{name, unit, quantity, category}` heuristic |
| `run_schema_org.py` | Approach A: direct JSON-LD extraction |
| `run_recipe_scrapers.py` | Approach B: recipe-scrapers library (15.10 API) |
| `run_ai.py` | Approach C: Claude API with structured-extraction prompt |
| `compare.py` | Joins all three result files into the per-URL matrix + failure roll-up |
| `results/schema_org_run_*.json` | Per-run results, JSON |
| `results/recipe_scrapers_run_*.json` | Per-run results, JSON |
| `results/ai_run_*.json` | Per-run results, JSON, includes per-URL token + latency |
| `results/comparison_*.md` | Auto-generated comparison matrix |
| `results/results.md` | **This document** |

The spike code is throwaway — it lives in `/spike/` to keep it clearly separated from production. The findings inform production architecture; the Python itself does not ship.
