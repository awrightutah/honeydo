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
