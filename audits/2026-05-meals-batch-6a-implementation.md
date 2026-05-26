# Batch 6a — Meal Requests UI Implementation Report

Date: 2026-05-25
Branch: `feat/meals-batch-6a-2026-05-25`
Status: **changes uncommitted** — user reviews then commits

## Summary

Closes the kid-submits/admin-decides meal-request loop end-to-end:
- Kid sees "Request this meal" FAB on `recipe_detail`; opens `MealRequestSheet` (new file). Submits via `create_meal_request` RPC.
- Admin sees a new "Meal Requests" section as the 3rd block in `approvals_screen`. Approve calls `decide_meal_request` directly when request has both date+meal_type; otherwise opens `_ApproveMealRequestDialog` to collect overrides + optional note. Deny reuses `showRejectReasonDialog` with the new `verb: 'Deny'` param.
- Home shell's AppBar inbox badge count now sums chores + wishlist + meal_requests.

All 11 locked decisions honored. No migration, no new RPC — backend complete from Batches 1+2.

Deferred per Q1: 6b (kid recent-requests view + activity feed entries on decide), 6c (push notifications + APNs + edge function).

## Files modified / created

| File | Type | Net LOC | Purpose |
|---|---|---|---|
| `apps/mobile/lib/widgets/reject_reason_dialog.dart` | modified | +5 | Optional `String verb = 'Reject'` param on both the public function and `_RejectReasonDialog` state. Title + button label adapt. Backward-compatible. |
| `apps/mobile/lib/widgets/meal_request_sheet.dart` | **new** | +263 | Kid submission bottom sheet. Date picker (90-day window) + meal-type dropdown + Submit. Calls `create_meal_request` RPC. Active-member-aware via `MembershipHelper`. Pass 2 error pattern. |
| `apps/mobile/lib/screens/recipe_detail_screen.dart` | modified | +17 | Kid branch on the meal FAB's onPressed: kid → `MealRequestSheet.show`; adult → existing `_addToMealPlan`. Tooltip adapts. Import the new sheet. |
| `apps/mobile/lib/screens/approvals_screen.dart` | modified | +355 | New state `_pendingMealRequests`. Parallel query in `_loadData` (joined to recipes + members). New section in `build()` (3rd, after Wishlist). `_approveMealRequest` + `_denyMealRequest` handlers (Case A direct RPC; Case B prompts overrides via dialog). New `_MealRequestCard` widget. New `_ApproveMealRequestDialog` StatefulWidget + `_ApproveMealResult` data class. New `_formatMealDate` helper + `_mealTypeEmojis` constant. |
| `apps/mobile/lib/screens/home_shell_screen.dart` | modified | +13 | `_loadPendingTotal` extended with 3rd parallel query for `meal_requests` pending. Comment notes the missing `mealRequestsVersion` realtime listener (6b followup). |

**Net: +653 LOC.** Larger than the ~380 estimated in the investigation — most of the overflow is the `_ApproveMealRequestDialog` (~150 LOC) and `_MealRequestCard` thumbnail handling (~80 LOC) being more involved than the investigation rough-sized.

## Phase 1 — reject_reason_dialog verb param

3-line API change with backward-compatibility:

```dart
Future<String?> showRejectReasonDialog(
  BuildContext context,
  String itemName, {
  String verb = 'Reject',      // NEW
}) {
  return showDialog<String?>(
    context: context,
    builder: (ctx) => _RejectReasonDialog(itemName: itemName, verb: verb),
  );
}

class _RejectReasonDialog extends StatefulWidget {
  const _RejectReasonDialog({required this.itemName, required this.verb});
  final String itemName;
  final String verb;              // NEW
  // ...
}
```

Title becomes `'$verb "$itemName"?'` and the FilledButton label is `Text(widget.verb)`. Existing callers (chore_dashboard removed in 5b-i; chore_detail; approvals chore reject) pass no `verb` → default `'Reject'` preserves their behavior. The new meal-request deny calls `showRejectReasonDialog(context, recipeTitle, verb: 'Deny')`.

## Phase 2 — MealRequestSheet (new file)

`apps/mobile/lib/widgets/meal_request_sheet.dart` (~263 LOC). Bottom sheet StatefulWidget with the static `show` entry point:

```dart
final sent = await MealRequestSheet.show(
  context,
  recipeId: ...,
  recipeTitle: ...,
);
```

State: `DateTime? _selectedDate`, `String? _selectedMealType`, `bool _isSubmitting`.

Layout:
- "Request this meal" title + recipe title subtitle
- **When?** section — InkWell row showing `_selectedDate` ("Mar 15" format) or "Any day" placeholder. Tap opens `showDatePicker` with `firstDate=today`, `lastDate=today+90` (Q9). Clear-to-null IconButton when date is set.
- **What meal?** section — `DropdownButtonFormField<String?>` with "Any meal" (null) + 5 enum values (`breakfast`, `lunch`, `dinner`, `snack`, `other`) with emojis.
- Full-width FilledButton "Send request" + secondary "Cancel".

`_submit`:
1. Loads membership via `MembershipHelper.loadActiveMembership(includeHouseholdJoin: true)`.
2. Defensive: throws if membership null or `!Permissions.isKid` — sheet should only open for kids.
3. Calls `create_meal_request` RPC with all 5 params (`p_household_id`, `p_member_id`, `p_recipe_id`, `p_requested_for_date` as `YYYY-MM-DD` or null, `p_meal_type` or null).
4. SnackBar "Request sent — waiting for admin approval" (Q11) → `Navigator.pop(context, true)`.
5. Pass 2 error pattern on failure.

Date format helper `_formatDate` — "MMM d" if current year else "MMM d, yyyy".

## Phase 3 — recipe_detail kid branch

Existing meal FAB (`heroTag: 'meal'`, `onPressed: _addToMealPlan`) gets its onPressed branched on `Permissions.isKid(_householdMember)`:

```dart
FloatingActionButton.small(
  heroTag: 'meal',
  onPressed: () async {
    if (Permissions.isKid(_householdMember)) {
      await MealRequestSheet.show(
        context,
        recipeId: widget.recipeId,
        recipeTitle: _recipe?['title'] ?? 'this meal',
      );
    } else {
      await _addToMealPlan();   // existing adult flow
    }
  },
  backgroundColor: AppColors.skyBlue,
  tooltip: Permissions.isKid(_householdMember)
      ? 'Request this meal'
      : 'Add to meal plan',
  child: const Icon(Icons.calendar_month, color: Colors.white),
),
```

Imports `meal_request_sheet.dart`. Both branches `await` to satisfy `unawaited_futures` lint (caught mid-implementation — the original `_addToMealPlan()` was un-awaited; analyzer flagged the new context).

Note: the meal FAB was already visible to kids — its existing `canEdit` gate was `widget.isHouseholdRecipe` (NOT `isAdmin`), so no visibility change is needed. The change is purely in the onPressed branching.

## Phase 4 — approvals_screen integration

### State + query

New field:
```dart
List<Map<String, dynamic>> _pendingMealRequests = [];
```

Added as 4th sequential query in `_loadData` (after the 3 existing chore + photo + wishlist queries):

```dart
final pendingMealsRaw = await Supabase.instance.client
    .from('meal_requests')
    .select(
        '*, recipe:household_recipes(title, image_url), '
        'requester:household_members!requested_by_member_id(display_name, kind)')
    .eq('household_id', householdId)
    .eq('status', 'pending')
    .order('created_at', ascending: false);
```

setState updates 4 fields atomically (including the new `_pendingMealRequests`).

`hasAny` extends:
```dart
final hasAny = _pendingVerification.isNotEmpty
    || _pendingWishlist.isNotEmpty
    || _pendingMealRequests.isNotEmpty;
```

### Build — 3rd section

Added after the Pending Wishlist conditional block, before the closing `]` (Q10 — chores → wishlist → meals):

```dart
if (_pendingMealRequests.isNotEmpty) ...[
  _SectionHeader(title: 'Meal Requests', count: _pendingMealRequests.length),
  const SizedBox(height: 8),
  ..._pendingMealRequests.map((req) {
    final recipeTitle = req['recipe']?['title'] ?? 'this meal';
    return _MealRequestCard(
      key: ValueKey(req['id']),
      request: req,
      onApprove: () => _approveMealRequest(req),
      onDeny: () => _denyMealRequest(req['id'], recipeTitle),
    );
  }),
  const SizedBox(height: 24),
],
```

ValueKey on each card (5b-i lesson; non-negotiable). Empty state ("🎉 All caught up!") unchanged in copy; it just shows when all three sections are empty (Q10).

### Handlers

`_approveMealRequest(request)`:
- **Case A** (request has both `requested_for_date` AND `meal_type`): call `decide_meal_request(p_request_id, p_approved: true)` directly. SnackBar "Added to meal plan" → reload.
- **Case B** (either field null): open `_ApproveMealRequestDialog` → on confirm, call RPC with `p_planned_for_override`, `p_meal_type_override`, optional `p_note`. SnackBar → reload.
- Pass 2 error pattern.

`_denyMealRequest(requestId, recipeTitle)`:
- Opens `showRejectReasonDialog(context, recipeTitle, verb: 'Deny')`. Title shows "Deny X?"; button shows "Deny".
- If reason is null → cancelled. Otherwise call `decide_meal_request(p_request_id, p_approved: false, p_note: reason.isEmpty ? null : reason)`. SnackBar "Request denied" → reload.

### New widgets

**`_MealRequestCard`** (`StatelessWidget`, ~135 LOC):
- Card with padding; Row of (image, expanded column)
- Image: 64x64 `ClipRRect(Image.network(recipeImageUrl, ...))` with `errorBuilder` fallback to a grey placeholder + restaurant icon. If `image_url` is null/empty, renders the placeholder directly.
- Column: recipe title (bold), metadata row `'$mealStr · $dateStr'` (e.g., "🌙 Dinner · Mar 15" or "Any meal · Any day"), then `'Requested by [kid] · 2h ago'` (reuses `_formatRelative`).
- Bottom button row: Deny (coral OutlinedButton) + Approve (grassGreen FilledButton).

**`_ApproveMealResult`** — small data class bundling `date`, `mealType`, optional `note`.

**`_ApproveMealRequestDialog`** (`StatefulWidget`, ~150 LOC):
- Constructor takes `recipeTitle`, optional `initialDate`, optional `initialMealType` (pre-fill from the kid's submission).
- State: `_date`, `_mealType` (defaults to 'dinner'), `_noteController` (TextEditingController — owned by State, disposed in `dispose` per 5b-i lesson).
- Date picker InkWell + Meal type Dropdown + Note TextField (2 lines, 500 char max).
- Submit validates date is set (raises SnackBar if not), then `Navigator.pop(context, _ApproveMealResult(...))`. Empty note → null.

### New file-level helpers

`_mealTypeEmojis` const map + `_formatMealDate(iso)` helper. Both used by `_MealRequestCard` and `_ApproveMealRequestDialog`.

## Phase 5 — home_shell `_loadPendingTotal` extension

Aggregator query extended from 2 parallel queries to 3:

```dart
final results = await Future.wait([
  // chores pending_verification (existing)
  // shopping_items is_wishlist=true (existing)
  Supabase.instance.client
      .from('meal_requests')
      .select('id')
      .eq('household_id', householdId)
      .eq('status', 'pending'),
]);
final total = (results[0] as List).length
            + (results[1] as List).length
            + (results[2] as List).length;
```

### Realtime status

`RealtimeService` (apps/mobile/lib/services/realtime_service.dart) has version notifiers for chores, shopping, mealPlans, recipes, members, points, rewards, announcements — but **no `mealRequestsVersion`**.

For 6a, count freshness on the AppBar badge relies on:
1. Initial load (existing `_loadHouseholdInfo` calls `_loadPendingTotal` after admin determined)
2. Navigation-return refresh (the existing `await Navigator.push(ApprovalsScreen) → _loadPendingTotal`)

This is identical to the realtime pattern for chores/shopping when those listeners fire too late — fine at current single-household scale.

**Followup for Batch 6b**: add `mealRequestsVersion` to `RealtimeService` + subscribe in home_shell. Inline comment in `_loadPendingTotal` flags this. Once 6b lands the activity feed entries (which happen via RPC's INSERT into wherever the activity feed reads from), the realtime channel can detect them too. Easy to bolt on later.

## Phase 6 — Analyzer deltas

| Scope | Before | After | Net new errors | Net new info/warnings |
|---|---|---|---|---|
| `flutter analyze apps/mobile/` | 362 | 368 | **0** | +6 |

The pre-existing `MyApp` error in `test/widget_test.dart:16` is unchanged.

The +6 routine warnings are split across the new files:
- `meal_request_sheet.dart`: 1-2 routine `prefer_const_constructors` + 1 `inference_failure_on_function_invocation` on the new `.rpc('create_meal_request')` call site
- `approvals_screen.dart`: 2-3 routine warnings on `.rpc('decide_meal_request')` (2 call sites — Case A direct + Case B with overrides) + the `_ApproveMealRequestDialog` build
- `recipe_detail_screen.dart`: routine warnings on the new `MaterialPageRoute`-style closure inside the FAB

All match existing codebase patterns. **No new errors.**

**Caught mid-implementation**: `unawaited_futures` at `recipe_detail_screen.dart:561` on the `_addToMealPlan()` call inside my new branched onPressed closure. Fixed with `await`. The enclosing closure was already `async`.

## iPhone smoke-test checklist

After rebuilding on this branch:

| # | Path | Expected |
|---|---|---|
| 1 | As Randi, open a recipe_detail | Two small FABs visible: cart + calendar. Calendar tooltip reads "Request this meal" |
| 2 | Tap calendar FAB | `MealRequestSheet` opens from bottom; "Request this meal" title; recipe name as subtitle |
| 3 | Tap "Send request" with both fields null (Any day, Any meal) | SnackBar "Request sent — waiting for admin approval"; sheet pops |
| 4 | SQL verify | `meal_requests` row exists: `requested_by_member_id=Randi`, `recipe_id` correct, `status='pending'`, `requested_for_date IS NULL`, `meal_type IS NULL` |
| 5 | Switch to admin → AppBar | Inbox badge increments to include the meal request |
| 6 | Open Approvals | New "Meal Requests" section (3rd, after Wishlist) with the card. Recipe title, image (if recipe has one), "Any meal · Any day", "Requested by Randi · just now" |
| 7 | Tap Approve | Case B dialog opens (since fields were null). Pre-filled meal type = "dinner"; date empty. |
| 8 | Pick a date, add an optional note, tap Approve | RPC fires with override params + p_note. Card disappears. SnackBar "Added to meal plan". Badge decrements. |
| 9 | SQL verify | `meal_requests` row updated: `status='approved'`, `decided_at` set, `decided_note` populated. New `meal_plans` row created with admin's chosen date + meal_type. |
| 10 | Case A test | As Randi submit again, this time picking a date + meal_type. As admin tap Approve — should fire RPC DIRECTLY, no dialog. SnackBar + reload. |
| 11 | Deny test | As Randi submit another. As admin tap Deny → `showRejectReasonDialog` opens. Title reads "Deny "[recipe name]"?". Button reads "Deny". |
| 12 | Type a deny reason → tap Deny | SnackBar "Request denied". Card disappears. SQL: `status='denied'`, `decided_note` populated. |
| 13 | Empty state | Approve/deny everything → "🎉 All caught up!" still renders correctly |
| 14 | Adult recipe_detail | Calendar FAB tooltip reads "Add to meal plan"; tap opens existing meal-plan dialog (not MealRequestSheet) |
| 15 | Mid-Approvals profile switch | Same as 5b-i pattern — switch to Randi mid-screen, Approvals pops back to home |

## Known followups

### Batch 6b (planned next)

- **Kid "My recent requests" view** — recipe_library_screen or kid profile gets a section listing the kid's recent meal_requests with status + decided_note. Lets kid see "Mom approved my Mac and Cheese request" without push.
- **Activity feed entry on decide** — wire `decide_meal_request` to also insert an `analytics_events` row (or wherever activity feed reads), so the kid sees the decision in their activity feed.
- **Add `RealtimeService.mealRequestsVersion`** + subscribe in home_shell so the AppBar badge updates instantly on multi-device scenarios. Inline comment in `_loadPendingTotal` flags this as the right place to wire it.

### Batch 6c (planned after 6b)

- **iOS push notifications** for meal request decisions. APNs cert setup + `device_tokens` registration + edge function for server-side dispatch. First push-enabled feature.

### Other latent items not from this batch

- **`shopping_category_screen.dart:104` dispose bug** (noted from 5b-ii) — still pending. Apply the `_AddCategoryDialog` StatefulWidget pattern from 5b-ii or the `_RejectReasonDialog` pattern from 5b-i.
- **Necessity-category vs UI-dropdown mismatch** (5b-ii surfaced; broader reconciliation in the smart-shopping-pantry workstream stub).

## What 6a explicitly did NOT touch

- `meal_planner_screen.dart` kid path (out of scope; could be a kid entry point in a future polish)
- Activity feed (6b)
- Push notifications (6c)
- `RealtimeService` (6b will add `mealRequestsVersion`)
- Any RPC or migration (`create_meal_request` + `decide_meal_request` shipped Batch 2; perfect for 6a)
- `Permissions.isKid` (already exists)
- The chore or wishlist sections of Approvals — only the new 3rd section was added

## Next steps for the user

1. Review the 5 files (2 new + 3 modified).
2. Rebuild iOS on this branch.
3. Smoke-test the 15 paths above. Particular attention to Case A vs Case B approve flows; verify the SQL state changes match expectations.
4. Commit + push with the standard template.
5. Schedule 6b (recent-requests + activity feed + realtime listener).
6. Schedule 6c (push notifications + APNs).

After 6a + 6b + 6c, Pass 3 remaining: Batch 7 (UI hardening), Batch 8 (music app deep link). The kid permissions workstream becomes complete.
