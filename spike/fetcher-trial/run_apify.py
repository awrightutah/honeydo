"""
Apify Web Scraper trial — runs the 4 URLs that the baseline fetcher failed on,
using Apify's headless-browser web scraper actor.

Process:
  1. Start an Apify Web Scraper run with all 4 URLs.
  2. Poll the run until it completes (or times out).
  3. Fetch the dataset items (each contains HTML for one URL).
  4. Run our schema.org + recipe-scrapers parsers on each.
  5. Save results.

Output: results/apify_run_<timestamp>.json
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
APIFY_TOKEN = os.environ.get("APIFY_TOKEN")
if not APIFY_TOKEN or APIFY_TOKEN == "your_key_here":
    print("ERROR: APIFY_TOKEN not set in .env", file=sys.stderr)
    sys.exit(1)

SCRIPT_DIR = Path(__file__).resolve().parent
TEST_SET_PATH = SCRIPT_DIR / "test_set_apify.json"
RESULTS_DIR = SCRIPT_DIR / "results"
RESULTS_DIR.mkdir(exist_ok=True)

# Apify's generic Web Scraper actor. It runs a headless Chromium for each URL.
ACTOR_ID = "apify~web-scraper"  # tilde-separated form used in Apify API URLs
APIFY_BASE = "https://api.apify.com/v2"

# Polling parameters
MAX_POLL_SECONDS = 600  # 10 minutes total budget
POLL_INTERVAL_SECONDS = 5


def start_run(urls: list[str]) -> tuple[str, str]:
    """Start an Apify Web Scraper run. Returns (run_id, dataset_id)."""
    # The Web Scraper actor takes a startUrls list and a pageFunction.
    # We use a minimal pageFunction that just returns the page HTML.
    page_function = """
    async function pageFunction(context) {
        const { request, page } = context;
        const html = await page.content();
        return {
            url: request.url,
            html: html,
            statusCode: 200,
        };
    }
    """
    input_payload = {
        "startUrls": [{"url": u} for u in urls],
        "pageFunction": page_function,
        "proxyConfiguration": {"useApifyProxy": True},
        # Don't crawl deeper — we only want the start URLs themselves
        "linkSelector": "",
        "pseudoUrls": [],
        "maxPagesPerCrawl": len(urls),
        "maxRequestRetries": 1,
        # Give the page time to render JS
        "pageLoadTimeoutSecs": 60,
        "navigationTimeoutSecs": 60,
    }
    url = f"{APIFY_BASE}/acts/{ACTOR_ID}/runs"
    headers = {"Authorization": f"Bearer {APIFY_TOKEN}"}
    resp = requests.post(url, json=input_payload, headers=headers, timeout=30)
    resp.raise_for_status()
    run_data = resp.json()["data"]
    return run_data["id"], run_data.get("defaultDatasetId")


def poll_run(run_id: str) -> dict:
    """Poll the run until it completes. Returns the final run object."""
    url = f"{APIFY_BASE}/actor-runs/{run_id}"
    headers = {"Authorization": f"Bearer {APIFY_TOKEN}"}
    start = time.monotonic()
    while True:
        elapsed = time.monotonic() - start
        if elapsed > MAX_POLL_SECONDS:
            raise TimeoutError(f"Apify run did not complete within {MAX_POLL_SECONDS}s")
        resp = requests.get(url, headers=headers, timeout=30)
        resp.raise_for_status()
        run = resp.json()["data"]
        status = run["status"]
        print(f"  [poll {int(elapsed)}s] status={status}")
        if status in ("SUCCEEDED", "FAILED", "ABORTED", "TIMED-OUT"):
            return run
        time.sleep(POLL_INTERVAL_SECONDS)


def fetch_dataset(dataset_id: str) -> list[dict]:
    """Fetch the dataset items (one per URL fetched)."""
    url = f"{APIFY_BASE}/datasets/{dataset_id}/items?format=json"
    headers = {"Authorization": f"Bearer {APIFY_TOKEN}"}
    resp = requests.get(url, headers=headers, timeout=60)
    resp.raise_for_status()
    return resp.json()


def try_schema_org(html: str, url: str) -> dict:
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
    urls = [r["url"] for r in test_set]
    url_to_meta = {r["url"]: r for r in test_set}

    print(f"Starting Apify Web Scraper run for {len(urls)} URLs")
    run_id, dataset_id = start_run(urls)
    print(f"Run ID: {run_id}")
    print(f"Dataset ID: {dataset_id}")
    print("---")
    print("Polling for completion (~1-3 min typically)...")

    run = poll_run(run_id)
    final_status = run["status"]
    print(f"\nFinal status: {final_status}")
    print(f"Run stats: {json.dumps(run.get('stats', {}), indent=2)}")
    if final_status != "SUCCEEDED":
        print(f"WARNING: run did not succeed cleanly. Partial results may still be available.")

    items = fetch_dataset(dataset_id)
    print(f"\nDataset returned {len(items)} items")

    # Index by URL for lookup (Apify may return items in any order)
    items_by_url = {item.get("url"): item for item in items}

    results = []
    for entry in test_set:
        url = entry["url"]
        print(f"\n[{entry['id']}] {url}")
        item = items_by_url.get(url)
        if not item or not item.get("html"):
            print(f"  No HTML returned for this URL")
            results.append({
                "id": entry["id"],
                "source_type": entry.get("source_type"),
                "url": url,
                "fetch": {"ok": False, "html_bytes": 0, "error": "no item in dataset"},
                "schema_org": None,
                "recipe_scrapers": None,
            })
            continue

        html = item["html"]
        html_bytes = len(html.encode("utf-8"))
        print(f"  Fetched HTML: {html_bytes:,} bytes")

        schema_result = try_schema_org(html, url)
        print(f"  schema.org: {'OK' if schema_result['ok'] else 'FAIL'} "
              f"({schema_result['ingredient_count']} ingredients) "
              f"{schema_result['error'] or ''}")
        scrapers_result = try_recipe_scrapers(html, url)
        print(f"  recipe-scrapers: {'OK' if scrapers_result['ok'] else 'FAIL'} "
              f"({scrapers_result['ingredient_count']} ingredients) "
              f"{scrapers_result['error'] or ''}")

        results.append({
            "id": entry["id"],
            "source_type": entry.get("source_type"),
            "url": url,
            "fetch": {"ok": True, "html_bytes": html_bytes, "error": None},
            "schema_org": schema_result,
            "recipe_scrapers": scrapers_result,
        })

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_path = RESULTS_DIR / f"apify_run_{timestamp}.json"
    with open(out_path, "w") as f:
        json.dump({
            "timestamp": timestamp,
            "fetcher": "apify web-scraper (useApifyProxy=true)",
            "run_id": run_id,
            "final_status": final_status,
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
