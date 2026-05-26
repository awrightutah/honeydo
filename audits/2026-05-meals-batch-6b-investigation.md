# Batch 6b — Meal Requests Followup (Kid Recent-Requests View + Activity Feed Entries + Realtime Notifier)

Date: 2026-05-25
Branch: `feat/meals-batch-6b-2026-05-25`
Status: **READ-ONLY investigation** — no code, no migration, no commit

## Summary

Batch 6a closed the kid-submits/admin-decides loop. Three follow-on items from the spec remain:

1. **`RealtimeService.mealRequestsVersion`** — wire a Postgres-changes listener on `meal_requests` and expose a `ValueNotifier<int>`. Small: ~16 LOC in `realtime_service.dart`, ~3 LOC in `home_shell_screen.dart` to drop the 6a-era TODO. **No surprises.**

2. **Activity feed entry on decide** — **MAJOR scope finding**: the activity feed is a **client-side aggregator**, not a server-side event log. There is no `activity_feed`, `activity_entries`, or `activity_log` table anywhere in `supabase/migrations/`. `apps/mobile/lib/screens/activity_feed_screen.dart` (437 LOC) builds the feed in `_loadData()` by querying five source tables (`chores`, `achievements`, `point_transactions`, `reward_redemptions`, `household_members`), merging in memory, and sorting by timestamp. **Implication**: "adding meal requests to the feed" = adding a 6th query block + an icon + a description string. No new table, no new RPC, no trigger, no RLS work. ~50–60 LOC in `activity_feed_screen.dart`.

3. **Kid "My recent requests" view** — entirely new screen (no existing infrastructure). The spec calls it "a view on the kid-side recipe library." Investigation surfaces several open design questions about placement, filtering, and interactivity. ~250–350 LOC.

**Push notifications (item 4 from the spec) are NOT in scope for 6b.** They land in 6c with APNs setup + device tokens + edge function dispatch. The spec lists them as a separate sub-bullet under Batch 6 and 6a's investigation explicitly deferred them.

## Total scope estimate

| Sub-piece | LOC | Risk | Notes |
|---|---|---|---|
| A. RealtimeService notifier | ~20 | low | Copy-paste of existing 8 notifiers |
| B. Activity feed entry on decide | ~60 | low | Sixth query block in existing aggregator |
| C. Recent requests kid view | ~250–350 | medium | New screen; design decisions pending |
| **Total** | **~330–430** | medium | Comparable to 6a's ~653 actual |

**Recommendation: ship as one batch (6b)**. Sub-piece B turned out to be much smaller than feared once Phase 0 revealed the feed is client-side. None of the three pieces has heavy mutual coupling, but they all share the same realtime channel and read from the same table, so bundling reduces re-test cost.

If a split is preferred:
- **6b-i** = A + C (kid-facing UX: notifier + recent-requests screen)
- **6b-ii** = B (activity feed amendment)

But honestly the activity feed amendment is too small (~60 LOC) to deserve its own batch — recommend keep bundled.

---

## Phase 0 — Activity feed inventory (CRITICAL)

### Schema
**Result: no activity feed table exists.**

```
$ grep -rli "activity_feed\|activity_entries\|activity_log\|activities" supabase/migrations/
(no matches)
```

Searched all 21 migration files. Closest hits in `0001_initial_schema.sql`:
- `analytics_events` (line 382) — telemetry, not user-facing activity
- `audit_logs` (line 406) — system audit, not user-facing activity

Neither is wired to the activity feed screen.

### App side
**Result: client-side aggregator at `apps/mobile/lib/screens/activity_feed_screen.dart` (437 LOC).**

`_loadData()` (lines 25–176) issues 5 parallel queries to source tables and merges results in-memory:

| # | Source table | Mapped to type | Fields pulled |
|---|---|---|---|
| 1 | `chores` (filtered by `status IN ('verified', 'pending_verification')`) | `chore_completed` | id, title, status, completed_at, point_value, member name+kind |
| 2 | `achievements` | `achievement_earned` | earned_at, badge_name, icon, member name+kind |
| 3 | `point_transactions` | `points` | created_at, amount, type, note, member name+kind |
| 4 | `reward_redemptions` | `reward_redeemed` | redeemed_at, point_cost, reward title+icon, member name+kind |
| 5 | `household_members` | `member_joined` | created_at, display_name, kind |

After each block, results are pushed into a single `List<Map<String, dynamic>> allActivities`. Then a single `allActivities.sort(...)` by parsed timestamp. Filter chips on the UI side (`_filter` state) hide types.

### Access path
Reached via the home_shell popup menu, item value `'activity'` (`home_shell_screen.dart:372` and `:496`). **No admin gating** — the menu item is visible to kids too. But because `activity_feed_screen.dart:34` uses the legacy `.eq('auth_user_id', user.id)` pattern, a kid session actually loads the parent admin's membership, so the kid sees the admin's view. Pre-existing bug, documented for Batch 7.

### RPCs / triggers
**Result: nothing emits anything.**

```
$ grep -rn "activity\|notify\|raise notice" supabase/migrations/0017*.sql supabase/migrations/0021*.sql
(no activity-related matches; only the standard `RAISE EXCEPTION` error paths)
```

No `approve_chore` / `approve_wishlist_item` / `decide_meal_request` writes to any activity table. They each just `UPDATE`/`INSERT` their primary table.

### What this means for 6b
**Adding meal_requests to the feed = pure client work.**

In `activity_feed_screen.dart._loadData()`, add a 6th `try { ... }` block analogous to the existing 5:

```dart
// 6. Meal request decisions
try {
  final mealReqs = await Supabase.instance.client
      .from('meal_requests')
      .select('id, decided_at, status, decided_note, '
              'household_recipes!meal_requests_recipe_id_fkey(title), '
              'household_members!meal_requests_requested_by_member_id_fkey(display_name, kind)')
      .eq('household_id', householdId)
      .neq('status', 'pending')      // only approved + denied
      .order('decided_at', ascending: false)
      .limit(20);

  for (final m in mealReqs) {
    allActivities.add({
      'type': 'meal_request_decided',
      'timestamp': m['decided_at'],
      'member_name': m['household_members']?['display_name'] ?? 'Someone',
      'member_kind': m['household_members']?['kind'] ?? 'adult_auth_user',
      'recipe_title': m['household_recipes']?['title'] ?? 'a meal',
      'status': m['status'],
      'decided_note': m['decided_note'],
      'id': m['id'],
    });
  }
} catch (_) {}
```

Plus an icon arm in `_buildActivityIcon` (e.g., `restaurant_menu_rounded` with `honeyGold` background) and a description arm in `_getActivityDescription` like:

```dart
'meal_request_decided' => activity['status'] == 'approved'
    ? ' had "${activity['recipe_title']}" approved for the meal plan'
    : ' had "${activity['recipe_title']}" denied'
        '${(activity['decided_note'] as String?)?.isNotEmpty == true ? " — \"${activity['decided_note']}\"" : ""}',
```

Plus a filter chip ("Meals") in `build()`.

Total: ~60 LOC of additions, no refactors. **The spec note "Activity feed entry on the kid's side" already implicitly assumed this aggregator model — it referenced `activity_feed_screen.dart` by name.**

### Note about the kid scoping bug
`activity_feed_screen.dart:32-34` uses `.eq('auth_user_id', user.id)`. When a kid is the active member (via ActiveMemberService), the query still returns the parent admin's row. So the kid currently sees the admin's view of the activity feed, not their own. This is a pre-existing latent bug, captured in the user's Batch 7 followup list (9 screens to migrate to `MembershipHelper`).

**Decision needed (Q4)**: should 6b also migrate `activity_feed_screen.dart` to `MembershipHelper.loadActiveMembership(...)`? Doing so is ~5 LOC and is the only way the kid will actually see their own request entries in the feed when they're active. Without it, the kid still sees admin-perspective entries and the new meal_request_decided events flow only to admin-visible feed pages.

---

## Phase 1 — Spec excerpts

From `/audits/2026-05-kid-profile-permissions-spec.md`:

**Spec row 3 (Q3, line 16)** — the canonical decision:

> **Three channels:** activity feed entry, "My recent requests" view on recipe library, AND iOS push notification (if push is enabled in the app). Same channels fire on both approve and deny. Auto-archive after 30 days.

**Lines 107-111**:

> 1. **Activity feed entry** on the kid's side. New row in the activity feed surface (existing infrastructure in `activity_feed_screen.dart`). Member kind tagging already exists for activity rows.
> 2. **"My recent requests" view** on the kid-side recipe library. A new small section listing the kid's `meal_requests` rows with status (pending/approved/denied) and `decided_note` rendered when present.
> 3. **iOS push notification** with the same message. Honors the user's `notification_preferences` (existing table) — if push is disabled, this channel is skipped silently; the activity feed entry and recent-requests view still appear.

**Lines 138-143**:

> - Activity feed entry on the kid's side (existing infrastructure in `activity_feed_screen.dart`).
> - "My recent requests" view on the kid-side recipe library: list of the kid's `meal_requests` rows with status (pending/approved/denied) and `decided_note` rendered if present.
>
> Auto-archive (hard-delete) after 30 days, same retention window as chore photos. Batch 6 lands the APNs setup and device-token registration; this is the first push-enabled feature.

### What the spec is silent on
- Whether the "section on recipe library" should be tab-style, popup-menu entry, or in-page section. Spec just says "view on the kid-side recipe library."
- Time horizon (the spec says 30-day auto-archive, but doesn't specify whether the kid view filters to 7d / 30d / all).
- Whether the kid can interact (cancel pending, re-request denied).
- Whether the kid sees status badges/colors or just rows.
- Whether the "Meals" filter on activity feed is on by default or requires a filter chip tap.

These all need user decisions before Phase 2 implementation.

---

## Phase 2 — Recent requests view (design)

### Entry point options

**Option A — Tab on recipe_library_screen.dart**
- Add a 3rd tab "My Requests" alongside "My Recipes" + "Browse Library", visible only to kids.
- Pro: spec literal — "view on the kid-side recipe library."
- Con: `recipe_library_screen.dart:64` uses the legacy `.eq('auth_user_id', user.id)` pattern, so the kid will see admin's recipe library content even before the new tab is added. Would force a MembershipHelper migration on recipe_library_screen — a Batch 7 item that becomes a 6b dependency. +30 LOC of churn.

**Option B — Standalone screen, reached from popup menu (admin-popup-style, kid-only entry)**
- New screen `kid_my_requests_screen.dart` (~200-250 LOC). Reached via a popup menu item that's gated by `Permissions.isKid(_myMembership)`.
- Uses `MembershipHelper.loadActiveMembership(...)` from day 1 — no legacy pattern issue.
- Pro: clean isolation; doesn't drag recipe_library into the kid-perms migration this batch.
- Con: divergence from the spec phrasing.

**Option C — Floating "My Requests" affordance on `recipe_detail_screen.dart`**
- After a kid submits a request via `MealRequestSheet`, surface a small chip "View my requests" in the SnackBar action. Plus a permanent entry from the popup menu.
- Pro: discoverability.
- Con: more places to add UI; only slightly different from B.

**Recommendation: Option B**. Lower coupling, fits the existing popup-menu pattern, and avoids dragging the wider MembershipHelper migration into this batch. If the user really wants the "recipe library tab" placement, defer until after Batch 7 lands the membership migration on `recipe_library_screen.dart`.

### What the view shows

Per spec (lines 108, 140): rows of the kid's `meal_requests` with status + `decided_note`. Reasonable per-row content:

- Recipe thumbnail (left, 56×56, fallback to honey emoji)
- Recipe title (bold)
- Status badge (pill: yellow "Pending", green "Approved", red "Denied")
- Submitted-on timestamp (relative: "3 days ago")
- For approved: scheduled date + meal_type pill
- For denied: `decided_note` rendered if non-empty

### Filter / time horizon

Reasonable defaults:
- **All-time** by default. The 30-day archive (spec line 143) means rows older than 30 days are hard-deleted anyway, so "all-time" effectively caps at 30 days.
- No filter chips — keep it simple. Add segmented control later if requested.

### Read-only vs interactive

**Read-only for 6b**. Spec doesn't mention cancel/re-request. Recommend:
- No "Cancel" action on pending requests in 6b. Kid can still tap the recipe to re-open the request sheet if they want to re-submit (but no de-dup constraint exists on `meal_requests`, so they'd just create another pending row — admin can deny one).
- No "Request again" action on denied rows in 6b. Same workaround: tap into the recipe detail.
- Both could be added in 6c or later as polish.

### Realtime updates

The view should `addListener` to `RealtimeService.instance.mealRequestsVersion` (added in sub-piece A) and reload its query when bumped. Standard pattern from `recipe_library_screen.dart:42-43`.

### Active-member resolution

Critical: **use `MembershipHelper.loadActiveMembership(includeHouseholdJoin: true)` from day 1**. The screen filters meal_requests by `requested_by_member_id = membership['id']`, so getting the correct member id is the whole point. If we use the legacy `.eq('auth_user_id', ...)` we'll filter by the parent admin's id and show zero rows.

---

## Phase 3 — RealtimeService changes

`apps/mobile/lib/services/realtime_service.dart` (163 LOC) has 8 existing notifiers + 8 corresponding `onPostgresChanges` blocks. Adding `mealRequestsVersion` is a copy-paste:

```dart
// Field declaration (line 17-24 area):
final ValueNotifier<int> mealRequestsVersion = ValueNotifier(0);

// Subscription block (after announcements at line 136):
_channel!.onPostgresChanges(
  event: PostgresChangeEvent.all,
  callback: (_) => mealRequestsVersion.value++,
  filter: PostgresChangeFilter(
    type: PostgresChangeFilterType.eq,
    column: 'household_id',
    value: householdId,
  ),
  schema: 'public',
  table: 'meal_requests',
);

// reset() body (line 160 area):
mealRequestsVersion.value = 0;
```

Total: ~16 LOC in `realtime_service.dart`.

In `home_shell_screen.dart`:
- Remove the 6a TODO comment at lines 120-124.
- Add `RealtimeService.instance.mealRequestsVersion.addListener(_onApprovalsSourceChanged);` in `initState()` (where the chores/shopping listeners already exist).
- Add the matching `removeListener` in `dispose()`.

~3 LOC in `home_shell_screen.dart`.

`approvals_screen.dart` should also subscribe so the admin sees new requests appear instantly. Standard 2-line addition (one listener add, one remove).

`kid_my_requests_screen.dart` (new in sub-piece C) subscribes for the same reason.

### Re-test
- Kid submits request → admin's badge count increments without page refresh.
- Admin decides → kid's recent-requests view updates without page refresh (assuming kid screen is foregrounded).

---

## Phase 4 — Activity feed integration

### Client-side vs server-side
Given Phase 0 — no server-side activity table — **client-side is the only option**. No trigger to add, no RPC amendment. Just amend `activity_feed_screen.dart._loadData()`.

### Code shape
See Phase 0 "What this means for 6b" section above. Three additions:

1. **`_loadData()`**: add a 6th `try { ... }` block querying `meal_requests` with `status != 'pending'`, joined to `household_recipes` (title) and `household_members` (display_name + kind).

2. **`_buildActivityIcon()`**: switch arm for `'meal_request_decided'` returning a circular container with `Icons.restaurant_menu_rounded` (or similar) in `honeyGold` (approved) or `coral` (denied). Approved-vs-denied could share an icon and just vary color.

3. **`_getActivityDescription()`**: switch arm rendering the description string. Suggested copy:
   - Approved: `' had "<recipe>" approved for the meal plan'`
   - Denied without note: `' had "<recipe>" denied'`
   - Denied with note: `' had "<recipe>" denied — "<note>"'`

4. **`_buildFilterChip` calls in `build()`**: add a new chip:
   ```dart
   _buildFilterChip('meal_request_decided', 'Meals', Icons.restaurant_menu)
   ```

### Pre-existing latent bug acknowledgment
`activity_feed_screen.dart:32-34` will continue to return admin membership for kid sessions until Batch 7's wider migration. The new meal_request entries will surface for the admin's view of the feed (which is what matters for shared family awareness). Kid-perspective feed accuracy depends on the Batch 7 migration. **Q4 below asks whether to bundle that 5-LOC fix into 6b.**

### Filter member by household_id only?
The current 5 queries all filter by `household_id` only — they show **every** household member's activity, including the active user's own actions. Recommend the meal_request block follow the same convention (filter on `household_id`, not `requested_by_member_id`). Kids in the household will see other kids' approved/denied requests too. That's the existing semantic of the feed.

---

## Phase 5 — Total scope (restated)

| Sub-piece | File | New file? | LOC |
|---|---|---|---|
| A | `services/realtime_service.dart` | no | +16 |
| A | `screens/home_shell_screen.dart` | no | +3, -5 (drop TODO) |
| A | `screens/approvals_screen.dart` | no | +3 |
| B | `screens/activity_feed_screen.dart` | no | +60 |
| C | `screens/kid_my_requests_screen.dart` | **yes** | +250–300 |
| C | `screens/home_shell_screen.dart` | no | +6 (popup menu item, kid-gated) |
| **Total** | | | **~340–390 LOC** |

If Q4 = "yes migrate activity_feed to MembershipHelper": +5 LOC. If "yes migrate recipe_library too (Option A)": +10 LOC and a wider Batch 7 dependency.

No migrations, no new RPCs, no RLS changes. Backend is already 100% complete from Batches 1+2 + 6a.

---

## Phase 6 — Open questions for the user

1. **Recent-requests entry point**: Option A (recipe library tab, kid-only — requires MembershipHelper migration of recipe_library now), B (standalone screen + popup menu entry, kid-only — recommended), or C (recipe_library tab + a chip from MealRequestSheet's SnackBar)?

2. **Filter / time horizon on recent-requests view**: All-time (default, capped at 30-day auto-archive)? Or segmented control by status (Pending / Approved / Denied)?

3. **Interactive actions on recent-requests view (6b)**: Read-only (recommended)? Or include "Cancel" on pending + "Request again" on denied?

4. **Migrate `activity_feed_screen.dart:32-34` to `MembershipHelper` as part of 6b?** Otherwise kid sees admin's activity feed (pre-existing latent bug from Batch 7's followup list). 5-LOC fix; small enough to bundle but technically out of strict 6b scope.

5. **Activity feed entries: filter by household_id only (matches existing 5 sources) or also tag with `requested_by_member_id` for kid-side filtering?** Recommend household_id-only — matches current semantic where the feed is family-wide.

6. **Recent-requests view content per row**: any objections to the proposed thumbnail + title + status pill + timestamp + (date/meal_type | decided_note) layout? Specifically, render the `decided_note` as a quoted inline string under the title, or as a separate "Why" line?

7. **Auto-archive (30-day hard-delete)**: spec mentions this. Is there an existing cron job to lean on, or do we want to add a Postgres function + pg_cron schedule in 6b? **Recommend defer to 6c** — same window as APNs setup, so they can ship together. For 6b, the kid view just queries everything (≤30 days' worth is small enough to not matter).

8. **Should the kid's MealRequestSheet's success SnackBar include a "View my requests" action chip** that opens the new screen? Nice discoverability touch.

9. **Activity feed filter chip label for the new type — "Meals" or "Meal Requests"?** "Meals" is shorter, matches the existing chip word-count.

10. **Icon for `meal_request_decided`**: `Icons.restaurant_menu_rounded` (matches the 6a sheet)? Or different (e.g., `Icons.calendar_month_rounded` for approved vs `Icons.block_rounded` for denied)?

11. **Approve vs deny color treatment in activity feed**: shared icon with green-vs-red background tint (consistent with `chore_completed` styling), or differentiated icon?

---

## Phase 7 — Recommended path forward

1. User answers Q1–Q11 (or accepts the recommended defaults inline).
2. Single implementation batch on `feat/meals-batch-6b-2026-05-25` containing all three sub-pieces.
3. Smoke-test paths:
   - Kid submits request → admin sees badge increment without page refresh (sub-piece A).
   - Admin decides → kid's recent-requests view updates without refresh (sub-piece A + C).
   - Admin opens activity feed → sees new "decided" entry (sub-piece B).
   - Kid opens popup menu → "My Requests" item visible (sub-piece C).
   - Kid taps "My Requests" → sees their pending + approved + denied with notes (sub-piece C).
4. PR, push, iPhone smoke, audit doc, commit.

### Apply Pass-2/Supabase patterns
- `MembershipHelper.loadActiveMembership(includeHouseholdJoin: true)` in the new screen.
- Pass 2 error pattern (`try/catch` → `debugPrint` → non-const SnackBar with `\$e`) on every RPC/query call site.
- `ValueKey(request['id'])` on each row in the list (List<T>.map() reconciliation safety).
- No `StatefulWidget` dialog needed in 6b unless we add a "Cancel" confirm dialog — if so, follow the `reject_reason_dialog.dart` pattern.

---

## What this batch deliberately does NOT include
- No migrations.
- No new RPCs.
- No push notifications, APNs cert, device_tokens, edge function dispatch. **All in 6c.**
- No 30-day auto-archive cron job. **Defer to 6c.**
- No mass migration of all 9 legacy `.eq('auth_user_id', user.id)` screens — only `activity_feed_screen.dart` if Q4 = yes; full migration deferred to Batch 7.
- No re-submit / cancel actions on the kid view.
- No changes to `approve_chore` / `approve_wishlist_item` / `decide_meal_request` RPCs.

---

## Next steps (for the user)
- Answer Q1–Q11 (or accept the recommended defaults), then kick off the implementation pass.
- The implementation should fit a single commit per the standing 3-step rule pattern.
