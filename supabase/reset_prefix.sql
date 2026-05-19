-- HomeHub / Honeydo reset prefix
-- Use this only during initial setup before real production data exists.
-- It drops app-owned public schema objects created by the initial migration.

-- Drop app tables first. CASCADE removes dependent policies/triggers/indexes.
drop table if exists public.audit_logs cascade;
drop table if exists public.feedback_requests cascade;
drop table if exists public.analytics_events cascade;
drop table if exists public.device_tokens cascade;
drop table if exists public.notification_preferences cascade;
drop table if exists public.subscriptions cascade;
drop table if exists public.shopping_items cascade;
drop table if exists public.shopping_lists cascade;
drop table if exists public.stores cascade;
drop table if exists public.meal_plans cascade;
drop table if exists public.household_recipes cascade;
drop table if exists public.master_recipe_ratings cascade;
drop table if exists public.master_recipes cascade;
drop table if exists public.calendar_event_members cascade;
drop table if exists public.calendar_events cascade;
drop table if exists public.calendar_tags cascade;
drop table if exists public.achievements cascade;
drop table if exists public.point_transactions cascade;
drop table if exists public.reward_redemptions cascade;
drop table if exists public.rewards cascade;
drop table if exists public.chore_history cascade;
drop table if exists public.chore_verification_photos cascade;
drop table if exists public.chores cascade;
drop table if exists public.chore_templates cascade;
drop table if exists public.household_invites cascade;
drop table if exists public.household_members cascade;
drop table if exists public.households cascade;
drop table if exists public.profiles cascade;

-- Drop helper functions.
drop function if exists public.set_updated_at() cascade;
drop function if exists public.is_household_member(uuid) cascade;
drop function if exists public.is_household_admin(uuid) cascade;

-- Drop app enum types.
drop type if exists public.feedback_status cascade;
drop type if exists public.moderation_status cascade;
drop type if exists public.recipe_source cascade;
drop type if exists public.meal_type cascade;
drop type if exists public.point_transaction_type cascade;
drop type if exists public.chore_difficulty cascade;
drop type if exists public.chore_status cascade;
drop type if exists public.subscription_status cascade;
drop type if exists public.subscription_tier cascade;
drop type if exists public.member_kind cascade;
drop type if exists public.household_role cascade;
