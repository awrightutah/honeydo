#!/usr/bin/env bash
set -euo pipefail

echo "Checking HomeHub scaffold..."

test -f README.md
test -f docs/product-spec.md
test -f docs/setup-guide.md
test -f supabase/migrations/0001_initial_schema.sql
test -f supabase/seed.sql
test -f services/api/package.json
test -f services/api/src/server.js
test -f apps/admin-dashboard/package.json
test -f apps/admin-dashboard/src/App.jsx
test -f apps/mobile/pubspec.yaml
test -f apps/mobile/lib/main.dart

echo "Scaffold files present."
