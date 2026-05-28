# Recipe Surface Audit — Full Build Map for Shared Library (Path 2) — 2026-05-28

## Purpose

Complete read-only map of the recipe surface end-to-end (import → household storage → shared catalog → submission → moderation → clone), to serve as the build map for the shared-library vision. Extends:

- `audits/2026-05-27-recipe-code-inventory.md` — recipe code sweep
- `audits/2026-05-28-admin-surface-audit.md` — moderation pipeline + ADMIN_SECRET bug

No code changes. State at capture: `main @ 4b23be3`, working tree clean.

> ⚠ **Correction to yesterday's Phase A audit:** Phase A said "Clone-to-household + counter: UNUSED — RPC defined but never called." That was wrong. Today's read of `recipe_library_screen.dart:254-280` confirms `_addToHousehold(masterRecipe)` is fully wired — it INSERTs the clone with `source='master_library'` AND calls `increment_master_recipe_added_count` RPC. The Browse Library tab's "+" button at line 1467 calls it. This audit takes precedence on that point.

---

## The two-table data model

Two recipe tables, both from migration 0001, both with nutrition columns added in 0007.

### `master_recipes` — global shared catalog

```
id uuid PK
title, description, ingredients(jsonb), steps(jsonb), prep/cook time,
servings, difficulty, cuisine, tags(jsonb), image_url, source_url
submitted_by_user_id uuid → profiles
status moderation_status NOT NULL DEFAULT 'pending'
rejection_reason, approved_at, approved_by_user_id
average_rating numeric(3,2) DEFAULT 0
rating_count integer DEFAULT 0
added_count integer DEFAULT 0
created_at, updated_at
+ 4 nutrition cols from 0007
```

Indexes: `idx_master_recipes_status_rating (status, average_rating desc)` — built for the Browse Library "show top approved" query.

### `household_recipes` — per-household instances

```
id uuid PK
household_id uuid → households (CASCADE)
master_recipe_id uuid → master_recipes (SET NULL)   ← back-link to origin
title, description, ingredients, steps, ...           ← full copy, not just FK
image_url, source_url
source recipe_source NOT NULL DEFAULT 'manual'        ← enum: manual|imported_url|master_library
is_favorite boolean DEFAULT false
created_by_member_id uuid → household_members
created_at, updated_at
+ 4 nutrition cols from 0007
```

### The relationship: clone-with-back-link

A household recipe is a **full data copy** (title/ingredients/steps/etc. duplicated), with an **optional FK back to its master origin** (`master_recipe_id`) and a `source` enum recording how it got there:

| source value | Means | master_recipe_id |
|---|---|---|
| `manual` | user typed it in | NULL |
| `imported_url` | scraped via Railway `/recipes/import` | NULL |
| `master_library` | cloned from `master_recipes` | populated |

The back-link is `ON DELETE SET NULL`, so master deletions don't cascade to household copies. The household copy survives the catalog being curated. Households can edit their copy freely (RLS allows full CRUD on `household_recipes`); divergence from the master is the default.

`meal_plans.recipe_id` and `meal_requests.recipe_id` both FK to `household_recipes` only — `master_recipes` is browse-only until cloned. `shopping_items.source_recipe_id` also FKs `household_recipes`.

---

## RLS posture

| Table | Policy | Allows |
|---|---|---|
| `master_recipes` | `master_recipes_approved_read` (SELECT) | anyone authenticated can read rows where `status='approved'` OR they submitted the row |
| `master_recipes` | `master_recipes_submit` (INSERT) | any authenticated user — `with check (auth.uid() is not null)` |
| `master_recipes` | UPDATE/DELETE | no policy → blocked except for service-role (Railway admin endpoints) |
| `master_recipe_ratings` | `master_recipe_ratings_user_all` (ALL) | users CRUD their own ratings, `user_id = auth.uid()` |
| `household_recipes` | `household_scoped_recipes` (ALL) | any member of the household via `is_household_member(household_id)` |

**Posture is sound for a shared catalog:**
- Anyone with an account can submit (becomes pending)
- Only service-role can flip status (gated by Railway admin endpoints)
- Approved rows are publicly readable; pending/rejected are visible only to the submitter
- Per-household CRUD is unrestricted within the household

---

## The recipe RPCs

| RPC | Defined in | What it does | Called from | Status |
|---|---|---|---|---|
| `get_recipe_image_url(uuid)` | 0003:193 | Finds the latest object in the `recipe-images` bucket for a recipe id, returns a public URL | **nowhere in app code** | ✗ unused |
| `increment_master_recipe_added_count(uuid)` | 0002:241 | `UPDATE master_recipes SET added_count = added_count + 1 WHERE id = ?` | `recipe_library_screen.dart:279` (during `_addToHousehold`) | ✓ working |
| `create_meal_request(...)` | 0017:525 | Kid-only insert into `meal_requests` | `meal_request_sheet.dart:99` | ✓ working |
| `decide_meal_request(...)` | 0017:604 | Admin approve/deny + auto-create meal_plans row | `approvals_screen.dart:303, 321` | ✓ working |

There are **no RPCs** for: submitting to the shared library, the moderation flow (uses direct UPDATE from Railway service-role), recipe deletion, or rating roll-up.

---

## The pipeline, stage by stage

### Stage 1 — Import (URL → parsed recipe object)

**Status: PRESENT but weak.**

- Flutter UI: "Import Recipe from URL" dialog at `recipe_library_screen.dart:340-407`. URL input, "Import" button.
- `_importRecipe(url)` at line 409 POSTs to `${API_URL}/recipes/import`.
- Backend: Railway `services/api/src/server.js:155` runs `importRecipeFromUrl(url)` — bare Node `fetch` with custom UA, `node-html-parser`, schema.org JSON-LD walker, normalizes to `{title, ingredients:[{raw}], steps, ...}`.
- Returns JSON to the Flutter app → `_showImportedRecipeSheet(imported)` opens a confirm sheet (line 456) for the user to edit/save.
- **Measured hit rate: 1/3** on the standard test set (datacenter IP, no proxy, no JS render). Documented in `2026-05-27-recipe-code-inventory.md` "Measured Railway service hit rate" section.

### Stage 2 — Save to `household_recipes`

**Status: PRESENT.**

Three insert sites in `recipe_library_screen.dart`, one per `source` enum value:
- Line 259, `source='master_library'`: clone from master (see Stage 5)
- Line 700, `source='imported_url'`: confirm sheet after Stage 1 import → INSERT
- Line 994, `source='manual'`: manual "Add Recipe" form → INSERT

All three INSERT directly (no RPC); household-scoped RLS allows it.

### Stage 3 — Submit `household_recipes` → `master_recipes` (the "share to shared library" action)

**Status: MISSING.**

Confirmed via grep across `apps/` and `services/`: **zero INSERTs into `master_recipes` anywhere in the codebase.** The RLS policy `master_recipes_submit` (INSERT) permits any authenticated user to do this, but no UI calls it.

The only `master_recipes` reference outside the admin pipeline is `recipe_library_screen.dart:124` (SELECT approved rows for the Browse Library tab).

A user with a household recipe they love has no path to push it into the shared catalog. The schema is ready (`submitted_by_user_id`, `status='pending'` default, `source_url` to record provenance), but the verb is unbuilt.

### Stage 4 — Moderate (approve/reject `master_recipes`)

**Status: BROKEN at the API layer; UI present but inert.**

From `2026-05-28-admin-surface-audit.md`:
- `apps/admin/` (vanilla HTML/JS) has a fully-built Recipe Moderation page that calls `GET /admin/recipes/pending` + `POST /admin/recipes/:id/approve|reject`.
- Backend handlers in `server.js:623-690` are correct in shape (SELECT pending, UPDATE status to approved/rejected with timestamp/reason).
- But `env.ADMIN_SECRET` is `undefined` due to a zod-schema gap in `env.js`, so every admin endpoint returns 403 to every caller. **The moderation UI exists but cannot reach its backend.**

Also: even on success, the approve handler doesn't write `approved_by_user_id` — column exists, never populated.

### Stage 5 — Browse approved master recipes + clone to household

**Status: PRESENT — both halves work.**

- **Browse:** Recipe Library has 3 tabs (`recipe_library_screen.dart:1068-1070`): "My Recipes" / "Browse Library" / "My Requests" (kid-only). The Browse Library tab queries `master_recipes WHERE status='approved'` ordered by `average_rating` desc (line 124), renders cards with rating, difficulty, cuisine chips, and a "+" button.
- **Clone:** "+" button → `_addToHousehold(masterRecipe)` (line 254): INSERTs a full copy into `household_recipes` with `source='master_library'` + `master_recipe_id` back-link, then calls `increment_master_recipe_added_count` RPC, then reloads.
- `master_recipe_ratings` table exists with RLS, but **no UI reads or writes ratings**. The rating display in the Browse Library card (`rating_count`, line 1431 area) renders whatever's on the master row; nothing updates it.

---

## What Path 2 requires building — the actual work list

Grouped by effort type.

### BUILD NEW

| Item | Where | Size estimate |
|---|---|---|
| **"Share to shared library" UI on household recipe detail** | `recipe_detail_screen.dart` — add a share button (admin-only? any household member?) opening a confirm sheet → INSERT into `master_recipes` with `submitted_by_user_id = auth.uid()`, `source_url` carried over, status defaults to `'pending'` | ~100 LOC |
| **Submission deduplication** | New: either client-side check against title+source_url before insert, or DB unique constraint. Without it, the same recipe can be submitted N times | ~30 LOC + maybe a migration |
| **Rating UI** | `recipe_detail_screen.dart` when viewing a master-cloned recipe — 5-star input, INSERTs/UPDATEs `master_recipe_ratings` | ~80 LOC |
| **Rating roll-up trigger** | New migration: trigger on `master_recipe_ratings` AFTER INSERT/UPDATE/DELETE that recomputes `master_recipes.average_rating` + `rating_count`. Currently no trigger does this; the columns sit at 0 forever | ~25 LOC SQL |
| **"My Submissions" view** | New tab or settings section showing the user's pending/rejected submissions with the rejection_reason — currently the data is readable by RLS but no UI surfaces it | ~150 LOC |

### WIRE UP EXISTING

| Item | Where | What's needed |
|---|---|---|
| **`get_recipe_image_url` RPC** | Defined but never called. Image lookups currently rely on the `image_url` column stored at INSERT. Decide whether to use the RPC or rip it out | small |
| **`approved_by_user_id` writeback** | `services/api/src/server.js:644` approve handler — add this field to the `.update({})` payload | 1 line |

### FIX BROKEN

| Item | Where | Fix |
|---|---|---|
| **`ADMIN_SECRET` zod-schema gap** | `services/api/src/env.js` — add `ADMIN_SECRET: z.string().min(1).optional()` (or required, depending on deploy preference) to the schema, and pass `process.env.ADMIN_SECRET` into `envSchema.parse({...})` | 2 lines, 1 file |
| **Confirm `ADMIN_SECRET` is set on Railway** | Railway dashboard, not the code | env-var op |
| **Mobile recipe_library URL-paste flow's Railway dependency** | `recipe_library_screen.dart:419` — POSTs to a fetcher that gets 1/3. Architecture decision says the in-app WebView path supersedes this. Replace or fall back | medium — depends on WebView Sub-batch A |
| **`data_export_screen.dart:161` reads `.from('recipes')`** | There is no `recipes` table — should be `household_recipes`. Either dead query (silently 404s) or unimplemented column rename | 1 line |

---

## Thinnest-real-version sequencing suggestion

A v1 shared library that actually exercises the pipeline end-to-end, in minimum-viable form:

1. **Fix `ADMIN_SECRET`** (2 lines, isolated, low risk). Verify with a real probe afterward. This unblocks Stage 4 without doing anything else.

2. **Build "Share to shared library" button** on `recipe_detail_screen.dart`. Permissioned to admin only initially (simpler RLS reasoning; Phase 1 households are family-scale). No dedup — first submission is fine. No image upload to master bucket; just carry `image_url` text. Single sheet, one INSERT.

3. **Verify the moderation loop end-to-end** by submitting one real recipe from Andrew's household, approving it via `apps/admin/`, then seeing it appear in Browse Library on a different household. This is the smoke test that validates Stage 3 + 4 + 5 work as a whole.

4. **Rating UI + roll-up trigger** as a separate batch. Skip until v1 has real cataloged content worth rating.

5. **Submission management UI ("My Submissions")** — defer until v1 has more than one submitter. With only Andrew submitting, the rejection_reason can be communicated out-of-band.

6. **Defer indefinitely:** `get_recipe_image_url` (likely dead), `data_export_screen.dart:161` (dead query), dedup constraints (deal with it when we see duplicates).

Critical sequencing constraint: **Stage 3 cannot ship before Stage 4 works**, because submissions land as `status='pending'` and remain invisible (RLS) until moderated. If we shipped Share without fixing ADMIN_SECRET, submitters would feel like their submissions vanished into a black hole.

---

## Open questions / decisions needed before building

1. **Who can submit to the shared library — admin only, any household member, kids included?** Affects the "Share" button's visibility predicate. Default suggestion: admin-only for v1 to keep moderation volume low.

2. **Copyright on scraped recipes.** If a user imports from `allrecipes.com` via the in-app WebView and then submits to the shared catalog, the household recipe carries `source_url`. The submission would too. **The shared catalog is effectively a redistribution of scraped third-party content.** Legal exposure unknown. Same exposure exists for the per-household import today, but the shared catalog amplifies it. Probably the single biggest non-engineering risk in Path 2.

3. **Moderation policy.** Approve criteria? Reject reasons (lists/canned vs free-text)? Who moderates — Andrew only, or eventual household-admin moderation roles? For v1, Andrew-only via the `apps/admin/` shell is fine.

4. **Dedup strategy.** Hash (title + ingredients) match? Same `source_url` match? Or do nothing v1 and clean up by hand if needed.

5. **Image storage for master recipes.** Master recipe rows currently carry an `image_url` text. If users submit recipes with hot-linked images, those break when the source goes 404. Storing images in our `recipe-images` bucket on submission is more durable but adds upload + bandwidth cost. For v1, accept hot-linked URLs with the known fragility.

6. **`master_recipe_ratings` quality bar.** Once any user can rate any approved recipe, ratings become a moderation signal of their own. v1 doesn't need this — defer the whole rating surface.

7. **`apps/admin-dashboard/` (React stub) — keep or retire?** The vanilla `apps/admin/` covers Recipe Moderation today; the React app is mock data only. Retiring it is one `git rm -rf apps/admin-dashboard/` + a root `package.json` script update. Worth a quick yes/no decision rather than letting it rot.
