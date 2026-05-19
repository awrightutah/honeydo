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

app.get('/health', async (_req, res) => {
  res.json({ ok: true, service: 'homehub-api', environment: env.NODE_ENV, timestamp: new Date().toISOString() });
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
  const response = await fetch(url, { headers: { 'user-agent': 'HomeHubRecipeImporter/0.1' } });
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
  console.log(`HomeHub API listening on port ${env.PORT}`);
});
