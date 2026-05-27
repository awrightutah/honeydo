"""
Self-hosted Playwright fetcher trial — runs the 4 URLs that the baseline fetcher
and both commercial services (ScraperAPI free, Apify free) struggled with.

For each URL:
  1. Launch headless Chromium via Playwright.
  2. Navigate, wait for network idle, capture rendered HTML.
  3. Run schema.org JSON-LD extraction on the HTML.
  4. Run recipe-scrapers on the HTML.
  5. Record per-URL: navigation status, time elapsed, HTML byte size, parser results.

Output: results/playwright_run_<timestamp>.json

Note on the environment: running from local IP (residential ISP). This is the
best-case scenario for proxy detection. Production deployment would run from a
datacenter IP and likely perform worse — see findings doc for full context.
"""

import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeoutError
from recipe_scrapers import scrape_html
import extruct

SCRIPT_DIR = Path(__file__).resolve().parent
TEST_SET_PATH = SCRIPT_DIR / "test_set.json"
RESULTS_DIR = SCRIPT_DIR / "results"
RESULTS_DIR.mkdir(exist_ok=True)

# Navigation timeout (ms). 60s matches what Apify's web-scraper used so results
# are comparable. We'll see whether sites timeout at the same boundary.
NAV_TIMEOUT_MS = 60_000

# Use a realistic user-agent. Playwright's default UA contains "HeadlessChrome"
# which many anti-bot systems detect. Setting a real Chrome UA is the bare
# minimum disguise; sophisticated detection can still see other Playwright
# fingerprints (navigator.webdriver, etc.) but UA is the obvious first lever.
REALISTIC_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/120.0.0.0 Safari/537.36"
)


def fetch_via_playwright(browser, url: str) -> dict:
    """Fetch a URL using Playwright. Returns a dict with status info + HTML."""
    context = browser.new_context(user_agent=REALISTIC_UA)
    page = context.new_page()
    start = time.monotonic()
    try:
        response = page.goto(url, wait_until="domcontentloaded", timeout=NAV_TIMEOUT_MS)
        # After DOM is loaded, give JS a moment to render (some sites populate
        # schema.org JSON-LD via client-side JS).
        try:
            page.wait_for_load_state("networkidle", timeout=15_000)
        except PlaywrightTimeoutError:
            # Network never went idle (common for sites with constant analytics
            # beacons). Not fatal — we still have the rendered HTML at this point.
            pass
        html = page.content()
        duration = time.monotonic() - start
        status_code = response.status if response else None
        return {
            "ok": status_code == 200 and len(html) > 0,
            "status_code": status_code,
            "duration_seconds": round(duration, 2),
            "html": html,
            "html_bytes": len(html.encode("utf-8")),
            "error": None if status_code == 200 else f"HTTP {status_code}",
        }
    except PlaywrightTimeoutError as e:
        duration = time.monotonic() - start
        return {
            "ok": False,
            "status_code": None,
            "duration_seconds": round(duration, 2),
            "html": None,
            "html_bytes": 0,
            "error": f"PlaywrightTimeoutError: {e}",
        }
    except Exception as e:
        duration = time.monotonic() - start
        return {
            "ok": False,
            "status_code": None,
            "duration_seconds": round(duration, 2),
            "html": None,
            "html_bytes": 0,
            "error": f"{type(e).__name__}: {e}",
        }
    finally:
        try:
            page.close()
            context.close()
        except Exception:
            pass


def try_schema_org(html: str, url: str) -> dict:
    """Extract structured recipe data via JSON-LD."""
    try:
        data = extruct.extract(html, base_url=url, syntaxes=["json-ld"])
        json_ld_items = data.get("json-ld", [])
        recipes = []
        for item in json_ld_items:
            if isinstance(item, dict):
                t = item.get("@type")
                if t == "Recipe" or (isinstance(t, list) and "Recipe" in t):
                    recipes.append(item)
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
    # test_set.json is a bare list (no _meta wrapper)
    urls = test_set if isinstance(test_set, list) else test_set["urls"]

    print(f"Running self-hosted Playwright fetcher trial against {len(urls)} URLs")
    print(f"Browser: Chromium (headless)")
    print(f"User-Agent: realistic Chrome 120 macOS")
    print(f"Navigation timeout: {NAV_TIMEOUT_MS / 1000}s per request")
    print(f"Running from local IP (residential) — best-case for proxy detection")
    print("---")

    results = []
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        try:
            for entry in urls:
                url = entry["url"]
                print(f"\n[{entry['id']}] {url}")
                print(f"  Fetching via Playwright...", end=" ", flush=True)
                fetch_result = fetch_via_playwright(browser, url)
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
                    "fetch": {k: v for k, v in fetch_result.items() if k != "html"},
                    "schema_org": schema_result,
                    "recipe_scrapers": scrapers_result,
                })
        finally:
            browser.close()

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_path = RESULTS_DIR / f"playwright_run_{timestamp}.json"
    with open(out_path, "w") as f:
        json.dump({
            "timestamp": timestamp,
            "fetcher": "self-hosted playwright (chromium, headless, residential IP)",
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
