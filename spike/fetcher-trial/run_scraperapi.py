"""
ScraperAPI fetcher trial — runs the 5 URLs that the baseline requests-based
fetcher couldn't get past Cloudflare/anti-bot defenses.

For each URL:
  1. Fetch HTML via ScraperAPI (with render=true for JS-heavy sites).
  2. Save the HTML response.
  3. Run schema.org JSON-LD extraction on it.
  4. Run recipe-scrapers on it.
  5. Record per-URL: fetch status, fetch duration, HTML byte size,
     schema.org result, recipe-scrapers result.

Output: results/scraperapi_run_<timestamp>.json
"""

import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import requests
from dotenv import load_dotenv
from recipe_scrapers import scrape_html
import extruct

# --- Setup ----------------------------------------------------------------

load_dotenv()
SCRAPERAPI_KEY = os.environ.get("SCRAPERAPI_KEY")
if not SCRAPERAPI_KEY or SCRAPERAPI_KEY == "your_key_here":
    print("ERROR: SCRAPERAPI_KEY not set in .env", file=sys.stderr)
    sys.exit(1)

SCRIPT_DIR = Path(__file__).resolve().parent
TEST_SET_PATH = SCRIPT_DIR / "test_set.json"
RESULTS_DIR = SCRIPT_DIR / "results"
RESULTS_DIR.mkdir(exist_ok=True)

# ScraperAPI endpoint. render=true tells ScraperAPI to use a headless browser
# (necessary for JS-heavy sites like Allrecipes/Food Network).
SCRAPERAPI_ENDPOINT = "http://api.scraperapi.com/"

# Reasonable timeout — ScraperAPI's docs say render requests can take 30-60s.
FETCH_TIMEOUT_SECONDS = 70


def fetch_via_scraperapi(url: str) -> dict:
    """Fetch a URL through ScraperAPI. Returns a dict with status info + HTML."""
    params = {
        "api_key": SCRAPERAPI_KEY,
        "url": url,
        "render": "true",  # use headless browser
    }
    start = time.monotonic()
    try:
        resp = requests.get(SCRAPERAPI_ENDPOINT, params=params, timeout=FETCH_TIMEOUT_SECONDS)
        duration = time.monotonic() - start
        return {
            "ok": resp.status_code == 200,
            "status_code": resp.status_code,
            "duration_seconds": round(duration, 2),
            "html": resp.text if resp.status_code == 200 else None,
            "html_bytes": len(resp.content),
            "error": None if resp.status_code == 200 else f"HTTP {resp.status_code}",
        }
    except requests.exceptions.RequestException as e:
        return {
            "ok": False,
            "status_code": None,
            "duration_seconds": round(time.monotonic() - start, 2),
            "html": None,
            "html_bytes": 0,
            "error": f"{type(e).__name__}: {e}",
        }


def try_schema_org(html: str, url: str) -> dict:
    """Extract structured recipe data via JSON-LD."""
    try:
        data = extruct.extract(html, base_url=url, syntaxes=["json-ld"])
        json_ld_items = data.get("json-ld", [])
        # Find Recipe-typed items (can be nested in @graph or be the top object)
        recipes = []
        for item in json_ld_items:
            if isinstance(item, dict):
                t = item.get("@type")
                if t == "Recipe" or (isinstance(t, list) and "Recipe" in t):
                    recipes.append(item)
                # Check @graph
                graph = item.get("@graph", [])
                for g in graph:
                    if isinstance(g, dict):
                        gt = g.get("@type")
                        if gt == "Recipe" or (isinstance(gt, list) and "Recipe" in gt):
                            recipes.append(g)
        if recipes:
            r = recipes[0]
            ingredients = r.get("recipeIngredient", [])
            return {
                "ok": True,
                "ingredient_count": len(ingredients),
                "title": r.get("name"),
                "error": None,
            }
        return {"ok": False, "ingredient_count": 0, "title": None, "error": "no Recipe JSON-LD found"}
    except Exception as e:
        return {"ok": False, "ingredient_count": 0, "title": None, "error": f"{type(e).__name__}: {e}"}


def try_recipe_scrapers(html: str, url: str) -> dict:
    """Extract recipe via recipe-scrapers library."""
    try:
        scraper = scrape_html(html, org_url=url, supported_only=False)
        ingredients = scraper.ingredients()
        return {
            "ok": len(ingredients) > 0,
            "ingredient_count": len(ingredients),
            "title": scraper.title() if hasattr(scraper, "title") else None,
            "error": None if ingredients else "0 ingredients returned",
        }
    except Exception as e:
        return {"ok": False, "ingredient_count": 0, "title": None, "error": f"{type(e).__name__}: {e}"}


def main():
    with open(TEST_SET_PATH) as f:
        test_set = json.load(f)
    # Defensive: accepts both the bare-list shape (this spike's test_set.json)
    # and the wrapped {_meta, urls} shape (previous spike's). Either is fine.
    urls = test_set if isinstance(test_set, list) else test_set["urls"]

    print(f"Running ScraperAPI fetcher trial against {len(urls)} URLs")
    print(f"render=true (headless browser)")
    print(f"timeout={FETCH_TIMEOUT_SECONDS}s per request")
    print("---")

    results = []
    for entry in urls:
        url = entry["url"]
        print(f"\n[{entry['id']}] {url}")
        print(f"  Fetching via ScraperAPI...", end=" ", flush=True)
        fetch_result = fetch_via_scraperapi(url)
        if fetch_result["ok"]:
            print(f"OK ({fetch_result['duration_seconds']}s, {fetch_result['html_bytes']:,} bytes)")
        else:
            print(f"FAIL ({fetch_result['error']})")

        schema_result = None
        scrapers_result = None
        if fetch_result["ok"]:
            schema_result = try_schema_org(fetch_result["html"], url)
            print(f"  schema.org: {'OK' if schema_result['ok'] else 'FAIL'} "
                  f"({schema_result['ingredient_count']} ingredients) "
                  f"{schema_result['error'] or ''}")
            scrapers_result = try_recipe_scrapers(fetch_result["html"], url)
            print(f"  recipe-scrapers: {'OK' if scrapers_result['ok'] else 'FAIL'} "
                  f"({scrapers_result['ingredient_count']} ingredients) "
                  f"{scrapers_result['error'] or ''}")

        results.append({
            "id": entry["id"],
            "source_type": entry.get("source_type"),
            "url": url,
            "fetch": {k: v for k, v in fetch_result.items() if k != "html"},  # exclude raw HTML
            "schema_org": schema_result,
            "recipe_scrapers": scrapers_result,
        })

    # Save results
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_path = RESULTS_DIR / f"scraperapi_run_{timestamp}.json"
    with open(out_path, "w") as f:
        json.dump({
            "timestamp": timestamp,
            "fetcher": "scraperapi (render=true)",
            "total_urls": len(urls),
            "fetch_ok": sum(1 for r in results if r["fetch"]["ok"]),
            "schema_org_ok": sum(1 for r in results if r["schema_org"] and r["schema_org"]["ok"]),
            "recipe_scrapers_ok": sum(1 for r in results if r["recipe_scrapers"] and r["recipe_scrapers"]["ok"]),
            "results": results,
        }, f, indent=2)

    print("---")
    print(f"\nResults saved to {out_path.relative_to(SCRIPT_DIR)}")
    print(f"Summary: {sum(1 for r in results if r['fetch']['ok'])}/{len(urls)} fetched, "
          f"{sum(1 for r in results if r['schema_org'] and r['schema_org']['ok'])}/{len(urls)} schema.org parsed, "
          f"{sum(1 for r in results if r['recipe_scrapers'] and r['recipe_scrapers']['ok'])}/{len(urls)} recipe-scrapers parsed")


if __name__ == "__main__":
    main()
