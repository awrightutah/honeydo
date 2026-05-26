"""Join the three runner result files into a comparison markdown.

Picks up the latest run per approach (sorted by filename timestamp),
produces:
  1. A per-URL matrix (markdown table)
  2. Failure category roll-ups
  3. Success-rate breakdown by source_type
  4. Per-URL ingredient agreement for slots where >=2 approaches succeeded
  5. Cost + latency analysis for the AI approach

Writes results/comparison_<timestamp>.md.
"""

from __future__ import annotations

import glob
import json
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).parent
RESULTS_DIR = HERE / "results"


def _latest(prefix: str) -> dict:
    matches = sorted(RESULTS_DIR.glob(f"{prefix}_*.json"))
    if not matches:
        raise SystemExit(f"No {prefix}_*.json file in {RESULTS_DIR}")
    return json.loads(matches[-1].read_text())


def _result_marker(r: dict) -> str:
    """One-cell shorthand for the per-URL matrix."""
    if r["success"] is True:
        n = len(r["ingredients"])
        return f"✅ {n} ing"
    if r["success"] == "partial":
        n = len(r["ingredients"])
        return f"⚠️ {n} (partial)"
    err = r.get("error_type", "?")
    # Compress common errors
    short = {
        "HTTPError": "403/HTTP",
        "FetchFailed:HTTPError": "403/HTTP",
        "NoRecipeSchema": "no schema",
        "RecipeSchemaNotFound": "no schema",
        "NoSchemaFoundInWildMode": "no schema",
        "WebsiteNotImplementedError": "not supported",
        "ModelDeclaredNotARecipe": "not a recipe (AI)",
    }.get(err, err)
    return f"❌ {short}"


def _categorize_failure(r: dict) -> str:
    if r["success"] is True:
        return "success"
    if r["success"] == "partial":
        return "partial"
    err = r.get("error_type", "")
    if "HTTPError" in err:
        return "blocked_fetch"
    if "Schema" in err and "NotARecipe" not in err:
        return "no_schema_found"
    if "ParseFailed" in err or "JSON" in err:
        return "parse_error"
    if "NotARecipe" in err:
        return "not_a_recipe_ai"
    return "other"


def main() -> None:
    so = _latest("schema_org_run")
    rs = _latest("recipe_scrapers_run")
    ai = _latest("ai_run")

    so_by_id = {r["id"]: r for r in so["results"]}
    rs_by_id = {r["id"]: r for r in rs["results"]}
    ai_by_id = {r["id"]: r for r in ai["results"]}

    ids = sorted(set(so_by_id) | set(rs_by_id) | set(ai_by_id))

    # ── Build matrix ─────────────────────────────────────────────────────
    matrix_rows = []
    for i in ids:
        s = so_by_id.get(i)
        r = rs_by_id.get(i)
        a = ai_by_id.get(i)
        src = (s or r or a)["source_type"]
        edge = (s or r or a).get("edge_case")
        # Use the URL's last segment so the table doesn't overflow
        url = (s or r or a)["url"]
        url_short = "/".join(url.replace("https://", "").split("/")[:2]) + "/…"
        matrix_rows.append({
            "id": i,
            "url": url,
            "url_short": url_short,
            "source_type": src,
            "edge_case": edge,
            "schema_org": _result_marker(s),
            "recipe_scrapers": _result_marker(r),
            "ai": _result_marker(a),
            "schema_org_cat": _categorize_failure(s),
            "recipe_scrapers_cat": _categorize_failure(r),
            "ai_cat": _categorize_failure(a),
            "schema_org_ings": s["ingredients"],
            "recipe_scrapers_ings": r["ingredients"],
            "ai_ings": a["ingredients"],
        })

    # ── Roll-ups ─────────────────────────────────────────────────────────
    def rate(d, key):
        results = d["results"]
        full = sum(1 for r in results if r["success"] is True)
        return f"{full}/{len(results)} ({100 * full / len(results):.0f}%)"

    headline = {
        "schema_org": rate(so, "schema_org"),
        "recipe_scrapers": rate(rs, "recipe_scrapers"),
        "ai": rate(ai, "ai"),
    }

    # Per source_type breakdown
    by_src: dict[str, dict[str, int]] = {}
    for row in matrix_rows:
        st = row["source_type"]
        by_src.setdefault(st, {"total": 0, "so": 0, "rs": 0, "ai": 0})
        by_src[st]["total"] += 1
        if row["schema_org_cat"] == "success":
            by_src[st]["so"] += 1
        if row["recipe_scrapers_cat"] == "success":
            by_src[st]["rs"] += 1
        if row["ai_cat"] == "success":
            by_src[st]["ai"] += 1

    # Failure-category roll-up
    failure_cats: dict[str, dict[str, int]] = {
        "schema_org": {}, "recipe_scrapers": {}, "ai": {},
    }
    for row in matrix_rows:
        for app, key in [("schema_org", "schema_org_cat"),
                          ("recipe_scrapers", "recipe_scrapers_cat"),
                          ("ai", "ai_cat")]:
            cat = row[key]
            if cat in ("success", "partial"):
                continue
            failure_cats[app][cat] = failure_cats[app].get(cat, 0) + 1

    # ── At-least-one-succeeded vs failed-everywhere ──────────────────────
    n_any = sum(1 for row in matrix_rows
                if "success" in (row["schema_org_cat"], row["recipe_scrapers_cat"], row["ai_cat"]))
    n_all_fail = sum(1 for row in matrix_rows
                     if row["schema_org_cat"] != "success"
                     and row["recipe_scrapers_cat"] != "success"
                     and row["ai_cat"] != "success")

    # ── Cost + latency (AI only) ─────────────────────────────────────────
    ai_summary = ai["summary"]
    # Recompute per-URL avg excluding URLs that never made an API call
    # (FetchFailed: no tokens billed)
    api_calls = [r for r in ai["results"]
                 if r.get("input_tokens", 0) > 0]
    n_api = len(api_calls)
    avg_input = sum(r["input_tokens"] for r in api_calls) / n_api if n_api else 0
    avg_output = sum(r["output_tokens"] for r in api_calls) / n_api if n_api else 0

    # Pricing (claude-sonnet-4-5, approximate)
    # Public reference at time of spike: $3/M input, $15/M output
    SONNET_INPUT_PER_M = 3.0
    SONNET_OUTPUT_PER_M = 15.0
    # Haiku 4.5: $1/M input, $5/M output
    HAIKU_INPUT_PER_M = 1.0
    HAIKU_OUTPUT_PER_M = 5.0

    def cost(n, input_t, output_t, in_pm, out_pm):
        return n * (input_t * in_pm / 1_000_000 + output_t * out_pm / 1_000_000)

    cost_sonnet = cost(n_api, avg_input, avg_output, SONNET_INPUT_PER_M, SONNET_OUTPUT_PER_M)
    cost_per_url_sonnet = cost_sonnet / n_api if n_api else 0
    cost_per_url_haiku = (avg_input * HAIKU_INPUT_PER_M / 1_000_000
                          + avg_output * HAIKU_OUTPUT_PER_M / 1_000_000)

    # 200 imports per family per year (4/week × 50 weeks)
    annual_imports = 200
    annual_cost_sonnet = annual_imports * cost_per_url_sonnet
    annual_cost_haiku = annual_imports * cost_per_url_haiku

    # ── Ingredient agreement for multi-success slots ─────────────────────
    multi_success = [
        row for row in matrix_rows
        if sum(1 for c in (row["schema_org_cat"], row["recipe_scrapers_cat"], row["ai_cat"])
               if c == "success") >= 2
    ]
    agreement_rows = []
    for row in multi_success:
        so_n = len(row["schema_org_ings"]) if row["schema_org_cat"] == "success" else None
        rs_n = len(row["recipe_scrapers_ings"]) if row["recipe_scrapers_cat"] == "success" else None
        ai_n = len(row["ai_ings"]) if row["ai_cat"] == "success" else None
        agreement_rows.append({
            "id": row["id"],
            "url_short": row["url_short"],
            "so_n": so_n,
            "rs_n": rs_n,
            "ai_n": ai_n,
        })

    # ── Render markdown ──────────────────────────────────────────────────
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_path = RESULTS_DIR / f"comparison_{timestamp}.md"

    lines: list[str] = []
    lines.append(f"# Spike comparison — {timestamp}\n")
    lines.append(f"Sources:")
    lines.append(f"- schema_org: `{sorted(RESULTS_DIR.glob('schema_org_run_*.json'))[-1].name}`")
    lines.append(f"- recipe_scrapers: `{sorted(RESULTS_DIR.glob('recipe_scrapers_run_*.json'))[-1].name}`")
    lines.append(f"- ai: `{sorted(RESULTS_DIR.glob('ai_run_*.json'))[-1].name}` (model: `{ai.get('model', 'unknown')}`)\n")

    lines.append("## Headline\n")
    lines.append("| Approach | Success rate |")
    lines.append("|---|---|")
    lines.append(f"| schema.org | {headline['schema_org']} |")
    lines.append(f"| recipe-scrapers | {headline['recipe_scrapers']} |")
    lines.append(f"| AI (Claude) | {headline['ai']} |\n")
    lines.append(f"- URLs that succeeded on **at least one** approach: {n_any}/{len(matrix_rows)}")
    lines.append(f"- URLs that failed on **every** approach: {n_all_fail}/{len(matrix_rows)}\n")

    lines.append("## Per-URL matrix\n")
    lines.append("| ID | Source | URL | schema.org | recipe-scrapers | AI |")
    lines.append("|---|---|---|---|---|---|")
    for row in matrix_rows:
        edge_tag = " 🟡 *roundup*" if row["edge_case"] else ""
        lines.append(
            f"| {row['id']} | `{row['source_type']}`{edge_tag} | `{row['url_short']}` "
            f"| {row['schema_org']} | {row['recipe_scrapers']} | {row['ai']} |"
        )
    lines.append("")

    lines.append("## Per-source-type breakdown\n")
    lines.append("| Source type | URLs | schema.org | recipe-scrapers | AI |")
    lines.append("|---|---|---|---|---|")
    for st, s in by_src.items():
        t = s["total"]
        lines.append(
            f"| `{st}` | {t} "
            f"| {s['so']}/{t} ({100*s['so']/t:.0f}%) "
            f"| {s['rs']}/{t} ({100*s['rs']/t:.0f}%) "
            f"| {s['ai']}/{t} ({100*s['ai']/t:.0f}%) |"
        )
    lines.append("")

    lines.append("## Failure categories\n")
    cats_seen = set()
    for d in failure_cats.values():
        cats_seen.update(d.keys())
    lines.append("| Failure category | schema.org | recipe-scrapers | AI |")
    lines.append("|---|---|---|---|")
    for cat in sorted(cats_seen):
        lines.append(
            f"| `{cat}` | {failure_cats['schema_org'].get(cat, 0)} "
            f"| {failure_cats['recipe_scrapers'].get(cat, 0)} "
            f"| {failure_cats['ai'].get(cat, 0)} |"
        )
    lines.append("")

    lines.append("## Ingredient-count agreement (multi-success URLs)\n")
    lines.append("| ID | URL | schema.org | recipe-scrapers | AI |")
    lines.append("|---|---|---|---|---|")
    for row in agreement_rows:
        lines.append(
            f"| {row['id']} | `{row['url_short']}` "
            f"| {row['so_n'] or '—'} | {row['rs_n'] or '—'} | {row['ai_n'] or '—'} |"
        )
    lines.append("")

    lines.append("## AI cost + latency\n")
    lines.append(f"- API calls made (excludes pre-API fetch failures): {n_api}")
    lines.append(f"- Avg input tokens per call: {avg_input:,.0f}")
    lines.append(f"- Avg output tokens per call: {avg_output:,.0f}")
    lines.append(f"- Avg latency per call: {ai_summary['avg_latency_ms']:,} ms")
    lines.append("")
    lines.append(f"**Cost per successful import** (Sonnet 4.5 @ ${SONNET_INPUT_PER_M}/M in, ${SONNET_OUTPUT_PER_M}/M out):  ~${cost_per_url_sonnet:.4f}")
    lines.append(f"**Cost per successful import** (Haiku 4.5 @ ${HAIKU_INPUT_PER_M}/M in, ${HAIKU_OUTPUT_PER_M}/M out):  ~${cost_per_url_haiku:.4f}")
    lines.append("")
    lines.append(f"**Projected annual cost per family** (assumes {annual_imports} imports/year):")
    lines.append(f"- Sonnet 4.5: ~${annual_cost_sonnet:.2f}/family/year")
    lines.append(f"- Haiku 4.5: ~${annual_cost_haiku:.2f}/family/year")
    lines.append("")
    lines.append(f"_(Numbers reflect this spike's avg tokens per call. Production prompt may differ; treat ±50% as the realistic band.)_")
    lines.append("")

    out_path.write_text("\n".join(lines))
    print(f"Wrote {out_path}")
    print(f"Headline: schema_org {headline['schema_org']}, "
          f"recipe-scrapers {headline['recipe_scrapers']}, AI {headline['ai']}")
    print(f"All-fail URLs: {n_all_fail}/{len(matrix_rows)}")


if __name__ == "__main__":
    main()
