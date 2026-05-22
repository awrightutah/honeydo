# Kid Permissions Batch 1 (migration 0016) — Implementation

Date: 2026-05-22
Branch: `feat/kid-perms-schema-2026-05-22` (working-tree only; no commits)
Migration introduced: `supabase/migrations/0016_kid_perms_schema.sql` (260 lines)
Status: code complete — **migration not yet applied to Supabase, not committed**

## Summary

Migration 0016 is written and ready for review. It contains the seven schema-only statements agreed during the investigation, with the three deliberate omissions (is_household_kid helper, chore_verification_photos.rejected_reason column, pg_cron cleanup job) all documented inline. The file is idempotent end-to-end and includes a verification-queries comment block at the bottom for use in the Supabase SQL editor after applying.

No Dart code touched. No other migration files modified. No commits. Branch unchanged.

## Files created

| File | Lines | Purpose |
|---|---|---|
| `supabase/migrations/0016_kid_perms_schema.sql` | 260 | The migration (header comment + 7 statement blocks + verification queries) |
| `audits/2026-05-kid-perms-batch-1-implementation.md` | this | Implementation report |

No other files modified. `audits/2026-05-kid-perms-batch-1-investigation.md` from the previous step is preserved unchanged.

## Per-statement breakdown

| # | Lines | Statement | Idempotency mechanism |
|---|---|---|---|
| 1a | 74–82 | `CREATE TABLE public.necessity_categories` (composite PK on `(household_id, category)`) | `IF NOT EXISTS` |
| 1b | 83 | `ALTER TABLE public.necessity_categories ENABLE ROW LEVEL SECURITY` | Re-running is a no-op |
| 2a | 89–103 | `CREATE OR REPLACE FUNCTION public.seed_default_necessity_categories()` (plpgsql trigger function, INSERTs the 4 defaults `Hygiene, School Supplies, Basic Groceries, Medication`) | `CREATE OR REPLACE` |
| 2b | 104–108 | Trigger `seed_necessity_categories_on_household` AFTER INSERT on `households` | `DROP TRIGGER IF EXISTS` before `CREATE TRIGGER` |
| 3 | 115–119 | One-time backfill `INSERT … necessity_categories … SELECT FROM households CROSS JOIN (VALUES …)` for every existing household (Wrights + any others) | `ON CONFLICT DO NOTHING` |
| 4a | 128–131 | `ALTER TABLE public.shopping_items ADD COLUMN is_wishlist boolean NOT NULL DEFAULT false, ADD COLUMN approved_by_member_id uuid REFERENCES household_members(id) ON DELETE SET NULL, ADD COLUMN approved_at timestamptz` | `ADD COLUMN IF NOT EXISTS` on each |
| 4b | 136–138 | Partial index `idx_shopping_items_wishlist ON shopping_items(household_id, is_wishlist) WHERE is_wishlist = true` | `CREATE INDEX IF NOT EXISTS` |
| 5 | 146–147 | `ALTER TABLE public.household_members ADD COLUMN music_app_preference text` (nullable, no CHECK) | `ADD COLUMN IF NOT EXISTS` |
| 6a | 156–169 | `CREATE TABLE public.meal_requests` (recipe_id FKs to `household_recipes`; `meal_type meal_type` enum nullable; `status text … CHECK IN ('pending','approved','denied')`; decided_by/decided_at/decided_note for admin decision; standard timestamps) | `IF NOT EXISTS` |
| 6b | 173–179 | Two indexes: `idx_meal_requests_household_status(household_id, status)` and `idx_meal_requests_requested_by(requested_by_member_id)` | `CREATE INDEX IF NOT EXISTS` |
| 6c | 182 | `ALTER TABLE public.meal_requests ENABLE ROW LEVEL SECURITY` (zero policies — defense in depth, Batch 2 adds policies) | Re-running is a no-op |
| 7 | 195–200 | Owner-role backfill `UPDATE household_members SET role='owner' FROM households WHERE auth_user_id = owner_user_id AND role='admin'` | Filter `role='admin'` makes re-runs a no-op once promoted |

The `set_household_members_updated_at` trigger (existing, defined in 0001:442) will automatically bump `updated_at` on the backfill UPDATE; we also set it explicitly in the UPDATE for self-documentation.

## Deliberately omitted (with reasoning carried forward from the investigation)

| Omission | Why | Where it ends up |
|---|---|---|
| `is_household_kid(target_household_id uuid)` RLS helper | Sub_profiles have `auth_user_id IS NULL`. A helper filtering by `auth_user_id = auth.uid() AND kind = 'sub_profile'` can never match — kids do not hold JWTs. The realistic shape is `is_member_kid(p_member_id uuid)`, used inside SECURITY DEFINER RPCs. | Defer decision to Batch 2 when the RPC signatures are nailed down. Migration 0017 may add `is_member_kid(uuid)` if needed. |
| `chore_verification_photos.rejected_reason text` column | `chores.rejected_reason text` already exists (initial_schema.sql:107). Adding the column on the photos table would create two sources of truth for one piece of state. The Batch-4 reject flow will use the existing `chores.rejected_reason`. | Permanent skip. The spec should be amended after this batch lands (Open Question 7 from the investigation). |
| pg_cron 30-day photo retention job | pg_cron is not referenced by any existing migration; cannot verify it is enabled from migration files alone. The cleanup also has to delete the Storage object (not just the DB row) or files orphan in the `chore-photos` bucket — that's an Edge Function design pass on its own. We have 30+ days of operational runway after Batch 4 ships the photo flow before cleanup is needed. | Separate small migration (`0017_chore_photo_cleanup_cron.sql` or later) after pg_cron availability is confirmed AND the storage-cleanup approach is designed. |

Each omission is also documented in the header comment block of the migration file itself (lines 32–63), so anyone reading the SQL has the context inline.

## Verification queries to run after applying

These are also in the migration file as comments (lines 204–260), copy-pasteable into the Supabase SQL editor. Summary:

| Check | Query (abbreviated) | Expected result |
|---|---|---|
| A. Necessity defaults seeded | `SELECT h.name, count(nc.*) FROM households h LEFT JOIN necessity_categories nc … GROUP BY h.name` | Every household has count = 4 |
| B. shopping_items has the 3 new columns | `information_schema.columns WHERE table_name = 'shopping_items' AND column_name IN (…)` | 3 rows; `is_wishlist` NOT NULL with default `false`; others nullable |
| C. household_members has music_app_preference | `information_schema.columns WHERE … column_name = 'music_app_preference'` | 1 row, text, nullable |
| D. meal_requests exists with RLS enabled, zero policies | `pg_class.relrowsecurity` = true + `pg_policies` count = 0 | Pass |
| E. Owner-role backfill landed | `SELECT … FROM household_members hm JOIN households h ON h.id = hm.household_id WHERE hm.auth_user_id = h.owner_user_id` | All rows `role='owner'` (was `'admin'` before) |
| F. Seed trigger exists on households | `pg_trigger WHERE tgrelid = 'households'::regclass AND tgname = 'seed_necessity_categories_on_household'` | 1 row, enabled |

If A and E pass, the migration's data-effects are working. If B, C, D, F pass, the schema-effects are in place. Run after applying; report any unexpected results before proceeding to Batch 2.

## Open followups carried forward

Out-of-scope for Batch 1; reproduced here so they don't get lost:

1. **`is_member_kid(p_member_id uuid)` helper (or equivalent)** — decide in Batch 2 alongside the RPC design. If RPCs always look up the calling member's kind via the `household_members` row they're already fetching, a helper isn't strictly needed.

2. **pg_cron photo-cleanup migration.** Two unknowns to resolve first: (a) is pg_cron enabled on the Supabase project? (b) what's the right way to delete the Storage object — call `storage.delete()` from inside the cron body, or have the cron enqueue a job that an Edge Function processes? Worth its own short investigation pass before any SQL is written.

3. **Spec amendment.** After Batch 1 lands cleanly, update `/audits/2026-05-kid-profile-permissions-spec.md`:
   - Remove `is_household_kid()` from the Batch 1 row (replace with note about Batch 2 reconsideration).
   - Remove `chore_verification_photos.rejected_reason` from Batch 1 and from the implementation-notes section (use `chores.rejected_reason` instead).
   - Note that pg_cron was deferred.
   - Reword line 89 ("Existing rows that say 'admin' for creators are NOT backfilled in this workstream") to reflect that the backfill did happen in Batch 1.

4. **shopping_items.category case normalization.** The Batch-2 wishlist RPC compares incoming `category` against `necessity_categories.category`. Decision was case-insensitive via `lower()` in the lookup; the RPC needs to actually implement that.

5. **Batch 2 scope unchanged** from the spec — see `Batch plan` row 2 in the spec: RLS tightening on chores/photos/rewards/meal_plans/shopping_items/analytics + the 5 SECURITY DEFINER RPCs (`approve_chore`, `add_shopping_item`, `submit_kid_chore_with_photo`, `create_meal_request`, `decide_meal_request`).

## Next steps

1. **You review** the migration file. Sanity-check the SQL is what you expect; flag anything off.
2. **Apply 0016 to Supabase** via the SQL editor (one block, idempotent). Watch for any error output.
3. **Run the six verification queries** (A–F) and confirm each returns the expected result.
4. **Report back** any discrepancies, or confirm clean.
5. **Commit** `supabase/migrations/0016_kid_perms_schema.sql` and this implementation report on `feat/kid-perms-schema-2026-05-22`. Push with `--set-upstream`.
6. **Schedule Batch 2** (RLS + RPCs) as the next workstream — either stacked on this branch or on a new follow-up branch off it. The spec amendment per Followup 3 above is a small task that can land either before Batch 2 or alongside its merge to main.

## Git state (uncommitted)

```
$ git status --short
?? audits/2026-05-kid-perms-batch-1-implementation.md
?? supabase/migrations/0016_kid_perms_schema.sql
```

Both files untracked, on `feat/kid-perms-schema-2026-05-22`. Working tree otherwise clean.
