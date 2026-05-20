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
      <div class="endpoint"><span class="method post">POST</span><span class="path">/households</span></div>
      <div class="endpoint"><span class="method post">POST</span><span class="path">/households/:id/invites</span></div>
      <div class="endpoint"><span class="method post">POST</span><span class="path">/households/join</span></div>
      <div class="endpoint"><span class="method get">GET</span><span class="path">/households/mine</span></div>
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

// ── Household & Invite Endpoints ──────────────────────────────────────────────

/**
 * POST /households
 * Create a new household and add the creator as admin.
 * Body: { name, emoji?, theme_color? }
 * Header: Authorization: Bearer <supabase_access_token>
 */
app.post('/households', async (req, res) => {
  const authHeader = req.header('authorization') || '';
  const token = authHeader.replace('Bearer ', '');
  if (!token) return res.status(401).json({ ok: false, error: 'Missing authorization token' });

  const { data: { user }, error: authError } = await supabaseAdmin.auth.getUser(token);
  if (authError || !user) return res.status(401).json({ ok: false, error: 'Invalid or expired token' });

  const { name, emoji, theme_color } = req.body ?? {};
  if (!name || typeof name !== 'string' || name.trim().length === 0) {
    return res.status(400).json({ ok: false, error: 'name is required' });
  }
  if (name.trim().length > 50) {
    return res.status(400).json({ ok: false, error: 'name must be 50 characters or less' });
  }

  // Check subscription limits: free tier = max 1 household
  const { data: existingMemberships } = await supabaseAdmin
    .from('household_members')
    .select('household_id')
    .eq('user_id', user.id);

  // TODO: Enforce household limit based on subscription tier
  // Free tier: 1 household, Premium: unlimited

  const { data: household, error: createError } = await supabaseAdmin
    .from('households')
    .insert({
      name: name.trim(),
      theme_color: theme_color || '#F5A623',
      owner_user_id: user.id,
      tier: 'free',
      subscription_status: 'active',
    })
    .select()
    .single();

  if (createError) return res.status(500).json({ ok: false, error: 'Failed to create household' });

  // Ensure profile exists for the user
  await supabaseAdmin.from('profiles').upsert({
    id: user.id,
    email: user.email,
    display_name: user.user_metadata?.display_name || user.email?.split('@').first || 'Admin',
  }, { onConflict: 'id' });

  // Add creator as admin
  const { error: memberError } = await supabaseAdmin.from('household_members').insert({
    household_id: household.id,
    auth_user_id: user.id,
    role: 'admin',
    kind: 'adult_auth_user',
    display_name: user.user_metadata?.display_name || 'Admin',
    points_balance: 0,
    is_active: true,
    created_by: user.id,
  });

  if (memberError) return res.status(500).json({ ok: false, error: 'Failed to add household member' });

  // Create default calendar tags
  const defaultTags = [
    { name: 'Chores', color: '#F5A623', emoji: '🧹' },
    { name: 'Meals', color: '#7ED321', emoji: '🍽️' },
    { name: 'Shopping', color: '#4A90D9', emoji: '🛒' },
    { name: 'Family', color: '#FF6B6B', emoji: '❤️' },
    { name: 'School', color: '#9B59B6', emoji: '📚' },
    { name: 'Other', color: '#95A5A6', emoji: '📌' },
  ];

  await supabaseAdmin.from('calendar_tags').insert(
    defaultTags.map((tag) => ({ ...tag, household_id: household.id }))
  );

  res.status(201).json({ ok: true, household });
});

/**
 * POST /households/:id/invites
 * Generate an invite code for a household.
 * Body: { role?: 'admin' | 'member', kind?: 'adult' | 'child' }
 * Header: Authorization: Bearer <supabase_access_token>
 */
app.post('/households/:householdId/invites', async (req, res) => {
  const authHeader = req.header('authorization') || '';
  const token = authHeader.replace('Bearer ', '');
  if (!token) return res.status(401).json({ ok: false, error: 'Missing authorization token' });

  const { data: { user }, error: authError } = await supabaseAdmin.auth.getUser(token);
  if (authError || !user) return res.status(401).json({ ok: false, error: 'Invalid or expired token' });

  const { householdId } = req.params;
  const { role = 'member', kind = 'adult' } = req.body ?? {};

  // Verify the user is an admin of this household
  const { data: membership } = await supabaseAdmin
    .from('household_members')
    .select('role')
    .eq('household_id', householdId)
    .eq('auth_user_id', user.id)
    .maybeSingle();

  if (!membership || membership.role !== 'admin') {
    return res.status(403).json({ ok: false, error: 'Only household admins can create invites' });
  }

  // Check member limit: max 6 members
  const { count } = await supabaseAdmin
    .from('household_members')
    .select('*', { count: 'exact', head: true })
    .eq('household_id', householdId);

  if (count >= 6) {
    return res.status(400).json({ ok: false, error: 'Household has reached the maximum of 6 members' });
  }

  // Generate a unique 6-character invite code
  const code = crypto.randomBytes(3).toString('hex').toUpperCase();

  const { data: invite, error: inviteError } = await supabaseAdmin
    .from('household_invites')
    .insert({
      household_id: householdId,
      code,
      max_uses: 1,
      use_count: 0,
      created_by: user.id,
      expires_at: new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString(), // 7 days
    })
    .select()
    .single();

  if (inviteError) return res.status(500).json({ ok: false, error: 'Failed to create invite' });

  res.status(201).json({ ok: true, invite });
});

/**
 * POST /households/join
 * Join a household using an invite code.
 * Body: { code }
 * Header: Authorization: Bearer <supabase_access_token>
 */
app.post('/households/join', async (req, res) => {
  const authHeader = req.header('authorization') || '';
  const token = authHeader.replace('Bearer ', '');
  if (!token) return res.status(401).json({ ok: false, error: 'Missing authorization token' });

  const { data: { user }, error: authError } = await supabaseAdmin.auth.getUser(token);
  if (authError || !user) return res.status(401).json({ ok: false, error: 'Invalid or expired token' });

  const { code } = req.body ?? {};
  if (!code || typeof code !== 'string') {
    return res.status(400).json({ ok: false, error: 'code is required' });
  }

  // Look up the invite
  const { data: invite } = await supabaseAdmin
    .from('household_invites')
    .select('*')
    .eq('code', code.trim().toUpperCase())
    .maybeSingle();

  if (!invite) {
    return res.status(404).json({ ok: false, error: 'Invalid invite code' });
  }

  // Check expiration
  if (invite.expires_at && new Date(invite.expires_at) < new Date()) {
    return res.status(400).json({ ok: false, error: 'Invite code has expired' });
  }

  // Check if revoked
  if (invite.revoked_at) {
    return res.status(400).json({ ok: false, error: 'Invite code has been revoked' });
  }

  // Check max uses
  if (invite.use_count >= invite.max_uses) {
    return res.status(400).json({ ok: false, error: 'Invite code has reached its usage limit' });
  }

  // Check if already a member
  const { data: existing } = await supabaseAdmin
    .from('household_members')
    .select('id')
    .eq('household_id', invite.household_id)
    .eq('auth_user_id', user.id)
    .maybeSingle();

  if (existing) {
    return res.status(400).json({ ok: false, error: 'You are already a member of this household' });
  }

  // Check member limit
  const { count } = await supabaseAdmin
    .from('household_members')
    .select('*', { count: 'exact', head: true })
    .eq('household_id', invite.household_id);

  if (count >= 6) {
    return res.status(400).json({ ok: false, error: 'Household has reached the maximum of 6 members' });
  }

  // Ensure profile exists
  await supabaseAdmin.from('profiles').upsert({
    id: user.id,
    email: user.email,
    display_name: user.user_metadata?.display_name || user.email?.split('@').first || 'Member',
  }, { onConflict: 'id' });

  // Add as member
  const { error: memberError } = await supabaseAdmin.from('household_members').insert({
    household_id: invite.household_id,
    auth_user_id: user.id,
    role: 'member',
    kind: 'adult_auth_user',
    display_name: user.user_metadata?.display_name || 'Member',
    points_balance: 0,
    is_active: true,
    created_by: user.id,
  });

  if (memberError) return res.status(500).json({ ok: false, error: 'Failed to join household' });

  // Increment invite use count
  await supabaseAdmin.from('household_invites')
    .update({ use_count: invite.use_count + 1 })
    .eq('id', invite.id);

  // Get the household info for the response
  const { data: household } = await supabaseAdmin
    .from('households')
    .select('*')
    .eq('id', invite.household_id)
    .single();

  res.json({ ok: true, household });
});

/**
 * GET /households/mine
 * Get the current user's household(s) with members.
 * Header: Authorization: Bearer <supabase_access_token>
 */
app.get('/households/mine', async (req, res) => {
  const authHeader = req.header('authorization') || '';
  const token = authHeader.replace('Bearer ', '');
  if (!token) return res.status(401).json({ ok: false, error: 'Missing authorization token' });

  const { data: { user }, error: authError } = await supabaseAdmin.auth.getUser(token);
  if (authError || !user) return res.status(401).json({ ok: false, error: 'Invalid or expired token' });

  const { data: memberships, error } = await supabaseAdmin
    .from('household_members')
    .select('*, households(*)')
    .eq('auth_user_id', user.id);

  if (error) return res.status(500).json({ ok: false, error: 'Failed to fetch households' });

  res.json({ ok: true, households: memberships });
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

// ── Admin Endpoints ──────────────────────────────────────────────────────

/**
 * GET /admin/stats
 * Get system-wide statistics (admin only).
 * Header: Authorization: Bearer <supabase_access_token>
 */
app.get('/admin/stats', async (req, res) => {
  const authHeader = req.header('authorization') || '';
  const token = authHeader.replace('Bearer ', '');
  if (!token) return res.status(401).json({ ok: false, error: 'Missing authorization token' });

  const { data: { user }, error: authError } = await supabaseAdmin.auth.getUser(token);
  if (authError || !user) return res.status(401).json({ ok: false, error: 'Invalid or expired token' });

  // Verify admin role — for now, check if user is owner of any household
  const { data: adminMemberships } = await supabaseAdmin
    .from('household_members')
    .select('role')
    .eq('auth_user_id', user.id)
    .in('role', ['owner', 'admin'])
    .limit(1);

  // For system admin, we check app_metadata or a secret header
  const adminSecret = req.header('x-admin-secret') || '';
  const isSystemAdmin = adminSecret === env.ADMIN_SECRET;

  if (!isSystemAdmin && (!adminMemberships || adminMemberships.length === 0)) {
    return res.status(403).json({ ok: false, error: 'Admin access required' });
  }

  try {
    const [households, members, chores, recipes, subs] = await Promise.all([
      supabaseAdmin.from('households').select('id, tier, subscription_status, created_at', { count: 'exact' }),
      supabaseAdmin.from('household_members').select('id, kind, role, is_active', { count: 'exact' }),
      supabaseAdmin.from('chores').select('id, status', { count: 'exact' }),
      supabaseAdmin.from('master_recipes').select('id, status', { count: 'exact' }),
      supabaseAdmin.from('subscriptions').select('id, tier, status', { count: 'exact' }),
    ]);

    res.json({
      ok: true,
      stats: {
        households: { total: households.count || 0 },
        members: {
          total: members.count || 0,
          adults: members.data?.filter(m => m.kind === 'adult_auth_user').length || 0,
          kids: members.data?.filter(m => m.kind === 'sub_profile').length || 0,
        },
        chores: {
          total: chores.count || 0,
          completed: chores.data?.filter(c => c.status === 'verified').length || 0,
        },
        recipes: {
          total: recipes.count || 0,
          pending: recipes.data?.filter(r => r.status === 'pending').length || 0,
          approved: recipes.data?.filter(r => r.status === 'approved').length || 0,
        },
        subscriptions: {
          total: subs.count || 0,
          active: subs.data?.filter(s => s.status === 'active').length || 0,
        },
      },
    });
  } catch (error) {
    res.status(500).json({ ok: false, error: 'Failed to fetch stats' });
  }
});

/**
 * GET /admin/households
 * List all households (system admin only).
 */
app.get('/admin/households', async (req, res) => {
  const adminSecret = req.header('x-admin-secret') || '';
  if (adminSecret !== env.ADMIN_SECRET) {
    return res.status(403).json({ ok: false, error: 'System admin access required' });
  }

  const { data, error } = await supabaseAdmin
    .from('households')
    .select('*, household_members(count)')
    .order('created_at', { ascending: false })
    .limit(100);

  if (error) return res.status(500).json({ ok: false, error: 'Failed to fetch households' });
  res.json({ ok: true, households: data });
});

/**
 * GET /admin/recipes/pending
 * List pending recipe submissions (system admin only).
 */
app.get('/admin/recipes/pending', async (req, res) => {
  const adminSecret = req.header('x-admin-secret') || '';
  if (adminSecret !== env.ADMIN_SECRET) {
    return res.status(403).json({ ok: false, error: 'System admin access required' });
  }

  const { data, error } = await supabaseAdmin
    .from('master_recipes')
    .select('*')
    .eq('status', 'pending')
    .order('created_at', { ascending: false })
    .limit(50);

  if (error) return res.status(500).json({ ok: false, error: 'Failed to fetch pending recipes' });
  res.json({ ok: true, recipes: data });
});

/**
 * POST /admin/recipes/:id/approve
 * Approve a pending recipe submission.
 */
app.post('/admin/recipes/:id/approve', async (req, res) => {
  const adminSecret = req.header('x-admin-secret') || '';
  if (adminSecret !== env.ADMIN_SECRET) {
    return res.status(403).json({ ok: false, error: 'System admin access required' });
  }

  const { id } = req.params;
  const { data, error } = await supabaseAdmin
    .from('master_recipes')
    .update({ status: 'approved', approved_at: new Date().toISOString() })
    .eq('id', id)
    .select()
    .single();

  if (error) return res.status(500).json({ ok: false, error: 'Failed to approve recipe' });
  res.json({ ok: true, recipe: data });
});

/**
 * POST /admin/recipes/:id/reject
 * Reject a pending recipe submission.
 * Body: { reason?: string }
 */
app.post('/admin/recipes/:id/reject', async (req, res) => {
  const adminSecret = req.header('x-admin-secret') || '';
  if (adminSecret !== env.ADMIN_SECRET) {
    return res.status(403).json({ ok: false, error: 'System admin access required' });
  }

  const { id } = req.params;
  const { reason } = req.body ?? {};

  const { data, error } = await supabaseAdmin
    .from('master_recipes')
    .update({ status: 'rejected', rejection_reason: reason || null })
    .eq('id', id)
    .select()
    .single();

  if (error) return res.status(500).json({ ok: false, error: 'Failed to reject recipe' });
  res.json({ ok: true, recipe: data });
});

/**
 * GET /admin/feedback
 * List all feedback submissions.
 */
app.get('/admin/feedback', async (req, res) => {
  const adminSecret = req.header('x-admin-secret') || '';
  if (adminSecret !== env.ADMIN_SECRET) {
    return res.status(403).json({ ok: false, error: 'System admin access required' });
  }

  const { data, error } = await supabaseAdmin
    .from('feedback_requests')
    .select('*')
    .order('created_at', { ascending: false })
    .limit(100);

  if (error) return res.status(500).json({ ok: false, error: 'Failed to fetch feedback' });
  res.json({ ok: true, feedback: data });
});
