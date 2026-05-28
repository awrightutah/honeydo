# Admin Surface Audit — Phase A (read-only) — 2026-05-28

## Purpose

First audit-and-adopt pass on the admin moderation surface discovered in the orientation sweep. Confirms or refutes the suspected `ADMIN_SECRET` config bug and maps how the moderation pipeline is supposed to work. **No fixes applied — diagnosis only.**

State at capture: `main @ 361c0d1`, working tree clean.

---

## `ADMIN_SECRET` bug — verdict: **CONFIRMED** (from static analysis)

### Evidence

1. **`services/api/src/env.js` declares a zod schema with exactly 7 keys.** `ADMIN_SECRET` is not among them:
   ```js
   const envSchema = z.object({
     NODE_ENV, PORT,
     SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY,
     AUTHORIZE_NET_API_LOGIN_ID,
     AUTHORIZE_NET_TRANSACTION_KEY,
     AUTHORIZE_NET_SIGNATURE_KEY,
   });
   ```

2. **The `envSchema.parse({...})` call's input object only passes those same 7 keys** — `ADMIN_SECRET` is never read from `process.env` into the parse input. zod returns an object containing only the declared/parsed keys.

3. **`server.js:7` imports `{ env }` exclusively** — it never references `process.env.ADMIN_SECRET` directly. All 6 references read `env.ADMIN_SECRET`.

4. **Runtime behavior:** `env.ADMIN_SECRET` is `undefined`. Every admin-secret check is one of:
   - `if (adminSecret !== env.ADMIN_SECRET)` — evaluates to `if (anyString !== undefined)` → always `true` → return 403
   - `const isSystemAdmin = adminSecret === env.ADMIN_SECRET` — evaluates to `anyString === undefined` → always `false`

5. **Even supplying the correct secret on Railway in `process.env.ADMIN_SECRET` doesn't help** — the value never flows through zod's parsed `env` object that `server.js` consumes. The Railway env var is effectively orphaned.

### One non-obvious nuance: `/admin/stats` is partially reachable

The `/admin/stats` handler (line 537) is the only admin endpoint that **doesn't fail-closed on the secret check**. It checks `isSystemAdmin === true OR caller has owner|admin role`. With the bug, `isSystemAdmin` is always `false`, so the endpoint falls through to the role check. **Any owner/admin of any household can reach `/admin/stats` with just their Bearer token** — secret not required. The other 5 admin endpoints (`/admin/households`, `/admin/recipes/pending`, `/admin/recipes/:id/approve`, `/admin/recipes/:id/reject`, `/admin/feedback`) gate solely on the broken secret check and are unreachable to any caller.

### Why no live test needed

The bug is mechanically inescapable from the code path: zod-parsed `env` cannot contain a key the schema doesn't declare. The Railway service is running this code (commit `8d98ff8`, last touched 2026-05-20, no subsequent edits). The verdict is structural, not empirical.

---

## Admin endpoint surface

| Path | Method | Handler does | Tables touched | Auth requirement (as coded) | Effective auth (with bug) |
|---|---|---|---|---|---|
| `/admin/stats` | GET | aggregates counts across households / members / chores / recipes / subscriptions | `household_members`, `households`, `chores`, `master_recipes`, `subscriptions` | Bearer + (secret OR owner/admin role) | **Reachable** by any owner/admin via Bearer alone |
| `/admin/households` | GET | list 100 most-recent households with member counts | `households` (+`household_members(count)`) | `x-admin-secret` | **Unreachable** (always 403) |
| `/admin/recipes/pending` | GET | list 50 most-recent `master_recipes` with `status='pending'` | `master_recipes` | `x-admin-secret` | **Unreachable** (always 403) |
| `/admin/recipes/:id/approve` | POST | UPDATE `master_recipes` SET `status='approved'`, `approved_at=now()` | `master_recipes` | `x-admin-secret` | **Unreachable** (always 403) |
| `/admin/recipes/:id/reject` | POST | UPDATE `master_recipes` SET `status='rejected'`, `rejection_reason=?` | `master_recipes` | `x-admin-secret` | **Unreachable** (always 403) |
| `/admin/feedback` | GET | list 100 most-recent feedback_requests | `feedback_requests` | `x-admin-secret` | **Unreachable** (always 403) |

`approved_by_user_id` column exists on `master_recipes` but is **not written** by the approve handler — the handler sets `status` + `approved_at` only. Either an oversight or deliberately deferred.

---

## The vanilla admin UI (`apps/admin/`)

Three files, all single-drop from `8d98ff8`:
- `index.html` — sidebar shell + login form + page templates
- `app.js` — 318 lines, all behavior
- `styles.css` — visual

### What it does

1. **Login page** (`handleLogin`, app.js:65): user enters email + password + admin secret. Calls Supabase `/auth/v1/token?grant_type=password` directly (the Supabase **publishable key is hardcoded in `app.js`** — fine, it's a public key by design). On success, stashes `authToken` in `sessionStorage['honeydo_auth_token']` and `adminSecret` in `sessionStorage['honeydo_admin_secret']`. Then `showDashboard()`.

2. **Dashboard** delegates to a per-page loader on navigation:
   - `overview` → `loadStats()` → `GET /admin/stats`
   - `households` → `loadHouseholds()` → `GET /admin/households`
   - `recipes` → `loadPendingRecipes()` → `GET /admin/recipes/pending`, renders cards with Approve/Reject buttons (call `POST /admin/recipes/:id/approve|reject`)
   - `feedback` → `loadFeedback()` → `GET /admin/feedback`
   - `settings` → local form for `apiUrl` + `supabaseUrl` (persisted to `localStorage`)

3. **`apiCall(endpoint)` helper** (app.js:132) sets both headers on every request:
   ```js
   'Authorization': `Bearer ${state.authToken}`,
   'x-admin-secret': state.adminSecret,
   ```

### Effective behavior given the bug

Login works. Token is acquired. `state.adminSecret` is stored. **But every `apiCall()` to a `/admin/*` endpoint other than `/admin/stats` will return 403.** The UI shows error states (the `loadStats()` and other loaders pessimistically render `—` or "Failed to load"). On Recipe Moderation specifically, the empty-state branch reads `if (!data.ok || !data.recipes?.length)` → renders the 🎉 "No pending recipes to review!" message — masking the 403 as "nothing to do."

`/admin/stats` partial reachability would let `loadStats()` render real numbers if the logged-in user is an owner/admin of any household. The rest of the pages render no data.

---

## The `master_recipes` moderation pipeline

### Data model

`master_recipes` (migration 0001:223) is the global shared library. Key columns for moderation:

| Column | Default | Set by |
|---|---|---|
| `status moderation_status` | `'pending'` | INSERT default; `/admin/recipes/:id/{approve,reject}` updates |
| `submitted_by_user_id` | NULL | (intended: the submitter at INSERT time; not enforced) |
| `rejection_reason text` | NULL | `/admin/recipes/:id/reject` writes from body |
| `approved_at timestamptz` | NULL | `/admin/recipes/:id/approve` writes `now()` |
| `approved_by_user_id` | NULL | **never written** (column exists, no code sets it) |
| `added_count integer` | 0 | `increment_master_recipe_added_count(p_recipe_id)` RPC (migration 0002:241) |
| `average_rating numeric` | 0 | (intended: trigger from `master_recipe_ratings`; not verified) |
| `rating_count integer` | 0 | (same) |

Enum: `moderation_status = (pending, approved, rejected)` — migration 0001:17.

### RLS

- `master_recipes_approved_read` (0001:541): public SELECT where `status='approved'` OR `submitted_by_user_id = auth.uid()`. So anyone authenticated can read approved recipes + their own pending/rejected ones.
- `master_recipes_submit` (0001:542): any authenticated user can INSERT.
- No RLS policy on UPDATE/DELETE → blocked for everyone except service-role (which the Railway admin endpoints use).

### Status lifecycle (as designed)

```
[no row]
    │ (someone INSERTs; status defaults to 'pending')
    ▼
[pending] ────POST /admin/recipes/:id/approve────▶ [approved]
    │
    └─────POST /admin/recipes/:id/reject─────────▶ [rejected]
                  (sets rejection_reason)
```

### What's actually wired

- **Schema:** ✓ complete
- **RLS:** ✓ submission policy allows any authed user
- **Approve/reject endpoints:** ✓ written, ✗ unreachable due to the bug
- **Admin UI:** ✓ buttons exist, ✗ calls 403
- **Submission write path:** ✗ **nowhere in the codebase INSERTs into `master_recipes`.** Grep finds only SELECT/UPDATE callers in both `apps/mobile/` and `services/api/`. The mobile recipe-library screen reads `master_recipes WHERE status='approved'` (`recipe_library_screen.dart:124`) — purely a viewer. No "Submit to shared library" button exists.
- **`increment_master_recipe_added_count` RPC:** ✓ defined, ✗ never called from any client code.

---

## How it's SUPPOSED to work end-to-end

Reading intent from the schema + RLS + admin UI:

1. A household member creates a recipe in their household (`household_recipes` INSERT — works today).
2. **Some currently-missing UI** would let them "submit to shared library" → INSERTs a copy into `master_recipes` with `status='pending'` and `submitted_by_user_id = auth.uid()`. The RLS policy is already permissive for this.
3. A system admin opens `apps/admin/` (or in the future, the React `apps/admin-dashboard/`) and navigates to Recipe Moderation. They see pending submissions via `GET /admin/recipes/pending`.
4. Admin clicks Approve or Reject. `POST /admin/recipes/:id/approve|reject` flips status.
5. Once approved, the recipe becomes globally visible via the `master_recipes_approved_read` RLS policy.
6. Households browsing the shared library see approved recipes (the mobile app already does this read).
7. When a household "adds" an approved master recipe, they copy it to their `household_recipes` with `source='master_library'` + `master_recipe_id` FK, and the `increment_master_recipe_added_count(id)` RPC bumps the counter on the master row.

Steps 1, 6 partially work. Steps 2, 3, 4, 5, 7 are non-functional (each for a different reason).

---

## What's confirmed working vs broken vs unverified

| Component | Status | Evidence |
|---|---|---|
| `master_recipes` table + nutrition columns | ✓ working | Migrations 0001, 0007 applied; mobile reads approved rows |
| `moderation_status` enum | ✓ working | Defined 0001:17 |
| RLS: anyone can SELECT approved | ✓ working | Policy 0001:541 |
| RLS: any authed user can INSERT | ✓ working | Policy 0001:542 |
| **Submission UI (mobile)** | ✗ missing | No INSERT into `master_recipes` anywhere in `apps/mobile/lib/` |
| **Backend admin endpoints (approve/reject/pending/households/feedback)** | ✗ broken | `ADMIN_SECRET` bug — always 403 |
| `/admin/stats` endpoint | ⚠ partial | Reachable via owner/admin role, but loaded by a broken UI page |
| Admin UI (`apps/admin/`) | ⚠ shell works, data calls broken | Login + nav functional; data fetches hit 403 |
| Admin UI (`apps/admin-dashboard/` React) | ✗ stub | Hardcoded mock data, no fetch calls |
| `master_recipes.approved_by_user_id` writeback | ✗ not implemented | Column exists, approve handler doesn't write it |
| `increment_master_recipe_added_count` RPC | ✓ defined, ✗ uncalled | Never invoked from any client |
| `master_recipe_ratings` table + RLS | ✓ defined, ✗ unused | No reads or writes in any app code |
| `average_rating`/`rating_count` rollup | ⚠ unverified | No trigger seen in scanned migrations; needs deeper look |

---

## Open questions for Phase B (live testing or deeper read)

1. **Is `process.env.ADMIN_SECRET` actually set on Railway?** Bug doesn't depend on it being set, but fix design does — if it's already set, the fix is a one-line zod schema addition; if not, we need to provision it first.
2. **Is there a trigger or function on `master_recipe_ratings` that updates `average_rating`/`rating_count`?** Needs a fuller migration scan or a `\d+` on the table.
3. **Was the submission UI ever started and reverted?** Worth a `git log -S "master_recipes" --all` to see if any branch ever had INSERT-side code.
4. **Are there any rows in `master_recipes` right now?** Phase B can query directly (service-role via the Supabase admin client). Determines whether the pipeline has ever been exercised in production.
5. **Does Railway's deployed code actually match `services/api/src/server.js` at `8d98ff8`?** No live test was performed; assumes the file in the repo is what's running. Reasonable assumption (Railway auto-deploys main, no edits to the file since), but worth confirming if/when Phase B test is run.
6. **Should we keep both admin frontends, or retire `apps/admin-dashboard/`?** It's a scaffold that's never going to do anything without a write-up of its own. Worth a separate decision pass.
