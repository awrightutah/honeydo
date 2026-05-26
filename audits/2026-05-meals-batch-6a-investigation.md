# Batch 6a — Meal Requests UI Investigation

Date: 2026-05-25
Branch: `feat/meals-batch-6a-2026-05-25` (read-only investigation; no edits, no commits)
Status: investigation complete — **backend 100% shipped; app side 100% greenfield**; **recommend 6a = kid submission + admin Approvals integration only**; ~400-450 LOC; **defer 6b (kid recent-requests + activity feed) and 6c (push notifications) to separate batches**.

## Summary

The Batch 1/2 backend shipped everything 6a needs: `meal_requests` table, `create_meal_request` RPC (kid-only, inserts pending row), `decide_meal_request` RPC (admin-only, on approve atomically creates the matching `meal_plans` row), and full RLS coverage. **No new migrations or RPCs required for 6a.**

App side is greenfield — zero `meal_request` references in `apps/mobile/lib/`. 6a designs and builds both halves of the request loop: kid "Request this meal" from recipe_detail + admin Pending Meal Requests as the third section of the Approvals screen.

Out of scope for 6a, deferred to later sub-batches: kid "My recent requests" view (6b), activity feed entry on decide (6b), iOS push notifications + APNs/device-token infrastructure (6c — significant scope of its own).

## Phase 0 — Inventory

### Schema (migration 0016:156-179)

```sql
CREATE TABLE IF NOT EXISTS public.meal_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id uuid NOT NULL REFERENCES public.households(id) ON DELETE CASCADE,
  requested_by_member_id uuid NOT NULL REFERENCES public.household_members(id) ON DELETE CASCADE,
  recipe_id uuid NOT NULL REFERENCES public.household_recipes(id) ON DELETE CASCADE,
  requested_for_date date,
  meal_type meal_type,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'approved', 'denied')),
  decided_by_member_id uuid REFERENCES public.household_members(id) ON DELETE SET NULL,
  decided_at timestamptz,
  decided_note text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_meal_requests_household_status ON ... (household_id, status);
CREATE INDEX idx_meal_requests_requested_by ON ... (requested_by_member_id);
ALTER TABLE public.meal_requests ENABLE ROW LEVEL SECURITY;
```

**Critical design constraint**: `recipe_id` is **NOT NULL** — every meal request must reference an existing `household_recipes` row. No freeform meal names supported. Kid picks a recipe first, then requests it.

**`requested_for_date` and `meal_type` are nullable** — kid can submit without specifying. Admin can fill in at decide time via override params.

**`decided_note` is admin-only** — there's no field for the kid to attach a note at submission.

**Postgres `meal_type` enum** (from `0001_initial_schema.sql:15`): `breakfast, lunch, dinner, snack, other` (5 values).

### RPCs (migration 0017:519-707)

#### `create_meal_request(p_household_id, p_member_id, p_recipe_id, p_requested_for_date?, p_meal_type?)`

Kid-only. Validates:
1. Caller's JWT is in household
2. Member is active sub_profile (`is_member_kid`)
3. Member's household matches `p_household_id`
4. Recipe exists in this household

INSERT into `meal_requests` with status='pending'. Returns the new id.

Signature for grants/revokes: `(uuid, uuid, uuid, date, meal_type)`.

#### `decide_meal_request(p_request_id, p_approved, p_note?, p_planned_for_override?, p_meal_type_override?)`

Admin-only. Returns `jsonb {status, meal_request_id, meal_plans_id}`.

Validates:
1. Request exists
2. Caller is admin in the request's household
3. Status is currently 'pending' (raises on already-decided)

**On approve**:
- Resolves final date = `COALESCE(p_planned_for_override, v_requested_for_date)`
- Resolves final meal_type = `COALESCE(p_meal_type_override, v_request_meal_type)`
- **Raises** if either is still null after coalesce — admin MUST provide via override if request didn't specify
- INSERT into `meal_plans(household_id, planned_for, meal_type, recipe_id, created_by_member_id)`
- UPDATE meal_requests row: status='approved', decided_by_member_id, decided_at, decided_note=p_note
- Returns jsonb with `meal_plans_id` populated

**On deny**:
- UPDATE meal_requests row: status='denied', decided_by_member_id, decided_at, decided_note=p_note
- Returns jsonb with `meal_plans_id: null`

Signature for grants/revokes: `(uuid, boolean, text, date, meal_type)`.

### RLS (migration 0017:872-895)

```sql
-- 9f. meal_requests
CREATE POLICY meal_requests_household_select   -- any household member can SELECT
  ON public.meal_requests FOR SELECT
  USING (public.is_household_member(household_id));

-- No direct INSERT — kids go through create_meal_request RPC
CREATE POLICY meal_requests_no_direct_insert
  ON public.meal_requests FOR INSERT
  WITH CHECK (false);

CREATE POLICY meal_requests_admin_update      -- admin-only UPDATE (RPC bypasses via SECURITY DEFINER)
  ON public.meal_requests FOR UPDATE
  USING (public.is_household_admin(household_id))
  WITH CHECK (public.is_household_admin(household_id));

CREATE POLICY meal_requests_admin_delete      -- admin-only DELETE
  ON public.meal_requests FOR DELETE
  USING (public.is_household_admin(household_id));
```

All correct. Admin can SELECT all pending requests for their household. RPC mediates kid inserts. Direct UPDATE blocked for non-admins.

### App-side (`apps/mobile/lib/`)

`grep -rn "meal_request\|MealRequest"` → **zero results.** Greenfield.

For context: `recipe_detail_screen.dart` already has `_addToMealPlan` for adults (line 323). `meal_planner_screen.dart` has `_AddMealPlanSheet` with `_mealTypes = ['breakfast', 'lunch', 'dinner', 'snack', 'other']`. recipe_detail's existing meal-plan flow uses `['breakfast', 'lunch', 'dinner', 'snack']` (4 — no "other"). Both are reachable patterns.

## Phase 1 — Spec on meal requests

From spec line 124 (Batch 6 row) + line 103-111 ("Meal-decision notification channels"):

**What the spec says ships in Batch 6:**

1. **"Request this meal" on recipe detail** (kid-only via Permissions helper).
2. **Admin "Pending Meal Requests" section in Pending Requests** (= Approvals screen post-5b-i).
3. **Approve creates meal_plans row** (already in `decide_meal_request` RPC ✓), **deny updates status + decided_note** (✓ also in RPC).
4. **Kid "My recent requests" view** — new section on the kid-side recipe library showing the kid's meal_requests with status + decided_note.
5. **Activity feed entry on decide** — uses existing `activity_feed_screen.dart` infrastructure.
6. **iOS push notification on decide** — "Mom approved your Mac and Cheese request" — first push-enabled feature; ships APNs setup + `device_tokens` registration + server-side dispatch.

**The spec lumps all six items into Batch 6**, but reading the scope, items 4-6 each add real complexity:
- 4 (recent requests view) needs a new UI surface on recipe_library_screen and is independent of the request loop itself
- 5 (activity feed entry) needs the activity_feed infrastructure to be examined; likely requires a row insert at decide time
- 6 (push notifications) is its own major workstream — APNs cert setup, edge function for server-side dispatch, device_tokens flow, notification permission UX

**Recommendation: split Batch 6 into sub-batches:**
- **6a** (this brief): items 1-3 only. Closes the kid-submits/admin-decides loop end-to-end. Testable in isolation. ~400-450 LOC.
- **6b**: items 4-5 (kid recent-requests view + activity feed entry on decide). ~250-350 LOC.
- **6c**: item 6 (push notifications + APNs infrastructure). Significant scope of its own. Could be ~500-1000 LOC depending on edge function complexity.

The original spec didn't anticipate splits; the lessons-learned pattern from prior batches (4a/4b, 5a/5b-i/5b-ii) makes splits standard. Surfaced as Q1.

### Ambiguities the spec doesn't resolve

- **Does kid pick date + meal_type at submit, or leave for admin?** Spec doesn't say. RPC accepts both as optional. Two valid designs (Q2).
- **Where does kid submit from?** Spec says recipe_detail only. What about a "Browse recipes" entry in the kid's recipe library? Probably out of 6a (kid recent-requests view in 6b might add a "request another" entry point).
- **Admin approve flow when request has no date/meal_type?** Spec doesn't address; RPC raises if final date/meal_type still null after override. UI must prompt admin. (Q3.)

## Phase 2 — Kid-side submission UI

### Where kid submits

**Single entry point for 6a: recipe_detail_screen.dart's existing meal-plan area.**

Today adults see `_addToMealPlan` button (line 323). Kids see... actually, looking more carefully at recipe_detail's existing flow (`_addToMealPlan`), it doesn't have a kid gate today — kids can probably already tap it and write directly to `meal_plans`, which would be blocked by the meal_plans RLS policy (adult-only direct insert per spec). Worth confirming what happens; for 6a we add the kid path that routes through the RPC.

**Proposed UX**:
- When `Permissions.isKid(_householdMember)`, the existing "Add to meal plan" button text changes to **"Request this meal"** (or both buttons render with `isKid` choosing). The button opens a sheet/dialog.
- Adult sees unchanged "Add to meal plan" → direct insert to meal_plans (existing behavior).

### Submission sheet/dialog content

Three optional inputs:
- **Date**: showDatePicker — defaults to "Any day" (null) with a clear-to-null option
- **Meal type**: dropdown of breakfast/lunch/dinner/snack/other — defaults to null ("Any meal")
- **Notes from kid**: NO — schema has no field for kid notes. `decided_note` is admin's response only. Skip this input.

Submit button → calls `create_meal_request` RPC with the household_id, kid's member_id, recipe_id, optional date, optional meal_type. On success: SnackBar "Request sent — waiting for admin approval". On error: Pass 2 pattern (catch e + debugPrint + non-const SnackBar with `$e`).

### Date/meal_type defaults

**Recommendation (Q2)**: ask kid for date + meal_type at submit, both optional with clear "Any day"/"Any meal" presentation. This gives the kid an avenue to express intent ("I want this for dinner on Friday") while still allowing fast submission ("I want this someday"). Admin sees the kid's intent on the request card.

If both are skipped, admin's approve flow MUST prompt for them (RPC requires both at approve). Either:
- Auto-prompt admin when approving a "any/any" request (Phase 3 detail)
- Or block submission unless both are filled (more restrictive)

Recommend prompt-admin path — keeps kid UX flexible.

### Submission sheet — proposed widget structure

New file `apps/mobile/lib/widgets/meal_request_sheet.dart` (~150-180 LOC) — OR inline in recipe_detail_screen.dart as a private widget.

Recommend new file for reusability (kid recent-requests "Request again" affordance in 6b could reuse it).

Carries forward the **StatefulWidget pattern** for the controller-less inputs (this dialog doesn't have a TextEditingController so the controller-disposal lesson doesn't apply, but it does use StatefulBuilder semantics for the date/meal_type pickers).

Approximate skeleton:

```dart
Future<bool> showMealRequestSheet(BuildContext, {required String recipeTitle, required String recipeId}) async {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _MealRequestSheet(recipeTitle: recipeTitle, recipeId: recipeId),
  ) ?? false;
}

class _MealRequestSheet extends StatefulWidget {
  final String recipeTitle; final String recipeId;
  ...
}

class _MealRequestSheetState extends State<_MealRequestSheet> {
  DateTime? _selectedDate;
  String? _selectedMealType;
  bool _isSubmitting = false;

  Future<void> _submit() async {
    setState(() => _isSubmitting = true);
    try {
      // load active membership via MembershipHelper, get kid member_id + household_id
      await Supabase.instance.client.rpc('create_meal_request', params: {
        'p_household_id': householdId,
        'p_member_id': kidMemberId,
        'p_recipe_id': widget.recipeId,
        'p_requested_for_date': _selectedDate?.toIso8601String().substring(0, 10),
        'p_meal_type': _selectedMealType,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Request sent — waiting for admin approval')),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      debugPrint('create_meal_request failed: $e');
      // SnackBar with $e
    } finally { ... }
  }

  // build(): title "Request '$recipeTitle'", date picker (with "Any day" clear), meal_type dropdown, Cancel + Submit buttons
}
```

`_selectedDate` and `_selectedMealType` are both nullable — null = "Any". Submit packs them as nullable RPC params.

## Phase 3 — Admin Pending Meal Requests section (in Approvals)

### Section design — drop-in 3rd section

After 5b-i's Approvals architecture, adding the third section is mechanical:

1. New state in `approvals_screen.dart`: `_pendingMealRequests: List<Map<String, dynamic>>`
2. Add query in `_loadData` (parallel with existing pending verif + wishlist queries):

```dart
final pendingMeals = await Supabase.instance.client
    .from('meal_requests')
    .select(
        '*, recipe:household_recipes(title, image_url), requester:household_members!requested_by_member_id(display_name, kind)')
    .eq('household_id', householdId)
    .eq('status', 'pending')
    .order('created_at', ascending: false);
```

3. Add new conditional section in `build()` between Wishlist and the empty-state footer (Q10 order from 5b-i: chores → wishlist → meals):

```dart
if (_pendingMealRequests.isNotEmpty) ...[
  _SectionHeader(title: 'Meal Requests', count: _pendingMealRequests.length),
  const SizedBox(height: 8),
  ..._pendingMealRequests.map((req) => _MealRequestCard(
        key: ValueKey(req['id']),
        request: req,
        onApprove: () => _approveMealRequest(req),
        onDeny: () => _denyMealRequest(req['id'], req['recipe']?['title'] ?? 'this meal'),
      )),
  const SizedBox(height: 24),
],
```

ValueKey on each card — same lesson from 5b-i; non-negotiable.

### `_MealRequestCard` widget

Layout (mirrors `_WishlistCard` shape from 5b-i):

```
┌──────────────────────────────────────────────────────┐
│ Mac and Cheese                            (thumb)    │
│ 🍽️ Dinner · Friday, June 5                            │
│   (or "Any day · Any meal" if both null)             │
│ Requested by Randi · 2h ago                          │
│                                                      │
│ [ Deny ]                              [ Approve ]    │
└──────────────────────────────────────────────────────┘
```

- Title row: recipe title (bold) + optional small recipe image thumbnail at right
- Metadata row: meal_type emoji (or "Any meal") + " · " + date ("Any day" if null)
- "Requested by [kid] · [relative time]" — reuse the `_formatRelative` helper from approvals_screen
- Deny + Approve buttons (coral OutlinedButton + grassGreen FilledButton)

Optional polish: recipe image thumbnail (right side, ~64px square). `household_recipes.image_url` is publicly-accessible (recipes are not RLS-private). Use `Image.network`. ~30 LOC.

### `_approveMealRequest(request)` handler

Path depends on whether the request has both date AND meal_type set:

**Case A**: both fields are set on the request → tap Approve → call RPC directly. SnackBar "Added to meal plan". Reload.

**Case B**: either field is null → tap Approve → open a small dialog asking admin to specify the missing field(s):

```
┌─ Approve "Mac and Cheese" ──────────────┐
│                                         │
│ Date: [ Friday, June 5     ▾]           │
│ Meal: [ Dinner             ▾]           │
│                                         │
│ Note (optional): [ ... ]                │
│                                         │
│ [ Cancel ]            [ Approve ]       │
└─────────────────────────────────────────┘
```

Pre-fill any field that the kid DID specify. Admin fills the rest. Submit → RPC with `p_planned_for_override` + `p_meal_type_override` + optional `p_note`. SnackBar. Reload.

`p_note` is the admin's freeform note ("Sounds great, let's do it Friday") that gets stored on the request row. Not required.

### `_denyMealRequest(requestId, requestTitle)` handler

Per the existing wishlist deny pattern + the spec's emphasis on `decided_note`, recommend reusing `showRejectReasonDialog` from 5b-i. It already takes `(context, itemName)` and returns the trimmed text (null on cancel; empty string on Reject-without-text; non-empty on Reject-with-text). Adapt:
- Title: "Deny '$requestTitle'?"
- Body intro: "Tell them why (optional):" (existing copy already fits)

Then: call `decide_meal_request(approved: false, p_note: reason)`. SnackBar "Request denied". Reload.

Q4: confirm reusing `showRejectReasonDialog` vs a separate simple-confirm modal. Recommend **reuse** — the `decided_note` field in the schema is designed for this freeform admin response.

### One small refactor surfaced

`showRejectReasonDialog` currently titles itself `Reject "$itemName"?`. For meal requests we want "Deny". Either:
- Add an optional `verb` param (default 'Reject') so the dialog can render 'Deny "..."?' for meals
- Or use a different action verb display ("Submit" vs "Reject" on the button) and keep the dialog title generic

Recommend `verb` param. Backward-compatible (default keeps existing chore behavior). Surfaced as Q5.

## Phase 4 — Specific changes (LOC estimate)

### `apps/mobile/lib/widgets/meal_request_sheet.dart` (NEW, ~150 LOC)

- `showMealRequestSheet(context, {recipeTitle, recipeId, householdId, kidMemberId})` top-level function
- `_MealRequestSheet` StatefulWidget
- Date picker + meal_type dropdown + Submit handler
- Pass 2 error pattern

### `apps/mobile/lib/screens/recipe_detail_screen.dart` (~30 LOC)

- Existing `_addToMealPlan` stays for adults
- New: gate based on `Permissions.isKid(_householdMember)`. Kid path opens `showMealRequestSheet`. Adult path keeps `_addToMealPlan`.
- Button label adapts: kid sees "Request this meal"; adult sees existing "Add to meal plan"

### `apps/mobile/lib/screens/approvals_screen.dart` (~180 LOC)

- New state field `_pendingMealRequests`
- 3rd parallel query in `_loadData`
- New section in `build()` (above empty-state)
- New `_MealRequestCard` widget (~80 LOC)
- New `_approveMealRequest` handler (~50 LOC, with the Case B prompt sub-dialog)
- New `_denyMealRequest` handler (~25 LOC; reuses showRejectReasonDialog)
- New `_ApproveMealRequestDialog` (Case B) — small StatefulWidget for date/meal_type completion when request is "Any/Any"

### `apps/mobile/lib/screens/home_shell_screen.dart` (~15 LOC)

Extend `_loadPendingTotal`:

```dart
final results = await Future.wait([
  // existing 2 queries
  Supabase.instance.client.from('chores').select('id')
      .eq('household_id', householdId).eq('status', 'pending_verification'),
  Supabase.instance.client.from('shopping_items').select('id')
      .eq('household_id', householdId).eq('is_wishlist', true),
  // NEW:
  Supabase.instance.client.from('meal_requests').select('id')
      .eq('household_id', householdId).eq('status', 'pending'),
]);
final total = (results[0] as List).length
            + (results[1] as List).length
            + (results[2] as List).length;
```

Realtime: `RealtimeService.instance` would need a `mealRequestsVersion` listener. Looking at how `shoppingVersion` was added, this is straightforward — surface as Q6 whether to wire it now or rely on the existing navigation-return refresh pattern.

### `apps/mobile/lib/widgets/reject_reason_dialog.dart` (~3 LOC change)

Optional `String verb = 'Reject'` param → title becomes `'$verb "$itemName"?'`, button label adapts. Backward-compatible.

### Total scope

~380 LOC across 4 modified files + 1 new file (meal_request_sheet.dart). No migration. No new RPC. Modest size — comparable to Batch 5b-ii (~318 LOC).

## Phase 5 — Migration / RPC needs

**None.** Backend is complete. Both RPCs handle every kid+admin flow needed:

- `create_meal_request` handles kid submission with optional date/meal_type
- `decide_meal_request` handles admin approve (with override params for date/meal_type) + admin deny (with note)
- RLS already enforces the admin/kid distinction

The override params on `decide_meal_request` are exactly what we need for the admin's Case B flow ("kid didn't specify date/meal — admin fills in at approve").

## Phase 6 — Kid-side scope

For 6a specifically:
- Kid submission from recipe_detail (in scope, ~30 LOC there + ~150 LOC in new sheet)
- Submission feedback (SnackBar) is sufficient — kid does NOT see their own pending request status anywhere in 6a (that's 6b's "My recent requests" view)

For 6b (separate batch, surfaced for visibility):
- "My recent requests" view in recipe_library_screen — shows the kid's last N meal_requests with status + decided_note
- Activity feed entry on decide — wire `decide_meal_request` to also insert an `analytics_events` row (or wherever the activity feed reads from) so the kid sees "Mom denied your Mac and Cheese request" in their activity feed

For 6c (separate batch):
- iOS push notifications + APNs cert + device_tokens registration + edge function for server-side dispatch

The 6a/6b/6c split keeps each batch shippable + smoke-testable in isolation.

## Phase 7 — Scope estimate

| Component | File | LOC | Type |
|---|---|---|---|
| Meal request sheet widget | `widgets/meal_request_sheet.dart` | ~150 | NEW |
| recipe_detail kid branch | `recipe_detail_screen.dart` | ~30 | modified |
| Approvals 3rd section + handlers + _MealRequestCard + _ApproveMealRequestDialog | `screens/approvals_screen.dart` | ~180 | modified |
| _loadPendingTotal extension | `home_shell_screen.dart` | ~15 | modified |
| `verb` param on showRejectReasonDialog | `widgets/reject_reason_dialog.dart` | ~3 | modified |

**Total: ~380 LOC, 1 new file + 4 modified files. No migration, no new RPC.**

Comparable to Batch 5b-ii. Single batch — don't split further within 6a.

### What's deferred

- Batch 6b: kid recent-requests view + activity feed entry on decide. ~250-350 LOC.
- Batch 6c: push notifications + APNs cert + edge function dispatch. ~500-1000 LOC, lots of infra setup.

## Phase 8 — Open questions

**Architectural:**

- **Q1.** Split Batch 6 into 6a + 6b + 6c as proposed? Recommend **yes** — same lesson as 4a/4b, 5b-i/5b-ii.
- **Q2.** Submit-time prompts for date + meal_type — ask kid or skip? Recommend **ask, both optional**. Admin prompts for missing fields at approve time.
- **Q3.** Admin approve flow when request has no date OR no meal_type — prompt admin via a Case B dialog (recommended) OR raise an error from RPC (current behavior already does this — bad UX). Confirm dialog path.
- **Q4.** Reject/deny modal — reuse `showRejectReasonDialog` from 5b-i, or use a simple confirmation? Recommend **reuse** (gives admin freeform `decided_note`).
- **Q5.** Add `verb` param to `showRejectReasonDialog` so meal-request deny says "Deny X?" instead of "Reject X?"? Recommend **yes** — small, backward-compatible.
- **Q6.** `RealtimeService.mealRequestsVersion` listener for the home_shell badge — wire now in 6a, or rely on navigation-return refresh? Recommend **wire now** for parity with chores + shopping.

**UX:**

- **Q7.** "Request this meal" button copy — keep "Add to meal plan" with isKid branching swap, or two separate buttons (adult sees both)? Recommend **swap based on kind** (kid sees only "Request"; adult sees only "Add").
- **Q8.** Recipe thumbnail on meal-request cards in Approvals? Recommend **yes** (~30 LOC; `household_recipes.image_url` is already public-bucket-served).
- **Q9.** Date picker scope — limit to next 90 days like the existing chore-create flow does? Recommend **yes**.
- **Q10.** Empty Approvals copy when only meal section is empty (other sections have items) — no change, the section just hides (matches 5b-i pattern).
- **Q11.** SnackBar copy: submission "Request sent — waiting for admin approval"; approve "Added to meal plan"; deny "Request denied". Confirm.

**Out of scope (just confirming):**

- Activity feed entry: 6b
- Kid recent-requests view: 6b
- Push notifications + APNs setup: 6c
- Approving a request when the resulting meal_plans row would conflict with an existing one — `meal_plans` has no uniqueness constraint on (household, date, meal_type) per the schema; same date+meal could end up with multiple plans. Pre-existing behavior; not 6a's concern.

## Next steps

1. **You answer Q1-Q11.** Q1-Q6 are architectural; Q7-Q11 are UX defaults with recommendations.
2. **I write Batch 6a** — new sheet file + 4 modified files. Analyzer baseline + after; expect a few new info warnings on `.rpc('create_meal_request')`, `.rpc('decide_meal_request')`, and new MaterialPageRoute call sites.
3. **Commit + push** with the standard template.
4. **iPhone smoke test**:
   - Kid (Randi) opens a recipe → "Request this meal" button shows
   - Submits with date + meal_type → SnackBar; SQL confirms row inserted with status='pending', requested_by_member_id=Randi
   - Switch to admin → AppBar badge increments to include the meal request
   - Open Approvals → "Meal Requests" section appears as 3rd section with the new card
   - Tap Approve → because the kid specified date+meal_type, RPC fires directly → SnackBar; SQL confirms meal_requests.status='approved' + new meal_plans row exists
   - Repeat as kid: submit a "Any/Any" request (no date or meal_type)
   - As admin: tap Approve → Case B dialog opens → fill in date + meal_type → submit → RPC fires with override params → SnackBar; meal_plans row inserted with admin's chosen values
   - Tap Deny on a third request → `showRejectReasonDialog` (with new "Deny" verb) opens → type reason → submit → status='denied' + decided_note populated
5. **Schedule 6b** (recent requests + activity feed) and **6c** (push notifications) as separate batches.

After 6a + 6b + 6c ship, Pass 3 remaining: Batch 7 (UI hardening), Batch 8 (music app deep link). The kid permissions workstream becomes complete.
