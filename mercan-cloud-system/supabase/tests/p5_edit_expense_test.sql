-- Test for edit_employee_expense. Run AFTER 202611040005_edit_employee_expense.sql.
-- Paste the whole file into the Supabase SQL Editor. It uses one existing active employee from your roster
-- and a fake manager account, then ends with an INTENTIONAL error so everything is rolled back.
-- Expected last line:  ALL <n> CHECKS PASSED (all test data rolled back)
create temp table if not exists t5_res(n serial, name text, ok boolean, detail text);
truncate t5_res;
create or replace function pg_temp.t5_ok(p_name text, p_ok boolean, p_detail text default null)
returns void language plpgsql as $f$ begin insert into t5_res(name, ok, detail) values (p_name, coalesce(p_ok,false), p_detail); end $f$;
create or replace function pg_temp.t5_err(p_sql text) returns text language plpgsql as $f$
declare v text; begin begin execute p_sql; v := null; exception when others then v := sqlerrm; end; return v; end $f$;
create or replace function pg_temp.t5_expect(p_name text, p_sql text, p_pat text) returns void language plpgsql as $f$
declare v text := pg_temp.t5_err(p_sql);
begin if v is null then insert into t5_res(name, ok, detail) values (p_name, false, 'no error was raised');
      else insert into t5_res(name, ok, detail) values (p_name, v ilike p_pat, v); end if; end $f$;
create or replace function pg_temp.t5_audit_count() returns bigint language plpgsql as $f$
declare n bigint; begin begin execute 'select count(*) from public.audit_log' into n; exception when others then n := -1; end; return n; end $f$;
create or replace function pg_temp.t5_as(p_uid uuid) returns void language plpgsql as $f$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
      perform set_config('request.jwt.claim.sub', p_uid::text, true); end $f$;

do $do$
declare
  v_shop uuid; v_admin uuid; v_emp text; v_m uuid := '55555555-5555-5555-5555-555555555551';
  v_e1 jsonb; v_id1 uuid; v_id2 uuid; v_r jsonb; v_row public.employee_expenses%rowtype; v_ded uuid;
  v_a1 bigint; v_a2 bigint; v_fail int; v_total int; v_list text; v_err text;
begin
  select shop_id, user_id into v_shop, v_admin from public.shop_members where role = 'admin' limit 1;
  select employee_ref into v_emp from public.employee_registry where shop_id = v_shop and active limit 1;
  if v_admin is null or v_emp is null then raise exception 'SETUP: need an admin and one active employee in the roster'; end if;
  insert into auth.users(id, instance_id, aud, role, email, created_at, updated_at)
    values (v_m, '00000000-0000-0000-0000-000000000000','authenticated','authenticated','t5-manager@test.invalid', now(), now());
  insert into public.shop_members(shop_id, user_id, role) values (v_shop, v_m, 'manager');
  perform pg_temp.t5_as(v_admin);

  v_e1 := public.create_employee_expense(v_emp, 'Cash Advance', 100, 'T5 original', null);
  v_id1 := (v_e1->>'id')::uuid;
  v_a1 := pg_temp.t5_audit_count();   -- only used to see that edits write an audit entry (skipped if the table is named differently)

  -- pending edits
  v_r := public.edit_employee_expense(v_id1, 'Emergency Advance', 150, 'T5 changed', null, 'fix typo');
  select * into v_row from public.employee_expenses where id = v_id1;
  perform pg_temp.t5_ok('pending: category, amount, description updated', v_row.category = 'Emergency Advance' and v_row.amount = 150 and v_row.description = 'T5 changed', v_row.category||'/'||v_row.amount);
  perform pg_temp.t5_ok('pending: stays pending and is marked edited', v_row.approval_status = 'pending' and v_row.edited_at is not null and v_row.edited_by_name is not null and (v_r->>'approval_reset') = 'false');
  v_a2 := pg_temp.t5_audit_count();
  perform pg_temp.t5_ok('edit writes one audit entry (skipped if audit table not found)', v_a1 = -1 or v_a2 = v_a1 + 1, v_a1||'->'||v_a2);
  perform pg_temp.t5_ok('employee and reference unchanged', v_row.employee_ref = v_emp and v_row.reference = v_e1->>'reference');
  v_r := public.edit_employee_expense(v_id1, null, null, null, now() - interval '2 days', 'wrong date');
  select * into v_row from public.employee_expenses where id = v_id1;
  perform pg_temp.t5_ok('date can be edited alone', v_row.occurred_at < now() - interval '1 day' and v_row.amount = 150);

  perform pg_temp.t5_expect('no change is refused', format($q$select public.edit_employee_expense(%L,'Emergency Advance',150,'T5 changed',null,'nothing')$q$, v_id1), '%Nothing was changed%');
  perform pg_temp.t5_expect('reason is required', format($q$select public.edit_employee_expense(%L,null,200,null,null,' ')$q$, v_id1), '%reason is required%');
  perform pg_temp.t5_expect('bad category refused', format($q$select public.edit_employee_expense(%L,'Gift',null,null,null,'test')$q$, v_id1), '%valid expense category%');
  perform pg_temp.t5_expect('zero amount refused', format($q$select public.edit_employee_expense(%L,null,0,null,null,'test')$q$, v_id1), '%greater than zero%');
  perform pg_temp.t5_expect('blank description refused', format($q$select public.edit_employee_expense(%L,null,null,'   ',null,'test')$q$, v_id1), '%description%');
  perform pg_temp.t5_expect('future date refused', format($q$select public.edit_employee_expense(%L,null,null,null,now() + interval '5 days','test')$q$, v_id1), '%future%');
  perform pg_temp.t5_expect('unknown record refused', $q$select public.edit_employee_expense(gen_random_uuid(),null,200,null,null,'test')$q$, '%not found%');

  -- approved: description only keeps approval, amount change resets it
  perform public.decide_employee_expense(v_id1, 'approved', null, 'T5 signed authorization');
  v_r := public.edit_employee_expense(v_id1, null, null, 'T5 approved wording', null, 'clearer text');
  select * into v_row from public.employee_expenses where id = v_id1;
  perform pg_temp.t5_ok('approved: description edit keeps approval and authorization', v_row.approval_status = 'approved' and v_row.authorization_note is not null and (v_r->>'approval_reset') = 'false');
  v_r := public.edit_employee_expense(v_id1, null, 175, null, null, 'amount was wrong');
  select * into v_row from public.employee_expenses where id = v_id1;
  perform pg_temp.t5_ok('approved: amount change returns it to pending', v_row.approval_status = 'pending' and (v_r->>'approval_reset') = 'true' and v_row.amount = 175);
  perform pg_temp.t5_ok('approval fields are cleared on reset', v_row.decided_by is null and v_row.decided_at is null and v_row.authorization_note is null and v_row.decision_note is null);

  -- deductions block edits until reversed
  perform public.decide_employee_expense(v_id1, 'approved', null, 'T5 signed authorization again');
  v_r := public.apply_employee_deduction(v_id1, 20, '2026-11', '15th', null);
  v_ded := (v_r->>'id')::uuid;
  perform pg_temp.t5_expect('edit blocked while a deduction is applied', format($q$select public.edit_employee_expense(%L,null,null,'blocked',null,'try')$q$, v_id1), '%Reverse the deductions first%');
  perform public.reverse_employee_deduction(v_ded, 'T5 reversal');
  v_err := pg_temp.t5_err(format($q$select public.edit_employee_expense(%L,null,null,'after reversal',null,'ok now')$q$, v_id1));
  perform pg_temp.t5_ok('edit works again after the deduction is reversed', v_err is null, v_err);
  select * into v_row from public.employee_expenses where id = v_id1;
  perform pg_temp.t5_ok('description changed after reversal', v_row.description = 'after reversal' and v_row.deducted_amount = 0);

  -- rejected
  v_id2 := (public.create_employee_expense(v_emp, 'Other Employee Expenses', 50, 'T5 second', null)->>'id')::uuid;
  perform public.decide_employee_expense(v_id2, 'rejected', 'T5 rejected reason', null);
  perform pg_temp.t5_expect('rejected records cannot be edited', format($q$select public.edit_employee_expense(%L,null,null,'x',null,'try')$q$, v_id2), '%Rejected records cannot be edited%');

  -- who may edit
  perform pg_temp.t5_as(v_m);
  v_err := pg_temp.t5_err(format($q$select public.edit_employee_expense(%L,null,null,'manager edit',null,'try')$q$, v_id1));
  perform pg_temp.t5_ok('a manager cannot edit (admin only)', v_err is not null, v_err);
  perform pg_temp.t5_as(v_admin);
  execute 'set local role anon';
  v_err := null; begin perform public.edit_employee_expense(v_id1,null,null,'anon',null,'try'); exception when others then v_err := sqlstate; end;
  reset role;
  perform pg_temp.t5_ok('signed-out visitors cannot call it (permission denied)', v_err = '42501', v_err);

  select count(*) filter (where not ok), count(*) into v_fail, v_total from t5_res;
  if v_fail > 0 then
    select string_agg(format('[%s] %s (%s)', n, name, coalesce(detail,'')), E'\n' order by n) into v_list from t5_res where not ok;
    raise exception E'% OF % CHECKS FAILED:\n%', v_fail, v_total, v_list;
  end if;
  raise exception 'ALL % CHECKS PASSED (all test data rolled back)', v_total;
end $do$;
