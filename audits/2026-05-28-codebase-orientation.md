# Codebase Orientation Map (2026-05-28)

## Purpose

Read-only inventory of the entire Honeydo repo, prompted by yesterday's accidental discovery of the `services/api` Railway backend. Goal: know what exists — especially AI-scaffolded code we haven't discussed — **before** designing Phase 1 features that may already be partially built.

State at capture: `main @ ab85d79`, working tree clean (this doc is the only untracked file).

---

## Repo at a glance

```
honeydo/
├── apps/
│   ├── mobile/          Flutter — the app we know
│   ├── admin/           Vanilla HTML/JS admin (functional, talks to Railway /admin/*)
│   └── admin-dashboard/ React/Vite admin (scaffold only, hardcoded mock data)
├── services/
│   └── api/             Node/Express on Railway (~13 endpoints across 5 domains)
├── supabase/
│   └── migrations/      21 SQL files, 33 tables, 29 RPCs
├── spike/               Today's & yesterday's research spikes
├── audits/              79 audit docs accumulated across the project
├── docs/                CLAUDE_CODE_HANDOFF.md + product-spec.md + setup-guide.md
├── scripts/             check-project.sh
├── package.json         monorepo root (scripts: install:api, start, dev:api, build:admin, check)
└── railway.json         Railway deploy config → services/api
```

Root `package.json` is a thin monorepo — npm scripts that proxy to `services/api` (start the Railway server) and `apps/admin-dashboard` (build the React app). No workspaces. Flutter app is outside this surface.

Top-level legacy artifacts: `audit.md`, `audit_report.md` (dated 2025-05-21 / 2026-05-21 — early-project honesty audits from before this conversation history), `todo.md`.

---

## Apps

### `apps/mobile` (known territory)

| Dim | Value |
|---|---|
| Stack | Flutter 3.44 / Dart 3.12, Supabase client |
| Identity | `pubspec.yaml: name: honeydo_mobile` |
| Source files | 57 `.dart` files |
| Top-level lib dirs | `screens/`, `services/`, `widgets/`, `utils/`, `shared/`, `theme/` |
| Screen count | 32 in `lib/screens/` |
| Last meaningful activity | 2026-05-26 (Batch 7b-iii: active-member AppBar indicator) |

Screens list (alphabetical, 32 total):
```
achievements, activity_feed, announcements, approvals, auth, calendar,
chore_dashboard, chore_detail, chore_templates, data_export, feedback,
home_shell, household_setup, household_stats, invite_management,
meal_planner, member_profile, members, necessity_categories,
notification_preferences, onboarding, point_history, profile,
recipe_detail, recipe_library, rewards, search, settings,
shopping_category, shopping_list, splash, subscription
```

Yesterday's recipe-code-inventory covers the recipe-adjacent slice in depth.

### `apps/admin` ⚠️ **previously unknown**

| Dim | Value |
|---|---|
| Stack | **Vanilla HTML + CSS + JS** (no framework, no build step) |
| Source files | `index.html` + `app.js` (318 lines) + `styles.css` |
| Last commit touching it | `8d98ff8` (2026-05-20, single AI-scaffolded drop — same commit as `services/api`) |
| **Status** | **Functional** — wires to Railway `/admin/*` endpoints with real auth |

Sidebar navigation (from `index.html`):
```
📊 Overview      🏠 Households      🍳 Recipe Moderation
💬 Feedback      ⚙️ Settings
```

What it talks to (from `app.js`):
- Auth: Supabase `/auth/v1/token?grant_type=password` (hardcoded publishable key in source)
- API base: `https://honeydo-production-743d.up.railway.app` (overridable via localStorage)
- Endpoints called: `/admin/stats`, `/admin/households`, `/admin/recipes/pending`, `/admin/recipes/:id/approve|reject`, `/admin/feedback`
- Auth header pattern: `Authorization: Bearer <supabase token>` + `x-admin-secret: <secret>`
- Admin secret persisted in `sessionStorage`

**A complete recipe-moderation pipeline already exists here** — UI to view pending master_recipe submissions and approve/reject them. The `master_recipes` table that yesterday's inventory called "dead code in the mobile app" has a fully-built admin moderation UI here.

### `apps/admin-dashboard` ⚠️ **previously unknown — but it's a stub**

| Dim | Value |
|---|---|
| Stack | React 18 + Vite + Lucide icons + Recharts |
| Source files | `App.jsx` (150 lines) + `styles.css` (151 lines) — that's it |
| Last commit touching it | `8d98ff8` (same AI-scaffolded drop) |
| **Status** | **Stub** — pure UI, no API calls, hardcoded mock data |

Header note in `App.jsx`: *"Admin dashboard shell connected to Supabase in the next milestone."* — the "next milestone" never happened. Stat values are placeholders (24, 7, 13); the Recipe Moderation section shows three fictional recipes ("Mom's Famous Lasagna", "Quick Microwave Mug Cake", "One-Pan Honey Garlic Shrimp"). The only URL referenced in the entire source tree is `/admin/member` (in a string, not a fetch call).

Sidebar shape is broader than the vanilla one — adds: Chores, Meals & Shopping, Calendar Tags, Analytics, Audit Trail. So this was scaffolded as the *aspirational* admin frontend; the vanilla `apps/admin` is the *working* version.

Both admin frontends have `<script src="https://sites.super.myninja.ai/_assets/ninja-daytona-script.js">` in their HTML — a tracking script from MyNinja AI, the tool that scaffolded this project. Worth noting; probably harmless.

---

## `services/api` (Railway backend, Node 20 / Express)

Source tree:
```
services/api/src/
├── server.js          705 lines, all endpoints + landing page
├── env.js             zod schema for required env vars
└── supabaseAdmin.js   service-role client
```

Full endpoint surface (13 routes):

| Domain | Method | Path | Auth |
|---|---|---|---|
| Meta | GET | `/` | none (landing HTML) |
| Meta | GET | `/health` | none |
| **Recipes** | POST | `/recipes/import` | none |
| Households | POST | `/households` | Bearer token |
| Households | POST | `/households/:id/invites` | Bearer token + admin role |
| Households | POST | `/households/join` | Bearer token |
| Households | GET | `/households/mine` | Bearer token |
| Webhooks | POST | `/webhooks/authorize-net` | HMAC signature |
| Jobs | POST | `/jobs/send-notifications` | none (placeholder, TODO) |
| Admin | GET | `/admin/stats` | x-admin-secret OR owner/admin role |
| Admin | GET | `/admin/households` | x-admin-secret |
| Admin | GET | `/admin/recipes/pending` | x-admin-secret |
| Admin | POST | `/admin/recipes/:id/approve` | x-admin-secret |
| Admin | POST | `/admin/recipes/:id/reject` | x-admin-secret |
| Admin | GET | `/admin/feedback` | x-admin-secret |

Required env (from `env.js` zod schema):
```
SUPABASE_URL                  required
SUPABASE_SERVICE_ROLE_KEY     required
NODE_ENV, PORT                defaulted
AUTHORIZE_NET_API_LOGIN_ID    optional
AUTHORIZE_NET_TRANSACTION_KEY optional
AUTHORIZE_NET_SIGNATURE_KEY   optional
```

⚠️ **Latent config bug suspect:** all admin endpoints check `env.ADMIN_SECRET`, but `ADMIN_SECRET` is not declared in the zod schema in `env.js`. zod's `.parse()` only passes through declared keys, so `env.ADMIN_SECRET` is likely always `undefined` at runtime — which would make every admin endpoint return 403 regardless of what secret the caller supplies. Unverified — couldn't test without the actual secret. Live `GET /admin/recipes/pending` returns 403 with no auth and with junk auth, as expected; the unverified question is whether even the *correct* secret would work.

Yesterday measured `/recipes/import` at 1/3 success on the standard test set — datacenter IP, no proxy, no JS render, schema.org-only parser. The architecture-decision doc's "in-app WebView" path supersedes this without removing it.

---

## Database

21 migration files (`0001` through `0021`). **33 tables**, **29 RPCs**.

### Tables (alphabetical, 33 total)
```
achievements              calendar_tags           household_invites
analytics_events          chore_comments          household_members
announcements             chore_history           household_recipes
audit_logs                chore_templates         households
calendar_event_members    chore_verification_     master_recipe_ratings
calendar_events            photos                  master_recipes
                          chores                   meal_plans
                          device_tokens            meal_requests
                          feedback_requests        member_pin_secrets
                                                   necessity_categories
                                                   notification_preferences
                                                   point_transactions
                                                   profiles
                                                   reward_redemptions
                                                   rewards
                                                   shopping_items
                                                   shopping_lists
                                                   stores
                                                   subscriptions
```

Tables relevant for Phase 1 recipe work (covered in yesterday's recipe-code-inventory): `master_recipes`, `master_recipe_ratings`, `household_recipes`, `meal_plans`, `meal_requests`, `analytics_events`.

⚠️ **`device_tokens` table exists** — push-notification infrastructure (Batch 6c) has a DB landing spot already, despite the roadmap calling 6c "blocked on app name." App-name decision is still the blocker for Apple Developer Portal registration, but the schema isn't.

⚠️ **`audit_logs` table exists** but the only reference in `services/api/server.js` is in the React admin scaffold (which doesn't function). Hooked up to nothing on the writer side yet — needs verification.

⚠️ **`subscriptions` table + Authorize.net webhook endpoint** exists. The mobile app has a `subscription_screen.dart`. None of this has been discussed in any roadmap doc reviewed so far.

### RPCs (29 total)
Recipe-adjacent: `create_meal_request`, `decide_meal_request`, `get_recipe_image_url`, `increment_master_recipe_added_count`. Wishlist/shopping: `add_shopping_item`, `approve_wishlist_item`, `guard_shopping_items_wishlist_change`. Chore flow: `approve_chore`, `complete_chore_self`, `submit_kid_chore_with_photo`, `redo_chore`, `delete_chore_photo`, `award_points`, `award_points_to_member`, `check_and_award_achievements`, `check_and_award_achievements_for_member`. Permission helpers: `is_household_admin`, `is_household_member`, `is_member_kid`. PIN: `has_member_pin`, `set_member_pin`, `verify_member_pin`. Misc: `calculate_streak`, `get_leaderboard`, `get_avatar_url`, `seed_default_necessity_categories`, `set_updated_at`, `update_announcements_updated_at`, `update_chore_comments_updated_at`.

`increment_master_recipe_added_count` is interesting — it implies the shared-library "add this recipe to my household" flow has at least an RPC layer ready, even though the mobile app doesn't call it.

---

## Environment / config surface

Names only (no values):

| Var | Where read | Required? |
|---|---|---|
| `SUPABASE_URL` | mobile (`dotenv`), services/api (zod) | required |
| `SUPABASE_ANON_KEY` | mobile (`dotenv`) | required |
| `SUPABASE_SERVICE_ROLE_KEY` | services/api (zod) | required |
| `API_URL` | mobile (`dotenv`, default Railway URL) | optional |
| `NODE_ENV`, `PORT` | services/api (zod) | defaulted |
| `AUTHORIZE_NET_API_LOGIN_ID` | services/api (zod) | optional |
| `AUTHORIZE_NET_TRANSACTION_KEY` | services/api (zod) | optional |
| `AUTHORIZE_NET_SIGNATURE_KEY` | services/api (zod, also referenced via `env.`) | optional |
| `ADMIN_SECRET` | services/api **but missing from zod schema** | undeclared |
| `ANTHROPIC_API_KEY` | spike/ dirs only | spike-only |
| `SCRAPERAPI_KEY` | spike/fetcher-trial only | spike-only |

`.env.example` files: `apps/mobile/`, plus three under `spike/`. No `.env.example` in `services/api/` or `apps/admin-dashboard/`.

---

## Notable findings

1. **A complete recipe-moderation pipeline already exists** — `master_recipes` table + RLS + Railway `/admin/recipes/{pending,approve,reject}` endpoints + functional vanilla `apps/admin` UI. The "shared library schema design" listed as a Phase 1 next-investigation in the architecture-decision doc is partially done at the schema + admin-flow layer. What's missing: a write path from the mobile app (currently only one read of `master_recipes`) and the kid/adult browse/clone-to-household UX.

2. **Two admin frontends exist; one works, one is a stub.** `apps/admin` (vanilla JS) is the working version, ~318 lines of real fetch calls + auth flow. `apps/admin-dashboard` (React/Vite) is a scaffold with hardcoded mock data and a TODO note saying "connected to Supabase in the next milestone." The mock data even includes fictional recipes ("Mom's Famous Lasagna"). Neither is mentioned in any roadmap doc reviewed.

3. **MyNinja AI scaffolding artifact still embedded.** Both admin HTMLs include `<script src="https://sites.super.myninja.ai/_assets/ninja-daytona-script.js">`. Loaded from a third party every time an admin loads either dashboard. Probably tracking/telemetry from the AI tool that produced commit `8d98ff8`. Harmless functionally but a third-party dependency we didn't choose.

4. **Suspected `ADMIN_SECRET` zod-config bug.** `env.ADMIN_SECRET` is referenced 6 times in server.js, but `ADMIN_SECRET` is not declared in the zod schema in `env.js`. Likely outcome: `env.ADMIN_SECRET` is `undefined` at runtime, making every `adminSecret !== env.ADMIN_SECRET` check evaluate to `<anything> !== undefined`, which is always true → every admin endpoint returns 403 even with the correct secret. Unverified (would need the real secret to confirm). If true, the working vanilla admin app can't actually call any admin endpoint successfully.

5. **`device_tokens` table is ready for push notifications.** Batch 6c is "blocked on app name" for Apple-side registration, but the schema is already in place. When 6c unblocks, no migration is needed for the token-storage layer.

6. **`subscriptions` table + Authorize.net webhook + mobile `subscription_screen.dart` form a payments surface** that has not been discussed in any roadmap or audit doc reviewed. State unknown — needs its own orientation pass.

7. **`audit_logs` table exists but writer-side wiring is unclear.** Likely a planned-but-not-implemented audit surface. Worth a dedicated look if compliance/legal review (the parked "Pre-launch legal review stub") proceeds.

8. **`apps/mobile` has a `shared/` directory** under `lib/` that yesterday's recipe-code-inventory didn't cover. Not investigated today — adding to follow-ups.

9. **Top-level `audit.md` and `audit_report.md` exist from 2025-05/2026-05-21.** Pre-date this conversation; framed as "claimed features vs actual implementation" honesty audits. Likely informative context for what was real vs. AI-claimed at the start of the project.

10. **One commit (`8d98ff8`, 2026-05-20, by "SuperNinja") created:**
    - All of `services/api/`
    - All of `apps/admin/`
    - All of `apps/admin-dashboard/`
    - Plus most of the mobile app's screens
    - Plus migrations 0001-0010 (approximately)

    The pattern from yesterday's "look first, dig second" lesson generalizes: this single AI-scaffold commit is the source of nearly everything we haven't been touching. Anything *not* incrementally modified by named commits in the recent history is suspect for being scaffold-only / mock data / dead.

---

## Open questions for follow-up

These weren't answerable from a shallow sweep and may warrant deeper looks:

1. Is `ADMIN_SECRET` actually wired correctly on Railway despite the zod gap? Verify by either probing with the real secret or reading Railway env config.
2. What's in `apps/mobile/lib/shared/`? Yesterday's inventory skipped it.
3. Is `audit_logs` written by anything, anywhere? RLS? Triggers? Or pure schema-only?
4. What's in `apps/mobile/lib/screens/subscription_screen.dart` and how does it relate to the Authorize.net webhook? Is the payments path live, scaffolded, or dead?
5. What do `apps/mobile/test/`, `apps/mobile/android/`, `apps/mobile/PERFORMANCE.md` contain? (Test coverage, Android-specific config, perf notes.)
6. What's in `docs/CLAUDE_CODE_HANDOFF.md` and `docs/product-spec.md`? Either could supersede or contradict the roadmap-handoff doc we've been treating as authoritative.
7. The mobile `subscription_screen.dart` + `analytics_events` table + `audit_logs` table + Authorize.net webhook hint at a "compliance + billing" surface that's never been on our roadmap. Map this if subscriptions are intended to ship.
