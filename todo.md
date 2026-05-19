# Honeydo Build Todo

## Phase 0 — Project Setup Decisions
- [x] Confirm environment is switched to complex mode before heavy build work
- [x] Decide whether Supabase/Railway setup will be manual-guided or credential-assisted
- [x] Create initial monorepo structure plan

## Phase 1 — Foundation Scaffold
- [x] Create repository structure for Flutter app, backend API, admin dashboard, database, and legal pages
- [x] Add initial documentation/spec files
- [x] Add Supabase schema draft covering households, users, chores, recipes, calendar, shopping, payments, analytics, feedback, and audit trail
- [x] Add environment variable templates

## Phase 2 — Supabase Setup
- [x] Create/prepare Supabase project
- [x] Apply database schema and Row Level Security policies
- [x] Configure Supabase Auth
- [x] Configure Supabase Storage buckets for avatars, recipe images, and chore verification photos
- [x] Store Supabase keys in local environment templates

## Phase 3 — Backend API
- [x] Scaffold backend service for Railway
- [x] Add Supabase admin integration
- [x] Add Authorize.net webhook skeleton with signature verification
- [x] Add recipe import endpoint skeleton
- [x] Add notification job skeleton

## Phase 4 — Flutter Mobile App
- [x] Scaffold Flutter app
- [x] Add app theme: bright playful light/dark mode
- [x] Add auth and onboarding wizard shell
- [x] Add household/member profile shell
- [x] Add chore dashboard shell

## Phase 5 — Admin Dashboard
- [x] Scaffold admin web dashboard
- [x] Add login shell
- [x] Add household management shell
- [x] Add analytics dashboard shell
- [x] Add recipe moderation shell

## Phase 6 — Deployment Prep
- [x] Prepare Railway deployment config
- [x] Prepare build/test scripts
- [x] Document setup steps for local development and deployment

## Phase 7 — Final Verification for Initial Scaffold
- [x] Verify project structure exists
- [x] Verify docs and schema files are present
- [x] Summarize next build milestone

## Phase 8 — Railway Deployment Fixes
- [x] Add root Railway compatibility config for monorepo deploy detection
- [x] Push Railway fix to GitHub main
- [x] Verify /health endpoint returns 200 on Railway
- [x] Add GET / root route landing page so domain shows content in browser
- [x] Rename HomeHub references to Honeydo throughout API
- [x] Merge PR #2 and verify deployment live

## Phase 9 — Build Phase 2: Core Functionality (NEXT)
- [ ] Auth integration: Supabase auth flow in Flutter mobile app (sign up, sign in, password reset)
- [ ] Auth integration: Supabase auth flow in admin dashboard
- [ ] Household creation: Create/join household with invite codes
- [ ] Sub-profiles: Kid-safe sub-profiles under adult auth accounts (COPPA-safe)
- [ ] Chore CRUD: Create, assign, edit, delete chores with templates
- [ ] Chore verification: Admin approval flow with optional photo proof
- [ ] Gamification: Points, streaks, badges, leaderboard
- [ ] Meal planning: Weekly meal planner with recipe linking
- [ ] Shopping lists: Auto-generate from recipes, manual entry, multi-store
- [ ] Calendar: Shared calendar with custom tags/colors
- [ ] Recipe library: Master library, URL import, household recipes
- [ ] Payment integration: Authorize.net recurring billing for premium tier
- [ ] Push notifications: Firebase Cloud Messaging integration
- [ ] Legal drafts: Privacy policy, terms of service
