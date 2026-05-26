# Hallucination audit — AI extraction reliability

**Question**: When AI returns ingredients, are they faithful to the source page or is it inventing/dropping/distorting?

**Method**: Side-by-side comparison of the raw `recipeIngredient` strings (from schema.org JSON-LD on the source pages — ground truth for what the recipe author wrote) against the AI's structured output, for 3 representative slots where AI succeeded.

**Severity scale**:
- **cosmetic** — name normalized (e.g., "freshly cracked black pepper" → "black pepper"); quantity + unit faithful. Desirable behavior.
- **minor** — qualifier dropped that matters in some contexts but not for pantry/shopping (e.g., "unsalted butter" → "butter", "semi-sweet chocolate chips" → "chocolate chips"); or category off-by-one (almond milk → Beverages when Dairy might be more natural).
- **concerning** — quantity or unit changed from source, or wrong-class unit assigned (e.g., assigning "pinch" to a fresh-herb garnish where source specified no amount).
- **critical** — ingredient added that wasn't on the page (true hallucination), or dropped in a way that materially changes the recipe.

## Slot 4 — 40 Aprons Marry-Me Chicken

| # | Source (raw schema.org) | AI output | Severity | Notes |
|---|---|---|---|---|
| 1 | `3 pounds boneless, skinless chicken breasts` | `chicken breast` (3 lb, Meat) | cosmetic | Name normalized; qty/unit correct |
| 2 | `salt (to taste)` | `salt` (1 pinch, Pantry) | minor | AI imputed "1 pinch" for "to taste". Loses the "user adjusts" semantic but adds a sensible default for shopping aggregation. |
| 3 | `freshly cracked black pepper (to taste)` | `black pepper` (1 pinch, Pantry) | minor | Same pattern as #2 |
| 4 | `2 tablespoons olive oil (or other neutral oil)` | `olive oil` (2 tbsp, Pantry) | cosmetic | Dropped "or other neutral oil" qualifier; qty/unit correct |
| 5 | `2 tablespoons minced garlic` | `garlic` (2 tbsp, Produce) | cosmetic | Dropped "minced" prep instruction |
| 6 | `¾ cup low-sodium chicken broth (see Notes)` | `chicken broth` (0.75 cup, Pantry) | cosmetic | Dropped "low-sodium" qualifier (could be minor for sodium-sensitive cooks; cosmetic for shopping) |
| 7 | `½ cup heavy cream (at room temperature)` | `heavy cream` (0.5 cup, Dairy) | cosmetic | Dropped prep instruction |
| 8 | `½ cup grated fresh parmesan cheese (at room temperature, see Notes)` | `parmesan cheese` (0.5 cup, Dairy) | cosmetic | Dropped "grated fresh" + prep |
| 9 | `1 cup sun-dried tomatoes (preferably packed in oil)` | `sun-dried tomatoes` (1 cup, Pantry) | cosmetic | Dropped packing qualifier |
| 10 | `1 teaspoon dried oregano (more or less to taste)` | `oregano` (1 tsp, Pantry) | cosmetic | Dropped "dried" (could be minor for cooks substituting fresh) and "to taste" hedge |
| 11 | `½ teaspoon crushed red pepper flakes (more or less to taste)` | `red pepper flakes` (0.5 tsp, Pantry) | cosmetic | Dropped "crushed" + "to taste" |
| 12 | `chiffonaded fresh basil` (no qty) | `basil` (1 pinch, Produce) | **concerning** | AI assigned "1 pinch" to a fresh-herb garnish. Source specifies no amount; "pinch" is the wrong unit class for a chiffonade — actual usage is more like "a handful" or "2 tbsp loosely packed". A user following this would under-garnish significantly. |
| 13 | `grated fresh parmesan cheese` (second mention, garnish) | DROPPED — consolidated with row 8 | minor | The source lists parmesan twice (once in sauce, once as garnish). AI merged into a single 0.5-cup entry. **Acceptable** for shopping aggregation (we already buy parmesan). **Wrong** for recipe-as-written display (user wouldn't see the "sprinkle on top" garnish step). |

**Slot 4 summary**: 9 cosmetic, 3 minor, 1 concerning, 0 critical.

## Slot 8 — Sally's Chocolate Chip Cookies

| # | Source (raw schema.org) | AI output | Severity | Notes |
|---|---|---|---|---|
| 1 | `3/4 cup (12 Tbsp; 170g) unsalted butter, softened to room temperature` | `butter` (0.75 cup, Dairy) | minor | Dropped "unsalted" — meaningful in baking (salted butter adds ~1/4 tsp salt per stick). For shopping aggregation, fine. |
| 2 | `3/4 cup (150g) packed light or dark brown sugar` | `brown sugar` (0.75 cup, Pantry) | cosmetic | Dropped "packed" + "light or dark" optionality |
| 3 | `1/4 cup (50g) granulated sugar` | `sugar` (0.25 cup, Pantry) | cosmetic | Dropped "granulated" qualifier. For recipes mixing granulated + powdered, this would matter; not the case here. |
| 4 | `1 large egg, at room temperature` | `egg` (1 count, Dairy) | minor | Eggs are commonly shelved in dairy fridges but technically not dairy. Acceptable for shopping; some category schemas treat eggs separately. |
| 5 | `2 teaspoons pure vanilla extract` | `vanilla extract` (2 tsp, Pantry) | cosmetic | Dropped "pure" (vs imitation) — could matter to a serious baker |
| 6 | `2 cups (250g) all-purpose flour (spooned & leveled)` | `flour` (2 cup, Pantry) | minor | Dropped "all-purpose" — different flours behave very differently in baking. Fine for shopping; not fine for an authoritative recipe view. |
| 7 | `2 teaspoons cornstarch` | `cornstarch` (2 tsp, Pantry) | cosmetic | |
| 8 | `1 teaspoon baking soda` | `baking soda` (1 tsp, Pantry) | cosmetic | |
| 9 | `1/2 teaspoon salt` | `salt` (0.5 tsp, Pantry) | cosmetic | |
| 10 | `1 and 1/4 cup (225g) semi-sweet chocolate chips` | `chocolate chips` (1.25 cup, Pantry) | minor | Dropped "semi-sweet" — meaningful (dark/milk/semi-sweet/white are different products). For pantry shopping, "chocolate chips" is the canonical pantry slot. |

**Slot 8 summary**: 6 cosmetic, 4 minor, 0 concerning, 0 critical.

## Slot 12 — RecipeTin Eats Chicken Marsala

| # | Source (raw schema.org) | AI output | Severity | Notes |
|---|---|---|---|---|
| 1 | `2 large chicken breasts ((300g/10oz each), cut in half horizontally (or 4 thighs, Note 1))` | `chicken breast` (2 count, Meat) | cosmetic | Dropped weight detail + alternative + prep |
| 2 | `1/2 tsp cooking salt / kosher salt` | `salt` (0.5 tsp, Pantry) | cosmetic | Kosher and table salt have different volume-to-weight ratios; dropping the distinction is acceptable for shopping |
| 3 | `1/2 tsp black pepper` | `black pepper` (0.5 tsp, Pantry) | cosmetic | |
| 4 | `1/4 cup flour (, plain/all-purpose)` | `flour` (0.25 cup, Pantry) | cosmetic | |
| 5 | `2 tbsp extra virgin olive oil` | `olive oil` (2 tbsp, Pantry) | cosmetic | Dropped "extra virgin" — exactly the canonical-collapse the pantry use case wants |
| 6 | `2 tbsp / 30g unsalted butter` | `butter` (2 tbsp, Dairy) | minor | Same as slot 8: lost "unsalted" |
| 7 | `2 eschalots ((US: shallots), peeled and cut into 1cm / 1/3" squares (Note 2))` | `shallots` (2 count, Produce) | cosmetic | **AI correctly localized**: "eschalots" → "shallots" (AU/UK → US). Good. |
| 8 | `1 garlic (, finely minced)` | `garlic` (1 cloves, Produce) | minor | Source is ambiguous ("1 garlic" could mean clove, bulb, or head). AI inferred "1 clove" which is the most plausible reading. Documented assumption. |
| 9 | `2 cups white mushrooms (, sliced 0.5cm / 1/5" thick)` | `mushrooms` (2 cup, Produce) | cosmetic | Dropped "white" — different mushroom varieties cook similarly; fine for shopping |
| 10 | `1 cup dry marsala wine ((Note 3))` | `marsala wine` (1 cup, Beverages) | cosmetic | |
| 11 | `1/2 cup chicken stock/broth (, low sodium)` | `chicken stock` (0.5 cup, Pantry) | cosmetic | |
| 12 | `1/2 cup thickened / heavy cream ((Note 4))` | `heavy cream` (0.5 cup, Dairy) | cosmetic | **Another localization**: "thickened cream" (AU) → "heavy cream" (US). |
| 13 | `1/4 tsp cooking salt / kosher salt` | `salt` (0.25 tsp, Pantry) | cosmetic | |
| 14 | `1/8 tsp black pepper` | `black pepper` (0.125 tsp, Pantry) | cosmetic | Fraction-to-decimal conversion correct (1/8 = 0.125) |
| 15 | `1 tbsp finely chopped parsley (, for garnish (optional))` | `parsley` (1 tbsp, Produce) | cosmetic | Dropped "for garnish (optional)" — meaningful flag the AI could have preserved as a topping note, but not critical |

**Slot 12 summary**: 13 cosmetic, 2 minor, 0 concerning, 0 critical.

## Cross-slot summary

| Severity | Slot 4 | Slot 8 | Slot 12 | Total | % of 38 source items |
|---|---|---|---|---|---|
| cosmetic | 9 | 6 | 13 | 28 | 74% |
| minor | 3 | 4 | 2 | 9 | 24% |
| concerning | 1 | 0 | 0 | 1 | 3% |
| **critical** | **0** | **0** | **0** | **0** | **0%** |

## Findings

1. **Zero critical errors.** Across 38 source ingredients on 3 recipes, AI did not invent or drop a single ingredient in a way that materially changes the recipe. No hallucinations.
2. **Quantities and units are reliably preserved.** Every numeric quantity and every unit in the source was correctly translated by AI (including the `1/8` → `0.125` decimal conversion and the `¾` Unicode fraction → `0.75`). The one concerning case (slot 4 basil) was an *imputed* quantity where the source had none — not a transformation of an existing quantity.
3. **One concerning case worth understanding**: slot 4, "chiffonaded fresh basil" with no specified quantity → AI assigned `1 pinch`. This is the wrong unit *class* for a fresh-herb garnish ("pinch" implies dried-herb amounts; a chiffonade is more like a handful). For pantry purposes the impact is minimal (you have basil or you don't), but if the AI's output is shown verbatim to a cook following the recipe, "1 pinch of basil" is misleading.
4. **Localization is a feature.** AI correctly translated "eschalots" → "shallots" and "thickened cream" → "heavy cream" between AU and US terminology. recipe-scrapers would preserve the original term verbatim.
5. **Qualifier drops are the dominant "minor" issue.** "unsalted butter" → "butter", "semi-sweet chocolate chips" → "chocolate chips", "all-purpose flour" → "flour", "extra virgin olive oil" → "olive oil". For the *pantry/shopping aggregator* use case, these collapses are exactly what we want (two recipes calling for "butter" and "unsalted butter" should aggregate to one pantry slot). For a *recipe view* showing the recipe as the author wrote it, the qualifier loss is information loss.

## Verdict

**For the pantry/shopping aggregation use case: AI output is trustworthy.** Zero critical hallucinations across 38 source items, with quantities/units faithfully preserved. The 24% "minor" rate is dominated by *canonical-collapse behavior we explicitly asked for in the prompt* ("remove qualifiers like 'fresh', 'extra virgin', brand names").

**For a recipe-detail view showing the recipe as written: there is information loss.** A user looking at an imported Sally's recipe would see "butter" + "chocolate chips" + "flour" — they wouldn't know unsalted butter is required, semi-sweet chips are specified, or that all-purpose flour matters. **Recommendation**: store both the **canonical structured output** (for shopping aggregation, the app's existing structured format) AND the **original recipe text** (for a "show recipe as written" view). Don't throw away the source text — it has signal the canonical form drops.

The one concerning case (basil pinch) is a single instance and represents the boundary of AI judgment — when the source is genuinely ambiguous, AI guesses. Mitigation: a final "review imported recipe" step before the user saves (already recommended in the main `results.md`) catches this.

**Net effect on the main spike recommendation**: confirmed. AI output is reliable enough to ship. The "always run AI canonicalization for the pantry view" guidance stands. Add an architectural note: **persist the original recipe text alongside the canonical structured form** so the recipe-detail view doesn't lose information.
