#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "[preview] Checking Docker runtime..."
docker info >/dev/null

echo "[preview] Starting isolated local Supabase stack..."
npx supabase start

echo "[preview] Applying repository migrations to the local database only..."
npx supabase migration up --local

echo "[preview] Reading local publishable key..."
STATUS_ENV="$(npx supabase status -o env)"
eval "$STATUS_ENV"
export ANON_KEY
: "${ANON_KEY:?Supabase CLI did not return ANON_KEY}"

node --input-type=commonjs <<'NODE'
const fs = require("node:fs");
const key = process.env.ANON_KEY;
if (!key) throw new Error("Missing local Supabase ANON_KEY");
const js = `window.__TRACCIAMENTO_PREVIEW_CONFIG__ = {
  url: window.location.origin,
  publishableKey: ${JSON.stringify(key)}
};\n`;
fs.writeFileSync("preview-config.js", js, { mode: 0o600 });
NODE

echo "[preview] Starting Vite..."
if ! curl -fsS http://127.0.0.1:3000 >/dev/null 2>&1; then
  nohup npm run preview >/tmp/tracciamento-preview.log 2>&1 </dev/null &
fi

echo "[preview] Ready. App port: 3000 | Supabase Studio: 54323"
