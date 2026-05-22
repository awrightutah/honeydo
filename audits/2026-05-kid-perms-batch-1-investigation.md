# Kid Permissions Batch 1 (migration 0016) — Investigation

Date: 2026-05-22
Branch: `feat/kid-perms-schema-2026-05-22` (read-only investigation; no edits, no commits)
Spec reference: `/audits/2026-05-kid-profile-permissions-spec.md` (Batch plan row 1)
Status: investigation complete — three findings to resolve before writing 0016

## Summary

The Batch 1 scope as written by the spec is mostly straightforward additive SQL, but three issues surfaced that the user needs to decide before migration 0016 is drafted:

1. **`rejected_reason` already exists** — but on `chores`, not on `chore_verification_photos`. Adding it to `chore_verification_photos` per the spec would be a redundant column. Recommend skipping that part of Batch 1 and using the existing `chores.rejected_reason`.
2. **`is_household_kid()` as conceived in the spec is architecturally impossible.** Sub_profiles have `auth_user_id = NULL`. A helper that filters by `auth_user_id = auth.uid() AND kind = 'sub_profile'` can never match — kids do not have JWTs. The helper either has to take a `member_id` parameter (different signature than the existing two helpers) or be dropped from Batch 1.
3. **pg_cron is not referenced in any existing migration** — needs confirmation that the extension is enabled on the Supabase project before the daily cleanup job can be installed. Recommend deferring the cron schedule to a small follow-up migration after verification.

There is also a **spec-vs-brief contradiction** on the owner-role backfill: spec line 89 explicitly says backfill is *out of scope*, but the user's brief for this investigation adds the backfill as a "small addition agreed in chat." Flagging for awareness. (The user's brief takes priority; the spec line should probably be amended after this batch lands.)

Everything else in the spec's Batch 1 row is clean and ready to be written as straight SQL.

## Phase 1 — Batch 1 scope confirmation

The spec's Batch 1 row (verbatim from `/audits/2026-05-kid-profile-permissions-spec.md:113`):

> **1** — Migration 0016 (schema): `meal_requests`, `necessity_categories` (with 4 default rows per household), `shopping_items` 3 new columns, `household_members.music_app_preference`, `chore_verification_photos.rejected_reason`, `is_household_kid()` RLS helper, daily pg_cron job for 30-day photo retention. **Complexity:** Low (pure SQL). **Dependencies:** None.

Plus the user's brief addition this session:
- Update existing `household_members` rows where `role='admin'` for the household creator to `role='owner'`. The user calls this the "Wrights Home backfill" but it should generalize to all current households (and there's likely only one in the database today).

## Phase 2 — Existing schema inventory

### Conflict check on new names

`grep -rn "meal_requests\|necessity_categories\|music_app_preference\|rejected_reason\|is_household_kid" supabase/migrations/`:

```
supabase/migrations/0001_initial_schema.sql:107:  rejected_reason text,
```

One hit. Context — this is on the `chores` table, line 88-110:

```sql
create table public.chores (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  title text not null,
  description text,
  assigned_to_member_id uuid references public.household_members(id) on delete set null,
  created_by_member_id uuid references public.household_members(id) on delete set null,
  point_value integer not null default 5,
  bonus_points integer not null default 0,
  difficulty chore_difficulty not null default 'easy',
  due_at timestamptz,
  recurrence_rule text,
  status chore_status not null default 'assigned',
  requires_photo boolean not null default false,
  chore_of_day_date date,
  started_at timestamptz,
  completed_at timestamptz,
  verified_at timestamptz,
  verified_by_member_id uuid references public.household_members(id) on delete set null,
  rejected_reason text,                                      -- ← line 107
  auto_verify_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
```

**`rejected_reason` already exists on `chores`.** It does NOT exist on `chore_verification_photos` (verified by reading the table at 0001:113–121, no such column). The other four names (`meal_requests`, `necessity_categories`, `music_app_preference`, `is_household_kid`) do not appear in any migration.

### Enum types referenced by 0016

From `0001:8-18`:

```sql
create type household_role as enum ('owner', 'admin', 'member');
create type member_kind as enum ('adult_auth_user', 'sub_profile');
create type meal_type as enum ('breakfast', 'lunch', 'dinner', 'snack', 'other');
```

All three exist and are sufficient for what 0016 needs.

### `household_members` (0001:42–59)

```sql
create table public.household_members (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  kind member_kind not null,
  role household_role not null default 'member',
  auth_user_id uuid references public.profiles(id) on delete set null,
  display_name text not null,
  avatar_url text,
  pin_hash text,                            -- (dropped by migration 0013)
  points_balance integer not null default 0,
  is_active boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint household_members_auth_required_for_adult check (
    (kind = 'adult_auth_user' and auth_user_id is not null) or (kind = 'sub_profile')
  )
);
```

Note: `pin_hash` listed here is gone after migration 0013 dropped it. Confirmed kid rows have `auth_user_id IS NULL` (per the CHECK constraint, only adults are required to have auth_user_id).

### `households` (0001:30–40)

```sql
create table public.households (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  theme_color text default '#F5A623',
  owner_user_id uuid not null references public.profiles(id) on delete restrict,
  tier subscription_tier not null default 'free',
  subscription_status subscription_status not null default 'active',
  subscription_grace_ends_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
```

`owner_user_id` is the auth-level owner. Useful for the role backfill — the row to update is `household_members WHERE auth_user_id = households.owner_user_id`.

### `chore_verification_photos` (0001:113–121)

```sql
create table public.chore_verification_photos (
  id uuid primary key default gen_random_uuid(),
  chore_id uuid not null references public.chores(id) on delete cascade,
  household_id uuid not null references public.households(id) on delete cascade,
  uploaded_by_member_id uuid references public.household_members(id) on delete set null,
  storage_path text not null,
  delete_after timestamptz,                  -- ← used by the pg_cron cleanup
  created_at timestamptz not null default now()
);
```

`delete_after` exists, nullable, no default. Good — the cleanup cron can use it directly.

### `shopping_items` (0001:318–337)

```sql
create table public.shopping_items (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  shopping_list_id uuid not null references public.shopping_lists(id) on delete cascade,
  name text not null,
  quantity numeric,
  unit text,
  display_quantity text,
  store_id uuid references public.stores(id) on delete set null,
  category text,                             -- ← free-text, nullable
  purchased boolean not null default false,
  purchased_by_member_id uuid references public.household_members(id) on delete set null,
  purchased_at timestamptz,
  source_recipe_id uuid references public.household_recipes(id) on delete set null,
  source_meal_plan_id uuid references public.meal_plans(id) on delete set null,
  added_by_member_id uuid references public.household_members(id) on delete set null,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
```

`category` is free-text, nullable. `added_by_member_id` exists (confirms previous investigation finding). The wishlist columns will plug in alongside these.

### Recipe table identity — `household_recipes`, not `recipes`

Confirmed: there is no `recipes` table. There are:
- `master_recipes` (0001:223) — the global moderated recipe library
- `household_recipes` (0001:259) — per-household saved recipes (this is what `meal_plans.recipe_id` references at 0001:287)

**`meal_requests.recipe_id` must FK to `household_recipes`**, mirroring `meal_plans.recipe_id`. This matches the spec's intent (kids request from "the recipe library" — which in the app is the household's saved set).

### Existing RLS helpers (0001:455–477)

```sql
create or replace function public.is_household_member(target_household_id uuid)
returns boolean as $$
  select exists (
    select 1
    from public.household_members hm
    where hm.household_id = target_household_id
      and hm.auth_user_id = auth.uid()
      and hm.is_active = true
  );
$$ language sql stable security definer;

create or replace function public.is_household_admin(target_household_id uuid)
returns boolean as $$
  select exists (
    select 1
    from public.household_members hm
    where hm.household_id = target_household_id
      and hm.auth_user_id = auth.uid()
      and hm.is_active = true
      and hm.role in ('owner', 'admin')
  );
$$ language sql stable security definer;
```

Pattern: `sql stable security definer`, references `auth.uid()`. Any new helper should follow the same shape.

## Phase 3 — pg_cron status

`grep -rn "pg_cron\|cron.schedule" supabase/migrations/` returned **zero hits**. pg_cron has never been touched by any migration in this project.

Supabase makes pg_cron available, but it has to be enabled on the project (Dashboard → Database → Extensions → toggle pg_cron). Once enabled, like pgcrypto, it lives in the `extensions` schema and the scheduling function is `cron.schedule(...)` — but the `cron` schema is usually exposed at the top level (not under `extensions.cron`) once the extension is in place.

**Recommendation:** **defer pg_cron from Batch 1.** Reasons:
1. We can't verify availability from migration files alone.
2. The cron schedule call requires real-time confirmation that the function works (a misnamed schema reference fails silently if the migration just states `CREATE EXTENSION IF NOT EXISTS pg_cron` and the schema is wrong).
3. The cleanup is operationally low-risk to delay: until the first chore-verification photo is uploaded AND aged 30 days, there's nothing to clean. We have at least 30 days of runway after Batch 4 lands the photo flow.
4. We just had a three-iteration pgcrypto schema-qualification debugging arc in Pass 2; adding pg_cron in the same situation invites the same problem.

Suggested: land the schema (tables + columns + helper + backfill) in 0016. Create a separate small migration `0017_chore_photo_cleanup_cron.sql` after the user confirms pg_cron is enabled on the project and we've verified the correct fully-qualified call signature (`cron.schedule('name', '0 3 * * *', $$ ... $$)` is the typical form, but the exact syntax should be tested manually before being committed).

## Phase 4 — Proposed migration in execution order

Working title: `supabase/migrations/0016_kid_perms_schema.sql`.

Order of statements matters for foreign-key targets and triggers. Below is the proposed sequence with reasoning.

### Step 1 — `is_household_kid()` helper (deferred / signature flag)

**The spec wants this:**
```sql
-- ⚠ FLAGGED — see Phase 6, Open Question 1
create or replace function public.is_household_kid(target_household_id uuid)
returns boolean as $$
  select exists (
    select 1
    from public.household_members hm
    where hm.household_id = target_household_id
      and hm.auth_user_id = auth.uid()
      and hm.is_active = true
      and hm.kind = 'sub_profile'
  );
$$ language sql stable security definer;
```

**Problem:** sub_profiles have `auth_user_id IS NULL`. The clause `auth_user_id = auth.uid()` excludes them by definition. **This function will always return false.**

The architectural reality (confirmed in Pass 2 PIN work and the kid-permissions investigation): kids do not have JWTs. RLS only sees the adult's `auth.uid()`. There is no way for RLS to know "the calling user is acting AS a kid right now" — only the app knows, via `ActiveMemberService`.

The function as the spec describes it cannot serve its intended purpose. Three resolutions:
- **(a) Drop the function from Batch 1.** Wait until Batch 2 to decide. Batch 2's RPCs take `p_member_id` and verify the calling adult is in the same household; the kid-vs-adult branching happens inside the RPC by looking up `p_member_id`'s kind, no helper needed.
- **(b) Redefine as `is_member_kid(p_member_id uuid)`** that takes a member_id and returns whether that member is a sub_profile. Useful inside RPCs. Different signature from the existing two helpers.
- **(c) Keep the helper as written but with a comment that it's a no-op placeholder until JWT custom-claim work lands.** Worst of all worlds.

**Recommend (a) drop from Batch 1**, revisit in Batch 2 once the RPC shapes are nailed down. The spec line referencing this helper should be amended.

### Step 2 — `necessity_categories` table

```sql
create table public.necessity_categories (
  household_id uuid not null references public.households(id) on delete cascade,
  category text not null,
  created_at timestamptz not null default now(),
  primary key (household_id, category)
);

alter table public.necessity_categories enable row level security;
```

- Composite PK on `(household_id, category)` — no surrogate id needed; the natural key is unique.
- ON DELETE CASCADE so categories disappear when a household is deleted.
- RLS enabled with zero policies (defense in depth — Batch 2 adds policies).

Open question: **case sensitivity** of `category` vs `shopping_items.category`. Discussed in Phase 6.

### Step 3 — Default-seed trigger

```sql
create or replace function public.seed_default_necessity_categories()
returns trigger
language plpgsql
as $$
begin
  insert into public.necessity_categories (household_id, category) values
    (new.id, 'Hygiene'),
    (new.id, 'School Supplies'),
    (new.id, 'Basic Groceries'),
    (new.id, 'Medication')
  on conflict do nothing;
  return new;
end;
$$;

create trigger seed_necessity_categories_on_household
  after insert on public.households
  for each row execute function public.seed_default_necessity_categories();
```

Runs after every new household insert. `ON CONFLICT DO NOTHING` makes it safe if a household is somehow re-inserted (impossible under normal flow, but idempotent).

### Step 4 — Backfill defaults for existing households

```sql
insert into public.necessity_categories (household_id, category)
select h.id, c.category
  from public.households h
  cross join (values ('Hygiene'), ('School Supplies'), ('Basic Groceries'), ('Medication')) as c(category)
on conflict do nothing;
```

Picks up the Wrights household plus anything else already inserted.

### Step 5 — `shopping_items` three new columns + partial index

```sql
alter table public.shopping_items
  add column if not exists is_wishlist boolean not null default false,
  add column if not exists approved_by_member_id uuid references public.household_members(id) on delete set null,
  add column if not exists approved_at timestamptz;

create index if not exists idx_shopping_items_wishlist
  on public.shopping_items(household_id, is_wishlist)
  where is_wishlist = true;
```

- `is_wishlist boolean not null default false` — existing rows become "not on the wishlist," i.e., active list items. This matches the resolved-question intent (wishlist is opt-in for kid inserts; existing data stays on the active list).
- `approved_by_member_id` and `approved_at` nullable — populated only when admin approves.
- Partial index because the vast majority of rows will be `is_wishlist=false`; only the "Pending Wishlist" admin view needs an index, and that view only ever queries `where is_wishlist = true`.

### Step 6 — `household_members.music_app_preference`

```sql
alter table public.household_members
  add column if not exists music_app_preference text;
```

Nullable. No CHECK constraint (see Phase 6 open question).

### Step 7 — `chore_verification_photos.rejected_reason` — FLAGGED

**Per spec, this would be:**

```sql
-- ⚠ FLAGGED — see Phase 6, Open Question 2
alter table public.chore_verification_photos
  add column if not exists rejected_reason text;
```

**Problem:** `chores.rejected_reason` already exists. Admin "reject" populates the column on the chore row itself. Adding a second `rejected_reason` on `chore_verification_photos` creates two sources of truth.

Three resolutions:
- **(a) Skip this line.** Use the existing `chores.rejected_reason` for the rejection note. Photos themselves don't need their own reason field.
- **(b) Keep both with distinct semantics**: `chores.rejected_reason` is the chore-level decision note; `chore_verification_photos.rejected_reason` is photo-specific (e.g., "photo too blurry, redo"). Requires UX clarity.
- **(c) Drop `chores.rejected_reason` and migrate any data to `chore_verification_photos.rejected_reason`.** Most invasive; rejects existing column.

**Recommend (a) skip.** Photo-specific rejection reasons aren't in the spec's allowed/disallowed actions, and one-photo-per-chore-submission is the apparent UX. Update the spec to remove this from the implementation notes after Batch 1.

### Step 8 — `meal_requests` table + indexes

```sql
create table public.meal_requests (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  requested_by_member_id uuid not null references public.household_members(id) on delete cascade,
  recipe_id uuid not null references public.household_recipes(id) on delete cascade,
  requested_for_date date,
  meal_type meal_type,
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'denied')),
  decided_by_member_id uuid references public.household_members(id) on delete set null,
  decided_at timestamptz,
  decided_note text,
  created_at timestamptz not null default now()
);

create index idx_meal_requests_household_status on public.meal_requests(household_id, status);
create index idx_meal_requests_requested_by on public.meal_requests(requested_by_member_id);

alter table public.meal_requests enable row level security;
```

Notes:
- `recipe_id` FKs to `household_recipes` (matching `meal_plans.recipe_id`).
- `meal_type` uses the existing `meal_type` enum (5 values).
- `status` uses a `text` column with a CHECK rather than introducing a new enum, to keep the migration tighter and allow easier expansion (e.g., `'archived'`) without an enum alter.
- ON DELETE CASCADE everywhere except `decided_by_member_id` (admin can leave; their decisions live on as audit info).
- RLS enabled, zero policies — Batch 2 adds them.

`requested_for_date` and `meal_type` are nullable because the spec doesn't require kids to specify them. The admin's decide step (Batch 2) can default them if needed.

### Step 9 — Owner-role backfill

```sql
update public.household_members hm
  set role = 'owner', updated_at = now()
  from public.households h
  where hm.household_id = h.id
    and hm.auth_user_id = h.owner_user_id
    and hm.role = 'admin';
```

Generalized to all households where the creator's `household_members` row says `admin`. In production today there's likely one such row (Wrights), but writing it as a generic UPDATE means anything created before the Batch-3 app fix lands gets the right role.

⚠ **Spec contradiction:** spec line 89 says "Existing rows that say 'admin' for creators are NOT backfilled in this workstream (out of scope)." The user's brief overrides this. The spec line should be amended after this batch lands so the spec stays consistent with reality.

### Step 10 — DEFER pg_cron cleanup

Not included in 0016. To be added in a separate small migration after we verify pg_cron is enabled on the Supabase project. The future SQL will look approximately like:

```sql
-- 0017_chore_photo_cleanup_cron.sql (NOT in this batch)
create extension if not exists pg_cron;

select cron.schedule(
  'chore-photo-cleanup',
  '0 3 * * *',   -- daily at 03:00 UTC
  $$
  delete from public.chore_verification_photos
    where delete_after is not null and delete_after < now();
  $$
);
```

…but the actual call needs validation against Supabase's pg_cron configuration. Storage-object deletion (the photo file itself, not just the DB row) likely needs a separate path — either a server-side Edge Function or a `storage.delete()` helper call inside the cron's body. The row delete alone leaves orphaned bucket files. **This deserves its own investigation pass before any SQL is written.**

### Statement order summary

| # | Statement | Why this position |
|---|---|---|
| 1 | ~~`is_household_kid()`~~ DEFER | Architectural design issue — Phase 6 Q1 |
| 2 | `create table necessity_categories` + RLS enable | Foundation for the trigger and the backfill insert |
| 3 | `seed_default_necessity_categories()` function + trigger | After table exists |
| 4 | `INSERT ... necessity_categories` for existing households | After the table is in place |
| 5 | `ALTER shopping_items` + 3 columns + partial index | Independent |
| 6 | `ALTER household_members + music_app_preference` | Independent |
| 7 | ~~`ALTER chore_verification_photos + rejected_reason`~~ DEFER/SKIP | Redundant with `chores.rejected_reason` — Phase 6 Q2 |
| 8 | `create table meal_requests` + indexes + RLS enable | Independent of all above |
| 9 | `UPDATE household_members SET role='owner'` | After all schema changes; affects only data, no schema |
| 10 | pg_cron schedule | DEFER to separate migration |

## Phase 5 — RLS implications (preview only)

**Decision: yes, ENABLE ROW LEVEL SECURITY on both new tables in 0016 with zero policies.**

Mirrors what we did for `member_pin_secrets` in 0013: lock down by default, then Batch 2 opens up specific paths. This means between 0016 landing and 0017 (Batch 2) landing, no client can read or write `necessity_categories` or `meal_requests` — which is correct, because no app code exists for them yet either.

If we *forgot* to enable RLS now and 0017 took longer than expected, the new tables would inherit Postgres's "no RLS = everyone with table-level GRANT can SELECT" default. Better to fail closed.

The existing tables we ALTER (`shopping_items`, `household_members`, `chore_verification_photos`) already have RLS enabled with policies; the new columns inherit those policies automatically. No additional action needed on those.

## Phase 6 — Open questions for user

1. **`is_household_kid()` helper — drop, redefine, or keep as no-op?**
   The spec asks for it but the signature it implies (filter by `auth.uid()`) can never match a sub_profile. Recommend dropping from Batch 1 and revisiting in Batch 2. If you want a kid-detection helper today, the realistic form is `is_member_kid(p_member_id uuid)` — a different signature, used inside SECURITY DEFINER RPCs.

2. **`chore_verification_photos.rejected_reason` — add it anyway, or use the existing `chores.rejected_reason`?**
   `chores.rejected_reason` already exists. The simpler model is one rejection note per chore submission, stored on the chore. Recommend skipping the photo-level column. Confirm.

3. **pg_cron — defer to a follow-up migration, or attempt to enable in 0016?**
   No migration references it today. Cleanest path: defer, and ask the user to confirm pg_cron is enabled on the project. Separate concern: cleaning up the Storage object (not just the DB row) likely needs an Edge Function, which is its own investigation.

4. **`necessity_categories.category` case sensitivity.**
   `shopping_items.category` is free-text. When the wishlist RPC (Batch 2) compares an incoming item's category to the necessity list, do we want case-sensitive match ("Hygiene" ≠ "hygiene") or case-insensitive? The spec doesn't say. Recommend storing as-typed but comparing via `lower(category)` in the lookup query. Alternative: enforce `category = initcap(category)` at insert.

5. **`household_members.music_app_preference` — free text or CHECK constraint?**
   App will validate from a known list, but should the DB also enforce? CHECK constraint catches DB-direct mistakes and forces a migration to add new apps. No constraint preserves flexibility. Recommend no constraint; the app picker is the source of truth.

6. **Owner-role backfill scope — Wrights only, or all 'admin' creators?**
   The user's brief said "Wrights Home row" but the right SQL targets every household whose creator is currently 'admin'. Same effect today (one household), but worth confirming the generalized form is intended.

7. **Spec amendment.** After this batch lands, the spec should be updated:
   - Remove the `is_household_kid()` line from Batch 1 if we defer.
   - Remove the `chore_verification_photos.rejected_reason` line if we skip.
   - Change line 89 from "are NOT backfilled" to reflect that backfill DID happen.
   - Note that pg_cron was deferred to a follow-up migration.
   This is a separate documentation pass; not part of Batch 1's SQL.

8. **shopping_items existing data sanity check.** The `is_wishlist` column default is `false`, which makes existing items "not on the wishlist" — i.e., on the active list. Confirm this matches your intent. If you want existing items to be reviewed before they land on the active list (unlikely), the default would flip and a backfill would be needed.

## Next steps

In recommended order:

1. **You decide** on the 8 open questions above. Most have a clear recommendation; #1, #2, and #3 are the consequential ones.
2. Once decided, **I'll write `0016_kid_perms_schema.sql`** with the agreed-upon statements, idempotent, and we'll review it before applying.
3. **Apply 0016** to Supabase (paste into SQL editor; verify rows in `necessity_categories` after; verify `household_members` `role` for the Wrights creator flipped to `'owner'`; verify the new `shopping_items` columns visible).
4. **Commit 0016 + this investigation report** on `feat/kid-perms-schema-2026-05-22`. Push.
5. Plan Batch 2 (RLS + RPCs) on a follow-up branch.

Once Batch 1 lands and is verified, the spec file gets a small amendment per Open Question 7 to keep documentation consistent.
