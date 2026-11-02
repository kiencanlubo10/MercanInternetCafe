-- Mercan Internet Cafe cloud foundation
-- Run this entire file in Supabase SQL Editor as the project owner.
create extension if not exists pgcrypto;

create table if not exists public.shops (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'Mercan Internet Cafe',
  singleton_key text not null default 'mercan-internet-cafe' unique,
  timezone text not null default 'Asia/Manila',
  currency text not null default 'PHP',
  created_at timestamptz not null default now()
);

create table if not exists public.shop_members (
  shop_id uuid not null references public.shops(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('admin','manager','staff')),
  created_at timestamptz not null default now(),
  primary key (shop_id,user_id)
);

-- The original app stores its working records as one JSON document. Revision
-- checking prevents silent last-write-wins overwrites between simultaneous users.
create table if not exists public.shop_state (
  shop_id uuid primary key references public.shops(id) on delete cascade,
  state jsonb not null default '{}'::jsonb,
  revision bigint not null default 0,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);

create index if not exists shop_members_user_id_idx on public.shop_members(user_id);

create or replace function public.is_shop_member(p_shop_id uuid)
returns boolean language sql stable security definer set search_path = public
as $$ select exists(select 1 from public.shop_members m where m.shop_id=p_shop_id and m.user_id=auth.uid()); $$;
revoke all on function public.is_shop_member(uuid) from public;
grant execute on function public.is_shop_member(uuid) to authenticated;

alter table public.shops enable row level security;
alter table public.shop_members enable row level security;
alter table public.shop_state enable row level security;

drop policy if exists shops_read_member on public.shops;
create policy shops_read_member on public.shops for select to authenticated using (public.is_shop_member(id));
drop policy if exists members_read_same_shop on public.shop_members;
create policy members_read_same_shop on public.shop_members for select to authenticated using (public.is_shop_member(shop_id));
drop policy if exists state_read_member on public.shop_state;
create policy state_read_member on public.shop_state for select to authenticated using (public.is_shop_member(shop_id));
-- Writes are intentionally available only through the revision-checked RPC below.
revoke insert, update, delete on public.shop_state from anon, authenticated;
revoke insert, update, delete on public.shops from anon, authenticated;
revoke insert, update, delete on public.shop_members from anon, authenticated;

grant select on public.shops, public.shop_members, public.shop_state to authenticated;

create or replace function public.bootstrap_mercanshop()
returns jsonb language plpgsql security definer set search_path = public, auth
as $$
declare v_shop uuid; v_role text;
begin
  if auth.uid() is null then raise exception 'You must sign in first'; end if;
  select shop_id, role into v_shop, v_role from public.shop_members where user_id=auth.uid() order by created_at limit 1;
  if v_shop is null then
    if exists(select 1 from public.shops) then
      raise exception 'Your account is not yet a member of Mercan Internet Cafe. Ask the shop admin to add your registered email under Settings → Team access.';
    end if;
    insert into public.shops(name,timezone,currency) values ('Mercan Internet Cafe','Asia/Manila','PHP') returning id into v_shop;
    insert into public.shop_members(shop_id,user_id,role) values (v_shop,auth.uid(),'admin');
    v_role := 'admin';
  end if;
  return jsonb_build_object('shop_id',v_shop,'role',v_role);
end; $$;
revoke all on function public.bootstrap_mercanshop() from public;
grant execute on function public.bootstrap_mercanshop() to authenticated;

create or replace function public.save_shop_state(p_state jsonb, p_expected_revision bigint)
returns bigint language plpgsql security definer set search_path = public, auth
as $$
declare v_shop uuid; v_role text; v_revision bigint;
begin
  if auth.uid() is null then raise exception 'You must sign in first'; end if;
  select shop_id,role into v_shop,v_role from public.shop_members where user_id=auth.uid() order by created_at limit 1;
  if v_shop is null then raise exception 'No shop membership found'; end if;
  if v_role not in ('admin','manager') then raise exception 'Your role is read-only'; end if;
  if p_state is null or jsonb_typeof(p_state) <> 'object' then raise exception 'Invalid shop data'; end if;
  insert into public.shop_state(shop_id,state,revision,updated_at,updated_by)
    values(v_shop,p_state,1,now(),auth.uid())
    on conflict (shop_id) do nothing;
  if found then return 1; end if;
  update public.shop_state set state=p_state, revision=revision+1, updated_at=now(), updated_by=auth.uid()
    where shop_id=v_shop and revision=p_expected_revision
    returning revision into v_revision;
  if v_revision is null then raise exception 'SYNC_CONFLICT: Another user changed the records. Reload the page before saving again.'; end if;
  return v_revision;
end; $$;
revoke all on function public.save_shop_state(jsonb,bigint) from public;
grant execute on function public.save_shop_state(jsonb,bigint) to authenticated;

-- Add an existing registered user to the shop. Only the shop admin can do this.
create or replace function public.grant_shop_member(p_email text, p_role text default 'staff')
returns void language plpgsql security definer set search_path = public, auth
as $$
declare v_shop uuid; v_role text; v_user uuid;
begin
  select shop_id,role into v_shop,v_role from public.shop_members where user_id=auth.uid() order by created_at limit 1;
  if v_shop is null or v_role <> 'admin' then raise exception 'Only a shop admin can add members'; end if;
  if p_role not in ('manager','staff') then raise exception 'Role must be manager or staff'; end if;
  select id into v_user from auth.users where lower(email)=lower(trim(p_email)) limit 1;
  if v_user is null then raise exception 'No registered account found for that email. Ask the user to sign up first.'; end if;
  insert into public.shop_members(shop_id,user_id,role) values(v_shop,v_user,p_role)
  on conflict(shop_id,user_id) do update set role=excluded.role;
end; $$;
revoke all on function public.grant_shop_member(text,text) from public;
grant execute on function public.grant_shop_member(text,text) to authenticated;

-- Enable Supabase Realtime for cross-device updates.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='shop_state'
  ) then
    alter publication supabase_realtime add table public.shop_state;
  end if;
end $$;
