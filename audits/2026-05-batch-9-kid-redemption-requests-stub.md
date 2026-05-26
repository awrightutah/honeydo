# Batch 9 — Kid Redemption Requests via Approvals (Stub)

Date captured: 2026-05-26
Branch: `docs/batch-9-stub-2026-05-26`
Status: **STUB — not implemented**. Architecture locked, ready to implement when prioritized.

## Why this batch exists

Pre-Batch 7a-i, kids could "redeem" rewards by direct INSERT to `point_transactions`. The legacy `.eq('auth_user_id', user.id)` membership lookup silently returned the parent admin's row, so:

- Kid taps "Redeem" → INSERT to `point_transactions` with admin's `member_id` → debits admin's balance
- Bug appeared to work from the UI side (kid sees points decrement on screen because admin's balance changes, but their own balance didn't)
- Real data integrity issue: admin's points slowly drained by kid actions

Batch 7a-i fixed the membership lookup so redemption attempts now target the kid's own `member_id`. But the `point_transactions` RLS policy correctly blocks kids from INSERTing — RLS error: `new row violates row-level security policy for table "point_transactions"`.

This exposes an architectural gap: kids shouldn't have free redemption rights. They should request, admin approves. Same pattern as wishlist (Batch 5a) and meal requests (Batch 6a).

## Product decision

**Kids request redemptions, admin approves via Approvals dashboard.** This matches the established pattern for any kid action that affects shared household resources.

## Architecture

### Database

**New table: `reward_redemption_requests`**

```sql
CREATE TABLE reward_redemption_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id uuid NOT NULL REFERENCES households(id) ON DELETE CASCADE,
  requested_by_member_id uuid NOT NULL REFERENCES household_members(id) ON DELETE CASCADE,
  reward_id uuid NOT NULL REFERENCES rewards(id) ON DELETE CASCADE,
  points_cost integer NOT NULL,  -- snapshot at request time per Q2
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','denied')),
  decided_by_member_id uuid REFERENCES household_members(id) ON DELETE SET NULL,
  decided_at timestamptz,
  decided_note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_rrr_household_status ON reward_redemption_requests (household_id, status);
CREATE INDEX idx_rrr_requested_by ON reward_redemption_requests (requested_by_member_id);
```

Migration filename: `0022_reward_redemption_requests.sql` (or whatever's next in the migration sequence at implementation time).

### RPCs

**`create_redemption_request(p_reward_id uuid) RETURNS uuid` (kid-callable)**

```
SECURITY DEFINER. Sets search_path safely.

1. Resolve current_member from auth.uid() → household_members
2. Verify current_member.kind = 'sub_profile' OR allow admins for self-test (consider)
3. Load reward, snapshot points_cost = reward.points_cost
4. Validate current_member.points_balance >= points_cost
   - If insufficient: RAISE EXCEPTION 'INSUFFICIENT_POINTS' (kid UI shows "you need X more points")
5. INSERT INTO reward_redemption_requests with status='pending'
6. RETURN new request id
```

Per Q3 (locked): block at request time. Validation in the RPC. Kid UI catches the exception and surfaces "you need X more points" message.

**`decide_redemption_request(p_request_id uuid, p_decision text, p_note text DEFAULT NULL) RETURNS void` (admin-only)**

```
SECURITY DEFINER. Sets search_path safely.

1. Resolve current_member from auth.uid() → household_members
2. Verify current_member.role in ('admin_owner','admin') AND household matches request's household
3. Load request, ensure status='pending'
4. If p_decision = 'approved':
   a. Re-validate kid's points_balance >= request.points_cost (RACE-SAFE)
      - If insufficient now (kid spent points elsewhere): mark denied with note
        'Insufficient points at decision time' and exit
   b. UPDATE household_members SET points_balance = points_balance - points_cost
        WHERE id = request.requested_by_member_id
   c. INSERT INTO point_transactions (member_id, amount, type, source_id, note)
        VALUES (requested_by_member_id, -points_cost, 'redemption',
                request.reward_id, 'Reward redemption: ' || reward.name)
   d. INSERT INTO reward_redemptions (member_id, reward_id, redeemed_at)
   e. UPDATE request: status='approved', decided_by_member_id, decided_at, decided_note=p_note
5. If p_decision = 'denied':
   a. UPDATE request: status='denied', decided_by_member_id, decided_at, decided_note=p_note
6. Single transaction (RPC body is atomic)
```

### RLS

```sql
ALTER TABLE reward_redemption_requests ENABLE ROW LEVEL SECURITY;

-- Members can SELECT their own pending/approved/denied requests
CREATE POLICY rrr_select_own ON reward_redemption_requests
  FOR SELECT
  USING (
    requested_by_member_id IN (
      SELECT id FROM household_members
      WHERE auth_user_id = auth.uid() OR id IN (
        SELECT id FROM household_members WHERE household_id = reward_redemption_requests.household_id
      )
    )
  );

-- Admins SELECT all in household
CREATE POLICY rrr_select_admin ON reward_redemption_requests
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM household_members
      WHERE auth_user_id = auth.uid()
        AND household_id = reward_redemption_requests.household_id
        AND role IN ('admin_owner','admin')
    )
  );

-- INSERT only via RPC (no direct table writes from anyone)
-- UPDATE only via RPC

-- DELETE: admins only (rare; for cleanup, not normal flow)
CREATE POLICY rrr_delete_admin ON reward_redemption_requests
  FOR DELETE
  USING (
    EXISTS (
      SELECT 1 FROM household_members
      WHERE auth_user_id = auth.uid()
        AND household_id = reward_redemption_requests.household_id
        AND role IN ('admin_owner','admin')
    )
  );
```

The kid SELECT policy needs to handle that kids have `auth_user_id IS NULL`. The active-member system (sub_profile flow) means we need the active member's `id` to match `requested_by_member_id`. Since sub_profiles can't authenticate directly, the SELECT works by:
- Adult auth.uid() resolves to admin row
- Admin can see requests in their household (via the admin SELECT policy)
- Kid sub_profile only SELECTs via the app's MembershipHelper-resolved queries (not auth.uid()-driven)

This may require revising the kid SELECT policy. Open question deferred to implementation time.

### Approvals dashboard integration

**4th section, placed after meal_requests per Q6 (locked).**

New `_RedemptionRequestCard` widget:
- Recipe-style card: reward icon/name (left), kid display_name + points_cost (center), Approve/Deny actions (right)
- Approve: direct (no note needed)
- Deny: opens reject_reason_dialog (existing widget from 5b-i, reused) — note is optional

Approvals query block:
```dart
.from('reward_redemption_requests')
.select('*, household_members!requested_by_member_id(display_name,avatar_url), rewards(name,icon,points_cost)')
.eq('household_id', householdId)
.eq('status', 'pending')
.order('created_at', ascending: true)
```

Realtime: new `redemptionRequestsVersion` notifier in RealtimeService. approvals_screen listens; home_shell badge counts pending; rewards_screen listens so kid sees status updates.

### Kid UI on rewards_screen

**Q4 locked: new "My Requests" tab parallel to recipe_library's pattern.**

Two tabs: existing rewards grid stays as "Rewards" tab; new "My Requests" tab shows kid's request history.

Tab structure (uses dynamic TabController like recipe_library_screen after 6b — adjust if kid count changes... actually rewards_screen doesn't have member-context-dependent tab count, so static `TabController(length: 2)` is fine).

But: gate the "My Requests" tab to only render for kids (Permissions.isKid). Admin sessions see just "Rewards" tab.

**Redeem button UX change for kids:**
- Pre: button label "Redeem" → direct INSERT attempt → RLS error
- Post: button label "Request" → confirm dialog "Request [reward name] for [points]?" → call create_redemption_request RPC → SnackBar "Request sent! Admin will review."
- If RPC returns INSUFFICIENT_POINTS: SnackBar "You need X more points" + close confirm dialog

For admin on rewards_screen: button label stays "Redeem" (direct flow, since admins have permission). Admin redemption hits direct point_transactions INSERT.

**Request card on "My Requests" tab:**
- Reward icon + name
- Status pill (yellow pending / green approved / coral denied)
- Below: relative time ("Submitted 2h ago" / "Approved 1h ago" / `decided_note` if denied)

### RealtimeService

```dart
final ValueNotifier<int> redemptionRequestsVersion = ValueNotifier<int>(0);

// In _setupChannels():
.onPostgresChanges(
  event: PostgresChangeEvent.all,
  schema: 'public',
  table: 'reward_redemption_requests',
  callback: (payload) => redemptionRequestsVersion.value++,
)
```

Following the established 9-notifier pattern (after `mealRequestsVersion` added in 6b, this would be the 10th).

## Locked decisions

**Q1: Architecture mirrors wishlist + meal_requests pattern.** Single table + 2 RPCs + 4th Approvals section + kid request flow with confirmation modal.

**Q2: Reward cost snapshot at request time.** Protects against admin changing reward cost after request submitted. Stored in `reward_redemption_requests.points_cost`.

**Q3: Block insufficient points at request time** in the create RPC. Kid sees "you need X more points" SnackBar. Re-validate at decision time (race-safe) — if kid spent points elsewhere between request and approval, request auto-denies with note.

**Q4: Kid UI = new "My Requests" tab on rewards_screen.** Mirrors meal_requests recent-requests pattern from 6b. Static 2-tab structure; "My Requests" tab gated to kids only.

**Q5: 30-day auto-archive DEFERRED.** Bundle later with meal_requests auto-archive work (6c-iv or similar). For now: requests stay forever.

**Q6: Approvals dashboard position = 4th section after meal_requests.** Chronological/batch order: wishlist → chore_verifications → meal_requests → reward_redemption_requests.

## Open questions (to resolve at implementation time)

1. **Admin redeeming for themselves**: should admins also use the request flow (just for symmetry), or skip the request and direct-redeem? Currently leaning: admin direct-redeem via existing flow. The request system is only for sub_profile members.

2. **RLS SELECT for kid sub_profiles**: kid `auth_user_id IS NULL` means the standard `auth.uid()` check doesn't work directly. Needs MembershipHelper-aware policy. Same shape as existing kid-readable tables (consult wishlist or meal_requests RLS for the pattern).

3. **What if reward gets deleted while request is pending?** ON DELETE CASCADE deletes the request. Kid notices the request disappeared. Acceptable.

4. **Existing `reward_redemptions` table schema**: verify it exists and has the columns the decide RPC needs. May need a migration to add columns. Investigation deferred to implementation phase.

5. **Notification on decision**: push notification when admin approves/denies. Goes in 6c push notifications workstream, not in 9.

6. **Activity feed integration**: similar to meal_request_decided entries from 6b. Should `reward_redemption_request_decided` appear in activity feed? Lean yes — parallels meal_requests pattern. Add as a 7th query block in activity_feed_screen.

## Implementation roadmap

Estimated total: **4-6 hours**, comparable to 6a.

**Phase 1: Migration + RPCs (~1.5 hrs)**
- Create `reward_redemption_requests` table + RLS + indexes
- Implement `create_redemption_request` RPC with insufficient-points validation
- Implement `decide_redemption_request` RPC with race-safe re-validation
- Verify against existing `rewards` and `reward_redemptions` schema

**Phase 2: Approvals dashboard 4th section (~1.5 hrs)**
- Add `_RedemptionRequestCard` widget
- New query block in approvals_screen
- Realtime listener for `redemptionRequestsVersion`
- Approve direct + Deny via reject_reason_dialog
- home_shell badge count includes redemption requests

**Phase 3: Kid UI on rewards_screen (~1.5 hrs)**
- Convert single-tab to 2-tab structure
- "My Requests" tab gated to kids
- "Request" button (kid-only label) opens confirm modal → RPC
- Handle INSUFFICIENT_POINTS error
- _RequestHistoryCard widget for kid's view
- Realtime listener on rewards_screen

**Phase 4: Activity feed integration (~30 min) — optional, can defer**
- 7th query block in activity_feed_screen for `reward_redemption_request_decided`
- Icon: Icons.card_giftcard, color: green (approved) / coral (denied)
- Filter chip: "Rewards" or similar

**Phase 5: Smoke test + commit (~30 min)**
- ~15 paths to verify
- SQL verifications for points_balance, point_transactions, request state
- Multi-step flows: request → approve → verify balance, request → deny with note → verify

## Dependencies

**Must exist before Batch 9 can ship:**
- 5a wishlist pattern (exists) — architectural template
- 5b-i Approvals dashboard (exists) — 4th section host
- 6a meal_requests pattern (exists) — architectural template
- 6b realtime + activity feed integration patterns (exists)
- 7a-i rewards_screen migration (exists) — Permissions checks rely on this
- 7a-ii point_history privacy fix (exists) — kid sees only own transactions
- 5b-i reject_reason_dialog (exists) — reused for deny flow
- 7b polish complete (just shipped, v0.6.0)

**Could come later:**
- 6c push notifications — would add push on decide, but not required for 9 to ship
- Auto-archive workstream — deferred per Q5

## LOC estimate

| Layer | Estimated LOC |
|-------|--------------:|
| Migration | ~120 LOC |
| RPCs | ~150 LOC SQL |
| Approvals section | ~150 LOC Dart |
| Kid UI + tab | ~200 LOC Dart |
| Activity feed | ~50 LOC Dart |
| RealtimeService | ~14 LOC Dart |
| **Total** | **~700 LOC** |

In line with 6a's actual ~620 LOC.

## References

- `audits/2026-05-meals-batch-6a-investigation.md` — wishlist + meal_request architecture reference
- `audits/2026-05-meals-batch-6b-investigation.md` — recent-requests tab pattern + activity feed integration
- `audits/2026-05-batch-7a-i-implementation.md` — rewards bug context + decision to capture Batch 9
- `audits/2026-05-batch-7a-membership-migration-investigation.md` — 17-screen scope reveal
- migrations directory — verify `rewards` and `reward_redemptions` table schemas before implementation

## When to ship

No urgency until you have real kid users hitting the rewards screen and trying to redeem. The current state (kid sees RLS error if they try to redeem) is acceptable interim behavior given no real users. When you start onboarding actual families, prioritize Batch 9 before launch.

If push notifications work continues (6c), Batch 9 fits nicely between 6c-ii and 6c-iii — add the redemption decision push trigger as the 3rd-or-later event type, alongside meal_request_decided.
