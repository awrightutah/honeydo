import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import rateLimit from 'express-rate-limit';
import crypto from 'crypto';
import { parse } from 'node-html-parser';
import { env } from './env.js';
import { supabaseAdmin } from './supabaseAdmin.js';

const app = express();

app.use(helmet());
app.use(cors({ origin: true, credentials: true }));
app.use(rateLimit({ windowMs: 60_000, limit: 120 }));

// Keep raw body available for Authorize.net webhook signature verification later.
app.use(express.json({
  limit: '2mb',
  verify: (req, _res, buf) => {
    req.rawBody = buf;
  },
}));

app.get('/', (_req, res) => {
  res.type('html').send(`<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Honeydo API</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: linear-gradient(135deg, #FFF8F0 0%, #FDEBD0 100%);
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      color: #2D3436;
    }
    .card {
      background: white;
      border-radius: 24px;
      padding: 48px;
      max-width: 520px;
      width: 90%;
      text-align: center;
      box-shadow: 0 8px 32px rgba(0,0,0,0.08);
    }
    .bee { font-size: 64px; margin-bottom: 16px; }
    h1 { font-size: 28px; margin-bottom: 8px; color: #2D3436; }
    .tagline { color: #636E72; font-size: 16px; margin-bottom: 32px; }
    .status {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      background: #E8F8F5;
      color: #00B894;
      padding: 8px 20px;
      border-radius: 100px;
      font-weight: 600;
      font-size: 14px;
      margin-bottom: 32px;
    }
    .status .dot {
      width: 8px; height: 8px;
      background: #00B894;
      border-radius: 50%;
      animation: pulse 2s infinite;
    }
    @keyframes pulse {
      0%, 100% { opacity: 1; }
      50% { opacity: 0.4; }
    }
    .endpoints {
      text-align: left;
      background: #F8F9FA;
      border-radius: 16px;
      padding: 20px;
      margin-top: 8px;
    }
    .endpoints h3 {
      font-size: 13px;
      text-transform: uppercase;
      letter-spacing: 1px;
      color: #B2BEC3;
      margin-bottom: 12px;
    }
    .endpoint {
      display: flex;
      align-items: center;
      gap: 12px;
      padding: 8px 0;
      font-size: 14px;
      border-bottom: 1px solid #ECEEF0;
    }
    .endpoint:last-child { border-bottom: none; }
    .method {
      font-weight: 700;
      font-size: 11px;
      padding: 3px 8px;
      border-radius: 4px;
      min-width: 44px;
      text-align: center;
    }
    .get { background: #D5F5E3; color: #1E8449; }
    .post { background: #D6EAF8; color: #2471A3; }
    .path { font-family: 'SF Mono', 'Fira Code', monospace; color: #2D3436; }
  </style>
</head>
<body>
  <div class="card">
    <div class="bee">🐝</div>
    <h1>Honeydo API</h1>
    <p class="tagline">Household chore management &amp; meal planning</p>
    <div class="status"><span class="dot"></span> Operational</div>
    <div class="endpoints">
      <h3>Available Endpoints</h3>
      <div class="endpoint"><span class="method get">GET</span><span class="path">/health</span></div>
      <div class="endpoint"><span class="method post">POST</span><span class="path">/recipes/import</span></div>
      <div class="endpoint"><span class="method post">POST</span><span class="path">/webhooks/authorize-net</span></div>
      <div class="endpoint"><span class="method post">POST</span><span class="path">/jobs/send-notifications</span></div>
    </div>
  </div>
</body>
</html>`);
});

app.get('/health', async (_req, res) => {
  res.json({ ok: true, service: 'honeydo-api', environment: env.NODE_ENV, timestamp: new Date().toISOString() });
});

app.post('/webhooks/authorize-net', async (req, res) => {
  const signatureHeader = req.header('x-anet-signature') || '';
  const verified = verifyAuthorizeNetSignature(req.rawBody, signatureHeader);

  if (!verified && env.AUTHORIZE_NET_SIGNATURE_KEY) {
    return res.status(401).json({ ok: false, error: 'Invalid Authorize.net signature' });
  }

  // TODO: Map Authorize.net events to subscription records.
  await supabaseAdmin.from('analytics_events').insert({
    event_type: 'authorize_net_webhook_received',
    metadata: { eventType: req.body?.eventType ?? null, verified },
  });

  res.json({ ok: true, received: true });
});

app.post('/recipes/import', async (req, res) => {
  const { url } = req.body ?? {};
  if (!url || typeof url !== 'string') {
    return res.status(400).json({ ok: false, error: 'url is required' });
  }

  try {
    const imported = await importRecipeFromUrl(url);
    res.json({ ok: true, recipe: imported });
  } catch (error) {
    res.status(422).json({ ok: false, error: error.message });
  }
});

app.post('/jobs/send-notifications', async (_req, res) => {
  // TODO: Implement Firebase Cloud Messaging dispatch for reminders/digests.
  await supabaseAdmin.from('analytics_events').insert({
    event_type: 'notification_job_triggered',
    metadata: { status: 'placeholder' },
  });
  res.json({ ok: true, status: 'placeholder' });
});

function verifyAuthorizeNetSignature(rawBody, header) {
  if (!env.AUTHORIZE_NET_SIGNATURE_KEY) return false;
  if (!header.startsWith('sha512=')) return false;

  const expected = `sha512=${crypto
    .createHmac('sha512', Buffer.from(env.AUTHORIZE_NET_SIGNATURE_KEY, 'hex'))
    .update(rawBody)
    .digest('hex')}`;

  return crypto.timingSafeEqual(Buffer.from(expected), Buffer.from(header));
}

async function importRecipeFromUrl(url) {
  const response = await fetch(url, { headers: { 'user-agent': 'HoneydoRecipeImporter/0.1' } });
  if (!response.ok) throw new Error(`Failed to fetch recipe URL: ${response.status}`);

  const html = await response.text();
  const root = parse(html);
  const jsonLdScripts = root.querySelectorAll('script[type="application/ld+json"]');

  for (const script of jsonLdScripts) {
    const text = script.textContent.trim();
    if (!text) continue;
    try {
      const parsed = JSON.parse(text);
      const recipe = findRecipeJsonLd(parsed);
      if (recipe) return normalizeRecipe(recipe, url);
    } catch {
      // Continue scanning other scripts.
    }
  }

  throw new Error('No schema.org Recipe data found. Manual entry or AI fallback will be needed.');
}

function findRecipeJsonLd(value) {
  if (!value) return null;
  if (Array.isArray(value)) {
    for (const item of value) {
      const found = findRecipeJsonLd(item);
      if (found) return found;
    }
  }
  if (typeof value === 'object') {
    const type = value['@type'];
    if (type === 'Recipe' || (Array.isArray(type) && type.includes('Recipe'))) return value;
    if (value['@graph']) return findRecipeJsonLd(value['@graph']);
  }
  return null;
}

function normalizeRecipe(recipe, sourceUrl) {
  const ingredients = Array.isArray(recipe.recipeIngredient)
    ? recipe.recipeIngredient.map((item) => ({ raw: String(item) }))
    : [];

  const stepsRaw = recipe.recipeInstructions ?? [];
  const steps = Array.isArray(stepsRaw)
    ? stepsRaw.map((step) => typeof step === 'string' ? step : step.text).filter(Boolean)
    : [];

  return {
    title: recipe.name ?? 'Imported Recipe',
    description: recipe.description ?? null,
    image_url: Array.isArray(recipe.image) ? recipe.image[0] : recipe.image ?? null,
    ingredients,
    steps,
    prep_time: recipe.prepTime ?? null,
    cook_time: recipe.cookTime ?? null,
    total_time: recipe.totalTime ?? null,
    servings: recipe.recipeYield ?? null,
    cuisine: recipe.recipeCuisine ?? null,
    tags: recipe.keywords ? String(recipe.keywords).split(',').map((tag) => tag.trim()) : [],
    source_url: sourceUrl,
  };
}

app.listen(env.PORT, () => {
  console.log(`Honeydo API listening on port ${env.PORT}`);
});
