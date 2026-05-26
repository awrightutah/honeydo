"""Approach B — recipe-scrapers Python library.

For each URL in test_set.json:
  1. `scrape_me(url, wild_mode=True)` to allow fallback to generic schema.org
     extraction on sites not in the explicit support list.
  2. Pull title, yields, total_time, ingredients (free-text), instructions.
  3. Parse each ingredient line into the app's {name, unit, quantity, category}
     shape using `ingredient_parser.parse_ingredient_line`.

Outputs results/recipe_scrapers_run_<ISO>.json with per-URL success/fail.
"""

from __future__ import annotations

import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from http_fetch import fetch_html
from ingredient_parser import parse_ingredient_line

HERE = Path(__file__).parent
TEST_SET_PATH = HERE / "test_set.json"
RESULTS_DIR = HERE / "results"


def run_one(entry: dict) -> dict:
    """Process a single test-set entry."""
    # Import lazily so the file can at least load when recipe-scrapers
    # isn't installed yet.
    try:
        from recipe_scrapers import scrape_html
        from recipe_scrapers._exceptions import (
            WebsiteNotImplementedError,
            NoSchemaFoundInWildMode,
        )
    except ImportError as e:
        return {
            "id": entry["id"],
            "url": entry["url"],
            "source_type": entry["source_type"],
            "edge_case": entry.get("edge_case"),
            "success": False,
            "title": None,
            "ingredients": [],
            "raw_response": None,
            "error_type": "ImportError",
            "error_message": f"recipe-scrapers not installed: {e}",
            "latency_ms": 0,
        }

    url = entry["url"]
    start = time.monotonic()
    try:
        # recipe-scrapers 15.x split fetching from scraping. We pre-fetch
        # with our own http_fetch helper (so the User-Agent and timeout
        # match the other runners) then hand the HTML to `scrape_html`.
        # `supported_only=False` is the 15.x replacement for the old
        # `wild_mode=True` — it falls back to generic schema.org extraction
        # for sites recipe-scrapers doesn't explicitly support. Without it
        # the library raises WebsiteNotImplementedError on unknown domains
        # which would understate its real reach for random_blog URLs.
        html = fetch_html(url)
        scraper = scrape_html(html, org_url=url, supported_only=False)
        title = scraper.title()
        try:
            yields = scraper.yields()
        except Exception:
            yields = None
        try:
            total_time = scraper.total_time()
        except Exception:
            total_time = None
        raw_ingredients = scraper.ingredients() or []

        parsed = [parse_ingredient_line(line) for line in raw_ingredients]

        latency_ms = int((time.monotonic() - start) * 1000)

        partial = (
            not parsed
            or all(i.get("_parse_quality") == "name_only" for i in parsed)
        )

        return {
            "id": entry["id"],
            "url": url,
            "source_type": entry["source_type"],
            "edge_case": entry.get("edge_case"),
            "success": True if not partial else "partial",
            "title": title,
            "ingredients": parsed,
            "raw_response": {
                "title": title,
                "ingredients": raw_ingredients,
                "yields": yields,
                "total_time": total_time,
            },
            "error_type": None,
            "error_message": None,
            "latency_ms": latency_ms,
        }
    except WebsiteNotImplementedError as e:
        latency_ms = int((time.monotonic() - start) * 1000)
        return {
            "id": entry["id"],
            "url": url,
            "source_type": entry["source_type"],
            "edge_case": entry.get("edge_case"),
            "success": False,
            "title": None,
            "ingredients": [],
            "raw_response": None,
            "error_type": "WebsiteNotImplementedError",
            "error_message": str(e),
            "latency_ms": latency_ms,
        }
    except NoSchemaFoundInWildMode as e:
        latency_ms = int((time.monotonic() - start) * 1000)
        return {
            "id": entry["id"],
            "url": url,
            "source_type": entry["source_type"],
            "edge_case": entry.get("edge_case"),
            "success": False,
            "title": None,
            "ingredients": [],
            "raw_response": None,
            "error_type": "NoSchemaFoundInWildMode",
            "error_message": str(e),
            "latency_ms": latency_ms,
        }
    except Exception as e:
        latency_ms = int((time.monotonic() - start) * 1000)
        return {
            "id": entry["id"],
            "url": url,
            "source_type": entry["source_type"],
            "edge_case": entry.get("edge_case"),
            "success": False,
            "title": None,
            "ingredients": [],
            "raw_response": None,
            "error_type": type(e).__name__,
            "error_message": str(e),
            "latency_ms": latency_ms,
        }


def summarize(results: list[dict]) -> dict:
    total = len(results)
    full = sum(1 for r in results if r["success"] is True)
    partial = sum(1 for r in results if r["success"] == "partial")
    fail = sum(1 for r in results if r["success"] is False)

    by_type: dict[str, dict[str, int]] = {}
    for r in results:
        st = r["source_type"]
        by_type.setdefault(st, {"full": 0, "partial": 0, "fail": 0})
        if r["success"] is True:
            by_type[st]["full"] += 1
        elif r["success"] == "partial":
            by_type[st]["partial"] += 1
        else:
            by_type[st]["fail"] += 1

    return {
        "total": total,
        "successful_extractions": full,
        "partial_extractions": partial,
        "failures": fail,
        "by_source_type": by_type,
    }


def main() -> int:
    if not TEST_SET_PATH.exists():
        print(f"ERROR: {TEST_SET_PATH} not found", file=sys.stderr)
        return 1
    test_set = json.loads(TEST_SET_PATH.read_text())
    entries = test_set["urls"]

    print(f"Running recipe-scrapers against {len(entries)} URLs...")
    results = []
    for i, entry in enumerate(entries, start=1):
        print(f"  [{i:>2}/{len(entries)}] {entry['url']}")
        results.append(run_one(entry))

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_path = RESULTS_DIR / f"recipe_scrapers_run_{timestamp}.json"
    RESULTS_DIR.mkdir(exist_ok=True)
    out_path.write_text(
        json.dumps(
            {
                "approach": "recipe_scrapers",
                "timestamp": timestamp,
                "summary": summarize(results),
                "results": results,
            },
            indent=2,
            ensure_ascii=False,
        )
    )
    print(f"\nWrote {out_path}")
    summary = summarize(results)
    print(f"  full success: {summary['successful_extractions']}/{summary['total']}")
    print(f"  partial:      {summary['partial_extractions']}/{summary['total']}")
    print(f"  failed:       {summary['failures']}/{summary['total']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
