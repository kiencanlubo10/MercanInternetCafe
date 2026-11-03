-- Priority 4 test (sessions, login history, per-user permissions).
-- Run AFTER 202611040004_sessions_permissions.sql. Paste the WHOLE file into the Supabase SQL Editor.
-- It creates three fake accounts (manager, staff, outsider) inside a transaction, runs the checks,
-- then ends with an INTENTIONAL error so everything is rolled back. Real data is not changed.
-- Expected last line:  ALL <n> CHECKS PASSED (all test data rolled back)
-- Anything else lists the failed checks: send it back unchanged.

create temp table if not exists t4_res(n serial, name text, ok boolean, detail text);
truncate t4_res;

create or replace function pg_temp.t4_ok(p_name text, p_ok boolean, p_detail text default null)
returns void language plpgsql as $f$
begin insert into t4_res(name, ok, detail) values (p_name, coalesce(p_ok, false), p_detail); end $f$;

-- returns the error message of running p_sql, or null if it ran without error
create or replace function pg_temp.t4_err(p_sql text)
returns text language plpgsql as $f$
declare v_msg text;
begin
  begin execute p_sql; v_msg := null;
  exception when others then v_msg := sqlerrm; end;
  return v_msg;
end $f$;

create or replace function pg_temp.t4_expect(p_name text, p_sql text, p_pat text)
returns void language plpgsql as $f$
declare v_msg text := pg_temp.t4_err(p_sql);
begin
  if v_msg is null then insert into t4_res(name, ok, detail) values (p_name, false, 'no error was raised');
  else insert into t4_res(name, ok, detail) values (p_name, v_msg ilike p_pat, v_msg); end if;
end $f$;

create or replace function pg_temp.t4_pass(p_name text, p_sql text)
returns void language plpgsql as $f$
declare v_msg text := pg_temp.t4_err(p_sql);
begin insert into t4_res(name, ok, detail) values (p_name, v_msg is null, v_msg); end $f$;

create or replace function pg_temp.t4_as(p_uid uuid)
returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
end $f$;

do $do$
declare
  v_shop uuid; v_admin uuid;
  v_m uuid := '44444444-4444-4444-4444-444444444441';  -- fake manager
  v_s uuid := '44444444-4444-4444-4444-444444444442';  -- fake staff
  v_x uuid := '44444444-4444-4444-4444-444444444443';  -- fake outsider (not a member)
  v_sales text; v_exp text; v_set text; v_zzz text;
  v_p jsonb; v_n integer; v_n2 integer; v_err text; v_b boolean; v_t timestamptz;
  v_state jsonb; v_rev bigint; v_new bigint; v_r jsonb; v_id1 uuid; v_id2 uuid;
  v_fail integer; v_total integer; v_list text;
begin
  select shop_id, user_id into v_shop, v_admin from public.shop_members where role = 'admin' limit 1;
  if v_admin is null then raise exception 'SETUP: no admin found in shop_members'; end if;
  insert into public.shop_state(shop_id, state, revision) values (v_shop, '{}'::jsonb, 0) on conflict (shop_id) do nothing;

  insert into auth.users(id, instance_id, aud, role, email, created_at, updated_at) values
    (v_m, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't4-manager@test.invalid', now(), now()),
    (v_s, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't4-staff@test.invalid', now(), now()),
    (v_x, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't4-outsider@test.invalid', now(), now());
  insert into public.shop_members(shop_id, user_id, role) values (v_shop, v_m, 'manager'), (v_shop, v_s, 'staff');

  v_sales := format($q$update public.shop_state set state = jsonb_set(state,'{sales}',coalesce(state->'sales','[]'::jsonb)||'[{"id":"t4s"}]'::jsonb) where shop_id = %L$q$, v_shop);
  v_exp   := format($q$update public.shop_state set state = jsonb_set(state,'{expenses}',coalesce(state->'expenses','[]'::jsonb)||'[{"id":"t4e"}]'::jsonb) where shop_id = %L$q$, v_shop);
  v_set   := format($q$update public.shop_state set state = jsonb_set(state,'{settings}',coalesce(state->'settings','{}'::jsonb)||'{"t4":1}'::jsonb) where shop_id = %L$q$, v_shop);
  v_zzz   := format($q$update public.shop_state set state = jsonb_set(state,'{zzz_unknown}','1'::jsonb) where shop_id = %L$q$, v_shop);

  -- ---- default permissions ----
  perform pg_temp.t4_as(v_admin);
  v_p := public.my_permissions();
  perform pg_temp.t4_ok('admin: all four permissions true', (v_p->>'role') = 'admin' and (v_p->>'sales')::boolean and (v_p->>'expenses')::boolean and (v_p->>'employees')::boolean and (v_p->>'settings')::boolean, v_p::text);
  perform pg_temp.t4_as(v_m);
  v_p := public.my_permissions();
  perform pg_temp.t4_ok('manager default: all four true', (v_p->>'sales')::boolean and (v_p->>'expenses')::boolean and (v_p->>'employees')::boolean and (v_p->>'settings')::boolean, v_p::text);
  perform pg_temp.t4_as(v_s);
  v_p := public.my_permissions();
  perform pg_temp.t4_ok('staff default: all four false', not (v_p->>'sales')::boolean and not (v_p->>'expenses')::boolean and not (v_p->>'employees')::boolean and not (v_p->>'settings')::boolean, v_p::text);

  -- ---- trigger enforcement (defaults) ----
  perform pg_temp.t4_expect('staff cannot change sales', v_sales, '%PERMISSION_DENIED%');
  perform pg_temp.t4_expect('staff cannot change expenses', v_exp, '%PERMISSION_DENIED%');
  perform pg_temp.t4_expect('staff cannot change settings', v_set, '%PERMISSION_DENIED%');
  perform pg_temp.t4_as(v_m);
  perform pg_temp.t4_pass('manager can change sales (default)', v_sales);
  perform pg_temp.t4_pass('manager can change expenses (default)', v_exp);
  perform pg_temp.t4_pass('manager can change settings (default)', v_set);
  perform pg_temp.t4_expect('manager cannot change an unknown section', v_zzz, '%only an admin%');
  perform pg_temp.t4_as(v_admin);
  perform pg_temp.t4_pass('admin can change an unknown section', v_zzz);
  perform pg_temp.t4_pass('admin can change sales', v_sales);

  -- ---- per-user overrides ----
  perform public.set_member_permission(v_m, 'sales', false);
  perform pg_temp.t4_as(v_m);
  perform pg_temp.t4_expect('manager with sales denied cannot change sales', v_sales, '%PERMISSION_DENIED%');
  perform pg_temp.t4_pass('manager with sales denied can still change expenses', v_exp);
  perform pg_temp.t4_as(v_admin);
  perform public.set_member_permission(v_m, 'sales', null);
  perform pg_temp.t4_as(v_m);
  perform pg_temp.t4_pass('removing the override restores manager sales access', v_sales);

  perform pg_temp.t4_as(v_admin);
  perform public.set_member_permission(v_s, 'sales', true);
  perform pg_temp.t4_as(v_s);
  v_p := public.my_permissions();
  perform pg_temp.t4_ok('staff with sales grant: my_permissions shows sales true, expenses false', (v_p->>'sales')::boolean and not (v_p->>'expenses')::boolean, v_p::text);
  perform pg_temp.t4_pass('staff with sales grant can change sales', v_sales);
  perform pg_temp.t4_expect('staff with sales grant still cannot change expenses', v_exp, '%PERMISSION_DENIED%');

  -- ---- save_shop_state_p4 ----
  select state, revision into v_state, v_rev from public.shop_state where shop_id = v_shop;
  v_err := null; v_new := null;
  begin
    v_new := public.save_shop_state_p4(jsonb_set(v_state, '{sales}', coalesce(v_state->'sales','[]'::jsonb) || '[{"id":"t4rpc"}]'::jsonb), v_rev);
  exception when others then v_err := sqlerrm; end;
  perform pg_temp.t4_ok('staff with sales grant can save sales through save_shop_state_p4', v_new = v_rev + 1, coalesce(v_err, v_new::text));
  v_err := null;
  begin
    perform public.save_shop_state_p4(jsonb_set(v_state, '{sales}', '[]'::jsonb), v_rev);
  exception when others then v_err := sqlerrm; end;
  perform pg_temp.t4_ok('stale revision is rejected as SYNC_CONFLICT', v_err ilike '%SYNC_CONFLICT%', v_err);
  select state, revision into v_state, v_rev from public.shop_state where shop_id = v_shop;
  v_err := null;
  begin
    perform public.save_shop_state_p4(jsonb_set(v_state, '{expenses}', coalesce(v_state->'expenses','[]'::jsonb) || '[{"id":"t4x"}]'::jsonb), v_rev);
  exception when others then v_err := sqlerrm; end;
  perform pg_temp.t4_ok('staff cannot save expenses through save_shop_state_p4', v_err ilike '%PERMISSION_DENIED%', v_err);
  perform pg_temp.t4_as(v_admin);
  perform public.set_member_permission(v_s, 'sales', null);
  perform pg_temp.t4_as(v_s);
  perform pg_temp.t4_expect('removing the staff grant blocks sales again', v_sales, '%PERMISSION_DENIED%');

  -- ---- who may manage permissions ----
  perform pg_temp.t4_as(v_m);
  perform pg_temp.t4_expect('manager cannot set permissions', format($q$select public.set_member_permission(%L,'sales',true)$q$, v_s), '%Only a shop admin%');
  perform pg_temp.t4_expect('manager cannot list the team', 'select * from public.list_team()', '%Only a shop admin%');
  perform pg_temp.t4_as(v_admin);
  perform pg_temp.t4_expect('unknown permission name is refused', format($q$select public.set_member_permission(%L,'payroll',true)$q$, v_s), '%Unknown permission%');
  perform pg_temp.t4_expect('admin permissions cannot be restricted', format($q$select public.set_member_permission(%L,'sales',false)$q$, v_admin), '%cannot be restricted%');
  perform pg_temp.t4_expect('non-member target is refused', format($q$select public.set_member_permission(%L,'sales',true)$q$, v_x), '%not a member%');

  -- ---- sessions and login history ----
  perform pg_temp.t4_as(v_m);
  v_id1 := public.start_session('t4-key-manager-1', 'Test Chrome');
  select count(*) into v_n from public.login_events where user_id = v_m and event = 'login';
  perform pg_temp.t4_ok('start_session returns an id and logs one login', v_id1 is not null and v_n = 1, v_n::text);
  v_id2 := public.start_session('t4-key-manager-1', 'Test Chrome');
  select count(*) into v_n from public.login_events where user_id = v_m and event = 'login';
  perform pg_temp.t4_ok('starting the same session again reuses it and logs no second login', v_id2 = v_id1 and v_n = 1, v_n::text);
  perform pg_temp.t4_pass('touch_session works for an open session', $q$select public.touch_session('t4-key-manager-1')$q$);
  perform pg_temp.t4_expect('touch_session on an unknown key is refused', $q$select public.touch_session('t4-never-started')$q$, '%SESSION_UNKNOWN%');
  perform pg_temp.t4_expect('too-short session key is refused', $q$select public.start_session('abc','x')$q$, '%Invalid session key%');
  perform pg_temp.t4_as(v_x);
  perform pg_temp.t4_expect('non-member cannot start a session', $q$select public.start_session('t4-key-outsider-1','x')$q$, '%membership%');
  perform pg_temp.t4_as(v_m);
  perform public.end_session('t4-key-manager-1');
  select count(*) into v_n from public.login_events where user_id = v_m and event = 'logout';
  select end_reason into v_err from public.user_sessions where id = v_id1;
  perform pg_temp.t4_ok('end_session closes the session and logs logout', v_n = 1 and v_err = 'logout', v_n::text || '/' || coalesce(v_err, 'null'));
  perform pg_temp.t4_expect('touch_session after logout is refused', $q$select public.touch_session('t4-key-manager-1')$q$, '%SESSION_REVOKED%');
  perform pg_temp.t4_expect('start_session cannot reopen an ended session', $q$select public.start_session('t4-key-manager-1','x')$q$, '%SESSION_REVOKED%');

  -- ---- admin views ----
  perform pg_temp.t4_as(v_m);  perform public.start_session('t4-key-manager-2', 'Test Edge');
  perform pg_temp.t4_as(v_s);  perform public.start_session('t4-key-staff-1', 'Test Phone');
  perform pg_temp.t4_as(v_admin);
  select count(*) into v_n from public.list_team() where email like 't4-%@test.invalid';
  perform pg_temp.t4_ok('list_team shows the two fake members with emails', v_n = 2, v_n::text);
  select count(*) into v_n from public.list_team() where email = 't4-staff@test.invalid' and active and role = 'staff' and not (permissions->>'sales')::boolean;
  perform pg_temp.t4_ok('list_team shows staff as active with sales false', v_n = 1, v_n::text);
  select count(*) into v_n from public.list_team() where email = 't4-manager@test.invalid' and online;
  perform pg_temp.t4_ok('list_team shows the manager as online', v_n = 1, v_n::text);
  select count(*) into v_n from public.list_sessions(true) where email like 't4-%@test.invalid';
  select count(*) into v_n2 from public.list_sessions(false) where email like 't4-%@test.invalid';
  perform pg_temp.t4_ok('list_sessions: open ones only vs all (2 open, 3 total)', v_n = 2 and v_n2 = 3, v_n::text || '/' || v_n2::text);
  select count(*) into v_n from public.list_login_history(v_m, 50);
  perform pg_temp.t4_ok('list_login_history filters by user (manager: login, logout, login = 3)', v_n = 3, v_n::text);
  perform pg_temp.t4_as(v_s);
  perform pg_temp.t4_expect('staff cannot read login history of others', 'select * from public.list_login_history(null, 10)', '%Only a shop admin%');

  -- ---- revoke sessions ----
  perform pg_temp.t4_as(v_admin);
  v_r := public.revoke_member_sessions(v_s);
  perform pg_temp.t4_ok('revoke ends the staff open session', (v_r->>'sessions_ended')::int = 1 and jsonb_exists(v_r, 'tokens_removed'), v_r::text);
  perform pg_temp.t4_as(v_s);
  perform pg_temp.t4_expect('revoked session is refused on its next heartbeat', $q$select public.touch_session('t4-key-staff-1')$q$, '%SESSION_REVOKED%');
  select count(*) into v_n from public.login_events where user_id = v_s and event = 'revoked';
  perform pg_temp.t4_ok('revoke is logged in login history', v_n = 1, v_n::text);
  perform pg_temp.t4_as(v_admin);
  perform pg_temp.t4_expect('admin cannot revoke their own sessions', format($q$select public.revoke_member_sessions(%L)$q$, v_admin), '%Use Sign out%');
  perform pg_temp.t4_expect('revoke refuses a non-member', format($q$select public.revoke_member_sessions(%L)$q$, v_x), '%not a member%');
  perform pg_temp.t4_as(v_m);
  perform pg_temp.t4_expect('manager cannot revoke sessions', format($q$select public.revoke_member_sessions(%L)$q$, v_s), '%Only a shop admin%');

  -- ---- deactivate / reactivate ----
  perform pg_temp.t4_as(v_s);  perform public.start_session('t4-key-staff-2', 'Test Phone 2');
  perform pg_temp.t4_as(v_admin);
  perform public.set_member_active(v_s, false);
  select banned_until into v_t from auth.users where id = v_s;
  select end_reason into v_err from public.user_sessions where user_id = v_s and session_key = 't4-key-staff-2';
  perform pg_temp.t4_ok('deactivate bans sign-in and ends open sessions', v_t > now() + interval '1 year' and v_err = 'deactivated', coalesce(v_t::text, 'null') || '/' || coalesce(v_err, 'null'));
  select count(*) into v_n from public.list_team() where email = 't4-staff@test.invalid' and not active;
  perform pg_temp.t4_ok('list_team shows the deactivated member as inactive', v_n = 1, v_n::text);
  perform public.set_member_active(v_s, true);
  select banned_until into v_t from auth.users where id = v_s;
  perform pg_temp.t4_ok('reactivate clears the ban', v_t is null, coalesce(v_t::text, 'null'));
  perform pg_temp.t4_expect('admin cannot deactivate themselves', format($q$select public.set_member_active(%L,false)$q$, v_admin), '%your own account%');
  perform pg_temp.t4_as(v_m);
  perform pg_temp.t4_expect('manager cannot deactivate anyone', format($q$select public.set_member_active(%L,false)$q$, v_s), '%Only a shop admin%');

  -- ---- audit trail and append-only ----
  perform pg_temp.t4_as(v_admin);
  select count(*) into v_n from public.security_audit where action = 'permission' and target_id in (v_m, v_s);
  perform pg_temp.t4_ok('permission changes are audited (4 changes)', v_n = 4, v_n::text);
  select count(*) into v_n from public.security_audit where action in ('revoke_sessions','deactivate','activate') and target_id = v_s;
  perform pg_temp.t4_ok('revoke, deactivate and activate are audited', v_n = 3, v_n::text);
  perform pg_temp.t4_expect('login history cannot be edited', $q$update public.login_events set event = 'login'$q$, '%append-only%');
  perform pg_temp.t4_expect('login history cannot be deleted', $q$delete from public.login_events$q$, '%append-only%');
  perform pg_temp.t4_expect('audit log cannot be edited', $q$update public.security_audit set action = 'x'$q$, '%append-only%');
  perform pg_temp.t4_expect('audit log cannot be deleted', $q$delete from public.security_audit$q$, '%append-only%');

  -- ---- access control as the signed-in database role ----
  perform pg_temp.t4_as(v_m);
  execute 'set local role authenticated';
  select count(*) into v_n from public.user_sessions where user_id <> v_m;
  select count(*) into v_n2 from public.login_events where user_id <> v_m;
  reset role;
  perform pg_temp.t4_ok('manager sees only their own sessions and login events', v_n = 0 and v_n2 = 0, v_n::text || '/' || v_n2::text);

  perform pg_temp.t4_as(v_m);
  execute 'set local role authenticated';
  select count(*) into v_n from public.security_audit;
  reset role;
  perform pg_temp.t4_ok('manager cannot read the audit log', v_n = 0, v_n::text);

  perform pg_temp.t4_as(v_s);
  execute 'set local role authenticated';
  select count(*) into v_n from public.member_permissions where user_id <> v_s;
  reset role;
  perform pg_temp.t4_ok('staff cannot read other members permissions', v_n = 0, v_n::text);

  perform pg_temp.t4_as(v_admin);
  execute 'set local role authenticated';
  select count(*) into v_n from public.user_sessions where user_id in (v_m, v_s);
  select count(*) into v_n2 from public.security_audit;
  reset role;
  perform pg_temp.t4_ok('admin sees everyone sessions and the audit log', v_n >= 3 and v_n2 >= 7, v_n::text || '/' || v_n2::text);

  perform pg_temp.t4_as(v_admin);
  execute 'set local role authenticated';
  v_err := null; begin insert into public.member_permissions(shop_id, user_id, permission, allowed) values (v_shop, v_s, 'sales', true); exception when others then v_err := sqlstate; end;
  v_b := v_err = '42501'; v_err := null;
  begin insert into public.user_sessions(shop_id, user_id, session_key) values (v_shop, v_admin, 't4-direct-insert'); exception when others then v_err := sqlstate; end;
  reset role;
  perform pg_temp.t4_ok('nobody can write permissions or sessions directly (permission denied)', v_b and v_err = '42501', v_err);

  execute 'set local role authenticated';
  v_err := null; begin perform public.p4_effective_permission(v_shop, v_m, 'sales'); exception when others then v_err := sqlstate; end;
  v_b := v_err = '42501'; v_err := null;
  begin perform public.p4_ctx(); exception when others then v_err := sqlstate; end;
  reset role;
  perform pg_temp.t4_ok('internal helpers are not callable by signed-in users', v_b and v_err = '42501', v_err);

  execute 'set local role anon';
  v_err := null; begin perform public.start_session('t4-anon-key-1', 'x'); exception when others then v_err := sqlstate; end;
  reset role;
  perform pg_temp.t4_ok('signed-out visitors cannot call start_session (permission denied)', v_err = '42501', v_err);

  -- ---- existing P1 behaviour is untouched ----
  perform pg_temp.t4_as(v_s);
  perform pg_temp.t4_expect('original save_shop_state still refuses staff', $q$select public.save_shop_state('{}'::jsonb, 0)$q$, '%read-only%');

  -- ---- verdict (always raises, so everything rolls back) ----
  select count(*) filter (where not ok), count(*) into v_fail, v_total from t4_res;
  if v_fail > 0 then
    select string_agg(format('[%s] %s (%s)', n, name, coalesce(detail, '')), E'\n' order by n) into v_list from t4_res where not ok;
    raise exception E'% OF % CHECKS FAILED:\n%', v_fail, v_total, v_list;
  end if;
  raise exception 'ALL % CHECKS PASSED (all test data rolled back)', v_total;
end $do$;
