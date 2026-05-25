# Necessity categories vs app dropdown — alignment investigation

Date: 2026-05-25
Branch: `feat/kid-perms-wishlist-2026-05-25` (read-only)
Status: investigation complete — **mismatch confirmed**; **none of the 4 seeded necessity categories appear in the app's dropdown**.

## Summary

The app's shopping category dropdown offers 12 hardcoded options. The 4 necessity defaults seeded by migration 0016 (Hygiene, School Supplies, Basic Groceries, Medication) **don't match any of them**. So when a kid picks a category from the actual dropdown, the case-insensitive necessity match in `add_shopping_item` always returns false, and every kid add goes to wishlist regardless of category. The bypass path never fires.

Fix: change the 4 necessity defaults to strings that exist in the dropdown. Recommend **Produce, Dairy, Pantry, Personal Care** — covers the spec's spirit (food staples + hygiene/health) while staying within the app's actual category space.

Migration: one new migration (0022) that (a) updates the trigger for future households, (b) optionally cleans up the existing 4 stale rows in the Wrights household and inserts the new 4. ~50 LOC, single migration, no app code changes.

## Phase 1 — Dropdown source location

**Canonical source: hardcoded in two Dart files.** Not database-sourced.

### Primary list: `apps/mobile/lib/screens/shopping_list_screen.dart:10-21`

```dart
const List<String> _shoppingCategories = [
  'Produce',
  'Dairy',
  'Meat & Seafood',
  'Pantry',
  'Frozen',
  'Bakery',
  'Beverages',
  'Snacks',
  'Household',
  'Personal Care',
  'Pet Supplies',
  'Other',
];
```

Used at line 349 to populate the `_AddShoppingItemSheet` category dropdown:
```dart
..._shoppingCategories.map((c) => DropdownMenuItem<String>(value: c, child: Text(c))),
```

Same 12 strings repeat at line 54-57 (`_categoryOrder` for sorting), line 60-66 (`_categoryIcons`), line 75-81 (`_categoryColors`), and line 810-813 (`_categoryEmojis` inside `_AddShoppingItemSheet`).

### Mirror list: `apps/mobile/lib/screens/shopping_category_screen.dart:19-32`

```dart
static const _defaultCategories = [
  _CategoryDef('Produce', Icons.eco_rounded, Color(0xFF4CAF50), '🥬'),
  _CategoryDef('Dairy', Icons.water_drop_rounded, Color(0xFF42A5F5), '🥛'),
  _CategoryDef('Meat & Seafood', Icons.set_meal_rounded, Color(0xFFEF5350), '🥩'),
  _CategoryDef('Pantry', Icons.inventory_2_rounded, Color(0xFFFF9800), '🫘'),
  _CategoryDef('Frozen', Icons.ac_unit_rounded, Color(0xFF29B6F6), '🧊'),
  _CategoryDef('Bakery', Icons.bakery_dining_rounded, Color(0xFFD4A373), '🍞'),
  _CategoryDef('Beverages', Icons.local_cafe_rounded, Color(0xFF7E57C2), '☕'),
  _CategoryDef('Snacks', Icons.cookie_rounded, Color(0xFFFFCA28), '🍪'),
  _CategoryDef('Household', Icons.cleaning_services_rounded, Color(0xFF78909C), '🧹'),
  _CategoryDef('Personal Care', Icons.spa_rounded, Color(0xFFEC407A), '🧴'),
  _CategoryDef('Pet Supplies', Icons.pets_rounded, Color(0xFF8D6E63), '🐾'),
  _CategoryDef('Other', Icons.more_horiz_rounded, Color(0xFF9E9E9E), '📦'),
];
```

Same 12 categories. Duplication-by-hand between the two files; worth flagging as a small followup (extract to a shared constants file), but unrelated to this bug.

**Note for the meal/recipe screens** (`meal_planner_screen.dart`, `recipe_detail_screen.dart`): neither screen exposes a category-picker on the shopping-add path. Their kid paths pass `p_category: null` to `add_shopping_item`, so the necessity check resolves to `lower('') = lower(<any seed>)` → always false → always wishlist. Those sites are unaffected by this fix; they'll keep landing in wishlist regardless of the seed contents.

## Phase 2 — Category-related schema in migrations

`grep -i "category" supabase/migrations/*.sql` (filtered to non-comment, non-RPC-param hits):

| Migration | Reference | Relevance |
|---|---|---|
| `0001_initial_schema.sql:78` | `room_or_category text` (in `chores`) | Unrelated to shopping |
| `0001_initial_schema.sql:327` | `category text` (in `shopping_items` — original column) | The free-text column the dropdown writes to |
| `0016_kid_perms_schema.sql:76` | `category text NOT NULL` (PK in `necessity_categories`) | The seed table — where the mismatch lives |
| `0016_kid_perms_schema.sql:94-99` | The 4-default seed trigger | **Source of the bug** |
| `0016_kid_perms_schema.sql:115-119` | Backfill INSERT for existing households | Same defaults applied to Wrights |
| `0017_kid_perms_rls_rpcs.sql:480-485` | `lower(nc.category) = lower(COALESCE(p_category, ''))` | The case-insensitive match the necessity bypass uses |

**No category enum, no shared CREATE TYPE, no foreign key from `shopping_items.category` to `necessity_categories.category`.** `shopping_items.category` is plain `text` (nullable) — anyone can write any string. The dropdown's 12 entries are the de facto canonical set, but only by Dart convention; the database doesn't enforce them.

Confirmation that **the schema doesn't constrain category to any list** — categories can be anything, the dropdown happens to offer 12, and the seed picked 4 that don't match any of those.

## Phase 3 — Proposed new necessity defaults

### Constraint check

Spec's original 4 (Hygiene, School Supplies, Basic Groceries, Medication) vs the app's 12:

| Spec default | Match in app's dropdown? |
|---|---|
| Hygiene | ❌ (closest: "Personal Care") |
| School Supplies | ❌ (closest: "Other" or "Household") |
| Basic Groceries | ❌ (closest: "Pantry" or "Produce") |
| Medication | ❌ (closest: "Personal Care") |

Zero matches. Every kid pick from the dropdown today fails the case-insensitive comparison.

### Recommended new defaults (4)

Goal: stay within the dropdown's existing 12 entries; honor the spec's "necessities not requiring approval" spirit; cover food staples + hygiene/health.

| New default | Maps to spec category | Justification |
|---|---|---|
| **Produce** | (food staple) | Fresh fruit/veg — kid asking for an apple shouldn't need admin approval |
| **Dairy** | Basic Groceries | Milk, eggs — staples |
| **Pantry** | Basic Groceries | Rice, pasta, canned staples |
| **Personal Care** | Hygiene + Medication | Covers toiletries AND basic OTC (the dropdown's only entry for these) |

**What this loses vs the spec:**
- "School Supplies" — the app doesn't have a category for non-grocery items beyond "Household" or "Other". Treating "Other" as a default would be too broad. Recommend: kid still requests school supplies via wishlist; admin approves. Not bypass-eligible until/unless we add a real "School Supplies" category to the dropdown.

**What this gains vs the spec:**
- Real matches against the dropdown. Kid picking "Personal Care" from the dropdown now correctly hits the bypass and the item goes directly to the active list.

### Alternative: more conservative (2 defaults)

If user prefers tighter default scope:
- **Pantry** — staples
- **Personal Care** — hygiene/medication

Admin can add more via the Batch 5b necessity-categories management screen. Pro: minimal auto-bypass surface. Con: more friction for kid common cases (asking for milk goes to wishlist).

### Alternative: app-side change (out of scope)

Long-term, could add "School Supplies" + "Medication" + "Hygiene" as explicit categories in the dropdown. Requires code changes in shopping_list_screen.dart (`_shoppingCategories`, `_categoryOrder`, `_categoryIcons`, `_categoryColors`, `_categoryEmojis`) AND shopping_category_screen.dart (`_defaultCategories`). Probably ~30 LOC across 2 files but doesn't unblock the immediate bug.

**Recommend the 4-default Produce/Dairy/Pantry/Personal Care set** for now; defer dropdown expansion to a polish pass.

## Phase 4 — Migration plan options

### Option A — Clean swap (simplest)

Migration `0022_align_necessity_categories.sql`:

```sql
-- 1. Update the seed trigger for future households
CREATE OR REPLACE FUNCTION public.seed_default_necessity_categories()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO public.necessity_categories (household_id, category) VALUES
    (NEW.id, 'Produce'),
    (NEW.id, 'Dairy'),
    (NEW.id, 'Pantry'),
    (NEW.id, 'Personal Care')
  ON CONFLICT DO NOTHING;
  RETURN NEW;
END;
$$;

-- 2. Delete the old defaults (any household, no preservation of custom)
DELETE FROM public.necessity_categories
 WHERE category IN ('Hygiene', 'School Supplies', 'Basic Groceries', 'Medication');

-- 3. Insert the new defaults for all existing households
INSERT INTO public.necessity_categories (household_id, category)
SELECT h.id, c.category
  FROM public.households h
  CROSS JOIN (VALUES ('Produce'), ('Dairy'), ('Pantry'), ('Personal Care')) AS c(category)
ON CONFLICT DO NOTHING;
```

**Pros**: simple. ~30 LOC. Idempotent (DELETE no-ops if already absent; INSERT no-ops on conflict).
**Cons**: nukes any custom necessity rows that happen to be named "Hygiene/School Supplies/Basic Groceries/Medication." Current state: only the Wrights household exists, no customizations made, so this is fine. For future households with custom data this would be destructive.

### Option B — Selective swap (preservation-aware)

Same as Option A but only DELETEs the original defaults if they were autogenerated (no `approved_by_member_id`-style audit columns on `necessity_categories` to distinguish, so we'd just match by exact string). Since `necessity_categories` has no provenance column, Option B is effectively the same as Option A — can't tell "this was a default" vs "this was a custom add named Hygiene."

If we DID want to preserve, we'd have to add a `created_by` column or `is_default` flag (schema change, more work). **Not worth it for one household with no customizations.**

### Recommendation

**Option A.** Single migration. Idempotent. Safe for the current single-household reality. If the app ever has multi-tenant customers with custom necessity entries named like the old defaults, we'd revisit — but that's hypothetical and out of current scope.

### What about the spec text?

The spec at `/audits/2026-05-kid-profile-permissions-spec.md` mentions the original 4 defaults in 3-4 places (decisions table, implementation notes, batch plan). After migration 0022 lands, those would be stale. Either:
- Leave the spec as historical (it documents what was originally seeded; migration 0022 documents the change)
- Amend the spec in a follow-up commit to mention the new 4 defaults

Recommend leave-and-document — migration 0022's header comment block becomes the canonical record of the change, with a one-line spec note pointing to it. Avoids a spec re-amend.

## Scope estimate

| Component | LOC | Files |
|---|---|---|
| Migration 0022 — update trigger + DELETE + INSERT | ~50 (with header + verification queries) | 1 new |
| Spec note (optional) | ~5 | 1 modified |

**Total: ~50-55 LOC, 1 new migration, optionally 1 spec touch-up.** No app code changes.

After landing: kid picks "Personal Care" from the dropdown → matches lowercase against the seeded "Personal Care" → bypass fires → item goes to main list (not wishlist). The Batch 5a behavior works as intended.

## Notable side observation

The 2-place duplication of the category list (shopping_list_screen.dart's 4-5 maps + shopping_category_screen.dart's `_defaultCategories`) is a maintenance hazard — adding a new category requires touching 6+ places. Worth flagging as a polish followup (extract to `apps/mobile/lib/constants/shopping_categories.dart` with a single source of truth). Not blocking; not in this fix's scope.

## Read-only constraint honored

No code, no migrations, no commits. Only this audit file written.
