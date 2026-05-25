# Kid Permissions Batch 5b-i — Implementation Report

Date: 2026-05-25
Branch: `feat/kid-perms-wishlist-batch-5b-2026-05-25`
Status: **changes uncommitted** — user reviews then commits

## Summary

Closes the architectural piece of 5b-i: unified **Approvals** screen replacing the chore_dashboard's old Pending Verification section. Admins now reach a single dashboard for both chore verifications and wishlist items via an AppBar inbox icon (with badge count). Future Batch 6 meal requests drop in as a third section.

All 11 locked decisions honored. The Necessity Categories admin screen + Settings tile lives in the next batch (5b-ii) per Q4.

## Files modified / created

| File | Type | Net LOC | Purpose |
|---|---|---|---|
| `apps/mobile/lib/widgets/reject_reason_dialog.dart` | **new** | +66 | Shared `showRejectReasonDialog(context, itemName)` — replaces 2 inline duplicates |
| `apps/mobile/lib/screens/approvals_screen.dart` | **new** | +519 | Unified Approvals dashboard: Pending Chore Verifications + Pending Wishlist sections + handlers + 2 card widgets + inline `_SectionHeader` + relative-time helper |
| `apps/mobile/lib/screens/chore_dashboard_screen.dart` | modified | **-218** | Strip Pending Verification (state + query + handler + `_showRejectReasonDialog` + section + Verify stat card + `_VerificationCard` widget + `_createNextRecurringChoreIfNeeded`); drop unused `chore_photo_viewer` import |
| `apps/mobile/lib/screens/chore_detail_screen.dart` | modified | **-30** | Replace inline `_showRejectReasonDialog` with shared util call; add import |
| `apps/mobile/lib/screens/home_shell_screen.dart` | modified | +94 | `_pendingTotal` state + `_loadPendingTotal` aggregator + 2 new realtime listeners + AppBar Approvals badge IconButton (admin-only) replacing the Members IconButton; import approvals_screen |

**Net LOC**: +66 + 519 + 94 − 218 − 30 = **+431 LOC** (vs ~+395 estimated; close).

## Phase 1 — `reject_reason_dialog.dart`

Top-level function `showRejectReasonDialog(BuildContext, String itemName) → Future<String?>`. Returns `null` if cancelled; returns trimmed text (possibly empty) if Reject tapped. Caller converts empty → null before passing to RPC.

Imports: `'package:flutter/material.dart'` + `'../theme/app_theme.dart'` (for `AppColors.coral`). Allocates + disposes a `TextEditingController` internally.

Behavior identical to the previous inline copies (multi-line TextField, maxLength 500, TextCapitalization.sentences, coral FilledButton). One canonical version replaces ~80 LOC of duplication across `chore_dashboard` and `chore_detail`.

## Phase 2 — `approvals_screen.dart` structure

**Top of file**: imports include `active_member_service`, `membership` (for the active-member helper from earlier), `permissions`, `chore_photo_viewer`, `reject_reason_dialog`, `chore_detail_screen` (for the verification card's tap target).

**State**:
- `_myMembership`, `_household`
- `_pendingVerification: List<Map<String, dynamic>>`
- `_latestPhotoByChoreId: Map<String, Map<String, dynamic>?>` — null entry = kid skipped (4a Skip Photo)
- `_pendingWishlist: List<Map<String, dynamic>>`
- `_isLoading: bool`

**Lifecycle**:
- `initState`: `_loadData()` + register `ActiveMemberService.activeMemberId` listener
- `dispose`: remove listener
- `_onActiveMemberChanged`: re-load; if no longer admin, `Navigator.pop(context)` (Q3)

**`_loadData`** flow:
1. `MembershipHelper.loadActiveMembership(includeHouseholdJoin: true)`
2. Bail if null OR not admin (defensive)
3. Sequentially load pending chores + their photos + pending wishlist items
4. `setState` updates all three collections

**Handlers**:
- `_verifyChore(choreId, approved)` — same logic as the old chore_dashboard version, now calls the shared `showRejectReasonDialog` util when `!approved`. Calls `approve_chore` RPC; on approve, calls `_createNextRecurringChoreIfNeeded` (migrated here alongside).
- `_approveWishlistItem(itemId)` — `approve_wishlist_item` RPC; SnackBar "Item added to shopping list"; `catch (e) → debugPrint → SnackBar with $e`.
- `_denyWishlistItem(itemId, name)` — confirmation modal ("Delete this wishlist item? This can't be undone."), then direct DELETE on shopping_items. Same error-surfacing pattern.

**Build**:
- AppBar title: "Approvals"
- Body if loading: `CircularProgressIndicator`
- Body if both lists empty: centered "🎉 All caught up! / Nothing waiting for approval right now." (Q9)
- Body otherwise: `RefreshIndicator(onRefresh: _loadData)` wrapping a `ListView` with sections:
  - if `_pendingVerification.isNotEmpty`: `_SectionHeader('Pending Chore Verifications', count)` + cards (Q10 — chores first)
  - if `_pendingWishlist.isNotEmpty`: `_SectionHeader('Pending Wishlist', count)` + cards

**Widgets in this file**:
- `_SectionHeader` (inlined; same layout as the existing one on chore_dashboard — Row with bold title + honeyGold count pill)
- `_VerificationCard` (migrated from chore_dashboard, unchanged behavior: photo thumbnail, title row, "Completed by [kid]", Reject/Approve)
- `_WishlistCard` (new for 5b-i: title row with display_quantity, category chip, "Requested by [kid] · [relative time]", Deny/Approve)
- `_formatRelative(iso)` top-level helper (~12 LOC) — produces "just now", "Xm ago", "Xh ago", "Xd ago", "Xw ago". No `time_ago` util existed in the codebase per a grep at the start of this batch.

## Phase 3 — chore_dashboard cleanup

**Removed state**:
- `_pendingVerification` list
- `_latestPhotoByChoreId` map

**Removed query**: the entire `if (Permissions.canVerifyChores(_myMembership))` block inside `_loadData` (pending-verif chores + their photos).

**Removed methods**:
- `_verifyChore` (~50 LOC)
- `_showRejectReasonDialog` (~40 LOC) — chore_dashboard had its own copy
- `_createNextRecurringChoreIfNeeded` (~30 LOC) — only called by `_verifyChore`; moves with it

**Removed widget**: `_VerificationCard` class (~115 LOC at end of file)

**Removed from `build()`**:
- The Verify stat card (Q8 — drop the third stat card since the AppBar badge subsumes it)
- The Pending Verification section block
- Simplified the `isAdmin`/`totalVerification` locals (the `isAdmin` local is no longer needed in this screen)

**Removed import**: `../widgets/chore_photo_viewer.dart` (now unused after `_VerificationCard` left)

Net chore_dashboard delta: **-218 LOC**. Becomes a focused "my chores" screen for the active member (kid OR adult). Kid-facing flows (Mark Complete, Re-do, rejected-reason callout in `_ChoreCard`) all untouched.

## Phase 4 — chore_detail update

**Diff**:
- Added: `import '../widgets/reject_reason_dialog.dart';`
- `_rejectFromDetail` now calls `await showRejectReasonDialog(context, ...)` instead of `await _showRejectReasonDialog(...)`.
- Inline `_showRejectReasonDialog` method (~40 LOC) deleted.

Behavior unchanged from Batch 4b — admin Reject chip on a pending-verification chore from chore_detail's Quick Actions still opens the same dialog, just from the canonical shared location now.

## Phase 5 — home_shell AppBar integration

### `_pendingTotal` state + aggregator

- New state field `int _pendingTotal = 0`.
- New method `_loadPendingTotal()` — fires only when `_household != null` and `Permissions.isAdmin(_myMembership)`. Two parallel id-only queries (`chores` pending_verification + `shopping_items` is_wishlist=true), sums lengths, `setState`s. On error: `debugPrint`, keeps last-known count (no UI churn on transient failures).
- Called from `_loadHouseholdInfo` after admin determined (with `await`), and from the two new realtime listeners.

### New realtime listeners

```dart
RealtimeService.instance.choresVersion.addListener(_onApprovalsSourceChanged);
RealtimeService.instance.shoppingVersion.addListener(_onApprovalsSourceChanged);
```

Both call `_loadPendingTotal()` so chore status changes (verified, rejected) and wishlist item changes (approved → is_wishlist=false; denied → row deleted) refresh the badge automatically.

### AppBar swap

**Removed**: the `IconButton(Icons.people_outline_rounded, ..._navigateToMembers)` (Q6 — Members reachable via popup menu's "Household Members" entry, which already existed at line 284).

**Added**: an admin-gated `Padding > Badge.count(count: _pendingTotal, isLabelVisible: _pendingTotal > 0, child: IconButton(Icons.inbox_rounded, ...))`. On tap: `Navigator.push` to `ApprovalsScreen`, then `await _loadPendingTotal()` on return so approve/deny actions during the navigation update the badge immediately.

### Count freshness story (per the brief's surface request)

The badge stays fresh via three triggers:
1. **Initial load** — `_loadHouseholdInfo` calls `_loadPendingTotal` after admin determined.
2. **Realtime** — `RealtimeService.instance.choresVersion` and `shoppingVersion` both call `_loadPendingTotal` on tick. Chore approve/reject/redo and wishlist approve/deny all cause realtime ticks via the existing infrastructure.
3. **Navigation return** — `await` on the `Navigator.push` lets us `_loadPendingTotal` after the user comes back from Approvals, even if a realtime tick was missed.

This is robust enough at current scale. If realtime ever proves unreliable for these tables, the Navigator-return refresh acts as a fallback.

## Phase 6 — Analyzer deltas

| Scope | Before | After | Net new errors | Net new info/warnings |
|---|---|---|---|---|
| `flutter analyze apps/mobile/` | 357 | 360 | **0** | +3 |

The pre-existing `MyApp` error in `test/widget_test.dart:16` is unchanged.

The +3 are routine `inference_failure_on_function_invocation` warnings on the new `.rpc('approve_chore', ...)`, `.rpc('approve_wishlist_item', ...)`, and `.delete()` call sites in `approvals_screen.dart` — matches every other Supabase SDK call in the codebase.

**Caught and fixed mid-implementation**: two new `unawaited_futures` errors at `home_shell:174` (the `_loadPendingTotal()` inside `_loadHouseholdInfo`) and `home_shell:347` (the `_loadPendingTotal()` inside the Approvals IconButton onPressed). Both fixed by adding `await` — the enclosing functions/closures are already async so it's free.

## iPhone smoke-test checklist

After rebuilding on the branch:

| # | Path | Expected |
|---|---|---|
| 1 | As admin (Andrew), at least one pending chore or wishlist item exists | AppBar shows the inbox icon with a number badge equal to total pending items |
| 2 | SQL check: badge count = chores in pending_verification + shopping_items with is_wishlist=true | Numbers match |
| 3 | Tap inbox icon | ApprovalsScreen opens via Navigator.push |
| 4 | Pending Chore Verifications section renders | Each chore shows photo thumbnail (or "No photo submitted" empty state for skip-path), title, "Completed by [kid name]", Reject + Approve buttons |
| 5 | Tap Approve on a chore | RPC fires; section card disappears; on return to home, badge decrements |
| 6 | Tap Reject on a chore → dialog from shared util | Dialog title shows the chore name; type a reason; tap Reject; submission succeeds; badge decrements |
| 7 | Pending Wishlist section renders | Each item shows name, optional display_quantity, category chip (honeyGold), "Requested by [kid] · 2h ago", Deny + Approve buttons |
| 8 | Tap Approve on a wishlist item | `approve_wishlist_item` RPC fires; SnackBar "Item added to shopping list"; card disappears |
| 9 | Tap Deny on a wishlist item | Confirmation modal "Delete this wishlist item? This can't be undone. \"X\" will be removed."; tap Delete; row deleted; SnackBar "Wishlist item removed"; card disappears |
| 10 | Both sections empty | Full-screen "🎉 All caught up! / Nothing waiting for approval right now." |
| 11 | While on Approvals, profile-switcher → switch to Randi | Screen automatically pops back to home (Q3) |
| 12 | While operating as Randi | AppBar shows no inbox icon (admin-gated; Q6 also removed the Members IconButton) |
| 13 | chore_dashboard | No Pending Verification section visible; no Verify stat card in the stats row (Q8); kid-facing My Chores section unchanged |
| 14 | chore_detail | Reject chip on a pending-verification chore (admin path) opens the same dialog as Approvals (shared util) |
| 15 | Members reachable | Via popup menu "Household Members" entry (was IconButton, now menu-only); also still reachable from Settings → Household tile |
| 16 | Real-time refresh | Have another household member submit a chore for verification → AppBar badge increments without manual reload |

## Known followups

- **Batch 5b-ii**: `necessity_categories_screen.dart` + Settings tile. Independent of 5b-i; ~195 LOC; could ship in either order.
- **Batch 6 (Meals)**: Meal Requests becomes a third section in approvals_screen. New state field + parallel query + `_MealRequestCard` + handlers calling `decide_meal_request` RPC. Drops into Phase 7 future-proofing slot.
- **`_SectionHeader` duplication**: now lives in both chore_dashboard (still used for "My Chores" section) and approvals_screen (used for both pending sections). ~25 LOC each. Worth extracting to `widgets/section_header.dart` in a polish pass if anyone else wants it.
- **`_formatRelative` helper**: only used in approvals_screen today. If 2+ files need it, extract to `utils/relative_time.dart`.
- **`_pendingTotal` real-time wiring**: the choresVersion + shoppingVersion realtime listeners are wired but haven't been smoke-tested under multi-device scenarios. Should work, but flag for the iPhone test.

## What 5b-i explicitly did NOT touch

- `necessity_categories_screen.dart` and Settings tile (Q4 — that's 5b-ii)
- `chore_photo_viewer.dart` (untouched per brief)
- Any RPC or migration (5b-i is pure Dart)
- Other navigation patterns beyond the AppBar action
- The `RealtimeService` itself (only added listeners)
- chore_dashboard's kid-facing flows (Mark Complete, Re-do, rejected callout, `_ChoreCard`)

## Next steps for the user

1. Review the 5 files (1 new util + 1 new screen + 3 modified screens).
2. Rebuild iOS app on this branch.
3. Smoke-test the 16 paths above.
4. Commit + push.
5. Schedule 5b-ii (necessity categories admin screen + Settings tile).

After both 5b-i and 5b-ii ship, Pass 3 remaining: Batches 6 (Meals — drops cleanly into Approvals as a third section), 7 (UI hardening), 8 (music app deep link).
