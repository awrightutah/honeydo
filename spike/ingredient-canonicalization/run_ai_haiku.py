"""Approach C — Claude API extraction.

For each URL in test_set.json:
  1. Fetch the HTML with a browser User-Agent.
  2. Clean to rendered text (drops <script>, so JSON-LD is REMOVED — see
     `http_fetch.clean_text_for_ai` docstring for why).
  3. Send to Claude with a structured-extraction prompt asking for the app's
     {name, unit, quantity, category} shape.
  4. Defensively parse the JSON response.

Outputs results/ai_haiku_run_<ISO>.json with per-URL success/fail plus token/
latency telemetry.

API KEY: loaded from .env via python-dotenv (ANTHROPIC_API_KEY).
MODEL: claude-sonnet-4-5 (per spike brief — user verified working).
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from dotenv import load_dotenv

from http_fetch import fetch_html, clean_text_for_ai

HERE = Path(__file__).parent
TEST_SET_PATH = HERE / "test_set.json"
RESULTS_DIR = HERE / "results"

MODEL = "claude-haiku-4-5-20251001"
MAX_TOKENS_OUT = 4096

SYSTEM_PROMPT = """You are a recipe ingredient extractor. Given the text content of a recipe page, extract the ingredients as JSON.

Output schema:

If the page IS a single recipe:
{
  "is_recipe": true,
  "title": "recipe title",
  "ingredients": [
    {
      "name": "...",
      "unit": "...",
      "quantity": "...",
      "category": "..."
    }
  ]
}

If the page is NOT a single recipe (roundup of multiple recipes, discussion thread, no recipe content, social media post, etc.):
{
  "is_recipe": false,
  "reason": "brief explanation"
}

Field rules:
- name: the canonical ingredient. No qualifiers like 'fresh', 'extra virgin', brand names, or prep instructions ('chopped'). Just the core ingredient. E.g., 'extra virgin olive oil' -> 'olive oil', 'freshly chopped parsley' -> 'parsley'.
- unit: short form like cup, tbsp, tsp, oz, lb, g, kg, ml, l, cloves, head, bunch, slice, pinch, dash. Use 'count' for whole-item ingredients ('4 eggs', '1 lemon').
- quantity: numeric amount as a string. Convert fractions to decimals ('1/2' -> '0.5', '1 1/2' -> '1.5').
- category: one of: Produce, Meat, Dairy, Pantry, Bakery, Frozen, Beverages, Other.

CRITICAL:
- Respond with ONLY valid JSON. No prose, no markdown fences, no explanation.
- Be honest. If you can't extract reliably, set is_recipe: false with a reason.
- Do NOT hallucinate ingredients. If a quantity is missing, leave it as '1' and set unit to 'count'.
"""


def _extract_json(text: str) -> dict:
    """Defensively parse JSON from the model response.

    Strips ``` fences if present, finds the first { ... last }, parses.
    Raises ValueError on parse failure.
    """
    s = text.strip()
    # Strip ```json ... ``` fences
    if s.startswith("```"):
        s = re.sub(r"^```[a-zA-Z]*\s*", "", s)
        s = re.sub(r"\s*```\s*$", "", s)
    # Best-effort: find the first { and last }
    if not s.startswith("{"):
        first = s.find("{")
        last = s.rfind("}")
        if first != -1 and last != -1 and last > first:
            s = s[first : last + 1]
    return json.loads(s)


def run_one(entry: dict, client) -> dict:
    """Process a single test-set entry. `client` is an Anthropic client."""
    url = entry["url"]
    fetch_start = time.monotonic()
    try:
        html = fetch_html(url)
        cleaned = clean_text_for_ai(html)
    except Exception as e:
        return {
            "id": entry["id"],
            "url": url,
            "source_type": entry["source_type"],
            "edge_case": entry.get("edge_case"),
            "success": False,
            "title": None,
            "ingredients": [],
            "raw_response": None,
            "error_type": f"FetchFailed:{type(e).__name__}",
            "error_message": str(e),
            "latency_ms": int((time.monotonic() - fetch_start) * 1000),
            "input_tokens": 0,
            "output_tokens": 0,
        }

    api_start = time.monotonic()
    try:
        resp = client.messages.create(
            model=MODEL,
            max_tokens=MAX_TOKENS_OUT,
            system=SYSTEM_PROMPT,
            messages=[
                {
                    "role": "user",
                    "content": f"Recipe page content:\n\n{cleaned}",
                }
            ],
        )
    except Exception as e:
        return {
            "id": entry["id"],
            "url": url,
            "source_type": entry["source_type"],
            "edge_case": entry.get("edge_case"),
            "success": False,
            "title": None,
            "ingredients": [],
            "raw_response": None,
            "error_type": f"AnthropicAPI:{type(e).__name__}",
            "error_message": str(e),
            "latency_ms": int((time.monotonic() - api_start) * 1000),
            "input_tokens": 0,
            "output_tokens": 0,
        }

    api_latency_ms = int((time.monotonic() - api_start) * 1000)
    raw_text = "".join(
        block.text for block in resp.content if getattr(block, "type", "") == "text"
    )

    try:
        parsed = _extract_json(raw_text)
    except Exception as e:
        return {
            "id": entry["id"],
            "url": url,
            "source_type": entry["source_type"],
            "edge_case": entry.get("edge_case"),
            "success": False,
            "title": None,
            "ingredients": [],
            "raw_response": raw_text,
            "error_type": "JSONParseFailed",
            "error_message": f"{type(e).__name__}: {e}",
            "latency_ms": api_latency_ms,
            "input_tokens": resp.usage.input_tokens,
            "output_tokens": resp.usage.output_tokens,
        }

    is_recipe = parsed.get("is_recipe", False)
    if not is_recipe:
        # Model declared this isn't a recipe. For edge cases (roundup post,
        # Pinterest, Instagram) this is the CORRECT graceful-failure
        # behaviour — record as a deliberate non-extraction rather than a
        # hard failure.
        return {
            "id": entry["id"],
            "url": url,
            "source_type": entry["source_type"],
            "edge_case": entry.get("edge_case"),
            "success": False,
            "title": None,
            "ingredients": [],
            "raw_response": parsed,
            "error_type": "ModelDeclaredNotARecipe",
            "error_message": parsed.get("reason", "model returned is_recipe=false"),
            "latency_ms": api_latency_ms,
            "input_tokens": resp.usage.input_tokens,
            "output_tokens": resp.usage.output_tokens,
        }

    ingredients = parsed.get("ingredients", []) or []
    return {
        "id": entry["id"],
        "url": url,
        "source_type": entry["source_type"],
        "edge_case": entry.get("edge_case"),
        "success": True,
        "title": parsed.get("title"),
        "ingredients": ingredients,
        "raw_response": parsed,
        "error_type": None,
        "error_message": None,
        "latency_ms": api_latency_ms,
        "input_tokens": resp.usage.input_tokens,
        "output_tokens": resp.usage.output_tokens,
    }


def summarize(results: list[dict]) -> dict:
    total = len(results)
    full = sum(1 for r in results if r["success"] is True)
    fail = sum(1 for r in results if r["success"] is False)

    total_input_tokens = sum(r.get("input_tokens", 0) for r in results)
    total_output_tokens = sum(r.get("output_tokens", 0) for r in results)
    total_latency_ms = sum(r.get("latency_ms", 0) for r in results)
    avg_latency_ms = int(total_latency_ms / total) if total else 0

    by_type: dict[str, dict[str, int]] = {}
    for r in results:
        st = r["source_type"]
        by_type.setdefault(st, {"full": 0, "fail": 0})
        if r["success"] is True:
            by_type[st]["full"] += 1
        else:
            by_type[st]["fail"] += 1

    return {
        "total": total,
        "successful_extractions": full,
        "failures": fail,
        "by_source_type": by_type,
        "total_input_tokens": total_input_tokens,
        "total_output_tokens": total_output_tokens,
        "total_latency_ms": total_latency_ms,
        "avg_latency_ms": avg_latency_ms,
    }


def main() -> int:
    load_dotenv(HERE / ".env")
    api_key = os.getenv("ANTHROPIC_API_KEY")
    if not api_key:
        print(
            "ERROR: ANTHROPIC_API_KEY not set. Copy .env.example to .env and paste your key.",
            file=sys.stderr,
        )
        return 1

    try:
        from anthropic import Anthropic
    except ImportError as e:
        print(f"ERROR: anthropic not installed: {e}", file=sys.stderr)
        return 1

    client = Anthropic(api_key=api_key)

    if not TEST_SET_PATH.exists():
        print(f"ERROR: {TEST_SET_PATH} not found", file=sys.stderr)
        return 1
    test_set = json.loads(TEST_SET_PATH.read_text())
    entries = test_set["urls"]

    print(f"Running Claude ({MODEL}) extraction against {len(entries)} URLs...")
    print(f"NOTE: this burns API tokens. Estimated cost ~$0.20-0.40 for {len(entries)} URLs.\n")
    results = []
    for i, entry in enumerate(entries, start=1):
        print(f"  [{i:>2}/{len(entries)}] {entry['url']}")
        results.append(run_one(entry, client))

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_path = RESULTS_DIR / f"ai_haiku_run_{timestamp}.json"
    RESULTS_DIR.mkdir(exist_ok=True)
    out_path.write_text(
        json.dumps(
            {
                "approach": "claude_api",
                "model": MODEL,
                "timestamp": timestamp,
                "summary": summarize(results),
                "results": results,
            },
            indent=2,
            ensure_ascii=False,
        )
    )
    summary = summarize(results)
    print(f"\nWrote {out_path}")
    print(f"  full success:    {summary['successful_extractions']}/{summary['total']}")
    print(f"  failed:          {summary['failures']}/{summary['total']}")
    print(f"  input tokens:    {summary['total_input_tokens']:,}")
    print(f"  output tokens:   {summary['total_output_tokens']:,}")
    print(f"  avg latency:     {summary['avg_latency_ms']:,} ms")
    return 0


if __name__ == "__main__":
    sys.exit(main())
