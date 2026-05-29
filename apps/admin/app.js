// Clanquility Admin Dashboard
(function() {
  'use strict';

  // State
  const state = {
    authToken: null,
    adminSecret: null,
    apiUrl: localStorage.getItem('honeydo_api_url') || 'https://honeydo-production-743d.up.railway.app',
    supabaseUrl: localStorage.getItem('honeydo_supabase_url') || 'https://knrdnshcbkvlopyzouee.supabase.co',
    currentPage: 'overview',
    stats: null,
  };

  // DOM refs
  const $ = (sel) => document.querySelector(sel);
  const $$ = (sel) => document.querySelectorAll(sel);

  // Initialize
  document.addEventListener('DOMContentLoaded', () => {
    // Restore session
    state.authToken = sessionStorage.getItem('honeydo_auth_token');
    state.adminSecret = sessionStorage.getItem('honeydo_admin_secret');

    if (state.authToken && state.adminSecret) {
      showDashboard();
    } else {
      showLogin();
    }

    // Nav click handlers
    $$('.nav-item').forEach(item => {
      item.addEventListener('click', (e) => {
        e.preventDefault();
        const page = item.dataset.page;
        navigateTo(page);
      });
    });

    // Login form
    $('#loginForm').addEventListener('submit', handleLogin);

    // Menu toggle
    $('#menuToggle').addEventListener('click', () => {
      $('#sidebar').classList.toggle('open');
    });

    // Load settings
    $('#settingsApiUrl').value = state.apiUrl;
    $('#settingsSupabaseUrl').value = state.supabaseUrl;
  });

  function showLogin() {
    $('#loginPage').classList.add('active');
    $$('.page:not(#loginPage)').forEach(p => p.classList.remove('active'));
    $('.sidebar-nav').style.display = 'none';
  }

  function showDashboard() {
    $('#loginPage').classList.remove('active');
    $('.sidebar-nav').style.display = '';
    navigateTo('overview');
  }

  async function handleLogin(e) {
    e.preventDefault();
    const email = $('#loginEmail').value;
    const password = $('#loginPassword').value;
    const secret = $('#adminSecret').value;

    try {
      // Authenticate with Supabase
      const response = await fetch(`${state.supabaseUrl}/auth/v1/token?grant_type=password`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'apikey': 'sb_publishable_1TzZ7xAHHzWSfIOTEJNbRQ_HymVVEQO',
        },
        body: JSON.stringify({ email, password }),
      });

      const data = await response.json();

      if (data.access_token) {
        state.authToken = data.access_token;
        state.adminSecret = secret;
        sessionStorage.setItem('honeydo_auth_token', data.access_token);
        sessionStorage.setItem('honeydo_admin_secret', secret);
        showDashboard();
      } else {
        alert('Login failed: ' + (data.error_description || data.msg || 'Unknown error'));
      }
    } catch (err) {
      alert('Login error: ' + err.message);
    }
  }

  function navigateTo(page) {
    state.currentPage = page;

    // Update nav
    $$('.nav-item').forEach(item => {
      item.classList.toggle('active', item.dataset.page === page);
    });

    // Update page title
    const titles = {
      overview: 'Overview',
      households: 'Households',
      recipes: 'Recipe Moderation',
      feedback: 'Feedback',
      settings: 'Settings',
    };
    $('#pageTitle').textContent = titles[page] || page;

    // Show correct page
    $$('.page').forEach(p => p.classList.remove('active'));
    $(`#${page}Page`).classList.add('active');

    // Load data
    switch (page) {
      case 'overview': loadStats(); break;
      case 'households': loadHouseholds(); break;
      case 'recipes': loadPendingRecipes(); break;
      case 'feedback': loadFeedback(); break;
    }

    // Close mobile sidebar
    $('#sidebar').classList.remove('open');
  }

  async function apiCall(endpoint, options = {}) {
    const headers = {
      'Authorization': `Bearer ${state.authToken}`,
      'x-admin-secret': state.adminSecret,
      'Content-Type': 'application/json',
    };

    const response = await fetch(`${state.apiUrl}${endpoint}`, {
      ...options,
      headers: { ...headers, ...options.headers },
    });

    if (response.status === 401) {
      sessionStorage.clear();
      showLogin();
      throw new Error('Session expired');
    }

    return response.json();
  }

  // ── Overview ──
  async function loadStats() {
    try {
      const data = await apiCall('/admin/stats');
      if (data.ok) {
        const s = data.stats;
        $('#statHouseholds').textContent = s.households?.total ?? '—';
        $('#statMembers').textContent = s.members?.total ?? '—';
        $('#statChores').textContent = s.chores?.completed ?? '—';
        $('#statRecipes').textContent = s.recipes?.total ?? '—';
        $('#statPremium').textContent = s.subscriptions?.active ?? '—';
        $('#statPending').textContent = s.recipes?.pending ?? '—';
      }
    } catch (err) {
      console.error('Failed to load stats:', err);
    }
  }

  // ── Households ──
  async function loadHouseholds() {
    try {
      const data = await apiCall('/admin/households');
      const tbody = $('#householdsTable');

      if (!data.ok || !data.households?.length) {
        tbody.innerHTML = '<tr><td colspan="5" class="empty">No households found</td></tr>';
        return;
      }

      tbody.innerHTML = data.households.map(h => `
        <tr>
          <td><strong>${escapeHtml(h.name || 'Unnamed')}</strong></td>
          <td><span class="status-badge ${h.tier === 'premium' ? 'status-premium' : 'status-free'}">${h.tier || 'free'}</span></td>
          <td><span class="status-badge status-active">${h.subscription_status || 'active'}</span></td>
          <td>${h.household_members?.[0]?.count ?? '?'}</td>
          <td>${formatDate(h.created_at)}</td>
        </tr>
      `).join('');
    } catch (err) {
      console.error('Failed to load households:', err);
    }
  }

  // ── Recipe Moderation ──
  async function loadPendingRecipes() {
    try {
      const data = await apiCall('/admin/recipes/pending');
      const container = $('#recipeCards');

      if (!data.ok || !data.recipes?.length) {
        container.innerHTML = '<div class="empty-state">🎉 No pending recipes to review!</div>';
        return;
      }

      container.innerHTML = data.recipes.map(r => `
        <div class="recipe-card">
          <div class="recipe-card-header">
            <h3>${escapeHtml(r.title)}</h3>
            <p>${escapeHtml(r.description || 'No description')}</p>
          </div>
          <div class="recipe-card-body">
            <div class="meta">
              ${r.cuisine ? `<span>${escapeHtml(r.cuisine)}</span>` : ''}
              ${r.difficulty ? `<span>${escapeHtml(r.difficulty)}</span>` : ''}
              ${r.servings ? `<span>${r.servings} servings</span>` : ''}
              <span>Submitted ${formatDate(r.created_at)}</span>
            </div>
            <div class="recipe-card-actions">
              <button class="btn btn-success btn-sm" onclick="approveRecipe('${r.id}')">✓ Approve</button>
              <button class="btn btn-danger btn-sm" onclick="rejectRecipe('${r.id}')">✕ Reject</button>
            </div>
          </div>
        </div>
      `).join('');
    } catch (err) {
      console.error('Failed to load recipes:', err);
    }
  }

  // ── Feedback ──
  async function loadFeedback() {
    try {
      const data = await apiCall('/admin/feedback');
      const tbody = $('#feedbackTable');

      if (!data.ok || !data.feedback?.length) {
        tbody.innerHTML = '<tr><td colspan="5" class="empty">No feedback yet</td></tr>';
        return;
      }

      tbody.innerHTML = data.feedback.map(f => `
        <tr>
          <td>${escapeHtml(f.type || 'feature_request')}</td>
          <td><strong>${escapeHtml(f.title)}</strong></td>
          <td><span class="status-badge ${f.status === 'new' ? 'status-pending' : 'status-active'}">${f.status}</span></td>
          <td>${formatDate(f.created_at)}</td>
          <td>
            <button class="btn btn-outline btn-sm" onclick="viewFeedback('${f.id}')">View</button>
          </td>
        </tr>
      `).join('');
    } catch (err) {
      console.error('Failed to load feedback:', err);
    }
  }

  // Global actions
  window.approveRecipe = async function(id) {
    try {
      const data = await apiCall(`/admin/recipes/${id}/approve`, { method: 'POST' });
      if (data.ok) {
        loadPendingRecipes();
        alert('Recipe approved!');
      }
    } catch (err) {
      alert('Error approving recipe: ' + err.message);
    }
  };

  window.rejectRecipe = async function(id) {
    const reason = prompt('Reason for rejection (optional):');
    try {
      const data = await apiCall(`/admin/recipes/${id}/reject`, {
        method: 'POST',
        body: JSON.stringify({ reason }),
      });
      if (data.ok) {
        loadPendingRecipes();
        alert('Recipe rejected.');
      }
    } catch (err) {
      alert('Error rejecting recipe: ' + err.message);
    }
  };

  window.viewFeedback = function(id) {
    alert('Feedback detail view coming soon! ID: ' + id);
  };

  window.saveSettings = function() {
    state.apiUrl = $('#settingsApiUrl').value;
    state.supabaseUrl = $('#settingsSupabaseUrl').value;
    state.adminSecret = $('#settingsAdminSecret').value;
    localStorage.setItem('honeydo_api_url', state.apiUrl);
    localStorage.setItem('honeydo_supabase_url', state.supabaseUrl);
    sessionStorage.setItem('honeydo_admin_secret', state.adminSecret);
    alert('Settings saved!');
  };

  // Helpers
  function escapeHtml(str) {
    const div = document.createElement('div');
    div.textContent = str;
    return div.innerHTML;
  }

  function formatDate(iso) {
    if (!iso) return '—';
    try {
      const d = new Date(iso);
      return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
    } catch {
      return '—';
    }
  }
})();
