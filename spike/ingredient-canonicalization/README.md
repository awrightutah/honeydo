# Spike: Ingredient Canonicalization

A throwaway investigation comparing two approaches for normalizing free-text
recipe ingredient strings into a canonical form. Output of this spike informs
the Smart Shopping / Pantry workstream's Q2 (mapping mechanism) and Q5 (test
methodology) decisions captured in
[`/audits/2026-05-smart-shopping-pantry-vision-stub.md`](../../audits/2026-05-smart-shopping-pantry-vision-stub.md)
(see the "Update 2026-05-26" section).

**Not shipping code.** Lives in `/spike/` to keep it clearly separated from
the production Flutter / Node / Supabase stacks.

## The problem

Recipe ingredients arrive as free text:
- `"1 cup heavy whipping cream"`
- `"heavy whipping cream, heavy"`
- `"Whipping cream — heavy"`

Same physical pantry item, three different strings. To do anything useful
downstream (aggregate shopping lists across recipes, deduct pantry stock,
suggest substitutions), we need a canonical form per item.

## The two approaches under test

### Approach A — Deterministic dictionary lookup
A hand-curated mapping table (`canonical_dict.json`) of input variations →
canonical key. Lookup is exact-match with simple normalization (lowercase,
strip whitespace, strip leading quantities/units). Cheap, fast, predictable.
Misses anything not in the dictionary.

### Approach B — AI canonicalization
Ask Claude (`claude-haiku-4-5-20251001`, the cheapest current model) to
return a canonical form for each input. Slower, costs API credits per call,
non-deterministic across runs. Handles long-tail inputs the dictionary
would miss.

## Test set methodology

Single test set of **50 entries** with three categories:
- **30 "common"** — natural variation (different quantities, ordering, casing)
- **10 "ambiguous"** — same word, different specificity (e.g. olive oil vs
  EV olive oil). Locked decision: for pantry use, ambiguous variants collapse
  to the more-general canonical form.
- **10 "edge_case"** — weird-but-real (brand names, "to taste", dashes)

Each entry has an `expected_canonical` (the form we'd want both approaches
to produce). Entries are tagged `real_recipe` (sourced from
`household_recipes.ingredients` rows) or `synthetic` (made up to cover the
category) so we know which results reflect real-world distribution.

See [`test_set.json`](./test_set.json) for the full set.

## How to run (placeholder — Phase 2)

```bash
# One-time setup
cd spike/ingredient-canonicalization
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
# Edit .env: paste your ANTHROPIC_API_KEY

# Run dictionary approach
python run_dictionary.py

# Run AI approach
python run_ai.py

# Compare results
python compare.py
```

(Phase 2 will populate the actual Python files.)

## Results land in

`./results/` (gitignored except for the human-readable summary report). Each
run writes a JSON file with per-entry input / expected / actual / match flag,
plus an aggregate `summary.md`.

## Reference

- [`/audits/2026-05-smart-shopping-pantry-vision-stub.md`](../../audits/2026-05-smart-shopping-pantry-vision-stub.md)
  for the broader Smart Shopping vision and the spike scope locked on
  2026-05-26.
