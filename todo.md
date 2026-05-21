# Honeydo Mobile App — Audit & Fix Plan

## Audit Complete ✅
- [x] Comprehensive audit of all claimed features vs actual code
- [x] Written detailed audit_report.md with findings

## Key Gaps Found

### Critical (Feature claimed but not functional)
- [ ] Profile switching for kid accounts (PIN verification flow)
- [ ] Chore auto-recurrence (recurrence_rule stored but not acted on)
- [ ] Auto-ingredient import from recipes to shopping list

### Important (Infrastructure exists but not wired in)
- [ ] Wire RealtimeService into more screens (chores, shopping, recipes, members, rewards)
- [ ] Wire OfflineService.fetchWithFallback into screens for offline data access
- [ ] Wire ApiService (with rate limiting) into screens instead of direct Supabase calls
- [ ] Wire ErrorBoundary/AsyncScreenBuilder into screens
- [ ] Add navigation from Members/Stats screens to MemberProfileScreen (orphaned screen)
- [ ] Apply AppA11y utilities to key interactive elements

### Nice-to-have
- [ ] Drag-and-drop meal plan reorder (currently swap-based)
- [ ] Push notification integration with FCM
- [ ] Supabase Edge Functions for server-side achievements and auto-recurrence
- [ ] Unit and widget tests
