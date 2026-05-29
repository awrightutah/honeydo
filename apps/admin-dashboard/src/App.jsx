import React, { useState } from 'react';
import { createRoot } from 'react-dom/client';
import { BarChart3, BookOpen, CalendarDays, ClipboardCheck, Home, Lightbulb, ShieldCheck, ShoppingCart, Users } from 'lucide-react';
import './styles.css';

const sections = [
  { key: 'overview', label: 'Overview', icon: Home },
  { key: 'household', label: 'Households', icon: Users },
  { key: 'chores', label: 'Chores', icon: ClipboardCheck },
  { key: 'meals', label: 'Meals & Shopping', icon: ShoppingCart },
  { key: 'calendar', label: 'Calendar Tags', icon: CalendarDays },
  { key: 'recipes', label: 'Recipe Moderation', icon: BookOpen },
  { key: 'analytics', label: 'Analytics', icon: BarChart3 },
  { key: 'feedback', label: 'Feature Requests', icon: Lightbulb },
  { key: 'security', label: 'Audit Trail', icon: ShieldCheck },
];

function App() {
  const [active, setActive] = useState('overview');
  const ActiveIcon = sections.find((section) => section.key === active)?.icon ?? Home;

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="logo"><span className="logo-mark">🐝</span> Clanquility</div>
        {sections.map((section) => {
          const Icon = section.icon;
          return (
            <button key={section.key} className={`nav-button ${active === section.key ? 'active' : ''}`} onClick={() => setActive(section.key)}>
              <Icon size={20} /> {section.label}
            </button>
          );
        })}
      </aside>
      <main className="main">
        <div className="header">
          <div>
            <h1><ActiveIcon size={30} /> {sections.find((section) => section.key === active)?.label}</h1>
            <p className="muted">Admin dashboard shell connected to Supabase in the next milestone.</p>
          </div>
          <span className="badge">Premium Admin</span>
        </div>
        <DashboardSection active={active} />
      </main>
    </div>
  );
}

function DashboardSection({ active }) {
  if (active === 'recipes') return <RecipeModeration />;
  if (active === 'analytics') return <Analytics />;
  if (active === 'household') return <Household />;
  if (active === 'feedback') return <Feedback />;
  return <Overview active={active} />;
}

function Overview() {
  return (
    <div className="grid">
      <Stat title="Chores Completed Today" value="24" note="Across active beta households" />
      <Stat title="Pending Verification" value="7" note="Needs admin review" />
      <Stat title="Recipe Imports" value="13" note="Schema.org importer ready" />
      <div className="card large">
        <h2>Build Priorities</h2>
        <div className="list">
          <Row title="Supabase schema and RLS" detail="Migration file created; apply after keys are available." />
          <Row title="Railway API" detail="Health, webhook, recipe import, and notification job skeletons created." />
          <Row title="Mobile app" detail="Flutter shell, onboarding, theme, and main tabs created." />
        </div>
      </div>
      <div className="card">
        <h2>Subscription Plan</h2>
        <p className="stat">$9.99</p>
        <p className="muted">Premium households, Authorize.net recurring billing.</p>
      </div>
    </div>
  );
}

function Household() {
  return (
    <div className="grid">
      <div className="card full">
        <h2>Household Management Shell</h2>
        <div className="list">
          <Row title="Multiple Admins" detail="Adult authenticated users can be owner/admin/member." />
          <Row title="Kid-Safe Sub-Profiles" detail="Display name, avatar, optional PIN; no child email collection." />
          <Row title="Invite Codes + QR" detail="Simple household joining flow planned." />
        </div>
      </div>
    </div>
  );
}

function RecipeModeration() {
  return (
    <div className="grid">
      <div className="card full">
        <h2>Pending Community Recipes</h2>
        <div className="list">
          <ModerationRow title="Mom's Famous Lasagna" meta="45 min · Medium · 6 servings" />
          <ModerationRow title="Quick Microwave Mug Cake" meta="5 min · Easy · 1 serving" />
          <ModerationRow title="One-Pan Honey Garlic Shrimp" meta="25 min · Easy · 4 servings" />
        </div>
      </div>
    </div>
  );
}

function Analytics() {
  return (
    <div className="grid">
      <Stat title="Daily Active Households" value="--" note="Will query analytics_events" />
      <Stat title="Premium Conversion" value="--" note="Free to premium funnel" />
      <Stat title="Churn Rate" value="--" note="Authorize.net subscription events" />
      <div className="card full">
        <h2>In-House Analytics</h2>
        <p className="muted">No third-party analytics overhead. App actions will write anonymous/product events to Supabase analytics_events.</p>
      </div>
    </div>
  );
}

function Feedback() {
  return (
    <div className="grid">
      <div className="card full">
        <h2>Request a Feature Queue</h2>
        <div className="list">
          <Row title="Feature request button" detail="Mobile app will submit ideas into feedback_requests." />
          <Row title="Admin review" detail="Dashboard will track new, reviewing, planned, completed, declined." />
        </div>
      </div>
    </div>
  );
}

function Stat({ title, value, note }) {
  return <div className="card"><h3>{title}</h3><p className="stat">{value}</p><p className="muted">{note}</p></div>;
}

function Row({ title, detail }) {
  return <div className="list-row"><div><strong>{title}</strong><div className="muted">{detail}</div></div></div>;
}

function ModerationRow({ title, meta }) {
  return <div className="list-row"><div><strong>{title}</strong><div className="muted">{meta}</div></div><div className="actions"><button className="btn secondary">Preview</button><button className="btn primary">Approve</button><button className="btn danger">Reject</button></div></div>;
}

createRoot(document.getElementById('root')).render(<App />);
