-- Test for move_employee_expense / void_employee_expense. Run AFTER 202611040006_move_void_expense.sql.
-- Needs two active employees in your roster. Everything is rolled back at the end.
-- Expected last line:  ALL <n> CHECKS PASSED (all test data rolled back)
create temp table if not exists t6_res(n serial, name text, ok boolean, detail text);
truncate t6_res;
create or replace function pg_temp.t6_ok(p_name text, p_ok boolean, p_detail text default null)
returns void language plpgsql as $f$ begin insert into t6_res(name, ok, detail) values (p_name, coalesce(p_ok,false), p_detail); end $f$;
create or replace function pg_temp.t6_err(p_sql text) returns text language plpgsql as $f$
declare v text; begin begin execute p_sql; v := null; exception when others then v := sqlerrm; end; return v; end $f$;
create or replace function pg_temp.t6_expect(p_name text, p_sql text, p_pat text) returns void language plpgsql as $f$
declare v text := pg_temp.t6_err(p_sql);
begin if v is null then insert into t6_res(name, ok, detail) values (p_name, false, 'no error was raised');
      else insert into t6_res(name, ok, detail) values (p_name, v ilike p_pat, v); end if; end $f$;
create or replace function pg_temp.t6_as(p_uid uuid) returns void language plpgsql as $f$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
      perform set_config('request.jwt.claim.sub', p_uid::text, true); end $f$;

do $do$
declare
  v_shop uuid; v_admin uuid; v_a text; v_b text; v_m uuid := '66666666-6666-6666-6666-666666666661';
  v_id uuid; v_id2 uuid; v_id3 uuid; v_r jsonb; v_row public.employee_expenses%rowtype; v_n int; v_net numeric; v_err text;
  v_fail int; v_total int; v_list text;
begin
  select shop_id, user_id into v_shop, v_admin from public.shop_members where role = 'admin' limit 1;
  select min(employee_ref), max(employee_ref) into v_a, v_b from public.employee_registry where shop_id = v_shop and active;
  if v_admin is null or v_a is null or v_a = v_b then raise exception 'SETUP: need an admin and two active employees in the roster'; end if;
  insert into auth.users(id, instance_id, aud, role, email, created_at, updated_at)
    values (v_m, '00000000-0000-0000-0000-000000000000','authenticated','authenticated','t6-manager@test.invalid', now(), now());
  insert into public.shop_members(shop_id, user_id, role) values (v_shop, v_m, 'manager');
  perform pg_temp.t6_as(v_admin);

  -- MOVE a pending record
  v_id := (public.create_employee_expense(v_a, 'Cash Advance', 300, 'T6 wrong person', null)->>'id')::uuid;
  v_r := public.move_employee_expense(v_id, v_b, 'entered under wrong employee');
  select * into v_row from public.employee_expenses where id = v_id;
  perform pg_temp.t6_ok('move: employee changed (ref and name), still pending', v_row.employee_ref = v_b and v_row.approval_status = 'pending' and v_row.employee_name = (select name from public.employee_registry where shop_id = v_shop and employee_ref = v_b) and (v_r->>'deductions_reversed') = '0', v_row.employee_ref);
  perform pg_temp.t6_ok('move: marked edited', v_row.edited_at is not null and v_row.edited_by_name is not null);
  perform pg_temp.t6_expect('move to the same employee refused', format($q$select public.move_employee_expense(%L,%L,'same')$q$, v_id, v_b), '%different employee%');
  perform pg_temp.t6_expect('move to an unknown employee refused', format($q$select public.move_employee_expense(%L,'NO-SUCH-EMP','x1x')$q$, v_id), '%not found%');
  perform pg_temp.t6_expect('move needs a reason', format($q$select public.move_employee_expense(%L,%L,' ')$q$, v_id, v_a), '%reason is required%');

  -- MOVE an approved record that already has two deductions
  v_id2 := (public.create_employee_expense(v_a, 'Cash Advance', 500, 'T6 deducted wrongly', null)->>'id')::uuid;
  perform public.decide_employee_expense(v_id2, 'approved', null, 'T6 signed authorization');
  perform public.apply_employee_deduction(v_id2, 40, '2026-11', '15th', null);
  perform public.apply_employee_deduction(v_id2, 10, '2026-11', '15th', null);
  v_r := public.move_employee_expense(v_id2, v_b, 'deducted from the wrong person');
  select * into v_row from public.employee_expenses where id = v_id2;
  perform pg_temp.t6_ok('move with deductions: both reversed and balance back to zero', (v_r->>'deductions_reversed') = '2' and v_row.deducted_amount = 0, v_r->>'deductions_reversed');
  select coalesce(sum(case kind when 'deduction' then amount else -amount end),0) into v_net from public.employee_deductions where expense_id = v_id2 and employee_ref = v_a;
  perform pg_temp.t6_ok('old employee net deductions on this record are zero', v_net = 0, v_net::text);
  perform pg_temp.t6_ok('moved record is pending with authorization cleared', v_row.approval_status = 'pending' and v_row.authorization_note is null and v_row.decided_by is null and v_row.employee_ref = v_b);
  perform public.decide_employee_expense(v_id2, 'approved', null, 'T6 new employee authorization');
  v_r := public.apply_employee_deduction(v_id2, 25, '2026-11', '30th', null);
  perform pg_temp.t6_ok('deduction can be applied again under the new employee', v_r->>'employee_ref' = v_b and v_r->>'amount' is not null, v_r->>'employee_ref');

  -- VOID
  v_r := public.void_employee_expense(v_id2, 'duplicate entry');
  select * into v_row from public.employee_expenses where id = v_id2;
  perform pg_temp.t6_ok('void with a deduction: reversed, rejected, balance zero', (v_r->>'deductions_reversed') = '1' and v_row.approval_status = 'rejected' and v_row.deducted_amount = 0, v_r->>'deductions_reversed');
  perform pg_temp.t6_ok('void note and markers are set', v_row.decision_note like 'VOIDED:%' and v_row.voided_at is not null and v_row.voided_by_name is not null and v_row.authorization_note is null);
  perform pg_temp.t6_expect('a voided record cannot be deducted', format($q$select public.apply_employee_deduction(%L,5,'2026-11','30th',null)$q$, v_id2), '%approved%');
  perform pg_temp.t6_expect('a voided record cannot be voided again', format($q$select public.void_employee_expense(%L,'again')$q$, v_id2), '%already rejected or voided%');
  perform pg_temp.t6_expect('a voided record cannot be moved', format($q$select public.move_employee_expense(%L,%L,'again')$q$, v_id2, v_a), '%cannot be moved%');
  perform pg_temp.t6_expect('a voided record cannot be edited', format($q$select public.edit_employee_expense(%L,null,null,'x',null,'again')$q$, v_id2), '%Rejected records cannot be edited%');
  v_id3 := (public.create_employee_expense(v_a, 'Other Employee Expenses', 20, 'T6 pending void', null)->>'id')::uuid;
  v_r := public.void_employee_expense(v_id3, 'not needed');
  select * into v_row from public.employee_expenses where id = v_id3;
  perform pg_temp.t6_ok('a pending record can be voided', v_row.approval_status = 'rejected' and v_row.voided_at is not null and (v_r->>'deductions_reversed') = '0');
  perform pg_temp.t6_expect('void needs a reason', format($q$select public.void_employee_expense(%L,'')$q$, v_id), '%reason is required%');
  perform pg_temp.t6_expect('unknown record refused', $q$select public.void_employee_expense(gen_random_uuid(),'test')$q$, '%not found%');

  -- who may do it
  perform pg_temp.t6_as(v_m);
  v_err := pg_temp.t6_err(format($q$select public.void_employee_expense(%L,'manager try')$q$, v_id));
  perform pg_temp.t6_ok('a manager cannot void (admin only)', v_err is not null, v_err);
  v_err := pg_temp.t6_err(format($q$select public.move_employee_expense(%L,%L,'manager try')$q$, v_id, v_a));
  perform pg_temp.t6_ok('a manager cannot move (admin only)', v_err is not null, v_err);
  perform pg_temp.t6_as(v_admin);
  execute 'set local role anon';
  v_err := null; begin perform public.void_employee_expense(v_id,'anon try'); exception when others then v_err := sqlstate; end;
  reset role;
  perform pg_temp.t6_ok('signed-out visitors cannot call void (permission denied)', v_err = '42501', v_err);
  execute 'set local role authenticated';
  v_err := null; begin perform public.p5_reverse_active_deductions(v_id,'direct'); exception when others then v_err := sqlstate; end;
  reset role;
  perform pg_temp.t6_ok('the internal reverse helper is not callable directly', v_err = '42501', v_err);

  select count(*) filter (where not ok), count(*) into v_fail, v_total from t6_res;
  if v_fail > 0 then
    select string_agg(format('[%s] %s (%s)', n, name, coalesce(detail,'')), E'\n' order by n) into v_list from t6_res where not ok;
    raise exception E'% OF % CHECKS FAILED:\n%', v_fail, v_total, v_list;
  end if;
  raise exception 'ALL % CHECKS PASSED (all test data rolled back)', v_total;
end $do$;
