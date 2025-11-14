-- =========================================================
-- Brainflect Core Data Model (Supabase)
-- Idempotent: safe to run multiple times
-- =========================================================
-- 0) Extensions / helper
create extension if not exists "uuid-ossp";

create extension if not exists "pgcrypto";

-- Timestamp helper for updated_at
create or replace function bf_set_timestamp () returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

-- =========================================================
-- 1) USERS + PROFILE / XP / VAULT
-- =========================================================
-- 1.1 bf_users ------------------------------------------------
create table if not exists public.bf_users (
  id uuid not null default extensions.uuid_generate_v4 (),
  base44_user_id text not null,
  email text not null,
  email_verified boolean null default false,
  -- public identity
  display_name text null,
  nickname text null,
  avatar_url text null,
  -- deeper profile
  full_name text null,
  bio_text text null,
  location text null,
  tagline text null,
  profile_image_url text null,
  accent_color text null,
  -- role & mentorship
  base44_role text null, -- e.g. 'admin', 'user', 'mod_lead'
  mentor_level smallint null, -- 0-6 (Listener-Legacy)
  -- lifecycle / status
  is_active boolean null default true,
  last_login_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint bf_users_pkey primary key (id)
);

-- Uniqueness / lookup indexes
create unique index if not exists idx_bf_users_base44_user_id on public.bf_users (base44_user_id);

create unique index if not exists idx_bf_users_email on public.bf_users (email);

-- Trigger for updated_at
drop trigger if exists bf_users_set_timestamp on public.bf_users;

create trigger bf_users_set_timestamp before
update on public.bf_users for each row
execute function bf_set_timestamp ();

-- 1.2 bf_vault_entries ---------------------------------------
create table if not exists public.bf_vault_entries (
  id uuid not null default extensions.uuid_generate_v4 (),
  user_id uuid not null,
  entry_type text not null default 'reflection'::text,
  title text null,
  content text not null,
  is_encrypted boolean null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint bf_vault_entries_pkey primary key (id),
  constraint bf_vault_entries_user_id_fkey foreign key (user_id) references bf_users (id) on delete cascade
);

drop trigger if exists bf_vault_entries_set_timestamp on public.bf_vault_entries;

create trigger bf_vault_entries_set_timestamp before
update on public.bf_vault_entries for each row
execute function bf_set_timestamp ();

-- 1.3 bf_xp_events -------------------------------------------
create table if not exists public.bf_xp_events (
  id uuid not null default extensions.uuid_generate_v4 (),
  user_id uuid not null,
  source text not null, -- 'checkin', 'referral', etc.
  amount integer not null default 0,
  related_entity_type text null, -- 'post', 'network', 'referral'
  related_entity_id text null,
  created_at timestamptz not null default now(),
  constraint bf_xp_events_pkey primary key (id),
  constraint bf_xp_events_user_id_fkey foreign key (user_id) references bf_users (id) on delete cascade
);

create index if not exists idx_bf_xp_events_user_id on public.bf_xp_events (user_id);

-- =========================================================
-- 2) SOCIAL GRAPH: POSTS / COMMENTS / REACTIONS / NETWORKS
-- =========================================================
-- 2.1 bf_networks --------------------------------------------
create table if not exists public.bf_networks (
  id uuid not null default extensions.uuid_generate_v4 (),
  owner_user_id uuid null,
  name text not null,
  slug text null,
  description text null,
  visibility text not null default 'public'::text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint bf_networks_pkey primary key (id),
  constraint bf_networks_slug_key unique (slug)
);

alter table public.bf_networks
add constraint bf_networks_owner_user_id_fkey foreign key (owner_user_id) references bf_users (id) on delete set null deferrable initially deferred;

drop trigger if exists bf_networks_set_timestamp on public.bf_networks;

create trigger bf_networks_set_timestamp before
update on public.bf_networks for each row
execute function bf_set_timestamp ();

-- 2.2 bf_network_members -------------------------------------
create table if not exists public.bf_network_members (
  id uuid not null default extensions.uuid_generate_v4 (),
  network_id uuid not null,
  user_id uuid not null,
  role text not null default 'member'::text, -- 'member','host','mod'
  joined_at timestamptz not null default now(),
  constraint bf_network_members_pkey primary key (id),
  constraint bf_network_members_network_id_user_id_key unique (network_id, user_id)
);

alter table public.bf_network_members
add constraint bf_network_members_network_id_fkey foreign key (network_id) references bf_networks (id) on delete cascade;

alter table public.bf_network_members
add constraint bf_network_members_user_id_fkey foreign key (user_id) references bf_users (id) on delete cascade;

-- 2.3 bf_posts ------------------------------------------------
create table if not exists public.bf_posts (
  id uuid not null default extensions.uuid_generate_v4 (),
  author_user_id uuid not null,
  post_type text not null default 'spark'::text, -- 'spark','update','path_note'
  network_id uuid null,
  content text not null,
  is_anonymous boolean null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint bf_posts_pkey primary key (id)
);

alter table public.bf_posts
add constraint bf_posts_author_user_id_fkey foreign key (author_user_id) references bf_users (id) on delete cascade;

alter table public.bf_posts
add constraint bf_posts_network_id_fkey foreign key (network_id) references bf_networks (id) on delete set null;

drop trigger if exists bf_posts_set_timestamp on public.bf_posts;

create trigger bf_posts_set_timestamp before
update on public.bf_posts for each row
execute function bf_set_timestamp ();

-- 2.4 bf_post_comments ---------------------------------------
create table if not exists public.bf_post_comments (
  id uuid not null default extensions.uuid_generate_v4 (),
  post_id uuid not null,
  author_user_id uuid not null,
  content text not null,
  created_at timestamptz not null default now(),
  constraint bf_post_comments_pkey primary key (id)
);

alter table public.bf_post_comments
add constraint bf_post_comments_post_id_fkey foreign key (post_id) references bf_posts (id) on delete cascade;

alter table public.bf_post_comments
add constraint bf_post_comments_author_user_id_fkey foreign key (author_user_id) references bf_users (id) on delete cascade;

-- 2.5 bf_post_reactions --------------------------------------
create table if not exists public.bf_post_reactions (
  id uuid not null default extensions.uuid_generate_v4 (),
  post_id uuid not null,
  user_id uuid not null,
  reaction_type text not null default 'upvote'::text, -- 'upvote','bookmark',etc.
  created_at timestamptz not null default now(),
  constraint bf_post_reactions_pkey primary key (id),
  constraint bf_post_reactions_post_id_user_id_reaction_type_key unique (post_id, user_id, reaction_type)
);

alter table public.bf_post_reactions
add constraint bf_post_reactions_post_id_fkey foreign key (post_id) references bf_posts (id) on delete cascade;

alter table public.bf_post_reactions
add constraint bf_post_reactions_user_id_fkey foreign key (user_id) references bf_users (id) on delete cascade;

-- =========================================================
-- 3) MESSAGING / THREADS / LIVE / CHECK-INS
-- (Structures kept generic; adjust later if needed)
-- =========================================================
-- 3.1 bf_message_threads -------------------------------------
create table if not exists public.bf_message_threads (
  id uuid not null default extensions.uuid_generate_v4 (),
  title text null,
  is_group boolean not null default false,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint bf_message_threads_pkey primary key (id),
  constraint bf_message_threads_created_by_fkey foreign key (created_by) references bf_users (id) on delete cascade
);

drop trigger if exists bf_message_threads_set_timestamp on public.bf_message_threads;

create trigger bf_message_threads_set_timestamp before
update on public.bf_message_threads for each row
execute function bf_set_timestamp ();

-- 3.2 bf_thread_participants ---------------------------------
create table if not exists public.bf_thread_participants (
  id uuid not null default extensions.uuid_generate_v4 (),
  thread_id uuid not null,
  user_id uuid not null,
  joined_at timestamptz not null default now(),
  constraint bf_thread_participants_pkey primary key (id),
  constraint bf_thread_participants_thread_id_user_id_key unique (thread_id, user_id)
);

alter table public.bf_thread_participants
add constraint bf_thread_participants_thread_id_fkey foreign key (thread_id) references bf_message_threads (id) on delete cascade;

alter table public.bf_thread_participants
add constraint bf_thread_participants_user_id_fkey foreign key (user_id) references bf_users (id) on delete cascade;

-- 3.3 bf_messages --------------------------------------------
create table if not exists public.bf_messages (
  id uuid not null default extensions.uuid_generate_v4 (),
  thread_id uuid not null,
  sender_id uuid not null,
  content text not null,
  created_at timestamptz not null default now(),
  is_deleted boolean not null default false,
  constraint bf_messages_pkey primary key (id)
);

alter table public.bf_messages
add constraint bf_messages_thread_id_fkey foreign key (thread_id) references bf_message_threads (id) on delete cascade;

alter table public.bf_messages
add constraint bf_messages_sender_id_fkey foreign key (sender_id) references bf_users (id) on delete cascade;

-- 3.4 bf_checkins --------------------------------------------
create table if not exists public.bf_checkins (
  id uuid not null default extensions.uuid_generate_v4 (),
  user_id uuid not null,
  mood text null,
  note text null,
  created_at timestamptz not null default now(),
  constraint bf_checkins_pkey primary key (id),
  constraint bf_checkins_user_id_fkey foreign key (user_id) references bf_users (id) on delete cascade
);

create index if not exists idx_bf_checkins_user_id_created_at on public.bf_checkins (user_id, created_at desc);

-- 3.5 bf_live_sessions ---------------------------------------
create table if not exists public.bf_live_sessions (
  id uuid not null default extensions.uuid_generate_v4 (),
  host_user_id uuid not null,
  title text not null,
  description text null,
  start_time timestamptz not null,
  end_time timestamptz null,
  visibility text not null default 'public'::text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint bf_live_sessions_pkey primary key (id),
  constraint bf_live_sessions_host_user_id_fkey foreign key (host_user_id) references bf_users (id) on delete cascade
);

drop trigger if exists bf_live_sessions_set_timestamp on public.bf_live_sessions;

create trigger bf_live_sessions_set_timestamp before
update on public.bf_live_sessions for each row
execute function bf_set_timestamp ();

-- 3.6 bf_live_attendance -------------------------------------
create table if not exists public.bf_live_attendance (
  id uuid not null default extensions.uuid_generate_v4 (),
  session_id uuid not null,
  user_id uuid not null,
  joined_at timestamptz not null default now(),
  left_at timestamptz null,
  constraint bf_live_attendance_pkey primary key (id),
  constraint bf_live_attendance_session_id_user_id_key unique (session_id, user_id)
);

alter table public.bf_live_attendance
add constraint bf_live_attendance_session_id_fkey foreign key (session_id) references bf_live_sessions (id) on delete cascade;

alter table public.bf_live_attendance
add constraint bf_live_attendance_user_id_fkey foreign key (user_id) references bf_users (id) on delete cascade;

-- =========================================================
-- 4) REFERRALS / SUBSCRIPTIONS / ROLES & USER ROLES
-- =========================================================
-- 4.1 bf_referrals -------------------------------------------
create table if not exists public.bf_referrals (
  id uuid not null default extensions.uuid_generate_v4 (),
  inviter_user_id uuid not null,
  invited_email text null,
  invite_code text not null,
  status text not null default 'pending'::text,
  accepted_user_id uuid null,
  created_at timestamptz not null default now(),
  accepted_at timestamptz null,
  constraint bf_referrals_pkey primary key (id),
  constraint bf_referrals_invite_code_key unique (invite_code)
);

alter table public.bf_referrals
add constraint bf_referrals_inviter_user_id_fkey foreign key (inviter_user_id) references bf_users (id) on delete set null;

alter table public.bf_referrals
add constraint bf_referrals_accepted_user_id_fkey foreign key (accepted_user_id) references bf_users (id) on delete set null;

-- 4.2 bf_roles ------------------------------------------------
create table if not exists public.bf_roles (
  id serial not null,
  code text not null,
  label text not null,
  description text null,
  constraint bf_roles_pkey primary key (id),
  constraint bf_roles_code_key unique (code)
);

-- 4.3 bf_user_roles ------------------------------------------
create table if not exists public.bf_user_roles (
  id uuid not null default extensions.uuid_generate_v4 (),
  user_id uuid not null,
  role_id integer not null,
  is_primary boolean null default false,
  created_at timestamptz not null default now(),
  constraint bf_user_roles_pkey primary key (id),
  constraint bf_user_roles_user_id_role_id_key unique (user_id, role_id)
);

alter table public.bf_user_roles
add constraint bf_user_roles_role_id_fkey foreign key (role_id) references bf_roles (id) on delete cascade;

alter table public.bf_user_roles
add constraint bf_user_roles_user_id_fkey foreign key (user_id) references bf_users (id) on delete cascade;

-- 4.4 bf_subscriptions ---------------------------------------
create table if not exists public.bf_subscriptions (
  id uuid not null default extensions.uuid_generate_v4 (),
  user_id uuid not null,
  plan_code text not null,
  status text not null default 'active'::text,
  started_at timestamptz not null default now(),
  ends_at timestamptz null,
  external_provider text null,
  external_subscription_id text null,
  constraint bf_subscriptions_pkey primary key (id)
);

alter table public.bf_subscriptions
add constraint bf_subscriptions_user_id_fkey foreign key (user_id) references bf_users (id) on delete cascade;

-- =========================================================
-- 5) SEED ROLES (admin / moderators / user)
-- =========================================================
insert into
  public.bf_roles (code, label, description)
values
  (
    'admin',
    'Admin',
    'Full Brainflect admin with access to all tools'
  ),
  (
    'mod_lead',
    'Lead Moderator',
    'Oversees moderators and escalated issues'
  ),
  (
    'mod_senior',
    'Senior Moderator',
    'Handles complex moderation and mentoring'
  ),
  (
    'mod_active',
    'Active Moderator',
    'Regular moderation duties'
  ),
  (
    'mod_trainee',
    'Trainee Moderator',
    'Learning moderation under supervision'
  ),
  (
    'moderator',
    'Moderator',
    'General moderation privileges'
  ),
  ('user', 'Member', 'Regular community member')
on conflict (code) do update
set
  label = excluded.label,
  description = excluded.description;

-- =========================================================
-- END
-- =========================================================
