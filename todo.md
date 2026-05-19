# Honeydo Mobile App - Build Plan

## Phase 9: Core Functionality ✅ COMPLETE
- [x] Auth flow with Supabase integration (AuthScreen)
- [x] Household setup flow (create/join) (HouseholdSetupScreen)
- [x] Chore dashboard with completion and verification (ChoreDashboardScreen)
- [x] Members management screen (MembersScreen)
- [x] Meal Planner Screen with Supabase integration
- [x] Shopping List Screen with Supabase integration
- [x] Calendar Screen with Supabase integration
- [x] Recipe Library Screen with Supabase integration
- [x] HomeShellScreen navigation updates
- [x] Gamification SQL functions (schema-aligned)
- [x] Package renamed to honeydo_mobile
- [x] All changes pushed to GitHub

## Phase 10: Rewards & Gamification UI (IN PROGRESS)

### 1. Rewards Screen
- [x] Build RewardsScreen with reward catalog
- [x] Display available rewards with point costs
- [x] Show user's current points balance
- [x] Reward redemption flow with confirmation
- [x] Redemption history display
- [x] Supabase integration for rewards and redemptions

### 2. Achievements/Badges Screen
- [x] Build AchievementsScreen
- [x] Display earned badges with icons and descriptions
- [x] Show locked badges (preview)
- [x] Supabase integration for achievements

### 3. Point Transaction History
- [x] Build PointHistoryScreen
- [x] Display all point transactions (earned, spent, adjusted)
- [x] Filter by transaction type
- [x] Show transaction details (source, date, note)

### 4. Settings Screen
- [x] Build SettingsScreen
- [x] Profile editing (display name)
- [x] Notification preferences
- [x] Household settings (name, emoji)
- [x] Account settings (email, password)
- [x] Sign out flow

### 5. Navigation Integration
- [ ] Wire RewardsScreen into HomeShellScreen menu
- [ ] Wire AchievementsScreen into HomeShellScreen menu
- [ ] Wire PointHistoryScreen into HomeShellScreen menu
- [ ] Wire SettingsScreen into HomeShellScreen menu
- [ ] Replace placeholder _showRewards() with full screen navigation
- [ ] Add achievements and point history to popup menu

### 6. Commit & Push
- [ ] Create Phase 10 branch
- [ ] Commit all new screen files
- [ ] Push to GitHub and create PR

## Phase 11: Settings & Profile Enhancements

### 1. Profile Management
- [ ] Profile photo upload to Supabase Storage
- [ ] Display name editing
- [ ] PIN management for kid profiles

## Phase 12: Push Notifications

### 1. Firebase Cloud Messaging Setup
- [ ] Add firebase_messaging dependency
- [ ] Configure FCM in Supabase
- [ ] Device token registration
- [ ] Push notification handling

### 2. Notification Types
- [ ] Chore reminders
- [ ] Chore completion notifications
- [ ] Meal planning reminders
- [ ] Achievement earned notifications
- [ ] Reward redemption notifications

## Phase 13: Payment Integration

### 1. Authorize.net Integration
- [ ] Add payment screen
- [ ] Credit card form
- [ ] Subscription tier selection
- [ ] Payment processing
- [ ] Subscription management

## Phase 14: Admin Dashboard

### 1. Admin Authentication
- [ ] Add admin login to dashboard
- [ ] Role-based access control

### 2. Admin Features
- [ ] User management
- [ ] Household management
- [ ] Recipe moderation (approve/reject)
- [ ] Analytics dashboard
- [ ] System settings

## Future Enhancements
- [ ] Offline support with local storage
- [ ] Dark mode toggle
- [ ] Widget support (iOS/Android)
- [ ] Apple Watch / Wear OS companion
- [ ] Voice assistant integration
- [ ] AI-powered recipe suggestions
- [ ] Smart home integration
