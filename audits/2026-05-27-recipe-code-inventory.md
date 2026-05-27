# Recipe Code Inventory (2026-05-27)

## Purpose

Snapshot of all recipe / meal / ingredient-related code in Honeydo as of 2026-05-27, prepping for the Phase 1 in-app WebView recipe-import workstream. The new import flow needs to land into existing recipe-adjacent code; this doc enumerates what's there.

Read-only inventory. No recommendations, no should-fix items — just "here's what's there."

State at capture: `main @ 75407ad`, working tree clean.

---

## Database layer

### Tables

All recipe/meal tables were introduced in `0001_initial_schema.sql` except `meal_requests` (added in `0016`). No tables have been added or renamed since.

#### `public.master_recipes` (0001:223)
Global / shared recipe library (currently unused by the app — see Observations). Columns of note:
```
id uuid PK
title text NOT NULL
description text
ingredients jsonb NOT NULL DEFAULT '[]'
steps jsonb NOT NULL DEFAULT '[]'
prep_time_minutes, cook_time_minutes, servings int
difficulty, cuisine text
tags jsonb
image_url, source_url text
submitted_by_user_id uuid → profiles
status moderation_status NOT NULL DEFAULT 'pending'  (enum: pending|approved|rejected)
rejection_reason text
approved_at, approved_by_user_id
average_rating numeric(3,2), rating_count int, added_count int
created_at, updated_at
```
Plus 4 nutrition columns from `0007_recipe_nutrition.sql`: `calories_per_serving int`, `protein_g numeric`, `carbs_g numeric`, `fat_g numeric`.

#### `public.master_recipe_ratings` (0001:249)
Per-user star rating for a master recipe. `(master_recipe_id, user_id)` unique. Unused by the app today.

#### `public.household_recipes` (0001:259)
Per-household recipe records. **This is the table the app actually reads/writes.** Same column shape as `master_recipes` plus:
```
household_id uuid → households (CASCADE)
master_recipe_id uuid → master_recipes (SET NULL)   -- nullable, links to master if imported
source recipe_source NOT NULL DEFAULT 'manual'      -- enum: manual|imported_url|master_library
is_favorite boolean DEFAULT false
created_by_member_id uuid → household_members
```
Same 4 nutrition columns from `0007`.

#### `public.meal_plans` (0001:282)
Calendar entry for "we're cooking X on date Y."
```
id, household_id, planned_for date, meal_type meal_type
recipe_id uuid → household_recipes (SET NULL)
custom_title text                       -- when no recipe linked
assigned_cook_member_id, servings, notes
created_by_member_id
created_at, updated_at
```

#### `public.meal_requests` (0016:156)
Kid-submitted "please make this recipe" requests.
```
id, household_id, requested_by_member_id → household_members
recipe_id uuid NOT NULL → household_recipes (CASCADE)
requested_for_date date, meal_type meal_type             -- both optional
status text NOT NULL DEFAULT 'pending'  CHECK in (pending,approved,denied)
decided_by_member_id, decided_at, decided_note text
created_at
```
Indexes: `(household_id, status)` and `(requested_by_member_id)`.

### Enums (0001:15-17)
- `meal_type = (breakfast, lunch, dinner, snack, other)`
- `recipe_source = (manual, imported_url, master_library)`
- `moderation_status = (pending, approved, rejected)` — `master_recipes.status` only

### RPCs

- **`get_recipe_image_url(recipe_id uuid)`** — `0003_storage_policies.sql:193`. Storage-bucket helper for the `recipe-images` bucket.
- **`create_meal_request(p_household_id, p_member_id, p_recipe_id, p_requested_for_date?, p_meal_type?)`** — `0017:525`. Kid-only insert path; SECURITY DEFINER. Validates caller is in household, member is a kid sub_profile, recipe exists in household. Returns the new request id.
- **`decide_meal_request(p_request_id, p_approved, p_note?, p_planned_for_override?, p_meal_type_override?)`** — `0017:604`. Admin-only. On approve, atomically inserts a matching `meal_plans` row. Returns `jsonb {status, meal_request_id, meal_plans_id}`.

No RPC for recipe creation/import — Flutter writes `household_recipes` directly via `.insert()`.

### RLS policies

- `household_recipes` — `household_scoped_recipes` (0001:530): full access to any household member via `is_household_member(household_id)`.
- `meal_plans` — `household_scoped_meal_plans` (0001:531): same shape.
- `master_recipes` — `master_recipes_approved_read` (0001:541, SELECT where status='approved' OR submitter); `master_recipes_submit` (0001:542, INSERT for any authed user).
- `master_recipe_ratings` — `master_recipe_ratings_user_all` (0001:543): users CRUD their own rows.
- `meal_requests` — 4 policies in `0017_kid_perms_rls_rpcs.sql:875-892`: household-scoped SELECT; INSERT blocked from clients (RPC-only); UPDATE/DELETE admin-only.

### Storage
- `recipe-images` bucket (`0003_storage_policies.sql:18-`): 5 MB limit, public read, authenticated upload, owner+admin update/delete.

---

## Flutter layer

No `models/`, `repositories/`, or `helpers/` directories exist. Screen files own their own data shapes — `household_recipes` rows flow around as `Map<String, dynamic>`.

### Screens

| File | Lines | Role |
|---|---|---|
| `apps/mobile/lib/screens/recipe_library_screen.dart` | 1699 | Recipe browse, create, **import from URL** (existing flow — see Observations), open detail. Kid-only "My Requests" tab (Batch 6b). |
| `apps/mobile/lib/screens/recipe_detail_screen.dart` | 1133 | View/edit a single household_recipe. Edit mode toggled via `_isEditing`. Ingredients held as `List<dynamic>` from the jsonb column. Hosts "Add to meal plan" + "Add ingredients to shopping list" actions. |
| `apps/mobile/lib/screens/meal_planner_screen.dart` | 925 | Weekly meal-plan grid. Reads `household_recipes` + `meal_plans`. `_AddMealPlanSheet` inserts a `meal_plans` row and optionally fans out ingredients via `add_shopping_item` RPC (kid) or direct `shopping_items` INSERT (adult). |

Other screens with read-only or peripheral recipe references:

| File | Touch points |
|---|---|
| `home_shell_screen.dart:55, 58` | Hosts `MealPlannerScreen` + `RecipeLibraryScreen` in the bottom NavigationBar (tabs "Meals" and "Recipes"). `_loadPendingTotal` at :136 queries `meal_requests` for the Approvals badge. |
| `approvals_screen.dart:149` | "Meal Requests" section — admin pending queue. Calls `decide_meal_request` RPC. |
| `activity_feed_screen.dart:178` | Queries decided `meal_requests` (status ≠ pending) for the feed. |
| `shopping_list_screen.dart:147` | Joins `household_recipes.title` when surfacing items added from a recipe. |
| `household_stats_screen.dart:77, 82` | Counts recipes + meal plans for the dashboard. |
| `data_export_screen.dart:155` | Exports `meal_plans` in the user's data dump. |
| `search_screen.dart:87, 330` | Searches `household_recipes`, pushes `RecipeDetailScreen`. |
| `onboarding_screen.dart`, `subscription_screen.dart`, `notification_preferences_screen.dart`, `household_setup_screen.dart`, `settings_screen.dart`, `shopping_category_screen.dart` | String references only ("recipes" copy in tour/marketing/preferences). |

### Widgets
- `apps/mobile/lib/widgets/meal_request_sheet.dart` (293 lines) — modal-bottom-sheet for kids to submit a `create_meal_request` RPC. Launched from `recipe_detail_screen.dart` and `recipe_library_screen.dart`.

### Services / utils
- `apps/mobile/lib/services/realtime_service.dart` — `mealRequestsVersion` ValueNotifier (line 25), Postgres-changes listeners on `meal_plans` (line 71) and `meal_requests` (line 149).
- `apps/mobile/lib/services/image_upload_service.dart:134-142` — `recipe-images` bucket upload helper.
- `apps/mobile/lib/services/feature_tour_service.dart:71-101` — Onboarding tour steps for "meals" and "recipes" tabs.
- `apps/mobile/lib/utils/permissions.dart:82` — Comment-only reference; no recipe-specific permission helpers (the generic `canDecideRequests` covers meal requests too).

No dedicated recipe service, model, or repository layer exists.

### Navigation surface

Bottom NavigationBar (`home_shell_screen.dart:266`):
```
Chores | Meals | Shop | Calendar | Recipes
```
The two recipe-adjacent tabs are **Meals** (`MealPlannerScreen`) and **Recipes** (`RecipeLibraryScreen`).

`RecipeDetailScreen` is pushed via `MaterialPageRoute` from three places:
- `meal_planner_screen.dart:459` (tapping a planned recipe)
- `recipe_library_screen.dart:1046` (tapping a recipe card)
- `search_screen.dart:330` (tapping a search hit)

`MealRequestSheet` is launched as a modal from `meal_request_sheet.dart:39` (helper function).

---

## Recent commit history (recipe-adjacent, last 60 days)

Newest first.

| Commit | Title | Area |
|---|---|---|
| `75407ad` | Merge spike: in-app Flutter WebView 4/4 (2026-05-27) | Spike |
| `013b531` | Merge spike: self-hosted Playwright 3/3 | Spike |
| `d95d99c` | Merge spike: ScraperAPI + Apify 1/4 | Spike |
| `1f80b9a` | Merge spike: recipe URL scraping comparison | Spike |
| `abb2c6b` | Batch 6b — meal request followups (kid My Requests tab, activity feed, realtime) | Feature |
| `5073c89` | Remove kid recipe-to-shopping bypass paths | Refactor |
| `3bb7e01` | Batch 6a — meal requests UI (kid submit + admin Approvals integration) | Feature |
| `a50fe00` | Batch 5a — wishlist backend (recipe-adjacent via shopping fanout) | Feature |
| `0a9684a` | Centralized active-member resolution for kid-aware screens (incl. recipe screens) | Fix |
| `4d78761` | recipe-detail: household_id + quantity sanitize on shopping insert | Fix |
| `aba41f3` | Batch-4 shopping list display + kid chore approval (recipe-detail quantity coercion) | Fix |
| Migrations | 0016, 0017, 0018, 0021 — kid-perms schema/RPCs/RLS touching meal_requests + recipe permissions | Backend |

---

## Notable observations

1. **An existing server-side URL-import flow is already wired into the app.** `recipe_library_screen.dart:419` calls `POST https://honeydo-production-743d.up.railway.app/recipes/import` (overridable via `dotenv.env['API_URL']`). It returns a JSON `recipe` object that `_showImportedRecipeSheet` (line 456) renders into a confirm sheet, then writes to `household_recipes` with `source='imported_url'` and `source_url=<original URL>`. Today's spike conclusion (in-app WebView) doesn't account for this pre-existing path. The Phase 1 work needs an explicit decision about how the WebView-based fetch relates to the Railway endpoint — replace, fall back to, or run in parallel.

2. **`master_recipes` exists in schema but is dead code in the app.** The table, its rating sub-table, RLS policies, and the `recipe_source = 'master_library'` enum value are all in place since 0001, but no Flutter `.from('master_recipes')` call exists outside `recipe_library_screen.dart:124` (which queries it for a UI panel). No write paths. The architecture-decision doc's "browse shared library (top priority)" path would land here.

3. **Ingredients are loosely-typed `jsonb`.** No schema enforcement on the array shape — `recipe_detail_screen.dart:124` reads `_recipe?['ingredients']` as `List<dynamic>`. Item shape is implicit (each item is a Map with whatever the import path produced). The Phase 1 parser output needs to agree with whatever this shape is or convert.

4. **No model layer.** Recipe rows flow as `Map<String, dynamic>` through every screen. Adding a `Recipe` model class would be greenfield; doing the WebView import without one means each screen continues to dot-walk the map.

5. **The `recipe_source` enum already has the `imported_url` value.** New URL-imported recipes via the WebView path can use it without a migration. The existing Railway-import flow also writes `'imported_url'`, so the source enum doesn't distinguish between fetch methods.

6. **`meal_requests.recipe_id` references `household_recipes`, not `master_recipes`.** Kids can only request something that's already in the household. If "browse shared library → request without copying" ever becomes a flow, this FK needs to widen.

7. **Realtime is wired for `meal_plans` + `meal_requests`, but not for `household_recipes`.** Multi-device recipe edits don't push live. Not blocking for Phase 1; just a gap to know about.

8. **No HTTP client elsewhere in the recipe path.** Outside the Railway import call, the recipe code paths use the Supabase client exclusively. Adding `webview_flutter` is a net-new dependency for this surface.

9. **`recipe-images` bucket is in place with permissive-read + auth-write policies.** Phase 1 can upload imported recipe images here without policy changes.

10. **The kid "My Requests" tab (Batch 6b) is conditional on `Permissions.isKid(membership)` and creates its TabController dynamically** (`recipe_library_screen.dart:48-86`). Any new tab added to this screen (e.g., a "Shared Library" tab) needs to coordinate with that resize pattern.

---

## Measured Railway service hit rate (2026-05-27)

After discovering that the Railway service exists, we POSTed the 3 known-good URLs from today's fetcher spike test set to `https://honeydo-production-743d.up.railway.app/recipes/import` to measure its actual success rate.

| URL | Upstream HTTP | Railway response | Result |
|---|---|---|---|
| Allrecipes | 402 (anti-bot wall) | 422 + `Failed to fetch recipe URL: 402` | FAIL |
| Food Network | 200 | 200 + parsed recipe (title, 18 ingredients, 5 steps, image, source_url) | SUCCESS |
| Damn Delicious | 403 (Cloudflare) | 422 + `Failed to fetch recipe URL: 403` | FAIL |

**Measured: 1/3 success rate.** Latencies 220-340ms — failures are instant upstream rejections, not Railway timeouts.

### Comparison to today's other fetchers (same 3 URLs)

| Fetcher | Score | Profile |
|---|---|---|
| Vanilla `requests` (baseline) | 0/3 | residential dev IP, no JS |
| **Railway `/recipes/import`** | **1/3** | **datacenter IP, no JS, no proxy** |
| ScraperAPI free, `render=true` | 1/3 | datacenter proxy pool, JS |
| Apify free, `web-scraper` | 1/3 | datacenter proxy pool, JS |
| Self-hosted Playwright | 3/3 | residential dev IP, JS |
| In-app Flutter WebView | 3/3 | residential phone IP, JS |

The Railway service sits in the bottom tier — same band as the free commercial scrapers, worse than either residential-IP option. Confirms today's spike finding that **proxy IP class is the dominant variable**.

### Failure mode is fetch, not parse

The schema.org JSON-LD parser layer (`node-html-parser` + `findRecipeJsonLd` + `normalizeRecipe`) works correctly — the Food Network success demonstrates this. The failure mode on Allrecipes and Damn Delicious is the upstream site refusing the fetch at the edge, before any HTML reaches the parser.

**Architectural implication:** if Phase 1 keeps the Railway service in any form (e.g., as a fallback for clients without WebView), the parser layer is reusable. Only the fetcher portion needs replacement (e.g., put a residential proxy in front of the Node `fetch()`, or proxy through ScraperAPI's `ultra_premium`).

If Phase 1 deprecates the Railway service entirely in favor of in-app WebView fetching, the parsing logic should still be ported (to Dart, or to a Supabase Edge Function) — it's working code, just on the wrong side of the fetcher.

---

## Pattern captured: look first, dig second

This inventory exists because today's four fetcher spikes were conducted as if recipe import were greenfield — and discovered, at the very end, that a Railway-hosted server-side `/recipes/import` endpoint and a full Flutter URL-paste UI were already in the repo. The Railway service was scaffolded by an AI tool (commit `8d98ff8` "Complete Honeydo app: Phases 1-18 full build" on 2026-05-20) and had not been surfaced to the developer in any handoff doc or roadmap.

The half-day of spike work was not wasted — the IP-class insight, the WebView measurement, and the failure-mode catalog are all portable findings that apply regardless of what the Railway service does. But the *positioning* of today's architecture decision doc as "Phase 1 next major work" needs amendment (Day 6 task) to acknowledge that pre-existing import code exists and to decide how it relates to the in-app WebView path.

**Pattern for future investigations:**

> Always do a code inventory before starting an investigation that assumes greenfield. When a roadmap doc or handoff says "X is the next major work," verify that X doesn't already exist (even partially, even scaffolded by a prior AI tool, even forgotten about) before designing it from scratch. A 10-minute `grep + find + git log` sweep at the start of an investigation can save a half-day of work done against the wrong assumption.

This pattern joins the standing patterns list in `audits/2026-05-26-roadmap-handoff.md` (or whatever the next roadmap doc supersedes it).
