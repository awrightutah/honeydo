# Day 7 TestFlight Bugs — Found 2026-05-29 evening / 2026-05-30 morning

## Source
First TestFlight install of build 1.0.0(1) on Andrew's iPhone (the developer's own device). No external testers invited yet.

## Bug 1: Calendar doesn't display meals

### Reproduction
1. Log into app
2. Navigate to calendar tab (Pass-3 calendar view)
3. Observe: meals that have been planned in the meal planning flow do not appear on the calendar

### Investigation needed
- Does the meal data exist in the database?
- Is the calendar fetching the right table / date range / household?
- Is meal data being saved to a different table than the calendar reads?

### Priority
Medium. Functional gap in a major Pass-3 feature, but does not block testing of other flows.

### Status
Documented. Not yet investigated.

## Bug 2: Recipe URL import fails catastrophically

### Reproduction
1. Log into app
2. Navigate to recipe library
3. Tap "Import from URL" (or whatever the entry point is — confirm during code investigation)
4. Enter URL: https://heygrillhey.com (or a specific recipe URL on heygrillhey.com)
5. Observe: app navigates to a new screen, screen goes blank/black, app becomes unresponsive
6. Workaround: hard-close app via app switcher, reopen, log back in

### Symptoms beyond the immediate failure
- App auth session was lost — required re-login after reopen. This is a separate concern from the import failure itself.

### Suspected scope
The recipe import flow currently uses the Railway-hosted fetcher (services/api/src/server.js → importRecipeFromUrl). The Day 5 spike showed a Flutter WebView fetcher won the comparison and was the recommended replacement, but that spike has NOT been merged into the production path. So the production path is still using the original fetcher.

Possible failure points:
- Fetcher times out or hangs on heygrillhey.com (HTML structure, JS-heavy page)
- Fetcher returns malformed/empty data that the UI doesn't handle
- Navigation transition fails or pushes a screen with no rendering state
- Auth session loss is likely a separate bug exposed by this code path

### Priority
HIGH. The recipe import flow is one of the headline differentiators of the app. Testers shouldn't be told "don't touch this" if it can be fixed quickly. Auth state loss is also concerning regardless of trigger.

### Status
Documented. Investigation starting morning of 2026-05-30.

## Other findings
None yet. More bugs will likely surface as additional testers are invited.
