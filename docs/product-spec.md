# Household App Product Spec

## Working Name

Internal name: HomeHub. Public app name TBD. Honeydo is a possible brand placeholder.

## Product Vision

A bright, playful, all-in-one household app that makes chores fun and keeps family life organized through chores, rewards, meals, recipes, shopping lists, calendars, reminders, and music-powered chore sessions.

## Users and Permissions

- Household Admin: authenticated adult account, can manage household, users, chores, rewards, meals, recipes, shopping, calendar, subscription, and verification.
- Additional Admins: premium households may have multiple adult admins.
- Sub-profiles: child-safe profiles under a household without collecting email or personal child account data. Display name/avatar/pin only.
- Total users: Free supports 2 household members. Premium supports up to 6.

## Core Modules

### Chores

- Create, assign, schedule, and recur chores up to 30 days out.
- Chore statuses: assigned, in_progress, pending_verification, verified, rejected, overdue.
- Admin verification is required before points are awarded.
- Optional photo proof.
- Chore of the Day spotlight with bonus points.
- Chore templates by room, season, and household type.
- Chore roulette and chore swap as premium engagement features.
- 30-day past chore history.

### Gamification

- Points per chore.
- Rewards store.
- Streaks, badges, bonus challenges, leaderboard.
- Full point transaction audit trail.
- 7-day subscription grace period before premium features become read-only.

### Calendar

- In-app calendar only.
- Monthly, weekly, and daily views.
- User-customizable tags with name, emoji/icon, and color.
- Events inherit tag color but can be overridden.
- Tag filtering.
- Proactive reminders and morning/evening digests.

### Meals and Recipes

- 30-day meal planner.
- Household private recipes.
- Import recipes from URL using schema.org Recipe markup, with AI extraction fallback later.
- Master Recipe Library available to all users for browsing.
- Premium users can add master recipes to household, submit recipes, rate recipes, use ingredient search, and receive suggestions.
- Recipe moderation queue in admin dashboard.

### Shopping Lists

- Apple-style clean shopping list UX.
- Manual item entry with quantity, unit, store, and category.
- Recipe ingredient selection: choose a recipe, select ingredients, adjust quantity/servings, and move selected items to shopping list.
- Meal-plan-generated shopping lists with ingredient consolidation.
- Multi-store sections and store filtering.
- Shopping list history for 30 days.

### Music

- External launch to Spotify or Apple Music playlists.
- App does not stream or control audio directly.
- Chore session timer can run alongside music.

### Admin Dashboard

- Household management.
- Chore command center.
- Verification queue.
- Reward and point management.
- Meal and shopping planner.
- In-house analytics dashboard.
- Feedback/request-a-feature queue.
- Recipe moderation queue.
- Subscription management status.

### Payments

- Authorize.net recurring billing at planned $9.99/month.
- App is free to download.
- Premium subscription handled externally on website/admin flow to avoid platform IAP fees where compliant.
- Backend receives Authorize.net webhooks and updates subscription status.

### Notifications

- Firebase Cloud Messaging.
- Proactive notifications: morning digest, evening recap, chore reminders, overdue nudges, verification alerts, badge/reward/streak alerts, calendar reminders.
- Quiet hours and notification preferences.

### Privacy and Security

- COPPA-conscious sub-profile model; no child emails or child auth accounts.
- Supabase Row Level Security on all household-scoped tables.
- API rate limiting.
- Input sanitization.
- HTTPS everywhere.
- Authorize.net webhook signature verification.
- Audit trail for sensitive actions and point changes.

## Freemium Model

### Free

- Up to 2 household members.
- Basic chore creation/assignment.
- Admin verification.
- Basic point system and rewards.
- Manual recipe entry.
- Browse-only master recipe library.
- Basic chore due notifications.

### Premium

- Up to 6 household members.
- 30-day chore calendar/history.
- Full gamification.
- Photo proof and auto-verify timer.
- Meal planner.
- Recipe URL import.
- Master Recipe Library add/submit/rate/search/suggestions.
- Auto-generated shopping lists.
- Shared tagged calendar and reminders.
- Music integration.
- Chore roulette/swap.
- Full admin dashboard.
- Data exports.
