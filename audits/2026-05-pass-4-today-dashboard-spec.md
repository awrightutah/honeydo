# Pass 4: Today Dashboard / Home Screen — Concept Stub

**Status:** Placeholder. Not yet designed. Implementation deferred until Pass 3 (kid permissions, Batches 1-8) ships.

## Origin

Surfaced during Batch 3 Half B iPhone testing on 2026-05-24. While testing the verified-chores-stale fix, the user observed there's no way for an admin (owner) to see outstanding chores assigned to other household members on the dashboard. The current Chores tab home only shows "My Chores" + "Pending Verification" — chores assigned to OTHER people in 'assigned' or 'in_progress' state are invisible.

This expanded into a broader concept: the app needs a daily overview / home screen that surfaces what's relevant for "today" across multiple concerns.

## Concept

A daily/home screen showing:

1. **Today's meal**
   - If a meal is planned for today: show it (recipe name, optionally photo, meal type)
   - If no meal planned: offer affordance to select one (recipe picker or "What's for dinner?" prompt)

2. **Today's calendar items**
   - List events scheduled for today
   - Empty state: playful copy, e.g., "No activities today — looks like you get to relax a little"

3. **All outstanding chores**
   - Non-completed chores across the whole household
   - Grouped by assignee (each member's chores together)
   - Shows chore name + assignee name
   - Statuses to include: assigned, in_progress (probably also pending_verification — TBD)

## Open Design Questions (resolve before implementing)

### Q1. Navigation / where does this live?
Options:
- New tab in bottom nav (e.g., "Today" or "Home"). Would replace or sit alongside existing tabs (Chores, Meals, Shop, Calendar, Recipes).
- Replace the current Chores tab default view (Chores tab becomes the Today dashboard, with chore-specific tools nested).
- New screen accessed from a button on existing dashboard (not a tab change).

### Q2. Scope per role
- Does kid see the same dashboard as adult, or a kid-specific version?
- Kids probably shouldn't see other members' chores (privacy / focus).
- Calendar / meal sections might be the same.
- Or: kid sees only their own chores + today's meal; admin sees everyone's chores.

### Q3. Refresh model
- Realtime updates as chores/meals change?
- Pull-to-refresh?
- Daily reset at midnight?

### Q4. Empty states for each section
- No chores today: what's the message?
- No meal planned: what's the affordance? Quick picker? "Plan a meal" CTA?
- No calendar items: confirmed copy "No activities today — looks like you get to relax a little" (or variations).

### Q5. Outstanding chores section specifics
- Group by assignee — confirmed
- Sort within each group? (Due date? Chore name? Points?)
- How to show "overdue" — visual indicator?
- Does pending_verification appear here (admin can verify from this section), or only assigned/in_progress?

### Q6. Meal section specifics
- Show what info? (Recipe name, photo, prep time, "Today's [Breakfast/Lunch/Dinner]")
- One meal slot or multiple (breakfast + lunch + dinner)?
- Quick action on the meal card (start cooking timer, view recipe, mark as cooked)?

### Q7. Calendar section specifics
- What's the calendar source? (App's own calendar feature? Device calendar import?)
- Show all-day vs. timed events?
- Tappable to view event details?

## Dependencies / Blockers

- **Kid permissions (Pass 3)** must ship first. The "scope per role" question depends on the permissions model being solid.
- **Meal plan UI** needs to be mature enough to support a "today's meal" surfacing pattern. This may already be fine; verify when designing.
- **Calendar feature** must be functional and queryable. Verify state when designing.

## Implementation Estimate (very rough)

3-5 batches probably:
- Batch 1: outstanding chores section (the originally-requested piece)
- Batch 2: today's meal section + meal picker affordance
- Batch 3: calendar section
- Batch 4: empty states + polish
- Batch 5 (if applicable): navigation restructure (new tab vs replace chores tab vs other)

## Not in Scope (Pass 4 specifically)

- Weekly view (this is a TODAY dashboard, not a weekly planner)
- Multi-day calendar (point at calendar tab for that)
- Notification scheduling (handled elsewhere)

## Next Steps When Picked Up

1. Resolve Q1-Q7 (similar walkthrough to how we resolved kid permissions Q1-Q11)
2. Write proper investigation pass
3. Implement in batches as above
4. Tag v0.4.0-today-dashboard or similar when complete
