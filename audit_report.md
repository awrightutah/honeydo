# Honeydo App — Honest Audit: Claimed vs. Actually Implemented

**Audit Date:** 2025-05-21  
**Commit:** 64bfee8 (main)  
**Methodology:** Grep every screen/service for actual implementation depth. Check for real Supabase queries, working UI flows, and end-to-end functionality vs. stub/placeholder code.

---

## Executive Summary

The codebase has **genuine, substantive implementations** for the majority of claimed features. Most screens are 400–1400 lines of real Dart code with Supabase integration, not stubs. However, several features are **partially implemented** or **missing** compared to what was claimed across Phases 1–18. The gaps fall into three categories:

1. **Missing entirely** — features claimed as built that have zero or near-zero implementation
2. **Partially implemented** — features that exist but lack key interactions
3. **Infrastructure only** — services/utilities that are well-built but not wired into screens

---

## Detailed Feature-by-Feature Audit

### ✅ FULLY IMPLEMENTED (Genuine, Working Code)

| Feature | Screen/Service | Lines | Evidence |
|---------|---------------|-------|----------|
| Auth (sign in, sign up, forgot password) | `auth_screen.dart` | 329 | Full Supabase auth with email/password, form validation, navigation |
| Household setup & join | `household_setup_screen.dart` | 467 | Create household, generate invite code, join by code |
| Chore dashboard (create, assign, complete, verify) | `chore_dashboard_screen.dart` | 818 | Full CRUD with Supabase, filtering, assignment, completion flow |
| Chore detail with comments | `chore_detail_screen.dart` | 1005 | Comments load from `chore_comments` table, add comment with `_addComment()` |
| Chore recurring schedules | `chore_dashboard_screen.dart` | 818 | Dropdown: once/daily/weekly/biweekly/monthly, stored as `recurrence_rule` |
| Shopping list with quantity editing | `shopping_list_screen.dart` | 1075 | Full quantity/unit editing in both add-sheet and inline edit dialog |
| Shopping category management | `shopping_category_screen.dart` | 280 | Add/reorder/delete categories, stored in Supabase |
| Recipe library (manual, URL, master) | `recipe_library_screen.dart` | 1405 | Manual add, URL import, master recipe browser with ratings |
| Recipe detail | `recipe_detail_screen.dart` | 1082 | Full ingredient/instruction display, image, rating, scaling |
| Meal planner | `meal_planner_screen.dart` | 883 | Week view, add meals, move between breakfast/lunch/dinner/snack |
| Calendar with events | `calendar_screen.dart` | 774 | Monthly view, create events with tags/colors, member assignment |
| Rewards store | `rewards_screen.dart` | 860 | Create rewards, redeem with points, admin management |
| Point history | `point_history_screen.dart` | 360 | Full transaction log with Supabase query |
| Achievements/badges | `achievements_screen.dart` | 346 | 8 badge types, earned vs. locked display, queries `achievements` table |
| Household stats | `household_stats_screen.dart` | 629 | Chore completion rates, leaderboard, shopping stats |
| Members management | `members_screen.dart` | 539 | Add kid profiles (sub-profiles), manage roles |
| COPPA-safe kid profiles with SHA-256 PIN | `members_screen.dart` | 539 | `crypto` package, `sha256.convert()` for PIN hashing, stored as `pin_hash` |
| Search (chores, recipes, shopping) | `search_screen.dart` | 704 | Multi-entity search with tab filtering, real Supabase queries |
| Activity feed | `activity_feed_screen.dart` | 437 | Aggregates from chores, meals, achievements, members |
| Announcements/pinned messages | `announcements_screen.dart` | 376 | Create/pin/delete announcements, admin-only creation |
| Profile editing | `profile_screen.dart` | 428 | Edit display name, avatar, kind display |
| Settings | `settings_screen.dart` | 629 | Full settings with navigation to sub-screens |
| Notification preferences | `notification_preferences_screen.dart` | 394 | Toggle categories, stored in `notification_preferences` table |
| Invite management | `invite_management_screen.dart` | 719 | Generate codes, view pending invites, revoke |
| Subscription screen | `subscription_screen.dart` | 479 | Free vs. Pro tier display (UI only, no payment integration) |
| Feedback screen | `feedback_screen.dart` | 375 | Submit feedback to `feedback_requests` table |
| Onboarding flow | `onboarding_screen.dart` | 435 | Step-by-step household setup wizard |
| Splash screen | `splash_screen.dart` | 133 | Auth check, navigation routing |
| Chore templates | `chore_templates_screen.dart` | 790 | Browse/create templates, instantiate as chores |
| Data export (JSON/CSV) | `data_export_screen.dart` | 254 | Full format selector, section picker, share via `share_plus` |
| Realtime service | `realtime_service.dart` | 162 | Supabase Realtime subscriptions for 8 tables, version notifiers |
| Offline service | `offline_service.dart` | 389 | Connectivity monitoring, local cache, pending operation queue, sync |
| Rate limiting & debouncing | `rate_limit_service.dart` | 192 | Debouncer, AsyncDebouncer, Throttler, RateLimiter (sliding window) |
| API service | `api_service.dart` | 201 | Centralized with rate limiting, retry logic, error handling |
| Feature tour | `feature_tour_service.dart` | 293 | 8-step overlay walkthrough with animations, version tracking |
| Error boundary | `error_boundary.dart` | ~160 | ErrorBoundary, AsyncScreenBuilder, AsyncListBuilder widgets |
| App error utilities | `app_error.dart` | ~200 | AppError snackbar helpers, ErrorView, EmptyView, LoadingView |
| Accessibility utilities | `app_a11y.dart` | ~200 | Semantics wrappers, touch target sizing, contrast checking |
| Offline banner | `offline_banner.dart` | — | Shows when connectivity is lost |
| Image upload | `image_upload_service.dart` | 151 | Pick from camera/gallery, upload to Supabase Storage |
| Notification service | `notification_service.dart` | 126 | Device token registration, preference checking |

---

### ⚠️ PARTIALLY IMPLEMENTED (Exists But Missing Key Parts)

| Feature | What Exists | What's Missing |
|---------|------------|----------------|
| **Member profile deep link** | `member_profile_screen.dart` (407 lines) — screen exists and renders profile data | No navigation path TO it. Neither `members_screen.dart` nor `household_stats_screen.dart` has `onTap` → `Navigator.push` to `MemberProfileScreen`. The screen is orphaned — you can't reach it from anywhere in the app. |
| **Meal plan reorder/drag-and-drop** | Meal plans can be moved between meal types (breakfast↔lunch↔dinner) via a swap button | No drag-and-drop reorder. Claimed "drag-and-drop reorder" but only a dropdown/button-based meal-type swap exists. Not a critical gap — the swap approach works — but it's not what was claimed. |
| **PIN verification on profile switch** | PIN is hashed with SHA-256 and stored during kid profile creation | There is no profile-switching UI and no PIN verification flow. Kids can't actually "sign in with a PIN." The PIN is collected and stored, but never checked. The app doesn't have a profile-switcher at all. |
| **Realtime in screens** | `RealtimeService` is well-built and initialized in `HomeShellScreen` | Only 2 screens actually listen to realtime events: `HomeShellScreen` (points + announcements) and `MealPlannerScreen`. The other 6 ValueNotifiers (chores, shopping, recipes, members, rewards) are broadcast but never consumed. Screens still do manual reloads. |
| **Offline integration in screens** | `OfflineService` has full cache/sync/queue implementation | No screen actually uses `fetchWithFallback()`, `fetchListWithFallback()`, or `performWrite()`. The service exists but screens all make direct Supabase calls. The `OfflineBanner` shows status, but data doesn't actually work offline. |
| **ApiService usage** | `ApiService` with rate limiting and retry is well-implemented | No screen uses `ApiService.instance`. Every screen makes direct `Supabase.instance.client` calls. The service is an unused utility. |
| **Error boundaries on screens** | `ErrorBoundary`, `AsyncScreenBuilder` widgets exist | No screen wraps its content in `ErrorBoundary`. Screens handle errors individually with try/catch + SnackBar. The utilities exist but aren't integrated. |
| **Accessibility in screens** | `AppA11y` utilities (semantics, touch targets, contrast) exist | No screen uses `AppA11y.labeled()`, `AppA11y.touchTarget()`, or `AccessibleCard`. The utilities exist but aren't applied to any widget. |
| **Home shell deep navigation** | Bottom nav with 5 tabs (Dashboard, Meals, Shopping, Calendar, Recipes) + popup menu for more | No quick-access to search from the shell (search is buried in popup menu). The "+" FAB only creates chores, not context-aware items (e.g., shopping item when on shopping tab). |

---

### ❌ MISSING ENTIRELY (Claimed But Not Implemented)

| Feature | What Was Claimed | Reality |
|---------|-----------------|---------|
| **Profile switching** (Phase 17) | "Kids access the app using a simple PIN under the adult's account" | No profile-switcher UI exists. No PIN entry dialog. No way to switch between adult and kid profiles within a session. The `pin_hash` column exists in the DB but is never read/verified. |
| **Chore auto-recurrence** (Phase 17) | "Recurring schedule support (daily/weekly/biweekly/monthly)" | The UI allows selecting a recurrence rule when creating a chore, and it's stored as `recurrence_rule` in the DB. But there is **no logic to automatically create the next occurrence** when a recurring chore is completed. It's just a label — the chore doesn't actually recur. This would need a Supabase Edge Function or client-side logic. |
| **Auto-ingredient import from recipes to shopping list** (Phase 15) | "Meal planner with auto-ingredient import" | The meal planner can link recipes to meal plans, and the recipe detail screen shows ingredients. But there is no button or logic to automatically add recipe ingredients to the shopping list. The connection between recipes → meal plans → shopping items is manual. |
| **Push notifications** (Phase 13) | Notification service with FCM integration | `NotificationService` can register device tokens and check preferences, but there is no FCM integration, no background message handler, and no notification display logic. The `notification_preferences_screen.dart` toggles are stored but not consumed by any push system. |
| **Supabase Edge Functions** (various phases) | Server-side logic for achievements, auto-recurrence, etc. | The `0002_gamification_functions.sql` migration defines a `check_and_award_achievements` function, but there's no Edge Function to trigger it on chore completion. Achievements are checked client-side only. No Edge Functions exist in the repo. |

---

## Architecture & Code Quality Assessment

### Strengths
- **Consistent theme** — `AppColors` and `AppTheme` are used throughout
- **Real Supabase integration** — screens query real tables, not mock data
- **Comprehensive schema** — 27 tables with RLS policies, indexes, and triggers
- **Well-structured services** — RealtimeService, OfflineService, RateLimitService are production-quality code
- **Good screen depth** — Most screens are 400–1000+ lines with full CRUD operations

### Weaknesses
- **Orphaned services** — ApiService, OfflineService's data methods, and ErrorBoundary exist but aren't consumed
- **No profile switching** — Core kid-profile feature is incomplete without it
- **No auto-recurrence** — The recurrence_rule is just a label, not functional
- **No offline data access** — The banner shows status, but screens crash without network
- **Inconsistent error handling** — Some screens use try/catch + SnackBar, others don't handle errors at all
- **No tests** — Zero test files exist in the entire project

---

## Summary Scorecard

| Category | Claimed | Actually Works | Partial | Missing |
|----------|---------|---------------|---------|---------|
| Core screens (auth, chores, meals, shopping, calendar, recipes) | 12 | 12 | 0 | 0 |
| Social features (members, profiles, comments, announcements, activity) | 5 | 3 | 2 | 0 |
| Gamification (points, rewards, achievements, badges) | 4 | 4 | 0 | 0 |
| Kid profiles (COPPA, PIN, profile switching) | 3 | 1 | 1 | 1 |
| Infrastructure (realtime, offline, rate limit, error handling, a11y) | 5 | 2 | 3 | 0 |
| Cross-feature flows (auto-recurrence, auto-ingredients, push notifications) | 3 | 0 | 0 | 3 |
| **TOTAL** | **32** | **22** | **6** | **4** |

**Bottom line:** Roughly **69% of claimed features are fully working**, **19% are partially implemented** (the service/utility exists but isn't wired into the app), and **12% are missing entirely**. The biggest gaps are profile switching for kid accounts, auto-recurrence for chores, and auto-ingredient import from recipes to shopping lists.

The app is a solid MVP with genuine depth in its core screens. The main work needed is wiring existing infrastructure services into the screens that should use them, and building the three missing cross-feature flows.
