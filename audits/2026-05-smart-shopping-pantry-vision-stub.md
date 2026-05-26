# Smart Shopping + Pantry + Integration Vision — Workstream Stub

**Status:** Placeholder. Strategic questions unresolved. No commitment to scope or timing.

## Why this exists

During Batch 5a iPhone testing, the necessity-vs-wishlist category mismatch surfaced a deeper product question about shopping category architecture. The user articulated a broader vision for what the shopping list (and the app as a whole) should be: better than Apple Reminders' smart list, with multiple deep integration features that no current competitor offers.

This stub captures that vision so it isn't lost. Implementation requires real strategic decisions that haven't been made yet.

## Origin

Surfaced during Pass 3 Batch 5a (kid wishlist routing) on 2026-05-25. The proximate trigger: the spec's seeded necessity_categories don't match the app's actual UI category dropdown options. The bigger reveal: the user's product vision involves features that go well beyond what the current category system supports.

## The full vision (as articulated)

Four interconnected pieces, in order of feasibility:

### 1. Recipe-to-shopping ingredient aggregation

When multiple recipes are added to the meal plan / shopping list, the app combines duplicate ingredients into single line items with aggregated quantities.

Example:
- Recipe A: 1 cup heavy whipping cream
- Recipe B: 1 cup heavy whipping cream
- Recipe C: 1 cup heavy whipping cream
- Recipe D: 1 cup heavy whipping cream
- Shopping list shows: "Heavy whipping cream — 4 cups"

Hard parts:
- Recipe ingredients are currently free-text strings; need structured (canonical_ingredient_id + quantity + unit)
- Unit conversion (cups, fl oz, pints, tbsp) requires a conversion table
- Ingredient identity is tricky ("heavy whipping cream" vs "whipping cream, heavy" vs "heavy cream" — same thing, different text)
- Need a canonical ingredients reference OR an AI-assisted matching layer

Feasibility: achievable. Multi-week work.

### 2. Pantry / fridge inventory with auto-deduction

A standing "what's in your kitchen" list that shopping list generation subtracts from.

Example:
- Recipes need 4 cups heavy whipping cream
- Pantry has 1 cup heavy whipping cream
- Shopping list shows: "Heavy whipping cream — buy 3 cups"

Hard parts:
- New table household_pantry (household_id, canonical_ingredient_id, quantity, unit, updated_at, optional expires_at)
- Updates require user discipline: easy "marked purchased → add to pantry"; harder "made recipe → deduct ingredients" (requires explicit "I cooked this" action)
- Pantry will drift from reality without good UX; may need periodic reconciliation prompts
- Expiration date tracking is its own feature (medium-large)

Feasibility: achievable but requires the ingredient-canonicalization work from Piece 1 to land first.

### 3. Smart categorization by store layout

When walking into a specific store, the shopping list is pre-sorted by that store's physical sections.

Hard parts — feasibility largely unclear:
- No grocery chain publishes a "here's our aisle layout" API
- Layouts vary by store location even within the same chain (Walmart in Salt Lake City vs Walmart in Provo)
- Internal data exists at chains but isn't externally accessible

Realistic alternatives:
- **Option A:** User-defined per-household "this is how OUR Costco is organized" — manual but accurate for the family's actual stores
- **Option B:** Generic store-type templates (grocery store, warehouse club, drugstore) — close enough for most use cases
- **Option C:** Skip store-specific entirely; use smart generic categorization (like Apple)

Verdict: store-specific via real APIs is mostly a pipe dream. Options A or B deliver 80% of the value at 20% of the complexity.

### 4. Kid permissions tied to the new category system

Kids can ONLY add to specific necessity categories that auto-bypass approval; everything else goes to wishlist.

This depends entirely on the category architecture being designed (Pieces 1 + 3). Until those exist, the necessity model can't be properly anchored.

Already partially shipped in Batch 5a: the wishlist-vs-necessity routing logic in `add_shopping_item` RPC works correctly. The gap is that the necessity_categories table contains strings ("Hygiene", "School Supplies") that don't match the app's hardcoded UI category dropdown ("Personal Care", "Beverages"). Reconciling these is part of this vision, not a small fix.

## The broader integration story

The user articulated their app's strategic position: differentiator is **integration depth** — chores + meals + shopping + recipes + permissions + photos all working together better than 5 separate apps would.

If integration is the killer feature, then the recipe-to-shopping-to-pantry triangle described above is the most important integration to build. It's literally the data flowing across 3 features (recipes, meal plans, shopping lists) that demonstrates the integration value.

## Strategic questions to resolve before starting

The user has NOT made these decisions yet. The stub captures them for future deliberation:

1. **Priority vs Pass 3:** Does this workstream preempt parts of Pass 3 (Batches 5b/6/7/8) or come strictly after?

2. **Sequencing within this workstream:** Recipe aggregation first? Pantry first? Categorization first? They have soft dependencies on each other.

3. **Category architecture:** Single source of truth across necessity_categories + UI dropdown + future store-section concept. Build a categories table, hardcoded in source, or AI-derived?

4. **Ingredient canonicalization:** Build a reference ingredients table, use AI matching, or punt the problem (free-text matching only)?

5. **Store-layout approach:** Generic templates, user-defined per-household, or both?

6. **Pantry maintenance UX:** How does the user keep pantry in sync with reality? Manual updates? Auto-deduct on purchase + manual deduction on cook? Periodic reconciliation prompts?

7. **Scope size:** Is this one mega-workstream or several smaller ones?

## Estimated rough scope (placeholders)

These are gut-feel estimates, not designs:

- **Piece 1 (recipe aggregation):** ~4-6 weeks. Requires recipe ingredient structuring (separate table or schema change), unit conversion logic, deduplication algorithm, UI updates to show aggregated rows.
- **Piece 2 (pantry):** ~3-4 weeks. New table, new screens for pantry CRUD, integration with shopping list generation, "I cooked this" deduction flow.
- **Piece 3 (categorization):** ~2-3 weeks for Option B (generic templates). Significantly more for Option A (user-defined store layouts).
- **Piece 4 (kid permissions reconciliation):** ~1 week. Mostly migration + UI updates to make necessity_categories source of truth or align with dropdown.

Total if all four ship: 10-14 weeks of focused work. The user works at a pace of roughly 1-3 hours per workday, so this is real calendar time even with full focus.

## What's already in place (foundation)

- shopping_items table with category column (currently hardcoded list in shopping_list_screen)
- necessity_categories table (per-household, configurable, seeded with 4 defaults)
- add_shopping_item RPC with wishlist-routing logic (Batch 5a)
- household_recipes table with ingredients (currently free-text)
- meal_plans table
- The integration-as-killer strategic frame

## What's explicitly out of scope of this stub

- Marketing positioning ("how do we tell people about this")
- Pricing and business model decisions
- Onboarding flow design
- AI/ML integration choices for ingredient matching or categorization (deferred until the manual version is built and we know what's hard)

## Triggers for starting

Start designing this workstream when ANY of these are true:

1. Pass 3 closes (Batches 5b, 6, 7, 8 all shipped)
2. User decides this is more important than remaining Pass 3 work
3. Real users (testers) request these features specifically

Until then: stays deferred. Pass 3 finishes first; this is the next major workstream candidate.

## Next steps when triggered

1. Answer the 7 strategic questions above
2. Pick a starting piece (probably Piece 1 — recipe aggregation — as foundation)
3. Real investigation pass for that piece's scope, schema changes, UI impact
4. Decide on canonical ingredient strategy (table? AI? free-text + dedupe?)
5. Build the piece, ship it, evaluate, decide next piece

This stub is intentionally vague on implementation. The strategic questions matter more right now than the technical ones.

End of stub.

---

# Update 2026-05-26 — First Strategic Decisions Locked

Two of the seven strategic questions from the original stub answered during the 2026-05-26 morning session. The remaining five (Q1 priority, Q3 category architecture, Q4 ingredient canonicalization implementation strategy, Q6 pantry maintenance UX, Q7 scope size) stay open for future sessions.

## Q2 (Sequencing) — LOCKED

**Decision:** Spike on ingredient canonicalization FIRST as Phase 0. Then execute Sequence A: Recipe aggregation → Pantry → Categorization → Kid permissions.

**Reasoning:** Recipe aggregation is the foundation of the integration story. Pantry depends on canonicalized ingredients to do auto-deduction. If canonicalization can't be solved cleanly, the entire 10-week roadmap is shakier than it looks. A 1-2 day spike de-risks the whole vision without committing to a long implementation path on a shaky foundation.

The user explicitly said "I don't like to figure things out along the way, it gets really messy." The spike is the antidote — answer the hard question first, then commit with confidence.

**Full execution order:**

| Phase | Work | Estimated calendar time |
|------:|------|------------------------:|
| 0 | Ingredient canonicalization spike (manual + AI compared) | 1-2 days |
| 1 | Recipe aggregation (depends on Phase 0 verdict) | 4-6 weeks |
| 2 | Pantry inventory + auto-deduction | 3-4 weeks |
| 3 | Categorization (generic grocery template, see Q5) | 2-3 weeks |
| 4 | Kid permissions reconciliation | 1 week |

Total: 10-14 weeks of focused work post-spike. User's actual pace (1-3 hrs per workday) makes the calendar longer — plan for 4-6 months elapsed time if pursued sequentially without other workstreams interleaving.

## Q5 (Store layout) — LOCKED

**Decision:** Option B — generic store-type templates. Per-household custom layouts (Option A) deferred to future enhancement.

**Starting scope:** ONE template only — generic grocery store. Expand to other store types (warehouse club, drugstore, etc.) later if real users request them.

**Reasoning:** Zero-onboarding-cost. Family doesn't have to manually organize a store on day one. The shopping list "just works" with a reasonable section order. Walking into any grocery store, produce is near the front, dairy/meat in the back, frozen on the perimeter — generic templates capture 70-80% of the smart-sorted-list feeling without per-store setup. Forward-compatible with Option A as a future "customize for YOUR Walmart" feature.

Starting with just grocery (not 2-3 templates) keeps v1 simple. Add warehouse club / drugstore templates when user research shows they're needed.

**Recommended generic grocery section order (placeholder, refine when implementing):**

1. Produce
2. Bakery
3. Deli
4. Meat & Seafood
5. Dairy & Eggs
6. Frozen
7. Pantry / Dry Goods
8. Snacks
9. Beverages
10. Health & Beauty
11. Household
12. Other / Misc

This list will need to reconcile with the necessity_categories table and the UI dropdown options as part of Q3 (category architecture) work — that question is still open.

## Phase 0 Spike — Scope Defined

**Goal:** Answer "can we map free-text recipe ingredient strings to a canonical reference reliably enough to power Phase 1?" Output is a decision: manual / AI / hybrid / not viable.

### Test sample

Build a fixed 50-ingredient test set from existing seeded recipes in household_recipes. Specifically:

- 30 common ingredients with natural variation in free-text representation (e.g., "heavy whipping cream" vs "whipping cream, heavy" vs "heavy cream")
- 10 ambiguous ingredients (e.g., "olive oil" vs "extra virgin olive oil" — same or different canonical?)
- 10 weird-but-real ingredients ("Trader Joe's Everything But the Bagel seasoning", "1 dash of Worcestershire") — edge cases

Test set should be saved as a CSV or JSON in `audits/spike-ingredient-canonicalization-test-set.json` (or wherever fits). Include the EXPECTED canonical match for each.

### Approach 1 — Manual canonicalization

Build a canonical_ingredients reference table with ~50 entries (or however many are needed to cover the test set).

Implement a string normalization pipeline:
1. Lowercase
2. Strip common qualifiers ("fresh", "the", "a", "fine", "extra")
3. Handle pluralization (lemons → lemon)
4. Word order tolerance (whipping cream, heavy → heavy whipping cream)
5. Exact match against canonical_ingredients.canonical_name

Test the pipeline on the 50-ingredient sample.

**Pass criteria:** 80%+ correct mapping with manual review of the failures.

**Output:** accuracy %, list of failure types, estimated work to handle the remaining 20% (more sophisticated string handling? brand-name aliasing table?).

### Approach 2 — AI canonicalization

Use Claude API (or another LLM) to map free-text → canonical entry. Prompt design:

```
You are an ingredient normalizer. Map the input ingredient phrase
to its canonical form. Canonical forms are: lowercase, common name,
no qualifiers (skip "fresh", "extra virgin", brand names unless the
brand IS the canonical). Examples:
- "1 cup heavy whipping cream" → "heavy whipping cream"
- "fresh lemon juice" → "lemon juice"
- "2 tbsp extra virgin olive oil" → "olive oil"
- "Trader Joe's Everything But the Bagel" → "everything bagel seasoning"

Input: [free text]
Output: [canonical form]
```

Run all 50 test ingredients through the API.

**Pass criteria:** 95%+ correct mapping.

**Output:** accuracy %, cost per call, latency per call, monthly cost estimate at 100 families × 4 recipes/week (rough heuristic — adjust to user's expected scale).

### Comparison + decision

Side-by-side table:

| Metric | Manual | AI |
|--------|--------|-----|
| Accuracy on test set | X% | Y% |
| Cost per match | ~free | $0.0001/call (approx) |
| Latency | <1ms | 1-3s |
| Setup cost | ~1 week to build pipeline | ~2 hours to wire up |
| Maintenance cost | adds new ingredients manually | LLM updates automatic |
| Offline behavior | works | requires network |

Decision criteria (whichever scores 4+):
- Manual wins if: accuracy >85%, AI accuracy isn't dramatically higher
- AI wins if: accuracy ≥95%, monthly cost is reasonable, latency acceptable
- Hybrid wins if: manual handles 80%, AI fallback handles the rest (best of both, more code)
- "Not viable" only if both score <70%

### Spike output

Single document saved to `audits/spike-ingredient-canonicalization-results-YYYY-MM-DD.md`:

- Test set summary
- Manual approach: accuracy + failure analysis
- AI approach: accuracy + cost + latency
- Recommendation: manual / AI / hybrid
- Implementation strategy for Phase 1 (Recipe aggregation) based on verdict
- Estimated additional work needed before Phase 1 can start

### Time budget

2 days maximum. If the spike is taking longer, stop and reassess scope. Most likely cause of overrun: building too elaborate a manual normalization pipeline. The spike is supposed to answer "can we?" not "have we built it?"

### Out of scope for the spike

- Recipe parsing (extracting quantity + unit from "1 cup heavy whipping cream") — that's Phase 1 work
- Unit conversion (cups → fl oz) — Phase 1
- Multi-recipe aggregation — Phase 1
- Pantry integration — Phase 2
- UI design — Phase 1

Just the canonical mapping problem. Tightly scoped.

## Triggers for starting the spike

Same as the original stub's "triggers for starting" — Pass 3 substantially done (it is, as of v0.6.0-ui-polish-complete + Batch 9 stub) OR user prioritizes this workstream over remaining Pass 3 items (6c push notifications, currently the only blocker).

Practical: the spike could happen any time after a name decision unblocks 6c-i, or before it if the user decides Smart Shopping is higher priority than push notifications.

## Open questions remaining (5 of 7)

Still unresolved, captured here for future sessions:

- **Q1 (Priority vs Pass 3):** Currently moot — Pass 3 is essentially done aside from 6c-blocked-on-name.
- **Q3 (Category architecture):** Single source of truth across necessity_categories + UI dropdown + future store-section concept. Most urgent of the remaining open questions because it touches both Phase 3 (Categorization) and the current shipped necessity_categories table.
- **Q4 (Ingredient canonicalization implementation):** Will be answered by the spike. Not really "open" anymore — the spike IS the answer-finding process.
- **Q6 (Pantry maintenance UX):** Real user testing needed. Hard to decide in a vacuum.
- **Q7 (Scope size):** Depends on Q2 + Q5 decisions, which are now locked. Effective answer: this is ONE workstream with 5 phases (Phase 0 spike + Phases 1-4), but each phase ships independently and can be evaluated before committing to the next.

## What changed in the bigger picture

Pre-update: 7 open strategic questions, no clear path to start.

Post-update: 2 questions locked, 1 (Q4) will be answered by a scoped spike, 1 (Q1) made moot by Pass 3 closure, 1 (Q7) effectively answered by the sequencing decision. The remaining 2 (Q3, Q6) can be deferred or addressed when implementation actually starts.

The workstream is no longer "vague vision needing 7 decisions." It's "scoped 4-month roadmap starting with a 2-day spike."

End of 2026-05-26 update.
