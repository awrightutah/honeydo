"""Approach A — schema.org JSON-LD extraction.

For each URL in test_set.json:
  1. Fetch the HTML with a browser User-Agent.
  2. Locate any <script type="application/ld+json"> with a Recipe entity.
  3. Pull out `recipeIngredient` (array of free-text strings) and
     `recipeYield`, `name`, `totalTime`.
  4. Parse each ingredient line into the app's {name, unit, quantity, category}
     shape using `ingredient_parser.parse_ingredient_line`.

Outputs results/schema_org_run_<ISO>.json with per-URL success/fail plus a
summary roll-up by source_type.
"""

from __future__ import annotations

import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from http_fetch import fetch_html, find_jsonld_recipe
from ingredient_parser import parse_ingredient_line

HERE = Path(__file__).parent
TEST_SET_PATH = HERE / "test_set.json"
RESULTS_DIR = HERE / "results"


def extract_ingredients(recipe: dict) -> list[dict]:
    """Pull `recipeIngredient` and parse each line into structured form."""
    raw = recipe.get("recipeIngredient") or recipe.get("ingredients") or []
    if isinstance(raw, str):
        # Some sites emit a single string with newlines. Split it.
        raw = [ln.strip() for ln in raw.splitlines() if ln.strip()]
    parsed = []
    for line in raw:
        if not isinstance(line, str):
            continue
        parsed.append(parse_ingredient_line(line))
    return parsed


def run_one(entry: dict) -> dict:
    """Process a single test-set entry. Returns the per-URL result dict."""
    url = entry["url"]
    start = time.monotonic()
    try:
        html = fetch_html(url)
        recipe = find_jsonld_recipe(html)
        latency_ms = int((time.monotonic() - start) * 1000)
        if recipe is None:
            return {
                "id": entry["id"],
                "url": url,
                "source_type": entry["source_type"],
                "edge_case": entry.get("edge_case"),
                "success": False,
                "title": None,
                "ingredients": [],
                "raw_response": None,
                "error_type": "NoRecipeSchema",
                "error_message": "No <script type='application/ld+json'> with a Recipe entity on the page",
                "latency_ms": latency_ms,
            }

        ingredients = extract_ingredients(recipe)
        # "Partial success" if we found a Recipe entity but it had no
        # ingredient lines (or all of them parsed as name_only — meaning
        # we couldn't recover quantity/unit from any of them).
        partial = (
            not ingredients
            or all(i.get("_parse_quality") == "name_only" for i in ingredients)
        )

        return {
            "id": entry["id"],
            "url": url,
            "source_type": entry["source_type"],
            "edge_case": entry.get("edge_case"),
            "success": True if not partial else "partial",
            "title": recipe.get("name"),
            "ingredients": ingredients,
            "raw_response": {
                # Trimmed: keep just the keys we'd care to debug. Full recipe
                # object can be huge with images/instructions/nutrition etc.
                "name": recipe.get("name"),
                "recipeIngredient": recipe.get("recipeIngredient"),
                "recipeYield": recipe.get("recipeYield"),
                "totalTime": recipe.get("totalTime"),
                "@type": recipe.get("@type"),
            },
            "error_type": None,
            "error_message": None,
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
    """Roll up successes/failures by source_type."""
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

    print(f"Running schema.org extraction against {len(entries)} URLs...")
    results = []
    for i, entry in enumerate(entries, start=1):
        print(f"  [{i:>2}/{len(entries)}] {entry['url']}")
        results.append(run_one(entry))

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_path = RESULTS_DIR / f"schema_org_run_{timestamp}.json"
    RESULTS_DIR.mkdir(exist_ok=True)
    out_path.write_text(
        json.dumps(
            {
                "approach": "schema_org",
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
