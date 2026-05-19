-- HomeHub / Honeydo initial Supabase schema draft
-- Generated for project: https://knrdnshcbkvlopyzouee.supabase.co

create extension if not exists "uuid-ossp";
create extension if not exists pgcrypto;

-- Enums
create type household_role as enum ('owner', 'admin', 'member');
create type member_kind as enum ('adult_auth_user', 'sub_profile');
create type subscription_tier as enum ('free', 'premium');
create type subscription_status as enum ('active', 'trialing', 'past_due', 'grace_period', 'cancelled', 'expired');
create type chore_status as enum ('assigned', 'in_progress', 'pending_verification', 'verified', 'rejected', 'overdue', 'cancelled');
create type chore_difficulty as enum ('easy', 'medium', 'hard', 'custom');
create type point_transaction_type as enum ('earned', 'spent', 'adjusted', 'bonus', 'reversed');
create type meal_type as enum ('breakfast', 'lunch', 'dinner', 'snack', 'other');
create type recipe_source as enum ('manual', 'imported_url', 'master_library');
create type moderation_status as enum ('pending', 'approved', 'rejected');
create type feedback_status as enum ('new', 'reviewing', 'planned', 'completed', 'declined');

-- Auth-linked user profile for adult accounts only.
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  display_name text not null,
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.households (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  theme_color text default '#F5A623',
  owner_user_id uuid not null references public.profiles(id) on delete restrict,
  tier subscription_tier not null default 'free',
  subscription_status subscription_status not null default 'active',
  subscription_grace_ends_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.household_members (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  kind member_kind not null,
  role household_role not null default 'member',
  auth_user_id uuid references public.profiles(id) on delete set null,
  display_name text not null,
  avatar_url text,
  pin_hash text,
  points_balance integer not null default 0,
  is_active boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint household_members_auth_required_for_adult check (
    (kind = 'adult_auth_user' and auth_user_id is not null) or (kind = 'sub_profile')
  )
);

create table public.household_invites (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  code text not null unique,
  expires_at timestamptz not null,
  max_uses integer not null default 1,
  use_count integer not null default 0,
  revoked_at timestamptz,
  created_by uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);

-- Chores and templates
create table public.chore_templates (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text,
  room_or_category text,
  difficulty chore_difficulty not null default 'easy',
  suggested_points integer not null default 5,
  suggested_frequency text,
  icon text,
  is_system boolean not null default true,
  household_id uuid references public.households(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table public.chores (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  title text not null,
  description text,
  assigned_to_member_id uuid references public.household_members(id) on delete set null,
  created_by_member_id uuid references public.household_members(id) on delete set null,
  point_value integer not null default 5,
  bonus_points integer not null default 0,
  difficulty chore_difficulty not null default 'easy',
  due_at timestamptz,
  recurrence_rule text,
  status chore_status not null default 'assigned',
  requires_photo boolean not null default false,
  chore_of_day_date date,
  started_at timestamptz,
  completed_at timestamptz,
  verified_at timestamptz,
  verified_by_member_id uuid references public.household_members(id) on delete set null,
  rejected_reason text,
  auto_verify_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.chore_verification_photos (
  id uuid primary key default gen_random_uuid(),
  chore_id uuid not null references public.chores(id) on delete cascade,
  household_id uuid not null references public.households(id) on delete cascade,
  uploaded_by_member_id uuid references public.household_members(id) on delete set null,
  storage_path text not null,
  delete_after timestamptz,
  created_at timestamptz not null default now()
);

create table public.chore_history (
  id uuid primary key default gen_random_uuid(),
  chore_id uuid references public.chores(id) on delete set null,
  household_id uuid not null references public.households(id) on delete cascade,
  completed_by_member_id uuid references public.household_members(id) on delete set null,
  verified_by_member_id uuid references public.household_members(id) on delete set null,
  completed_at timestamptz,
  verified_at timestamptz,
  points_awarded integer not null default 0,
  created_at timestamptz not null default now()
);

-- Gamification
create table public.rewards (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  title text not null,
  description text,
  point_cost integer not null,
  icon text,
  is_active boolean not null default true,
  created_by_member_id uuid references public.household_members(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.reward_redemptions (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  reward_id uuid not null references public.rewards(id) on delete restrict,
  member_id uuid not null references public.household_members(id) on delete cascade,
  point_cost integer not null,
  status text not null default 'pending',
  redeemed_at timestamptz not null default now(),
  approved_by_member_id uuid references public.household_members(id) on delete set null,
  approved_at timestamptz
);

create table public.point_transactions (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  member_id uuid not null references public.household_members(id) on delete cascade,
  type point_transaction_type not null,
  amount integer not null,
  balance_after integer not null,
  source_table text,
  source_id uuid,
  note text,
  created_by_member_id uuid references public.household_members(id) on delete set null,
  created_at timestamptz not null default now()
);

create table public.achievements (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  member_id uuid not null references public.household_members(id) on delete cascade,
  badge_key text not null,
  badge_name text not null,
  description text,
  icon text,
  earned_at timestamptz not null default now(),
  unique(member_id, badge_key)
);

-- Calendar
create table public.calendar_tags (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  name text not null,
  icon text,
  color text not null default '#4A90D9',
  created_by_member_id uuid references public.household_members(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.calendar_events (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  title text not null,
  description text,
  starts_at timestamptz not null,
  ends_at timestamptz,
  all_day boolean not null default false,
  recurrence_rule text,
  tag_id uuid references public.calendar_tags(id) on delete set null,
  color_override text,
  created_by_member_id uuid references public.household_members(id) on delete set null,
  reminder_minutes_before integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.calendar_event_members (
  event_id uuid not null references public.calendar_events(id) on delete cascade,
  member_id uuid not null references public.household_members(id) on delete cascade,
  primary key(event_id, member_id)
);

-- Recipes and meals
create table public.master_recipes (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text,
  ingredients jsonb not null default '[]'::jsonb,
  steps jsonb not null default '[]'::jsonb,
  prep_time_minutes integer,
  cook_time_minutes integer,
  servings integer,
  difficulty text,
  cuisine text,
  tags jsonb not null default '[]'::jsonb,
  image_url text,
  submitted_by_user_id uuid references public.profiles(id) on delete set null,
  source_url text,
  status moderation_status not null default 'pending',
  rejection_reason text,
  approved_at timestamptz,
  approved_by_user_id uuid references public.profiles(id) on delete set null,
  average_rating numeric(3,2) not null default 0,
  rating_count integer not null default 0,
  added_count integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.master_recipe_ratings (
  id uuid primary key default gen_random_uuid(),
  master_recipe_id uuid not null references public.master_recipes(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  rating integer not null check (rating between 1 and 5),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(master_recipe_id, user_id)
);

create table public.household_recipes (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  master_recipe_id uuid references public.master_recipes(id) on delete set null,
  title text not null,
  description text,
  ingredients jsonb not null default '[]'::jsonb,
  steps jsonb not null default '[]'::jsonb,
  prep_time_minutes integer,
  cook_time_minutes integer,
  servings integer,
  difficulty text,
  cuisine text,
  tags jsonb not null default '[]'::jsonb,
  image_url text,
  source recipe_source not null default 'manual',
  source_url text,
  is_favorite boolean not null default false,
  created_by_member_id uuid references public.household_members(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.meal_plans (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  planned_for date not null,
  meal_type meal_type not null,
  recipe_id uuid references public.household_recipes(id) on delete set null,
  custom_title text,
  assigned_cook_member_id uuid references public.household_members(id) on delete set null,
  servings integer,
  notes text,
  created_by_member_id uuid references public.household_members(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Shopping
create table public.stores (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  name text not null,
  address text,
  is_default boolean not null default false,
  created_by_member_id uuid references public.household_members(id) on delete set null,
  created_at timestamptz not null default now()
);

create table public.shopping_lists (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  name text not null default 'Current Shopping List',
  is_active boolean not null default true,
  created_by_member_id uuid references public.household_members(id) on delete set null,
  created_at timestamptz not null default now(),
  archived_at timestamptz
);

create table public.shopping_items (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  shopping_list_id uuid not null references public.shopping_lists(id) on delete cascade,
  name text not null,
  quantity numeric,
  unit text,
  display_quantity text,
  store_id uuid references public.stores(id) on delete set null,
  category text,
  purchased boolean not null default false,
  purchased_by_member_id uuid references public.household_members(id) on delete set null,
  purchased_at timestamptz,
  source_recipe_id uuid references public.household_recipes(id) on delete set null,
  source_meal_plan_id uuid references public.meal_plans(id) on delete set null,
  added_by_member_id uuid references public.household_members(id) on delete set null,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Payments and subscriptions
create table public.subscriptions (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  provider text not null default 'authorize_net',
  provider_subscription_id text,
  tier subscription_tier not null default 'premium',
  status subscription_status not null default 'active',
  amount_cents integer not null default 999,
  currency text not null default 'USD',
  current_period_starts_at timestamptz,
  current_period_ends_at timestamptz,
  cancelled_at timestamptz,
  grace_ends_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Notifications/preferences
create table public.notification_preferences (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references public.household_members(id) on delete cascade unique,
  morning_digest boolean not null default true,
  evening_recap boolean not null default true,
  chore_reminders boolean not null default true,
  verification_alerts boolean not null default true,
  gamification_alerts boolean not null default true,
  calendar_reminders boolean not null default true,
  quiet_hours_start time default '21:00',
  quiet_hours_end time default '07:00',
  updated_at timestamptz not null default now()
);

create table public.device_tokens (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references public.household_members(id) on delete cascade,
  platform text not null,
  token text not null unique,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);

-- In-house analytics and feedback
create table public.analytics_events (
  id bigserial primary key,
  household_id uuid references public.households(id) on delete cascade,
  member_id uuid references public.household_members(id) on delete set null,
  auth_user_id uuid references public.profiles(id) on delete set null,
  event_type text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table public.feedback_requests (
  id uuid primary key default gen_random_uuid(),
  household_id uuid references public.households(id) on delete cascade,
  submitted_by_member_id uuid references public.household_members(id) on delete set null,
  type text not null default 'feature_request',
  title text not null,
  description text,
  status feedback_status not null default 'new',
  admin_notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Audit trail
create table public.audit_logs (
  id bigserial primary key,
  household_id uuid references public.households(id) on delete cascade,
  actor_member_id uuid references public.household_members(id) on delete set null,
  actor_user_id uuid references public.profiles(id) on delete set null,
  action text not null,
  entity_table text,
  entity_id uuid,
  before_data jsonb,
  after_data jsonb,
  created_at timestamptz not null default now()
);

-- Helpful indexes
create index idx_household_members_household on public.household_members(household_id);
create index idx_chores_household_due on public.chores(household_id, due_at);
create index idx_chores_assigned_status on public.chores(assigned_to_member_id, status);
create index idx_chore_history_household_completed on public.chore_history(household_id, completed_at desc);
create index idx_calendar_events_household_starts on public.calendar_events(household_id, starts_at);
create index idx_household_recipes_household on public.household_recipes(household_id);
create index idx_master_recipes_status_rating on public.master_recipes(status, average_rating desc);
create index idx_meal_plans_household_date on public.meal_plans(household_id, planned_for);
create index idx_shopping_items_list on public.shopping_items(shopping_list_id, purchased, sort_order);
create index idx_analytics_events_type_time on public.analytics_events(event_type, created_at desc);

-- Utility: update updated_at
create or replace function public.set_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

create trigger set_profiles_updated_at before update on public.profiles for each row execute function public.set_updated_at();
create trigger set_households_updated_at before update on public.households for each row execute function public.set_updated_at();
create trigger set_household_members_updated_at before update on public.household_members for each row execute function public.set_updated_at();
create trigger set_chores_updated_at before update on public.chores for each row execute function public.set_updated_at();
create trigger set_rewards_updated_at before update on public.rewards for each row execute function public.set_updated_at();
create trigger set_calendar_tags_updated_at before update on public.calendar_tags for each row execute function public.set_updated_at();
create trigger set_calendar_events_updated_at before update on public.calendar_events for each row execute function public.set_updated_at();
create trigger set_master_recipes_updated_at before update on public.master_recipes for each row execute function public.set_updated_at();
create trigger set_master_recipe_ratings_updated_at before update on public.master_recipe_ratings for each row execute function public.set_updated_at();
create trigger set_household_recipes_updated_at before update on public.household_recipes for each row execute function public.set_updated_at();
create trigger set_meal_plans_updated_at before update on public.meal_plans for each row execute function public.set_updated_at();
create trigger set_shopping_items_updated_at before update on public.shopping_items for each row execute function public.set_updated_at();
create trigger set_subscriptions_updated_at before update on public.subscriptions for each row execute function public.set_updated_at();
create trigger set_feedback_requests_updated_at before update on public.feedback_requests for each row execute function public.set_updated_at();

-- RLS helper functions
create or replace function public.is_household_member(target_household_id uuid)
returns boolean as $$
  select exists (
    select 1
    from public.household_members hm
    where hm.household_id = target_household_id
      and hm.auth_user_id = auth.uid()
      and hm.is_active = true
  );
$$ language sql stable security definer;

create or replace function public.is_household_admin(target_household_id uuid)
returns boolean as $$
  select exists (
    select 1
    from public.household_members hm
    where hm.household_id = target_household_id
      and hm.auth_user_id = auth.uid()
      and hm.is_active = true
      and hm.role in ('owner', 'admin')
  );
$$ language sql stable security definer;

-- Enable RLS
alter table public.profiles enable row level security;
alter table public.households enable row level security;
alter table public.household_members enable row level security;
alter table public.household_invites enable row level security;
alter table public.chore_templates enable row level security;
alter table public.chores enable row level security;
alter table public.chore_verification_photos enable row level security;
alter table public.chore_history enable row level security;
alter table public.rewards enable row level security;
alter table public.reward_redemptions enable row level security;
alter table public.point_transactions enable row level security;
alter table public.achievements enable row level security;
alter table public.calendar_tags enable row level security;
alter table public.calendar_events enable row level security;
alter table public.calendar_event_members enable row level security;
alter table public.master_recipes enable row level security;
alter table public.master_recipe_ratings enable row level security;
alter table public.household_recipes enable row level security;
alter table public.meal_plans enable row level security;
alter table public.stores enable row level security;
alter table public.shopping_lists enable row level security;
alter table public.shopping_items enable row level security;
alter table public.subscriptions enable row level security;
alter table public.notification_preferences enable row level security;
alter table public.device_tokens enable row level security;
alter table public.analytics_events enable row level security;
alter table public.feedback_requests enable row level security;
alter table public.audit_logs enable row level security;

-- Initial RLS policies. These are broad household-scoped policies for scaffold; tighten by action in later migrations.
create policy profiles_self_select on public.profiles for select using (id = auth.uid());
create policy profiles_self_update on public.profiles for update using (id = auth.uid());

create policy households_member_select on public.households for select using (public.is_household_member(id));
create policy households_admin_update on public.households for update using (public.is_household_admin(id));

create policy household_members_select on public.household_members for select using (public.is_household_member(household_id));
create policy household_members_admin_all on public.household_members for all using (public.is_household_admin(household_id));

create policy household_scoped_invites on public.household_invites for all using (public.is_household_admin(household_id));
create policy household_scoped_chore_templates on public.chore_templates for all using (household_id is null or public.is_household_member(household_id));
create policy household_scoped_chores on public.chores for all using (public.is_household_member(household_id));
create policy household_scoped_chore_photos on public.chore_verification_photos for all using (public.is_household_member(household_id));
create policy household_scoped_chore_history on public.chore_history for all using (public.is_household_member(household_id));
create policy household_scoped_rewards on public.rewards for all using (public.is_household_member(household_id));
create policy household_scoped_redemptions on public.reward_redemptions for all using (public.is_household_member(household_id));
create policy household_scoped_points on public.point_transactions for select using (public.is_household_member(household_id));
create policy household_scoped_achievements on public.achievements for all using (public.is_household_member(household_id));
create policy household_scoped_calendar_tags on public.calendar_tags for all using (public.is_household_member(household_id));
create policy household_scoped_calendar_events on public.calendar_events for all using (public.is_household_member(household_id));
create policy household_scoped_recipes on public.household_recipes for all using (public.is_household_member(household_id));
create policy household_scoped_meal_plans on public.meal_plans for all using (public.is_household_member(household_id));
create policy household_scoped_stores on public.stores for all using (public.is_household_member(household_id));
create policy household_scoped_shopping_lists on public.shopping_lists for all using (public.is_household_member(household_id));
create policy household_scoped_shopping_items on public.shopping_items for all using (public.is_household_member(household_id));
create policy household_scoped_subscriptions on public.subscriptions for select using (public.is_household_admin(household_id));
create policy household_scoped_analytics on public.analytics_events for all using (household_id is null or public.is_household_member(household_id));
create policy household_scoped_feedback on public.feedback_requests for all using (household_id is null or public.is_household_member(household_id));
create policy household_scoped_audit on public.audit_logs for select using (household_id is null or public.is_household_admin(household_id));

-- Master recipe policies: approved recipes are readable by authenticated users; submissions/ratings by authenticated users.
create policy master_recipes_approved_read on public.master_recipes for select using (status = 'approved' or submitted_by_user_id = auth.uid());
create policy master_recipes_submit on public.master_recipes for insert with check (auth.uid() is not null);
create policy master_recipe_ratings_user_all on public.master_recipe_ratings for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Device tokens and notification preferences are member scoped but require app/backend mediation for sub-profiles.
create policy notification_preferences_member_read on public.notification_preferences for select using (
  exists(select 1 from public.household_members hm where hm.id = member_id and public.is_household_member(hm.household_id))
);
create policy device_tokens_member_all on public.device_tokens for all using (
  exists(select 1 from public.household_members hm where hm.id = member_id and public.is_household_member(hm.household_id))
);

-- Storage buckets to create in Supabase dashboard or via storage API:
-- avatars: public read, authenticated upload scoped by household/member path
-- recipe-images: public read, authenticated upload scoped by household/master path
-- chore-verification-photos: private, household admin/member read/write scoped by chore path, auto-delete after configured retention
