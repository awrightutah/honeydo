# Approvals Dashboard — Investigation

Date: 2026-05-25
Branch: `feat/kid-perms-wishlist-batch-5b-2026-05-25` (read-only investigation; no code changes)
Status: investigation complete — **recommend Option A (sections)** + **AppBar icon with badge** for navigation + **split 5b into 5b-i (Approvals) and 5b-ii (Necessity)**.

## Summary

Replacing 5b's "second section on chore_dashboard" plan with a dedicated **Approvals** screen that unifies all admin pending-items (chores, wishlist, future meals). This matches the spec's Decision F language verbatim and gives admins one place to land for "what needs my attention."

Key architectural conclusions:

1. **Screen structure**: Option A (one scrollable screen with conditionally-rendered sections) wins. Tabs (Option B) add chrome with no benefit at current scale; feed (Option C) is over-engineered. Future meal requests slot into a new section trivially.
2. **Navigation entry**: AppBar icon with count badge, admin-only — keeps the bottom NavigationBar at 5 destinations (Material 3 sweet spot), surfaces the "you have pending items" signal without needing the user to enter the screen, and naturally disappears for kid sessions.
3. **Reject-with-reason dialog**: extract to a shared util. Currently duplicated inline in `chore_dashboard._verifyChore` and `chore_detail._rejectFromDetail`; Approvals would make it the third call site. Extract once, ~50 LOC of new util replacing ~40 + ~30 LOC of inline duplicates.
4. **Sub-batch split**: 5b-i (Approvals screen + migrate Pending Verification + Pending Wishlist) and 5b-ii (Necessity Categories screen + Settings tile). 5b-i is an architectural refactor; 5b-ii is a separate admin-config feature. Independent, ship in either order.

**Net scope**: ~700 LOC across both sub-batches (vs ~315 LOC for the original 5b). The extra ~385 LOC is the cost of doing the unification properly: new Approvals screen (~300 LOC) + AppBar icon plumbing (~30 LOC) + reject dialog util (~50 LOC). chore_dashboard loses ~200 LOC of complexity it shouldn't have owned.

## Phase 1 — Current navigation structure

`home_shell_screen.dart` is the app shell. Structure:

```dart
class _HomeShellScreenState extends State<HomeShellScreen> {
  int _currentIndex = 0;
  // ...

  final List<Widget> _screens = const [
    ChoreDashboardScreen(),    // 0
    MealPlannerScreen(),       // 1
    ShoppingListScreen(),      // 2
    CalendarScreen(),          // 3
    RecipeLibraryScreen(),     // 4
  ];
```

Layout (lines ~190-210):
- **Body**: `IndexedStack(index: _currentIndex, children: _screens)` — all 5 screens stay alive in memory; switching tabs is instant.
- **Bottom nav**: Material 3 `NavigationBar` with **5 `NavigationDestination`s**: Chores / Meals / Shop / Calendar / Recipes.
- **AppBar actions** (right side, in order): points badge (TextButton with star icon + count), profile-switcher IconButton, search IconButton, members IconButton, 3-dot popup menu. **5 actions already.**

Notable: `_screens` is `const` — adding a screen means adding a `Widget` constructor call here AND a `NavigationDestination` to the destinations list AND adjusting `_currentIndex` semantics. Or — for Approvals — sidestepping `_screens` entirely with a `Navigator.push` from an AppBar icon.

**Material 3 NavigationBar guidance**: 3-5 destinations recommended. The app is at the upper bound. Adding a 6th would visibly crowd; Apple HIG agrees (4-5 max for tab bars). Replacing one is disruptive (Recipes? Calendar? all have legitimate roles).

So the bottom nav is "full." That constraints the Approvals entry point design — see Phase 5.

**Spec Decision F** (line 24): *"One unified Pending Requests dashboard showing pending chore verifications, pending wishlist items, and pending meal requests in one place. Lives where the existing chore_dashboard:347 'Pending Verification' section is, expanded into a tabbed or grouped view."*

The spec was ambiguous between "tabbed" and "grouped" (sections). User intent (this brief) is dedicated SCREEN, not just an expanded section. Decision F's "lives where the existing section is" was a placement hint, not a constraint — moving it to its own screen is a stronger version of the same idea.

## Phase 2 — Approvals screen structure options

### Option A — Sections (RECOMMENDED)

```
┌─ Approvals ────────────────────────────────────────┐
│                                                    │
│  Pending Verification (3)                          │
│  ┌──────────────────────────────────────────┐      │
│  │ "Take out the trash" — Randi             │      │
│  │ [photo] [Reject] [Approve]               │      │
│  └──────────────────────────────────────────┘      │
│  (… 2 more verification cards …)                   │
│                                                    │
│  Pending Wishlist (2)                              │
│  ┌──────────────────────────────────────────┐      │
│  │ "Toothpaste" — Personal Care             │      │
│  │ Requested by Randi · 2h ago              │      │
│  │ [Deny] [Approve]                         │      │
│  └──────────────────────────────────────────┘      │
│  (… 1 more wishlist card …)                        │
│                                                    │
│  (Batch 6: Pending Meal Requests would land here)  │
└────────────────────────────────────────────────────┘
```

One scrollable `ListView`. Each section header has a count badge (reuse the existing `_SectionHeader` style from chore_dashboard). Empty sections are conditionally suppressed (`if (_pendingVerification.isNotEmpty) ...[ section ]`). Whole-screen empty state if everything is zero: "All caught up! 🎉".

**Pros:**
- See everything at once. No tab-switching to spot work.
- Trivially extends for Batch 6 (Meals = new section).
- Mirrors the existing `_SectionHeader` + `_*Card` pattern from chore_dashboard — zero new UI vocabulary.
- Works gracefully when one section is large and another empty.

**Cons:**
- If one type explodes in volume (e.g., 50 wishlist items), scrolling to reach other sections is annoying. Practical mitigation: per-section "see all" cap with collapse — not needed at current scale (Wrights family).

### Option B — Tabs within Approvals

```
┌─ Approvals ────────────────────────────────────────┐
│  [ Chores (3) ] [ Wishlist (2) ] [ Meals (0) ]     │
│                                                    │
│  (current tab's list, full-height scroll)          │
└────────────────────────────────────────────────────┘
```

`TabBar` at top with one tab per type. Counts on tab labels.

**Pros:**
- Each type gets full vertical real estate. Better for high-volume single-type cases.
- Native tap-to-switch.

**Cons:**
- Forces "which tab to look at?" decision every time. Admin who genuinely has both chores AND wishlist pending has to tap-switch to see both.
- More UI chrome (the TabBar) for very little benefit at current scale.
- Empty-tab UX (showing "no pending chores" when wishlist HAS items but you're on the chores tab) feels wrong.

### Option C — Mixed time-sorted feed

```
┌─ Approvals ────────────────────────────────────────┐
│  [All] [Chores] [Wishlist] [Meals]   ← filter chips│
│                                                    │
│  10m ago — "Toothpaste" — Wishlist                 │
│  2h ago  — "Take out trash" — Chore                │
│  1d ago  — "Pizza" — Meal Request                  │
│  ...                                               │
└────────────────────────────────────────────────────┘
```

One feed sorted by `created_at DESC`. Cards are type-specific (chore card with photo thumbnail; wishlist card; meal-request card). Optional filter chips.

**Pros:**
- Modern. Recency emphasized.
- Filter chips give Option-B-style narrowing without losing the unified view.

**Cons:**
- Most complex to build (3+ card variants in one ListView).
- Sort-by-recency means oldest-pending items get buried.
- For a few-items-at-a-time UX (current scale), the complexity isn't earned.
- Card width / column layout needs more thought (type-specific cards have different heights).

### Recommendation: **Option A (sections)**

Best fit at current scale, scales cleanly for Batch 6, matches existing UI vocabulary, and never forces admin to tap-switch to see everything pending. The "one section gets huge" concern is theoretical at this household size.

## Phase 3 — Pending Verification migration

### What's currently in `chore_dashboard_screen.dart`

| Item | Lines (approx) | Stays / Moves |
|---|---|---|
| `_pendingVerification` state field | 25 | **Moves** |
| `_latestPhotoByChoreId` state | 27-28 | **Moves** (only used for verification card photos) |
| Pending Verification + photo side-query in `_loadData` | 112-145 | **Moves** |
| `_verifyChore` handler | 289-340 | **Moves** (~50 LOC) |
| `_showRejectReasonDialog` inline | 354-393 | **Extract to shared util** |
| Pending Verification section in `build()` | 500-515 | **Moves** |
| `_VerificationCard` widget | 801-915 | **Moves** (~115 LOC) |
| `_SectionHeader` widget | 600-622 | **Stays** (used by Pending Wishlist on chore_dashboard? No — Pending Wishlist would only be on Approvals now). Recommend **moving** to a shared `widgets/section_header.dart` since both screens use it. ~25 LOC. |

### What stays on `chore_dashboard_screen.dart`

The kid-facing chore-management UI:
- `_myChores` state, `_loadData`'s "load chores assigned to me" query (line 102-110)
- `_completeChore`, `_redoChore` handlers
- `_ChoreCard` widget (with Re-do button when rejected)
- `_AddChoreSheet` (the FAB-opened bottom sheet)
- Stats row (My Chores / My Points / Verify count card) — though the "Verify count card" stat should probably move to the AppBar's Approvals badge (Phase 5)
- The `_redoChore` undo snackbar pattern

### Net effect on chore_dashboard

- Loses: ~200-220 LOC (verification state + query + handler + widget + reject dialog + photo loading)
- Stays at: ~950 LOC down from 1168
- Becomes: a pure "my chores" screen for kids + admins viewing their own assigned chores. Cleaner mental model. The "Verify" stat card can go away or move to the AppBar badge.

### Reject-with-reason dialog extraction

Currently `_showRejectReasonDialog` is duplicated as a private method in **two** files:
- `chore_dashboard_screen.dart:354-393` (used by `_verifyChore`)
- `chore_detail_screen.dart:1067-1106` (used by `_rejectFromDetail` — Batch 4b's Reject chip)

Extracting to `apps/mobile/lib/widgets/reject_reason_dialog.dart` as a top-level function:

```dart
Future<String?> showRejectReasonDialog(BuildContext context, String choreName) async { ... }
```

Both existing call sites simplify to `final reason = await showRejectReasonDialog(context, choreName);`. Adds a 3rd call site (Approvals' Reject button) without duplicating again.

**Recommend extracting in 5b-i** — small, single-file change, removes ~80 LOC of duplication across 2 files, makes the new Approvals' reject path one-liner-y.

### Migration plan summary

1. Create `apps/mobile/lib/widgets/reject_reason_dialog.dart` (~50 LOC).
2. Update chore_dashboard + chore_detail to call the new util; delete inline duplicates.
3. Create new `apps/mobile/lib/screens/approvals_screen.dart`. Move Pending Verification state, query, handler, widget. Add Pending Wishlist (Phase 4 reuses 5b's design).
4. Delete the migrated bits from chore_dashboard. Simplify the stats row.
5. Optionally move `_SectionHeader` to a shared widgets file (~25 LOC). Worth doing if more screens will use it.

## Phase 4 — Pending Wishlist content

**Reuse 5b's design wholesale.** The 5b investigation's Phase 1-2 covers:
- The Supabase query (`shopping_items` + `requester:household_members!added_by_member_id` join, `is_wishlist=true`, ordered by `created_at DESC`)
- `_WishlistCard` widget (~90 LOC) — title row, category chip, "Requested by X · time ago", Deny/Approve buttons
- Approve handler (`approve_wishlist_item` RPC + SnackBar)
- Deny handler (confirmation modal → direct DELETE on shopping_items + SnackBar)

Only difference vs the 5b plan: lives in `approvals_screen.dart` instead of as a second section on chore_dashboard. Loading, query, handlers, widget — all identical.

## Phase 5 — Navigation entry point

### Options

**Option I — Add a 6th NavigationBar tab.** Material 3 / HIG discourage >5. Visually cramped, fundamentally suboptimal. **Not recommended.**

**Option II — Replace an existing tab.** E.g., move "Recipes" into a path reachable from Meal Planner / search-only. Disruptive UX change for existing users; muddies the navigation model. **Not recommended for Approvals specifically** (the unified inbox is auxiliary, not a core daily destination).

**Option III — AppBar icon with badge (RECOMMENDED).** New IconButton in the AppBar actions row, admin-only, with a badge showing total pending count (chore verifications + wishlist + future meals). Tap opens `ApprovalsScreen` via `Navigator.push` (full screen).

```dart
// In home_shell_screen.dart AppBar actions, gated:
if (Permissions.isAdmin(_myMembership))
  Badge(
    label: Text('$_pendingTotal'),
    isLabelVisible: _pendingTotal > 0,
    child: IconButton(
      icon: const Icon(Icons.inbox_rounded),
      onPressed: () => Navigator.push(context,
        MaterialPageRoute(builder: (_) => const ApprovalsScreen())),
      tooltip: 'Approvals',
    ),
  ),
```

Material 3 has a built-in `Badge` widget that wraps an `IconButton` cleanly. Icon: `Icons.inbox_rounded` (matches the "things needing my attention" semantic) — alternatives: `Icons.notifications_outlined`, `Icons.task_alt_outlined`.

**Pros:**
- Keeps bottom NavigationBar at 5 (Material sweet spot).
- Badge visually signals "you have work to do" without needing to open the screen.
- Naturally invisible for kid sessions (admin gate).
- Standard "inbox" UX pattern users will recognize.
- Doesn't disturb the existing tab semantics.

**Cons:**
- AppBar already has 5 actions (points badge, profile switcher, search, members, popup menu). Adding a 6th makes it crowded on small screens.
- **Mitigation**: move "Members" to the popup menu (it's also reachable from Settings → Household), opening a slot for Approvals.
- Less prominent than a tab — admins might forget to look. The badge mitigates this somewhat.

**Option IV — Floating Action Button.** App's existing FAB is on chore_dashboard (Add Chore). Repurposing or adding a global FAB doesn't compose well. **Not recommended.**

**Option V — Settings entry.** Lowest discoverability. The Approvals screen is daily-use territory for admins; settings is "config" territory. **Not recommended.**

### Recommendation: Option III + move Members to popup menu

Net AppBar changes:
- Add: Approvals badge icon (admin-only)
- Move: Members IconButton → popup menu entry "Household members"

Net 0 visible AppBar actions for admins; net -1 for kids (who lose nothing — they didn't see Approvals).

Count source: `_pendingTotal` lives in `_HomeShellScreenState`, computed from a small set of queries the shell runs on load + on realtime updates. Or alternatively: the Approvals screen owns the counts and we just show "0" until first load. Simpler — recommend the count be loaded by `home_shell` directly via a tiny aggregator query (or two counts).

## Phase 6 — Admin-only gating

Three layers, in defense-in-depth order:

1. **AppBar icon visibility** gated on `Permissions.isAdmin(_myMembership)`. Kids never see it.
2. **`ApprovalsScreen.build()` checks** `Permissions.isAdmin(_householdMember)` — if non-admin somehow lands here (e.g., deep-link, future routing), renders an "Admins only" centered text instead of the lists. ~5 LOC.
3. **RLS already enforces** at the data layer — `chores` UPDATE policies (via `approve_chore` RPC) and `shopping_items` UPDATE/DELETE policies require admin. Even if a kid bypassed the UI gates, the RPCs/RLS would reject.

Triple-redundant by design, low-cost.

### Profile-switcher edge case

If admin opens Approvals, then mid-screen switches to a kid via the profile switcher, the screen should react:
- `ActiveMemberService.instance.activeMemberId.addListener(_onActiveMemberChanged)` in `initState`
- On change, reload data; if now non-admin, `Navigator.pop(context)` back to home OR re-render as "Admins only"

Cleaner option: pop back. Surfaced as Q3.

## Phase 7 — Future-proofing for meal requests (Batch 6)

Option A (sections) makes Batch 6 trivial:

1. Add `_pendingMealRequests` state field + parallel query in `_loadData`
2. Add a "Pending Meal Requests" section in `build()` between Wishlist and the empty-state footer
3. Add `_MealRequestCard` widget — similar shape to `_WishlistCard`
4. Add Approve handler (calls `decide_meal_request` RPC with `p_approved: true`) and Deny handler (calls same RPC with `p_approved: false`)

The `_pendingTotal` count in the AppBar badge sums all three. The decide_meal_request RPC was shipped in Batch 2; only the UI side is new for 5b's successor.

If Batch 6 prefers tabs (Option B) for meals specifically, that'd be a bigger restructure. But there's no reason to think it will.

## Phase 8 — Scope estimate

### Sub-batch split (RECOMMENDED)

**Batch 5b-i — Approvals dashboard + migrate Pending Verification + Pending Wishlist**

| Component | LOC | Type |
|---|---|---|
| `approvals_screen.dart` (full screen with both sections, handlers, widgets) | ~300 | new |
| `reject_reason_dialog.dart` (extracted shared util) | ~50 | new |
| `chore_dashboard_screen.dart` cleanup (remove migrated bits, update stats row, drop reject dialog inline) | ~-200 | modified (net negative) |
| `chore_detail_screen.dart` (drop inline reject dialog, call shared util) | ~-25 | modified (net negative) |
| `home_shell_screen.dart` (AppBar icon + admin gate + badge count + load count) | ~50 | modified |
| Optionally `widgets/section_header.dart` (shared) | ~25 | new |

**Net 5b-i: ~+200 LOC** (300 + 50 + 50 + 25 - 200 - 25). Touches 4 existing files + 2-3 new files. Includes a real architectural refactor.

**Batch 5b-ii — Necessity Categories admin screen + Settings tile**

| Component | LOC | Type |
|---|---|---|
| `necessity_categories_screen.dart` | ~180 | new |
| `settings_screen.dart` (tile + import) | ~15 | modified |

**Net 5b-ii: ~+195 LOC.** Completely independent of 5b-i. Could ship in either order, but ship 5b-i first to validate the architectural pattern.

### Sub-batch comparison vs original 5b plan

| | Original 5b | Approvals (5b-i + 5b-ii) | Delta |
|---|---|---|---|
| New files | 1 (necessity_categories_screen) | 2-3 (approvals_screen, reject_reason_dialog, optionally section_header) + 1 from 5b-ii | +2-3 |
| Modified files | 2 (chore_dashboard, settings_screen) | 3 (chore_dashboard, chore_detail, home_shell) + 1 from 5b-ii | +1-2 |
| Net LOC | ~+315 | ~+395 (5b-i +200 + 5b-ii +195 = 395 net) | +80 |
| chore_dashboard size | grew (sections added) | shrank by ~200 LOC | net architectural improvement |
| chore_detail size | unchanged | shrank by ~25 LOC | small improvement |
| Reusable infrastructure shipped | none | reject dialog util, optionally section_header util | +2 reusable utilities |
| Future Batch 6 cost (Meals) | medium (touch chore_dashboard again) | low (new section in approvals_screen) | future savings |

The Approvals approach is ~80 LOC larger upfront and saves Batch 6 (Meals) significant architectural cost. The extra ~80 LOC buys:
- Cleaner separation of concerns (chore_dashboard is no longer multi-purpose)
- A reusable reject dialog util (eliminates duplication, lower future-maintenance cost)
- A clear "where do approvals go" answer for any future approval type
- The unified-admin-view UX the user explicitly asked for

### Should 5b-i and 5b-ii combine into single 5b?

~395 LOC across 5-6 files in one commit is doable but at the upper bound of "comfortable." Split makes review easier, lets each piece land independently, and avoids tangling a refactor (5b-i) with a new feature (5b-ii). **Recommend the split**, with 5b-i shipping first. Surfaced as Q4.

## Phase 9 — Open questions

**Architecture (consequential):**

- **Q1.** Approvals screen structure — Option A (sections), B (tabs), or C (feed)? Recommend **A**.
- **Q2.** Navigation entry — AppBar icon w/ badge (Option III), 6th tab (Option I), replace tab (Option II), FAB (IV), Settings (V)? Recommend **III**.
- **Q3.** Profile-switch mid-screen edge case — pop back to home, or re-render as "Admins only"? Recommend **pop back**.
- **Q4.** Split 5b into 5b-i (Approvals) and 5b-ii (Necessity)? Recommend **yes**.
- **Q5.** Reject-with-reason dialog — extract to shared util (`widgets/reject_reason_dialog.dart`), or keep inline duplicates? Recommend **extract** as part of 5b-i.
- **Q6.** Move "Members" IconButton to popup menu to make AppBar room for Approvals? Recommend **yes** (admins still reach Members from Settings → Household and the popup menu's "Household members" entry).

**UX (lower-stakes):**

- **Q7.** AppBar icon choice — `Icons.inbox_rounded` (recommended), `Icons.notifications_outlined`, `Icons.task_alt_outlined`, other?
- **Q8.** Stats row on chore_dashboard — keep the "Verify" count card after migration (now redundant with AppBar badge) or drop? Recommend **drop** (the AppBar badge subsumes it).
- **Q9.** Empty Approvals screen UX — "All caught up! 🎉" centered text, or something more elaborate? Recommend **simple text** matching the chore_dashboard's "No pending chores right now."
- **Q10.** Section ordering on Approvals screen — chores first (most numerous typically), wishlist second, meals third? Or alphabetical? Recommend **chores → wishlist → meals** (frequency + spec order).
- **Q11.** Count badge maximum — does `Badge(label: Text('99+'))` matter? At current household scale, unlikely to exceed 10. Decide later if it becomes relevant.

**Existing 5b decisions (carry over):**

- 5b-i's Pending Wishlist card design carries over from 5b's investigation (`_WishlistCard`, approve/deny handlers, confirmation modal, SnackBar copy).
- 5b-i's RLS coverage is unchanged: existing policies cover all queries and writes; no new migration.
- 5b-ii's necessity_categories screen design carries over unchanged from 5b's Phase 4.
- 5b-ii's Settings tile carries over unchanged from 5b's Phase 5.

## Next steps

1. **You answer Q1-Q11.** Q1-Q6 are the architectural choices; Q7-Q11 are UX defaults with recommendations.
2. **I write 5b-i first** — `approvals_screen.dart` + `reject_reason_dialog.dart` + chore_dashboard cleanup + chore_detail simplification + home_shell AppBar update. Analyzer baseline + after; expect a few new info warnings on the new `.rpc()` and `.delete()` call sites.
3. **Commit + push 5b-i.** Smoke test the unified Approvals flow end to end:
   - Kid (Randi) submits a chore with photo → admin sees Pending Verification on Approvals.
   - Kid adds a wishlist item → admin sees it in the same Approvals screen, second section.
   - Admin approves a chore → it disappears from Pending Verification.
   - Admin denies a wishlist item → confirmation modal → it disappears.
   - Switch to kid mid-screen → Approvals pops back.
   - AppBar badge updates correctly across approve/deny actions.
4. **Then 5b-ii** — necessity_categories_screen + Settings tile. Smaller, independent.
5. **Commit + push 5b-ii.** Smoke test the necessity CRUD flow.

After 5b-i + 5b-ii ship, Pass 3 remaining: Batches 6 (meal requests + push — drops into the Approvals screen as a new section), 7 (UI hardening), 8 (music app deep link).

## Read-only constraint honored

No code, no migrations, no commits. Only this audit file written.
