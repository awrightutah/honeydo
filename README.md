# HomeHub / Honeydo Household App

Native household management app for chores, rewards, meal planning, recipes, shopping lists, shared calendars, and an admin dashboard.

## Current Status

Planning is complete and initial scaffold is in progress.

## Monorepo Structure

```text
apps/
  mobile/              Flutter iOS/Android app
  admin-dashboard/     Web dashboard for household admins and platform owner
services/
  api/                 Railway backend API and background jobs
supabase/
  migrations/          Database schema and RLS migrations
  seed.sql             Starter data such as chore templates and recipe seeds
packages/
  shared/              Shared constants/types later
legal/                 Privacy policy and terms drafts
docs/                  Product, setup, and architecture documentation
scripts/               Utility scripts
```

## Core Stack

- Mobile: Flutter
- Admin dashboard: Next.js or React/Vite
- Backend API: Node.js on Railway
- Database/Auth/Realtime/Storage: Supabase
- Payments: Authorize.net recurring billing
- Notifications: Firebase Cloud Messaging
- Music: External Spotify / Apple Music deep links

## Supabase Project

Project URL: https://knrdnshcbkvlopyzouee.supabase.co

Public anon key and service role key are intentionally not committed.
