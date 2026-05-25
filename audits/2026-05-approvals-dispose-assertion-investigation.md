# Approvals dispose assertion — investigation

Date: 2026-05-25
Branch: `feat/kid-perms-wishlist-batch-5b-2026-05-25` (read-only investigation; no code changes)
Status: investigation complete — **root cause identified**; **1-line-per-card fix** (add `ValueKey` to dynamic list children).

## TL;DR

The assertion fires because `_pendingVerification.map(...)` and `_pendingWishlist.map(...)` produce children without `Key`s. When the list shrinks after Approve/Reject, Flutter's positional element reuse cascades into TYPE-MISMATCH boundaries between cards and the trailing `SizedBox`/section-header, forcing unmount-and-remount across multiple positions. During that cascade, the `ChorePhotoThumbnail`'s inherited-widget dependencies (Theme/MediaQuery via the embedded `FutureBuilder` rebuilds) can end up registered on an Element that's mid-teardown, tripping `_dependents.isEmpty` in `InheritedElement.unmount()`.

The same code in chore_dashboard pre-5b-i didn't fire because the My Chores section sat below the Pending Verification block, anchoring the cards' positions so the cascade stayed isolated within the card region (positional `didUpdateWidget` only, no type-mismatch boundary).

**Recommended fix**: add `key: ValueKey(chore['id'])` to `_VerificationCard` and `key: ValueKey(item['id'])` to `_WishlistCard` in approvals_screen. Two lines, zero side effects.

## Phase 1 — Verify-handler comparison

### approvals_screen `_verifyChore` (current)

```dart
Future<void> _verifyChore(String choreId, bool approved) async {
  try {
    final chore = _pendingVerification.firstWhere((c) => c['id'] == choreId);
    String? reasonForReject;
    if (!approved) {
      final reason = await showRejectReasonDialog(context, chore['title'] ?? 'this chore');
      if (reason == null) return;
      reasonForReject = reason.isEmpty ? null : reason;
    }
    await Supabase.instance.client.rpc('approve_chore', params: {
      'p_chore_id': choreId,
      'p_approved': approved,
      'p_reason': reasonForReject,
    });
    if (approved) await _createNextRecurringChoreIfNeeded(chore);
    await _loadData();   // ← triggers setState(_isLoading=true) then re-fetches
  } catch (e) { ... }
}
```

### chore_dashboard pre-5b-i `_verifyChore` (removed)

Byte-for-byte identical body. Same reload pattern: `await _loadData()` which does `setState(_isLoading = true)` first, then async queries, then `setState` with new lists.

**So the handler itself isn't the cause.** What differs is the surrounding widget tree.

## Phase 2 — `ChorePhotoThumbnail` lifecycle (`apps/mobile/lib/widgets/chore_photo_viewer.dart`)

`StatefulWidget`. State holds:
```dart
Future<String>? _signedUrl;
```

Lifecycle:
- `initState` → `_signedUrl = _generateSignedUrl(widget.storagePath!)` if `storagePath != null`
- `didUpdateWidget` → re-generate the future if `storagePath` changed
- `build` → wraps `Image.network(signedUrl)` in a `FutureBuilder<String>`

`build`'s `FutureBuilder` rebuilds on future resolution. The rebuild registers inherited-widget dependencies (theme color for the loading container background; MediaQuery via deep widget tree). If the Element is mid-teardown when the future resolves OR when a sibling type-mismatch forces a rebuild, the dependency registration ends up on a deactivating Element.

The full-screen view (`ChorePhotoFullScreenView`) also uses `MediaQuery.of(context)` for safe-area padding, but the thumbnail is what's in the cards, and the thumbnail is what gets unmounted on list shrink.

No `addListener` calls. No `context.read/watch`. The dependency surface is entirely via the FutureBuilder's automatic registration during `Image.network` rebuilds.

## Phase 3 — List rendering pattern (the real culprit)

### approvals_screen body when both sections have items

```dart
ListView(
  padding: const EdgeInsets.all(16),
  children: [
    if (_pendingVerification.isNotEmpty) ...[
      _SectionHeader('Pending Chore Verifications', _pendingVerification.length),
      const SizedBox(height: 8),
      ..._pendingVerification.map((chore) {            // ← no Key
        return _VerificationCard(chore: chore, ...);
      }),
      const SizedBox(height: 24),
    ],
    if (_pendingWishlist.isNotEmpty) ...[
      _SectionHeader('Pending Wishlist', _pendingWishlist.length),
      const SizedBox(height: 8),
      ..._pendingWishlist.map((item) => _WishlistCard(item: item, ...)),  // ← no Key
      const SizedBox(height: 24),
    ],
  ],
)
```

Suppose `_pendingVerification` has 3 chores [A, B, C] and `_pendingWishlist` has 2 items [X, Y]. Children before Approve, in order:

```
0: SectionHeader_PV (count=3)
1: SizedBox(8)
2: _VerificationCard(A)
3: _VerificationCard(B)
4: _VerificationCard(C)
5: SizedBox(24)              ← trailing spacer of PV section
6: SectionHeader_PW (count=2)
7: SizedBox(8)
8: _WishlistCard(X)
9: _WishlistCard(Y)
10: SizedBox(24)
```

User approves chore A. `_pendingVerification` becomes [B, C]. Children after:

```
0: SectionHeader_PV (count=2)
1: SizedBox(8)
2: _VerificationCard(B)
3: _VerificationCard(C)
4: SizedBox(24)              ← was position 5
5: SectionHeader_PW (count=2)  ← was position 6
...
```

Position-by-position element diff (Flutter's default reconciliation, no keys):

| Pos | Before | After | Action |
|---|---|---|---|
| 0 | SectionHeader_PV | SectionHeader_PV | update (count prop changes) |
| 1 | SizedBox | SizedBox | reuse |
| 2 | _VerificationCard(A) | _VerificationCard(B) | **`didUpdateWidget`** — chore prop swap; ChorePhotoThumbnail re-resolves signed URL |
| 3 | _VerificationCard(B) | _VerificationCard(C) | **`didUpdateWidget`** — same |
| 4 | _VerificationCard(C) | **SizedBox** | **TYPE MISMATCH** — unmount card + remount as SizedBox |
| 5 | SizedBox | **SectionHeader_PW** | **TYPE MISMATCH** — unmount + remount |
| 6 | SectionHeader_PW | SizedBox | **TYPE MISMATCH** — unmount + remount |
| 7-10 | shifted by 1 | shifted by 1 | similar cascade |

**The cascade**: every position from 4 onward becomes a type mismatch. Each requires an unmount + remount. During the unmount of `_VerificationCard(C)`, its child `ChorePhotoThumbnail` is being torn down WHILE the FutureBuilder (rebuilding from didUpdateWidget on cards at positions 2 and 3) is still acquiring inherited-widget dependencies in the same frame.

The framework's element-tree consistency check (`_dependents.isEmpty` at the InheritedElement layer being unmounted) sees a dependent that hasn't been deregistered yet, and the assertion fires.

### Why chore_dashboard pre-5b-i didn't fire

chore_dashboard's body had:
```
... (stats row) ...
if (isAdmin && _pendingVerification.isNotEmpty) ...[
  SectionHeader_PV
  SizedBox(8)
  cards...
  SizedBox(24)
],
SectionHeader_MC ('My Chores')
SizedBox(8)
... (either empty card or ..._myChores.map) ...
```

The **My Chores section is always present** (kid-facing). It anchors the bottom of the list. When `_pendingVerification` shrinks, the cards at positions 4..N shift UP, but they all stay as `_VerificationCard` (or, at the very end, as the next-section's header). The type-mismatch boundary only happens once — at the very last shifted position — and the My Chores section consumed any remaining positional slack.

In approvals_screen, there's no anchor. The Pending Wishlist section IS conditional. The trailing SizedBox is just a spacer. The cascade has nowhere stable to land.

## Phase 4 — Listener ordering check

The `ActiveMemberService` listener fires only on profile-switch, not on Approve/Reject. Not the trigger.

The `_loadData` flow inside `_verifyChore`:
1. setState(_isLoading=true) — body becomes spinner; ALL cards unmount; **first dispose pass**
2. async queries (await)
3. setState(new lists, _isLoading=false) — body becomes new ListView; cards mount

Wait — does step 1 actually trigger a dispose pass that would clear ALL the cards in one go? Yes. So actually the cascade I described in Phase 3 might NOT be the trigger if step 1 cleanly unmounts everything BEFORE step 3 mounts new things.

Let me reconsider: the assertion could fire DURING step 1 (the spinner-replacement dispose) for a slightly different reason — the cards being unmounted have ChorePhotoThumbnail children whose FutureBuilders are mid-resolution. As the parent unmounts, the FutureBuilder's pending future resolution might still register dependencies briefly.

Actually no — Flutter's `FutureBuilder` has internal `_activeCallbackIdentity` guarding to drop late completions on unmounted widgets. That's robust.

So the more likely actual trigger is the cascade in Phase 3 — the **second** setState's transition from spinner back to a ListView whose children layout doesn't match the previous ListView's positions. The framework optimizes by trying to reuse elements where possible, but the type-mismatch boundary mid-cascade triggers the inconsistency.

The asymmetry of "approvals_screen body in spinner state has 1 widget (CircularProgressIndicator), approvals_screen body in loaded state has N widgets" doesn't trigger the assertion by itself — that's a clean type-mismatch at the body root, the whole subtree unmounts and a new one mounts. Clean.

But between two LOADED states (3 cards vs 2 cards), the cascade fires. So the assertion is most likely triggered by the second setState (transitioning spinner → new ListView) when the new ListView is rendered and Flutter compares it to whatever element tree was previously there. If the spinner was the previous tree, it's a clean swap. If the previous tree was kept stale (Flutter might not have rebuilt the body yet between the two setStates if they're scheduled together), then the diff is 3-card-ListView vs 2-card-ListView, and the cascade applies.

Either way, the fix is the same — adding Keys to the list children makes the positional reconciliation stable.

## Phase 5 — Recommended fix

**Primary**: add `ValueKey` to both dynamic list children in approvals_screen's `build()`:

```dart
..._pendingVerification.map((chore) {
  final photo = _latestPhotoByChoreId[chore['id']];
  return _VerificationCard(
    key: ValueKey(chore['id']),        // ← add this
    chore: chore,
    latestPhoto: photo,
    onApprove: () => _verifyChore(chore['id'], true),
    onReject: () => _verifyChore(chore['id'], false),
    onPhotoDeleted: _loadData,
  );
}),

..._pendingWishlist.map((item) => _WishlistCard(
  key: ValueKey(item['id']),           // ← add this
  item: item,
  onApprove: () => _approveWishlistItem(item['id']),
  onDeny: () => _denyWishlistItem(item['id'], item['name'] ?? 'Item'),
)),
```

With keys, Flutter matches each card to its data by id regardless of position. When a card is removed:
- Removed card's Element is cleanly unmounted (no cascade)
- Other cards' Elements stay attached to the SAME state
- The trailing SizedBox and subsequent section stay as-is at their new positions (Flutter matches by key/type at the matched-key boundary)

`ValueKey(chore['id'])` is correct because:
- chore IDs are uuid strings → unique
- They're stable across rebuilds (same chore = same id)
- ValueKey's equality semantics match by string value

**Why not `ObjectKey(chore)`**: `chore` is a `Map<String, dynamic>` from a fresh Supabase query each `_loadData`. Different Map instance each time → ObjectKey would never match. ValueKey on the id is what we want.

**Why not `UniqueKey()`**: that would force unmount-remount every rebuild, defeating the purpose.

**Secondary defenses (not required to fix the assertion, but worth considering for resilience):**

- **Defer setState in handlers**: not necessary — `await _loadData()` is already correctly scheduled.
- **Cancel/dispose the photo thumbnail's FutureBuilder**: not necessary — Flutter handles late completions on unmounted FutureBuilders.
- **Replace `.map()` spread with `ListView.builder`**: would also fix the issue (builder uses `itemBuilder` with index → no positional cascade for the dynamic portion), but the section structure (heads + dynamic cards + spacers) is awkward to model as a single ListView.builder. Keys are simpler.

### Scope

| Change | LOC | File |
|---|---|---|
| `key: ValueKey(chore['id'])` on `_VerificationCard` | +1 | `approvals_screen.dart` |
| `key: ValueKey(item['id'])` on `_WishlistCard` | +1 | `approvals_screen.dart` |

**Total: 2 lines, 1 file. No new imports.** ValueKey is in `package:flutter/foundation.dart` which is re-exported via `package:flutter/material.dart` (already imported).

### Why this is the right fix specifically

- Addresses the actual cause (positional cascade across type-mismatch boundary) — not a symptom workaround.
- Matches Flutter best practice for any `List<T>.map((item) => Widget)` pattern that can shrink.
- Zero risk of regression — Keys only affect element reconciliation; they don't change build output.
- Two-line fix is small enough to confidently ship without follow-up testing beyond the smoke test that surfaced the bug.

## Phase 6 — Verification approach

After applying the fix:

1. Rebuild iOS.
2. From admin session with ≥2 pending chore verifications:
   - Tap Approve on the **first** card (the one most likely to trigger the cascade).
   - Confirm no assertion; card disappears; badge decrements.
3. Repeat for Reject (with reason dialog).
4. Repeat for wishlist Approve and Deny.
5. Verify the empty-state transition: approve the last card → screen shows "All caught up! 🎉" without assertion.
6. Cross-check the same flows in chore_detail (which still uses the shared reject util) — should remain unaffected.

## Related future considerations (not part of this fix)

- The same Keys pattern should be applied prospectively if Batch 6 adds a `_MealRequestCard` section to approvals_screen.
- The chore_dashboard's `_myChores.map((chore) => _ChoreCard(...))` doesn't have keys either; potentially vulnerable to the same pattern if both `_myChores` shrinks AND the trailing widget changes type. Today the trailing widget is always the same `_AddChoreSheet` FAB (anchored via Scaffold's `floatingActionButton`, not in the list), so the cascade has nowhere to bite. Add `key: ValueKey(chore['id'])` here too as a defensive measure during the same fix.
- `widgets/chore_photo_viewer.dart` doesn't need changes. The thumbnail's lifecycle is correct; it just got caught in the cascade.

## Read-only constraint honored

No code, no migrations, no commits. Only this audit file written.
