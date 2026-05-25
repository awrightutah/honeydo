# Kid Permissions Batch 5 — Investigation

Date: 2026-05-25
Branch: `feat/kid-perms-wishlist-2026-05-25` (read-only investigation; no edits, no commits)
Base: built on `2dc1ce9` (v0.3.0-kid-chore-photo tag — Batches 1-4 + merged spec amendment all in tree)
Status: investigation complete — **2 architectural gaps surfaced**; **no hard blockers**; 13 open questions.

## Summary

Schema (migration 0016) and the `add_shopping_item` RPC (migration 0017) are both shipped and architecturally sound for the Batch 5 happy path: kid taps Add → RPC routes to wishlist unless category is a household necessity. Adults' direct INSERT path is correctly gated by RLS (`is_wishlist=false AND kind='adult_auth_user'`).

But two real gaps surfaced that the spec didn't predict at Batch 1/2 design time:

**Gap 1 — RPC parameter set is narrower than the direct-INSERT path.** Three columns the app currently writes are NOT accepted by `add_shopping_item`: `source_recipe_id`, `source_meal_plan_id`, `display_quantity`. Adults will continue writing all three (direct INSERT). Kids using the RPC will lose this lineage. Affects sites 2, 3, 4 (recipe ingredients → shopping list). **Recommend migration 0021 amending the RPC to accept these as optional params.** Surfaced as Q1 below.

**Gap 2 — RLS on `shopping_items` UPDATE is permissive (any household member, including kids).** That means a kid could flip `is_wishlist=false` on their own wishlist row and self-approve. UI doesn't expose this today but it's a real defense-in-depth hole. **Recommend either tightening UPDATE policy with a column-level guard OR adding an `approve_wishlist_item` SECURITY DEFINER RPC.** Surfaced as Q2 below.

Beyond the two gaps, the rest of Batch 5 is straightforward: 4 insert-site branches, a new Pending Wishlist section (recommend Option A: same dashboard), and a new Necessity Categories screen accessed from Settings.

**Estimated scope (with Gap 1 + 2 RPC fixes)**: ~500-600 LOC across 1 new migration (0021) + 4 modified screens + 1 new screen (necessity categories) + 1 new section in chore_dashboard. **Borderline for one batch**; recommend splitting: 5a = RPC migration + insert-site branches + approve/deny RPC; 5b = Pending Wishlist UI + Necessity Categories screen. Surfaced as Q11.

## Phase 1 — Schema and infrastructure audit

### 1a. Schema (migration 0016) — confirmed shipped

All 4 design items present:

- **`shopping_items.is_wishlist boolean NOT NULL DEFAULT false`** — confirmed (0016:128-129). Plus `approved_by_member_id uuid` and `approved_at timestamptz` (0016:130-131). Partial index `idx_shopping_items_wishlist ON (household_id, is_wishlist) WHERE is_wishlist = true` exists (0016:136-138).
- **`necessity_categories` table** with composite PK `(household_id, category)` — confirmed (0016:74-79).
- **Default seed trigger** — `seed_default_necessity_categories()` fires `AFTER INSERT ON households` and inserts the 4 defaults (Hygiene, School Supplies, Basic Groceries, Medication) via `ON CONFLICT DO NOTHING` (0016:89-108).
- **Backfill for existing households** — already ran for the Wrights at migration time (0016:115-119).
- **RLS enabled** on `necessity_categories` (0016:83).

⚠️ **Naming note**: the spec referenced `requested_by_member_id` and `requested_at` columns. The schema actually shipped `approved_by_member_id` and `approved_at` (records who APPROVED, not who requested). The "requested by" info is captured by `shopping_items.added_by_member_id` (existing pre-batch-1 column). Not a blocker; the spec's prediction wording was slightly off from the as-shipped column names.

### 1b. RPCs (migration 0017) — `add_shopping_item` confirmed shipped

Signature (0017:403-411):

```sql
CREATE OR REPLACE FUNCTION public.add_shopping_item(
  p_household_id     uuid,
  p_member_id        uuid,
  p_name             text,
  p_quantity         numeric DEFAULT NULL,
  p_unit             text    DEFAULT NULL,
  p_category         text    DEFAULT NULL,
  p_store_id         uuid    DEFAULT NULL,
  p_shopping_list_id uuid    DEFAULT NULL
) RETURNS uuid
```

SECURITY DEFINER + `SET search_path = public` (Pattern 1). REVOKE FROM PUBLIC, anon + GRANT TO authenticated at 0017:722, 729 (Pattern 3). All correct.

Validation chain (0017:425-489):
1. Item name required + trimmed
2. Calling JWT is a household member (`is_household_member(p_household_id)`)
3. `p_member_id` exists in the household + is_active
4. Shopping list resolves: passed-in (validated to belong to household) OR auto-resolves to the oldest active list
5. is_wishlist computed: kid + category NOT in necessity_categories → true; adult → always false
6. INSERT row with all those values

Handles **both kid AND adult callers** — the per-kind branching at step 5 means the RPC is the canonical entry point for either. The spec says adults can retain direct INSERT for simplicity (RLS allows), but the RPC works for adults too if a unified path is preferred.

🚨 **Gap 1 surfaced** — see Phase 2 below. RPC accepts 8 params; direct INSERT writes columns the RPC doesn't accept (`source_recipe_id`, `source_meal_plan_id`, `display_quantity`).

### 1c. RLS policies — partial gap

**shopping_items** (0017:837-869):

```sql
-- Anyone in household can SELECT
CREATE POLICY shopping_items_household_select
  ON public.shopping_items FOR SELECT
  USING (public.is_household_member(household_id));

-- Direct INSERT: adult-only AND is_wishlist=false
CREATE POLICY shopping_items_adult_direct_insert
  ON public.shopping_items FOR INSERT
  WITH CHECK (
    is_wishlist = false
    AND public.is_household_member(household_id)
    AND EXISTS (
      SELECT 1 FROM public.household_members hm
       WHERE hm.auth_user_id = auth.uid()
         AND hm.household_id = shopping_items.household_id
         AND hm.kind = 'adult_auth_user'
         AND hm.is_active = true
    )
  );

-- UPDATE: any household member (including kids!) — GAP 2
CREATE POLICY shopping_items_household_update
  ON public.shopping_items FOR UPDATE
  USING (public.is_household_member(household_id))
  WITH CHECK (public.is_household_member(household_id));

-- DELETE: admin-only
CREATE POLICY shopping_items_admin_delete
  ON public.shopping_items FOR DELETE
  USING (public.is_household_admin(household_id));
```

**necessity_categories** (0017:897-915): SELECT by any member; INSERT/UPDATE/DELETE admin-only. All correct.

🚨 **Gap 2 — shopping_items UPDATE is too permissive.** A kid could flip `is_wishlist=false` on their own wishlist row via a direct UPDATE call from their adult-parent's JWT session (since kids share their parent's JWT). The Batch 5 UI doesn't expose this affordance to kids, but defense-in-depth wants this tightened.

Two fix options (Q2):
- **Option 2A** (RLS tweak): rewrite `shopping_items_household_update` with column-level WITH CHECK that disallows setting `is_wishlist=false` unless admin. Postgres RLS doesn't support per-column WITH CHECK directly; would need a trigger or restructured policy.
- **Option 2B** (RPC): add `approve_wishlist_item(p_item_id) RETURNS void` SECURITY DEFINER RPC that validates admin + flips is_wishlist=false. Tighten the UPDATE policy to disallow direct flips. Matches the rest of the kid-perms workstream pattern.

Recommend **Option 2B** for consistency with the workstream.

### 1d. Verification — would migration 0016 / 0017 still apply cleanly?

Yes. Both shipped at v0.3.0-kid-chore-photo. No re-run needed for Batch 5.

## Phase 2 — Shopping insert site audit (the 4 sites)

### Site 1 — `shopping_list_screen.dart:805` (`_addItem` — manual add dialog)

```dart
await Supabase.instance.client.from('shopping_items').insert({
  'household_id': widget.householdId,
  'shopping_list_id': widget.shoppingListId,
  'name': name,
  'quantity': double.tryParse(quantity),
  'unit': unit.isEmpty ? null : unit,
  'display_quantity': displayQuantity,        // ⚠ not in RPC signature
  'store_id': _selectedStoreId,
  'category': _selectedCategory,
  'purchased': false,
  'added_by_member_id': widget.myMemberId,
});
```

**Current behavior**: direct INSERT with the active list ID + manual name/quantity/category from the form.
**Branch for kid**: call `add_shopping_item` RPC. Has `category` → necessity check works. ⚠ Loses `display_quantity` (the formatted "2 lbs" string the UI computes from quantity + unit). RPC would store `quantity` + `unit` separately; the display layer can re-compute.
**Branch for adult**: keep current direct INSERT (preserves `display_quantity`).
**Error surfacing**: current code uses `const SnackBar(content: Text('Could not add item. Please try again.'))` — generic, no `$e`. Per the Pass 2 standing rule, should add `debugPrint` + non-const SnackBar with `$e` interpolation when branching for kid path.

### Site 2 — `shopping_list_screen.dart:1081` (`_addIngredients` — add recipe ingredients in bulk)

```dart
final inserts = _selectedIngredients.map((ing) => {
  'household_id': widget.householdId,
  'shopping_list_id': widget.shoppingListId,
  'name': ing,
  'display_quantity': null,                   // ⚠ not in RPC
  'purchased': false,
  'source_recipe_id': _selectedRecipeId,      // ⚠ not in RPC
  'added_by_member_id': widget.myMemberId,
}).toList();

await Supabase.instance.client.from('shopping_items').insert(inserts);
```

**Current behavior**: bulk insert (one statement, N items).
**Branch for kid**: must become N RPC calls (one per ingredient). RPC doesn't batch.
**Lineage loss**: `source_recipe_id` is lost for kid inserts unless Gap 1 is fixed.
**Branch for adult**: keep bulk INSERT.
**Error surfacing**: same generic SnackBar pattern; needs upgrade for kid path.

### Site 3 — `meal_planner_screen.dart:712` (auto-populate shopping list when adding a meal plan)

```dart
final inserts = ingredients.map((ing) {
  final text = ing is String ? ing : (ing['raw']?.toString() ?? ing.toString());
  return {
    'household_id': widget.householdId,
    'shopping_list_id': shoppingListId,
    'name': text,
    'purchased': false,
    'source_recipe_id': _selectedRecipeId,    // ⚠ not in RPC
    'source_meal_plan_id': mealPlanId,         // ⚠ not in RPC
    'added_by_member_id': widget.myMemberId,
  };
}).toList();

await Supabase.instance.client.from('shopping_items').insert(inserts);
```

**Practical kid impact**: meal plan creation is admin-territory today (Batch 6 will add kid meal _request_ flow but kid still doesn't create plans directly). So **this site likely never fires for kids** in practice. However, if a kid could reach `meal_planner_screen` in the current build (no kind gate yet — that's Batch 7), they could trigger it.
**Recommendation**: branch for kid using RPC anyway (defense in depth). Loses both `source_recipe_id` AND `source_meal_plan_id` for kid inserts unless Gap 1 is fixed.
**Error surfacing**: existing `catch (_)` swallows errors as "non-critical" (line 715). Kid path needs proper surfacing — silently failing on a kid's wishlist add is bad UX.

### Site 4 — `recipe_detail_screen.dart:266` (add recipe ingredients from recipe detail)

```dart
for (final ing in ingredients) {
  // ... compute ingMap + parsedQuantity ...
  await Supabase.instance.client.from('shopping_items').insert({
    'household_id': _householdMember!['household_id'],
    'shopping_list_id': selectedListId,
    'name': ingMap['raw'] ?? ingMap['name'] ?? ing.toString(),
    'quantity': parsedQuantity,
    'display_quantity': ingMap['raw']?.toString(),  // ⚠ not in RPC
    'purchased': false,
  });
}
```

**Already a loop** (one INSERT per ingredient) — converting to RPC for kid is parity, not a regression.
**Lineage**: this site does NOT write `source_recipe_id` (interesting inconsistency vs sites 2 and 3). So only `display_quantity` is the concern.
**Notable**: no `added_by_member_id` is set. Direct INSERT works because the column is nullable. RPC would set it from `p_member_id`. Slight behavior difference: kid inserts via RPC get the kid as `added_by_member_id`; adult direct inserts here leave it null.
**Error surfacing**: already correct (line 281-284, uses `SnackBar(content: Text('Error adding to shopping list: $e'))`).

### Shared concerns across the 4 sites

- **Optimistic UI**: today's screens don't optimistically render the new item; they `Navigator.pop()` and the parent screen re-loads. For kid path: since the item goes to wishlist, the parent screen's main list (filtered to `is_wishlist=false`) won't show it. Kid sees "nothing changed" unless we surface a confirmation. Worth a positive SnackBar: "Added to wishlist; waiting for admin approval."
- **Necessity bypass message**: when the kid's category IS a necessity, the item appears immediately on the shared list. Surface: "Added to shopping list" (same as adult) — but should we tell the kid WHY their item bypassed the wishlist? Recommend no special message; the behavior matches "regular add."
- **Branching helper**: rather than duplicate `if (Permissions.isKid(_myMembership))` at 4 sites, consider extracting an `addShoppingItemForCurrentMember(...)` helper. Either in `Permissions` (wrong place — it's not pure auth logic) or a new `apps/mobile/lib/services/shopping_service.dart`. Surfaced as Q12.

## Phase 3 — Pending Wishlist UI location

### Current state

`chore_dashboard_screen.dart` has a "Pending Verification" section (admin-only) rendered conditionally when `_pendingVerification.isNotEmpty`. The current layout (lines 369-379 in the file post-4b):

```dart
if (isAdmin && _pendingVerification.isNotEmpty) ...[
  _SectionHeader(title: 'Pending Verification', count: totalVerification),
  const SizedBox(height: 8),
  ..._pendingVerification.map((chore) => _VerificationCard(...)),
  const SizedBox(height: 24),
],
```

Followed by the kid's own "My Chores" section.

### Three options

**Option A — Add a second admin section to chore_dashboard** (recommended for velocity)
- New "Pending Wishlist" section header + cards below the existing "Pending Verification" section.
- Same `_pendingWishlist` state field loaded alongside `_pendingVerification`.
- New `_WishlistCard` widget (parallel to `_VerificationCard`).
- Estimated ~80-100 LOC additional in chore_dashboard.
- **Pros**: ships sooner; existing dashboard infrastructure reused.
- **Cons**: `chore_dashboard` now shows non-chore content. Naming becomes slightly off. Long-term should be renamed to `home_screen` or `pending_requests_screen`.

**Option B — New `pending_requests_screen.dart` with tabbed sections**
- New screen accessible from the home dashboard ("Pending Requests" button + count badge).
- TabBar with Verification / Wishlist / (Batch 6: Meals) tabs.
- More architectural work but properly factored for Batch 6.
- ~200-250 LOC for the new screen + small dashboard entry-point.
- **Pros**: scales for Batch 6 cleanly; correct factoring.
- **Cons**: more LOC; navigation entry-point design needs thought.

**Option C — Add Pending Wishlist as admin section on shopping_list_screen**
- Pre-existing screen; contextually appropriate (wishlist IS shopping).
- Admin-only section at the top.
- ~60-80 LOC in shopping_list_screen.
- **Pros**: contextually grouped; minimal new code paths.
- **Cons**: kids would see an empty pinned area (or we hide via `isAdmin` gate which is fine). Splits admin pending-requests across two screens (chores in chore_dashboard, wishlist in shopping_list_screen, meals TBD) — eventually un-unifies.

### Recommendation

**Option A** for Batch 5. The eventual Pass-3 endpoint (unified Pending Requests dashboard, per the spec's Q-F resolution) is Option B's shape. But shipping Option B now means doing the navigation architecture in Batch 5 just to support 2 sections (verification + wishlist), when Batch 6 will need to revisit it anyway to add Meals. Defer the unification to a Pass-3 polish batch (or Batch 6) and ship Batch 5 with Option A's lightweight 2-section dashboard.

Surfaced as Q3.

## Phase 4 — Pending Wishlist card design

### Data per card

Confirmed columns available on a wishlist row (post-Batch-1 schema):
- `name` (text, not null)
- `category` (text, nullable)
- `quantity` (numeric, nullable) + `unit` (text, nullable)
- `display_quantity` (text, nullable) — for adult-added items only; kid-added items via the RPC won't have this
- `added_by_member_id` (uuid) — join to `household_members.display_name` to show "Requested by Randi"
- `created_at` (timestamp) — for "Requested 2h ago"

### Card layout proposal

```
┌────────────────────────────────────────────────────────────────┐
│  📦 Apples                                    2 lbs            │
│  Produce                                                       │
│  Requested by Randi · 2h ago                                   │
│                                                                │
│  [  Deny  ]                          [  Approve  ]             │
└────────────────────────────────────────────────────────────────┘
```

- Approve in `AppColors.grassGreen` (matches the chore Approve pattern).
- Deny in `AppColors.coral`, outlined (matches chore Reject).
- Tap card opens a detail/edit view? Or no tap interaction? Recommend **no tap** for Batch 5 (the card has enough info; no edit-while-pending need).

### Approve action

**Gap 2 + the choice of RPC vs direct UPDATE**:

If Q2 chooses Option 2B (new `approve_wishlist_item` RPC), the approve handler calls:
```dart
await Supabase.instance.client.rpc('approve_wishlist_item', params: {
  'p_item_id': itemId,
});
```

If Q2 chooses Option 2A (RLS tweak only), the approve handler does a direct UPDATE:
```dart
await Supabase.instance.client.from('shopping_items').update({
  'is_wishlist': false,
  'approved_by_member_id': _myMembership!['id'],
  'approved_at': DateTime.now().toIso8601String(),
}).eq('id', itemId);
```

Recommend Option 2B (RPC). The columns `approved_by_member_id` and `approved_at` are server-side concerns and the SECURITY DEFINER context makes it clean.

### Deny action — spec is silent; surfacing options

Three options (Q4):

**Option 4A — Hard delete** (simplest, recommended for Batch 5)
- `DELETE FROM shopping_items WHERE id = X`
- RLS allows admin DELETE (existing policy `shopping_items_admin_delete`)
- Pro: no schema changes. Item just disappears.
- Con: kid has no record they were denied. No "why."

**Option 4B — Add a status column** (heavier)
- New column `wishlist_status text CHECK (status IN ('pending', 'approved', 'denied'))` + `denied_reason text` + `denied_at`
- Migration 0021 (or 0022) needed.
- Pro: kid can see denied items in a "My recent requests" view (mirrors Batch 6's meal-request pattern).
- Con: significant schema addition; not in Batch 5 scope per spec.

**Option 4C — Deny with reason but hard-delete after** (compromise)
- Show a dialog asking for optional reason (mirrors chore reject-with-reason from Batch 4b).
- Reason is captured in an `analytics_events` row OR a future `wishlist_denials` audit table — but spec doesn't have this scaffolding.
- For Batch 5: skip the audit, just delete. Match Batch 4b's reject-reason dialog only if user wants symmetric UX.

Recommend **Option 4A** for Batch 5 minimum-viable. Surface 4B as a future addition if user requests kid-side visibility of denied items.

### Should kid see denied items?

Per Q5: today, no — Option 4A hard-deletes. If we want this UX, the cleanest path is Option 4B's status column. Out of scope for Batch 5 unless user picks 4B.

## Phase 5 — Necessity Categories screen

### Schema confirmation

Table: `necessity_categories(household_id uuid, category text, created_at timestamptz)` with composite PK and CASCADE on household delete.

RLS:
- SELECT: any household member can read (kids need to know what's a necessity)
- INSERT/UPDATE/DELETE: admin-only

The 4 defaults are seeded per household via trigger; legacy households were backfilled.

### Screen design

New file: `apps/mobile/lib/screens/necessity_categories_screen.dart` (~150 LOC).

```
┌─ Necessity Categories ─────────────────────────────────┐
│                                                        │
│  Items in these categories skip the wishlist for kids  │
│  and add directly to the shared shopping list.         │
│                                                        │
│  ┌──────────────────────────────────────────┐ [×]      │
│  │ Hygiene                                  │          │
│  └──────────────────────────────────────────┘          │
│  ┌──────────────────────────────────────────┐ [×]      │
│  │ School Supplies                          │          │
│  └──────────────────────────────────────────┘          │
│  ┌──────────────────────────────────────────┐ [×]      │
│  │ Basic Groceries                          │          │
│  └──────────────────────────────────────────┘          │
│  ┌──────────────────────────────────────────┐ [×]      │
│  │ Medication                               │          │
│  └──────────────────────────────────────────┘          │
│                                                        │
│  [ + Add Category ]                                    │
│                                                        │
└────────────────────────────────────────────────────────┘
```

Each row: ListTile with the category text + IconButton(delete) trailing.

Add button → AlertDialog with a TextField; on Save, INSERT `(household_id, category)`. Composite PK + ON CONFLICT DO NOTHING handles dup attempts.

Editing in place? Composite PK means an edit is really delete-then-insert. **Recommend no inline edit for Batch 5**; delete + re-add is fine.

### Where the screen lives in the app

Currently `apps/mobile/lib/screens/` has settings_screen.dart and household-related screens. Need to add a navigation entry point:

**Option 5A** — From settings_screen as a `ListTile` "Necessity Categories" (admin-only, gated by `Permissions.canManageNecessityCategories`).
**Option 5B** — From shopping_list_screen as a top-right `IconButton` (admin-only).
**Option 5C** — From a new "Household Admin" hub screen (no such hub exists yet — would create one).

Recommend **Option 5A** (settings_screen). Aligns with how household-level admin config typically lives. Settings_screen already gates other admin sections.

Surfaced as Q6.

### Category name constraints

- Free text per the schema (no CHECK). Pro: flexibility. Con: typos / duplicate-meaning entries ("Hygeine" vs "Hygiene"; "Meds" vs "Medication").
- Could autocomplete from existing categories on `shopping_items.category`. Out of scope for Batch 5.

Surfaced as Q7.

### What happens when a category is deleted?

Existing `shopping_items` rows with that category text stay — only the necessity bypass disappears. Future kid inserts with that category will route to wishlist instead of bypassing.

Existing wishlist items with that category stay in wishlist (no auto-approval). Existing approved items stay approved (no demotion). Worth a one-line confirmation modal: "Delete 'X' from necessities? Existing items with this category aren't affected."

## Phase 6 — Kid flow UX

### Happy path (kid adds an item NOT in a necessity category)

1. Kid opens shopping list (sees household items, all `is_wishlist=false`)
2. Kid taps Add → fills name/quantity/category → Save
3. App calls `add_shopping_item` RPC with kid's member_id
4. RPC sets `is_wishlist=true` (category not in necessities)
5. App pops the dialog. SnackBar: **"Added to wishlist — waiting for approval"**
6. Kid sees... nothing new on the main list (filtered to is_wishlist=false). Confirmation message is essential.

### Necessity-bypass path (kid adds an item IN a necessity category)

1. Same flow as above
2. RPC sets `is_wishlist=false` (category matched a necessity)
3. Item appears immediately on the shared list
4. SnackBar: **"Added to shopping list"** (no special "necessity bypass" callout — keeps the UX simple)

### Adult path (unchanged)

1. Adult opens shopping list
2. Adult taps Add → Save
3. App uses direct INSERT (preserves all fields including `display_quantity`)
4. Item appears immediately

### Should there be a kid-side "My Pending Wishlist" view?

Worth considering: kid sees their own pending wishlist items somewhere (e.g., a section in shopping_list_screen). Allows kid to track what they've requested and what's been approved/denied.

Recommend **deferring** for Batch 5 — adds significant LOC. Surface as future polish. Q8.

### Optimistic UI on kid's add

Today the screens just Navigator.pop on success and parent reloads. Same shape works fine here. No optimistic UI needed in Batch 5.

## Phase 7 — Scope estimate

### With Gap 1 fix (RPC amendment) + Gap 2 fix (approve_wishlist_item RPC) + minimal-viable Batch 5

| Component | Files | LOC | Complexity |
|---|---|---|---|
| Migration 0021 — `add_shopping_item` amend (3 new optional params: `p_source_recipe_id`, `p_source_meal_plan_id`, `p_display_quantity`) + new `approve_wishlist_item(p_item_id)` RPC + RLS tightening for `shopping_items` UPDATE | new `.sql` | +120 | Medium (CREATE OR REPLACE + new function + policy rewrite) |
| Insert site 1 — shopping_list_screen `_addItem` | mod | +20 | Low (kid branch) |
| Insert site 2 — shopping_list_screen `_addIngredients` (loop conversion) | mod | +25 | Low-Medium (N round-trips for kid, error surfacing) |
| Insert site 3 — meal_planner_screen | mod | +25 | Low (defense-in-depth) |
| Insert site 4 — recipe_detail_screen | mod | +20 | Low (already in a loop) |
| Pending Wishlist section in chore_dashboard | mod | +100 | Medium (new `_pendingWishlist` state, query, `_WishlistCard` widget, approve/deny handlers) |
| Approve dialog/handler (calls `approve_wishlist_item` RPC) | inline in dashboard | +20 | Low |
| Deny handler (DELETE; Option 4A) | inline in dashboard | +30 | Low (confirmation dialog) |
| Necessity Categories screen (new file) | new | +180 | Medium (CRUD + add dialog + delete confirmation + load-on-init) |
| Settings entry point | mod settings_screen | +15 | Low |

**Total: ~555 LOC, 1 new migration + 1 new screen + 5 modified files.**

### Single-batch vs split

**Recommend split**:
- **Batch 5a — Backend + insert sites** (~210 LOC). Migration 0021 + 4 insert-site branches. Self-contained backend work; kid flow shifts to RPC-with-correct-fields; adults unchanged. UI for admin to manage wishlist comes in 5b.
- **Batch 5b — Admin UI** (~345 LOC). Pending Wishlist section on dashboard + Necessity Categories screen + Settings entry. UI-heavy half.

The two halves are clean to split: 5a delivers correct kid behavior (wishlist routing works server-side, items just sit pending until 5b ships the approve UI). Between 5a and 5b, admins could approve wishlist items via direct SQL or by waiting — neither is great UX, so 5b should follow 5a quickly.

Alternatively, single Batch 5 at ~555 LOC is borderline but doable in one push if user wants velocity. Surfaced as Q11.

## Phase 8 — Open questions

### Architecture (consequential)

**Q1. Gap 1 — RPC parameter set.** Recommend: amend `add_shopping_item` to accept `p_source_recipe_id`, `p_source_meal_plan_id`, `p_display_quantity` as optional params. Migration 0021. Avoids data asymmetry between kid (RPC) and adult (direct INSERT) writes. Alternative: accept the lineage loss for kid inserts since meal-planner/recipe-detail are mostly admin-driven flows today.

**Q2. Gap 2 — `shopping_items` UPDATE permissiveness.** Recommend: add `approve_wishlist_item(p_item_id) RETURNS void` RPC + tighten UPDATE policy to disallow direct `is_wishlist=false` writes by non-admins. Same migration 0021. Alternative: leave RLS as-is and rely on UI gating (Option 2A) — but defense-in-depth wants the RPC.

**Q3. Pending Wishlist UI location.** Options A/B/C from Phase 3. Recommend **A** (same dashboard, second section).

**Q4. Deny wishlist UX.** Options 4A (hard delete; recommended), 4B (status column + soft delete), 4C (delete with reason captured elsewhere).

**Q5. Kid sees denied items?** Recommend **no** for Batch 5 (couples with 4A hard-delete). If yes, must pick 4B.

**Q6. Necessity Categories screen entry point.** Recommend **5A (Settings)**. Alternatives: shopping_list_screen header or new admin hub.

**Q7. Category name constraints.** Recommend free text; flag autocomplete-from-history as future polish.

**Q8. Kid-side "My Pending Wishlist" view.** Recommend defer.

**Q9. Approve/Deny copy.**
- Approve confirmation message: "Added '$name' to shopping list" or no SnackBar at all? Recommend SnackBar (provides feedback).
- Deny confirmation modal: "Deny '$name'? This will remove the item." Recommend yes-confirm to avoid accidental deletion.

**Q10. Branching helper.** Should we extract `addShoppingItemForCurrentMember(...)` to a new `apps/mobile/lib/services/shopping_service.dart`, or duplicate the 4-line if/else at the 4 insert sites? Recommend **duplicate inline** for Batch 5 (cleaner diff; extract later if shopping logic grows).

**Q11. Single Batch 5 or split into 5a + 5b?** Recommend split (5a backend, 5b UI). Single ~555 LOC is doable but borderline.

### UX (smaller)

**Q12. Optimistic UI on kid's add?** Recommend no (parent screen reloads is fine).

**Q13. Naming wart for chore_dashboard becoming a multi-section hub.** Should we rename to `home_dashboard_screen` or leave as-is for Batch 5? Recommend leave; rename in a Pass-3 polish pass.

## Next steps

1. **Answer Q1-Q13.** Q1-Q4 are the architecture choices; Q5-Q13 are UX defaults with recommendations.
2. **Approve single-Batch-5 vs split.**
3. **I write Batch 5** (single OR 5a-first) — migration 0021 + Dart changes. Analyzer baseline before/after, 0 net new errors expected (likely +2-4 info on new `.rpc()` calls).
4. **Commit + push.**
5. **iPhone smoke-test**:
   - Adult adds an item via shopping_list → appears immediately on shared list
   - Kid (Randi) adds non-necessity item → SnackBar "Added to wishlist"; admin sees on dashboard pending; approve → item moves to shared list
   - Kid adds Hygiene item (necessity) → appears immediately on shared list
   - Admin denies a wishlist item → item disappears; confirmation modal works
   - Admin opens Settings → Necessity Categories → add new category → delete a default → confirm
   - Verify Gap 2 fix: try a direct UPDATE on a wishlist row as a non-admin (via SQL) — should fail post-migration 0021

After Batch 5, Pass 3 remaining: Batches 6 (meal requests + push), 7 (UI hardening), 8 (music deep link).

## Pattern notes

- Migration 0021 will use Pattern 1 (`SECURITY DEFINER` + `SET search_path = public`) and Pattern 3 (`REVOKE FROM PUBLIC, anon` + `GRANT EXECUTE TO authenticated`) on both the amended `add_shopping_item` and the new `approve_wishlist_item`. Pattern 2 doesn't apply (no pgcrypto, no overloaded function calls).
- All error surfacing across the 4 insert sites + the new dashboard handlers must follow `catch (e) → debugPrint → non-const SnackBar with $e` per Pass 2's PIN debugging lesson. Site 1 and site 2 currently have generic SnackBars without `$e` — those need upgrading as part of the branching.
- Site 3's `catch (_)` (line 715) silently swallows errors as "non-critical." For the kid path that's wrong UX. Either upgrade the catch OR keep silent only for adults.
