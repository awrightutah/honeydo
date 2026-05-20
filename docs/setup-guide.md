# Setup Guide

## 1. Supabase Setup

Project URL already provided:

```text
https://knrdnshcbkvlopyzouee.supabase.co
```

### Required keys

From Supabase Dashboard → Project Settings → API, collect:

- Project URL
- anon public key
- service_role key

Do not commit the service role key. Add it only to local `.env` files and Railway variables.

### Apply schema

In Supabase Dashboard → SQL Editor:

1. Open `supabase/migrations/0001_initial_schema.sql`.
2. Paste into SQL Editor.
3. Run it.
4. Open `supabase/seed.sql`.
5. Paste into SQL Editor.
6. Run it.

### Configure Auth

Recommended initial settings:

- Enable email/password auth.
- Enable email confirmation later before production.
- Add Google/Apple OAuth later after app bundle IDs/domains are final.
- Site URL will be set after the admin dashboard/web URL exists.

### Configure Storage Buckets

Create these buckets:

1. `avatars` — public read.
2. `recipe-images` — public read.
3. `chore-verification-photos` — private.

Storage RLS policies should be tightened after app paths are finalized.

## 2. Backend API Local Setup

```bash
cd services/api
cp .env.example .env
# Fill SUPABASE_SERVICE_ROLE_KEY
npm install
npm run dev
```

Health check:

```bash
curl http://localhost:3000/health
```

## 3. Railway Setup

Recommended after backend is committed to GitHub:

1. Create new Railway project.
2. Deploy from GitHub repository.
3. Set root/service directory to `services/api` if Railway asks.
4. Add variables from `services/api/.env.example`:
   - `SUPABASE_URL`
   - `SUPABASE_SERVICE_ROLE_KEY`
   - `AUTHORIZE_NET_API_LOGIN_ID`
   - `AUTHORIZE_NET_TRANSACTION_KEY`
   - `AUTHORIZE_NET_SIGNATURE_KEY`
5. Confirm `/health` works on Railway public URL.

## 4. Admin Dashboard Local Setup

```bash
cd apps/admin-dashboard
cp .env.example .env
# Fill NEXT_PUBLIC_SUPABASE_ANON_KEY or VITE equivalent once dashboard connection is implemented
npm install
npm run dev
```

## 5. Mobile App Local Setup

Flutter is not installed in the sandbox, so run locally:

```bash
cd apps/mobile
cp .env.example .env
flutter pub get
flutter run
```

## 6. Current Missing Secrets

Still needed from you:

- Supabase anon public key.
- Supabase service role key for backend/Railway.
- Authorize.net API credentials later.
- Firebase project credentials later.


## Production API

Railway API URL:

```text
https://honeydo-production-743d.up.railway.app
```

Health endpoint:

```text
https://honeydo-production-743d.up.railway.app/health
```

Verified healthy on 2026-05-19.
