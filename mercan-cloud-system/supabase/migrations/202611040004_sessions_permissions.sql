-- Priority 4: user sessions, login history, per-user permissions.
-- Idempotent and non-destructive. Requires the Priority 1 migration (shops, shop_members, shop_state).
-- It does NOT replace save_shop_state or is_shop_member (their live bodies may differ from the repo).
-- Section permissions are enforced by a trigger on shop_state, so every write path is covered.
--
-- Permissions (what a person may change in the shared records):
--   sales     -> state.sales
--   expenses  -> state.expenses, state.categories
--   employees -> state.employees, state.payments
--   settings  -> state.settings
-- Defaults: admin = all (cannot be restricted), manager = all, staff = none (read-only).
-- A per-user override can grant staff a section or take one away from a manager.
-- NOTE: the existing save_shop_state() still refuses staff. A staff grant only becomes
-- usable once the app calls save_shop_state_p4() (added below) instead.

-- ---------------------------------------------------------------------------
-- 1. Tables (append-only logs, no direct writes, admin or owner read)
-- ---------------------------------------------------------------------------
create table if not exists public.member_permissions (
  shop_id uuid not null references public.shops(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  permission text not null check (permission in ('sales','expenses','employees','settings')),
  allowed boolean not null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id),
  primary key (shop_id, user_id, permission)
);

create table if not exists public.user_sessions (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  session_key text not null check (length(session_key) between 8 and 80),
  device text,
  started_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  ended_at timestamptz,
  end_reason text check (end_reason in ('logout','revoked','deactivated','expired')),
  unique (user_id, session_key)
);
create index if not exists user_sessions_shop_seen_idx on public.user_sessions (shop_id, last_seen_at desc);

create table if not exists public.login_events (
  id bigint generated always as identity primary key,
  shop_id uuid not null references public.shops(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  event text not null check (event in ('login','logout','revoked')),
  device text,
  created_at timestamptz not null default now()
);
create index if not exists login_events_shop_time_idx on public.login_events (shop_id, created_at desc);

create table if not exists public.security_audit (
  id bigint generated always as identity primary key,
  shop_id uuid not null references public.shops(id) on delete cascade,
  actor_id uuid references auth.users(id),
  target_id uuid references auth.users(id),
  action text not null,
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create or replace function public.p4_prevent_mutation()
returns trigger language plpgsql as $$
begin raise exception 'This record is append-only and cannot be changed or deleted'; end $$;

drop trigger if exists login_events_append_only on public.login_events;
create trigger login_events_append_only before update or delete on public.login_events
  for each row execute function public.p4_prevent_mutation();
drop trigger if exists security_audit_append_only on public.security_audit;
create trigger security_audit_append_only before update or delete on public.security_audit
  for each row execute function public.p4_prevent_mutation();

-- ---------------------------------------------------------------------------
-- 2. Internal helpers (not callable by signed-in users)
-- ---------------------------------------------------------------------------
create or replace function public.p4_ctx(out v_shop uuid, out v_role text)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if auth.uid() is null then raise exception 'You must sign in first'; end if;
  select shop_id, role into v_shop, v_role from public.shop_members
   where user_id = auth.uid() order by created_at limit 1;
  if v_shop is null then raise exception 'No shop membership found'; end if;
end $$;

create or replace function public.p4_require_admin()
returns uuid language plpgsql stable security definer set search_path = public, auth as $$
declare v_shop uuid; v_role text;
begin
  select c.v_shop, c.v_role into v_shop, v_role from public.p4_ctx() c;
  if v_role <> 'admin' then raise exception 'Only a shop admin can do this'; end if;
  return v_shop;
end $$;

create or replace function public.p4_is_admin(p_shop uuid)
returns boolean language sql stable security definer set search_path = public, auth as $$
  select exists(select 1 from public.shop_members m
                 where m.shop_id = p_shop and m.user_id = auth.uid() and m.role = 'admin');
$$;

create or replace function public.p4_effective_permission(p_shop uuid, p_user uuid, p_perm text)
returns boolean language plpgsql stable security definer set search_path = public, auth as $$
declare v_role text; v_ov boolean;
begin
  select role into v_role from public.shop_members where shop_id = p_shop and user_id = p_user;
  if v_role is null then return false; end if;
  if v_role = 'admin' then return true; end if;
  select allowed into v_ov from public.member_permissions
   where shop_id = p_shop and user_id = p_user and permission = p_perm;
  if v_ov is not null then return v_ov; end if;
  return v_role = 'manager';
end $$;

create or replace function public.p4_log(p_shop uuid, p_target uuid, p_action text, p_detail jsonb default '{}'::jsonb)
returns void language sql security definer set search_path = public, auth as $$
  insert into public.security_audit(shop_id, actor_id, target_id, action, detail)
  values (p_shop, auth.uid(), p_target, p_action, coalesce(p_detail, '{}'::jsonb));
$$;

revoke all on function public.p4_ctx() from public, anon, authenticated;
revoke all on function public.p4_require_admin() from public, anon, authenticated;
revoke all on function public.p4_effective_permission(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.p4_log(uuid, uuid, text, jsonb) from public, anon, authenticated;
revoke all on function public.p4_prevent_mutation() from public, anon, authenticated;
-- p4_is_admin is used inside RLS policies, so signed-in users need execute on it.
revoke all on function public.p4_is_admin(uuid) from public, anon;
grant execute on function public.p4_is_admin(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Row level security: read only, owner or admin
-- ---------------------------------------------------------------------------
alter table public.member_permissions enable row level security;
alter table public.user_sessions enable row level security;
alter table public.login_events enable row level security;
alter table public.security_audit enable row level security;

revoke all on public.member_permissions, public.user_sessions, public.login_events, public.security_audit from anon;
revoke insert, update, delete, truncate on public.member_permissions, public.user_sessions,
  public.login_events, public.security_audit from authenticated;
grant select on public.member_permissions, public.user_sessions, public.login_events, public.security_audit to authenticated;

drop policy if exists member_permissions_read on public.member_permissions;
create policy member_permissions_read on public.member_permissions for select to authenticated
  using (user_id = auth.uid() or public.p4_is_admin(shop_id));
drop policy if exists user_sessions_read on public.user_sessions;
create policy user_sessions_read on public.user_sessions for select to authenticated
  using (user_id = auth.uid() or public.p4_is_admin(shop_id));
drop policy if exists login_events_read on public.login_events;
create policy login_events_read on public.login_events for select to authenticated
  using (user_id = auth.uid() or public.p4_is_admin(shop_id));
drop policy if exists security_audit_admin_read on public.security_audit;
create policy security_audit_admin_read on public.security_audit for select to authenticated
  using (public.p4_is_admin(shop_id));

-- ---------------------------------------------------------------------------
-- 4. Enforcement: section permissions on every shop_state update
-- ---------------------------------------------------------------------------
create or replace function public.p4_section_for_key(p_key text)
returns text language sql immutable as $$
  select case p_key
    when 'sales' then 'sales'
    when 'expenses' then 'expenses'
    when 'categories' then 'expenses'
    when 'employees' then 'employees'
    when 'payments' then 'employees'
    when 'settings' then 'settings'
    else null end;
$$;

create or replace function public.p4_shop_state_guard()
returns trigger language plpgsql security definer set search_path = public, auth as $$
declare k text; v_sec text;
begin
  -- Service/SQL-editor writes carry no signed-in user and are not restricted here.
  if auth.uid() is null then return new; end if;
  for k in
    select key from (select jsonb_object_keys(coalesce(old.state, '{}'::jsonb)) as key
                     union select jsonb_object_keys(coalesce(new.state, '{}'::jsonb))) s
  loop
    if (old.state -> k) is distinct from (new.state -> k) then
      v_sec := public.p4_section_for_key(k);
      if v_sec is null then
        if not exists (select 1 from public.shop_members m
                        where m.shop_id = new.shop_id and m.user_id = auth.uid() and m.role = 'admin') then
          raise exception 'PERMISSION_DENIED: only an admin can change "%"', k;
        end if;
      elsif not public.p4_effective_permission(new.shop_id, auth.uid(), v_sec) then
        raise exception 'PERMISSION_DENIED: you do not have permission to change %', v_sec;
      end if;
    end if;
  end loop;
  return new;
end $$;
revoke all on function public.p4_shop_state_guard() from public, anon, authenticated;
revoke all on function public.p4_section_for_key(text) from public, anon, authenticated;

drop trigger if exists shop_state_p4_guard on public.shop_state;
create trigger shop_state_p4_guard before update on public.shop_state
  for each row execute function public.p4_shop_state_guard();

-- Same revision-checked save as save_shop_state, but allows any member whose
-- permissions cover the changed sections (the trigger above does the checking).
create or replace function public.save_shop_state_p4(p_state jsonb, p_expected_revision bigint)
returns bigint language plpgsql security definer set search_path = public, auth as $$
declare v_shop uuid; v_role text; v_revision bigint;
begin
  select c.v_shop, c.v_role into v_shop, v_role from public.p4_ctx() c;
  if p_state is null or jsonb_typeof(p_state) <> 'object' then raise exception 'Invalid shop data'; end if;
  update public.shop_state set state = p_state, revision = revision + 1, updated_at = now(), updated_by = auth.uid()
   where shop_id = v_shop and revision = p_expected_revision
   returning revision into v_revision;
  if v_revision is null then
    if not exists (select 1 from public.shop_state where shop_id = v_shop) then
      if v_role not in ('admin','manager') then raise exception 'Your role is read-only'; end if;
      insert into public.shop_state(shop_id, state, revision, updated_at, updated_by)
        values (v_shop, p_state, 1, now(), auth.uid());
      return 1;
    end if;
    raise exception 'SYNC_CONFLICT: Another user changed the records. Reload the page before saving again.';
  end if;
  return v_revision;
end $$;
revoke all on function public.save_shop_state_p4(jsonb, bigint) from public, anon;
grant execute on function public.save_shop_state_p4(jsonb, bigint) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Sessions and login history (called by the signed-in user's browser)
-- ---------------------------------------------------------------------------
create or replace function public.start_session(p_session_key text, p_device text default null)
returns uuid language plpgsql security definer set search_path = public, auth as $$
declare v_shop uuid; v_role text; v_id uuid; v_ended timestamptz; v_reason text; v_dev text;
begin
  select c.v_shop, c.v_role into v_shop, v_role from public.p4_ctx() c;
  if p_session_key is null or length(p_session_key) not between 8 and 80 then raise exception 'Invalid session key'; end if;
  v_dev := left(coalesce(p_device, ''), 200);
  select id, ended_at, end_reason into v_id, v_ended, v_reason from public.user_sessions
   where user_id = auth.uid() and session_key = p_session_key;
  if v_id is null then
    insert into public.user_sessions(shop_id, user_id, session_key, device)
      values (v_shop, auth.uid(), p_session_key, v_dev) returning id into v_id;
    insert into public.login_events(shop_id, user_id, event, device) values (v_shop, auth.uid(), 'login', v_dev);
  elsif v_ended is not null then
    raise exception 'SESSION_REVOKED: this session was ended (%). Sign in again.', coalesce(v_reason, 'ended');
  else
    update public.user_sessions set last_seen_at = now() where id = v_id;
  end if;
  return v_id;
end $$;

create or replace function public.touch_session(p_session_key text)
returns void language plpgsql security definer set search_path = public, auth as $$
declare v_ended timestamptz; v_reason text; v_found boolean;
begin
  perform 1 from public.p4_ctx();
  select true, ended_at, end_reason into v_found, v_ended, v_reason from public.user_sessions
   where user_id = auth.uid() and session_key = p_session_key;
  if v_found is null then raise exception 'SESSION_UNKNOWN: start the session first'; end if;
  if v_ended is not null then raise exception 'SESSION_REVOKED: this session was ended (%). Sign in again.', coalesce(v_reason, 'ended'); end if;
  update public.user_sessions set last_seen_at = now() where user_id = auth.uid() and session_key = p_session_key;
end $$;

create or replace function public.end_session(p_session_key text)
returns void language plpgsql security definer set search_path = public, auth as $$
declare v_shop uuid; v_role text; v_id uuid;
begin
  select c.v_shop, c.v_role into v_shop, v_role from public.p4_ctx() c;
  update public.user_sessions set ended_at = now(), end_reason = 'logout'
   where user_id = auth.uid() and session_key = p_session_key and ended_at is null
   returning id into v_id;
  if v_id is not null then
    insert into public.login_events(shop_id, user_id, event) values (v_shop, auth.uid(), 'logout');
  end if;
end $$;

create or replace function public.my_permissions()
returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare v_shop uuid; v_role text;
begin
  select c.v_shop, c.v_role into v_shop, v_role from public.p4_ctx() c;
  return jsonb_build_object('role', v_role,
    'sales', public.p4_effective_permission(v_shop, auth.uid(), 'sales'),
    'expenses', public.p4_effective_permission(v_shop, auth.uid(), 'expenses'),
    'employees', public.p4_effective_permission(v_shop, auth.uid(), 'employees'),
    'settings', public.p4_effective_permission(v_shop, auth.uid(), 'settings'));
end $$;

-- ---------------------------------------------------------------------------
-- 6. Admin controls
-- ---------------------------------------------------------------------------
create or replace function public.list_team()
returns table (user_id uuid, email text, role text, active boolean, last_seen_at timestamptz,
               online boolean, permissions jsonb)
language plpgsql stable security definer set search_path = public, auth as $$
declare v_shop uuid;
begin
  v_shop := public.p4_require_admin();
  return query
  select m.user_id, u.email::text, m.role,
         (u.banned_until is null or u.banned_until < now()),
         (select max(s.last_seen_at) from public.user_sessions s where s.user_id = m.user_id and s.shop_id = v_shop),
         exists(select 1 from public.user_sessions s where s.user_id = m.user_id and s.shop_id = v_shop
                  and s.ended_at is null and s.last_seen_at > now() - interval '5 minutes'),
         jsonb_build_object(
           'sales', public.p4_effective_permission(v_shop, m.user_id, 'sales'),
           'expenses', public.p4_effective_permission(v_shop, m.user_id, 'expenses'),
           'employees', public.p4_effective_permission(v_shop, m.user_id, 'employees'),
           'settings', public.p4_effective_permission(v_shop, m.user_id, 'settings'))
    from public.shop_members m join auth.users u on u.id = m.user_id
   where m.shop_id = v_shop
   order by m.created_at;
end $$;

-- p_allowed: true = grant, false = deny, null = remove the override (back to the role default)
create or replace function public.set_member_permission(p_user uuid, p_permission text, p_allowed boolean)
returns void language plpgsql security definer set search_path = public, auth as $$
declare v_shop uuid; v_role text;
begin
  v_shop := public.p4_require_admin();
  if p_permission not in ('sales','expenses','employees','settings') then raise exception 'Unknown permission'; end if;
  select role into v_role from public.shop_members where shop_id = v_shop and user_id = p_user;
  if v_role is null then raise exception 'That user is not a member of this shop'; end if;
  if v_role = 'admin' then raise exception 'Admin permissions cannot be restricted'; end if;
  if p_allowed is null then
    delete from public.member_permissions where shop_id = v_shop and user_id = p_user and permission = p_permission;
  else
    insert into public.member_permissions(shop_id, user_id, permission, allowed, updated_at, updated_by)
      values (v_shop, p_user, p_permission, p_allowed, now(), auth.uid())
    on conflict (shop_id, user_id, permission)
      do update set allowed = excluded.allowed, updated_at = now(), updated_by = auth.uid();
  end if;
  perform public.p4_log(v_shop, p_user, 'permission', jsonb_build_object('permission', p_permission, 'allowed', p_allowed));
end $$;

create or replace function public.list_login_history(p_user uuid default null, p_limit integer default 100)
returns table (id bigint, user_id uuid, email text, event text, device text, created_at timestamptz)
language plpgsql stable security definer set search_path = public, auth as $$
declare v_shop uuid;
begin
  v_shop := public.p4_require_admin();
  return query
  select e.id, e.user_id, u.email::text, e.event, e.device, e.created_at
    from public.login_events e left join auth.users u on u.id = e.user_id
   where e.shop_id = v_shop and (p_user is null or e.user_id = p_user)
   order by e.created_at desc, e.id desc
   limit greatest(1, least(coalesce(p_limit, 100), 500));
end $$;

create or replace function public.list_sessions(p_open_only boolean default true)
returns table (id uuid, user_id uuid, email text, device text, started_at timestamptz,
               last_seen_at timestamptz, ended_at timestamptz, end_reason text, online boolean)
language plpgsql stable security definer set search_path = public, auth as $$
declare v_shop uuid;
begin
  v_shop := public.p4_require_admin();
  return query
  select s.id, s.user_id, u.email::text, s.device, s.started_at, s.last_seen_at, s.ended_at, s.end_reason,
         (s.ended_at is null and s.last_seen_at > now() - interval '5 minutes')
    from public.user_sessions s left join auth.users u on u.id = s.user_id
   where s.shop_id = v_shop and (not coalesce(p_open_only, true) or s.ended_at is null)
   order by s.last_seen_at desc
   limit 200;
end $$;

-- Ends every open session of a user. The app notices on its next heartbeat (touch_session)
-- and signs out. The server-side token removal below is best effort and reported back.
create or replace function public.revoke_member_sessions(p_user uuid)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare v_shop uuid; v_n integer; v_hard boolean := true;
begin
  v_shop := public.p4_require_admin();
  if p_user = auth.uid() then raise exception 'Use Sign out for your own account'; end if;
  if not exists (select 1 from public.shop_members where shop_id = v_shop and user_id = p_user) then
    raise exception 'That user is not a member of this shop';
  end if;
  update public.user_sessions set ended_at = now(), end_reason = 'revoked'
   where shop_id = v_shop and user_id = p_user and ended_at is null;
  get diagnostics v_n = row_count;
  if v_n > 0 then
    insert into public.login_events(shop_id, user_id, event) values (v_shop, p_user, 'revoked');
  end if;
  begin
    delete from auth.sessions where user_id = p_user;
  exception when others then v_hard := false;
  end;
  perform public.p4_log(v_shop, p_user, 'revoke_sessions', jsonb_build_object('sessions', v_n, 'tokens_removed', v_hard));
  return jsonb_build_object('sessions_ended', v_n, 'tokens_removed', v_hard);
end $$;

-- Deactivate = block sign-in and token refresh (auth ban) and end open sessions. Reversible.
create or replace function public.set_member_active(p_user uuid, p_active boolean)
returns void language plpgsql security definer set search_path = public, auth as $$
declare v_shop uuid; v_role text;
begin
  v_shop := public.p4_require_admin();
  if p_user = auth.uid() then raise exception 'You cannot deactivate your own account'; end if;
  select role into v_role from public.shop_members where shop_id = v_shop and user_id = p_user;
  if v_role is null then raise exception 'That user is not a member of this shop'; end if;
  if v_role = 'admin' and not coalesce(p_active, true) then raise exception 'Admin accounts cannot be deactivated here'; end if;
  if coalesce(p_active, true) then
    update auth.users set banned_until = null where id = p_user;
  else
    update auth.users set banned_until = now() + interval '100 years' where id = p_user;
    update public.user_sessions set ended_at = now(), end_reason = 'deactivated'
     where shop_id = v_shop and user_id = p_user and ended_at is null;
    begin delete from auth.sessions where user_id = p_user; exception when others then null; end;
  end if;
  perform public.p4_log(v_shop, p_user, case when coalesce(p_active, true) then 'activate' else 'deactivate' end);
end $$;

-- ---------------------------------------------------------------------------
-- 7. Who may call what
-- ---------------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'start_session(text,text)','touch_session(text)','end_session(text)','my_permissions()',
    'list_team()','set_member_permission(uuid,text,boolean)','list_login_history(uuid,integer)',
    'list_sessions(boolean)','revoke_member_sessions(uuid)','set_member_active(uuid,boolean)']
  loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
