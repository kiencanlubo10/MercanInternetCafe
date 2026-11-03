-- Priority 3 payroll test. Paste the WHOLE file into the Supabase SQL Editor and run it.
-- It creates test employees "T3-A" and "T3-B" and test sales dated March 2031, runs payroll on them,
-- then ends with an INTENTIONAL error so everything is rolled back.
-- Expected last line:  ALL 66 CHECKS PASSED (all test data rolled back)
-- Anything else lists the failed checks. Real data is not changed.

create temp table if not exists p3_res(n serial, name text, ok boolean, detail text);
truncate p3_res;

create or replace function pg_temp.p3_ok(p_name text, p_ok boolean, p_detail text default null)
returns void language plpgsql as $f$
begin insert into p3_res(name, ok, detail) values (p_name, coalesce(p_ok, false), p_detail); end $f$;

create or replace function pg_temp.p3_expect(p_name text, p_sql text, p_pat text)
returns void language plpgsql as $f$
declare v_msg text;
begin
  begin execute p_sql; v_msg := null;
  exception when others then v_msg := sqlerrm; end;
  if v_msg is null then
    insert into p3_res(name, ok, detail) values (p_name, false, 'no error was raised');
  else
    insert into p3_res(name, ok, detail) values (p_name, v_msg ilike p_pat, v_msg);
  end if;
end $f$;

create or replace function pg_temp.p3_as(p_uid uuid)
returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
end $f$;

do $do$
declare
  v_shop uuid; v_admin uuid;
  v_expA uuid; v_expA2 uuid; v_expB uuid; v_expB2 uuid;
  v_d500 uuid; v_dLocked uuid;
  v_r jsonb; v_run uuid; v_runB uuid; v_run30 uuid;
  v_n integer; v_x numeric; v_err text; v_before integer; v_after integer;
  v_fail integer; v_total integer; v_list text;
begin
  select shop_id, user_id into v_shop, v_admin from public.shop_members where role = 'admin' limit 1;
  if v_admin is null then raise exception 'SETUP: no admin found in shop_members'; end if;
  perform pg_temp.p3_as(v_admin);

  -- ---- test employees and test sales/bills (2031-03) ----
  insert into public.employee_registry(shop_id, employee_ref, name, monthly_salary, commission_rate, active, updated_at)
  values (v_shop, 'T3-A', 'Test Alpha', 20000, 10, true, now()),
         (v_shop, 'T3-B', 'Test Bravo', 10000, 0, true, now());

  update public.shop_state set state =
      jsonb_set(jsonb_set(state, '{sales}', coalesce(state->'sales','[]'::jsonb) || jsonb_build_array(
        jsonb_build_object('id','t3s1','date','2031-03-05','morning',1000,'night',500),
        jsonb_build_object('id','t3s2','date','2031-03-15','morning',500,'night',0),
        jsonb_build_object('id','t3s3','date','2031-03-02','morning','abc','night',100),
        jsonb_build_object('id','t3s4','date','2031-03-16','morning',3000,'night',0),
        jsonb_build_object('id','t3s5','date','2031-03-31','morning',0,'night',1000),
        jsonb_build_object('id','t3s6','date','2031-04-01','morning',600,'night',0),
        jsonb_build_object('id','t3s7','date','2031-02-28','morning',700,'night',0))),
      '{expenses}', coalesce(state->'expenses','[]'::jsonb) || jsonb_build_array(
        jsonb_build_object('id','t3e1','date','2031-03-10','category','Test','description','t','amount',400),
        jsonb_build_object('id','t3e2','date','2031-03-20','category','Test','description','t','amount',5000)))
   where shop_id = v_shop;
  select count(*) into v_n from public.shop_state where shop_id = v_shop;
  perform pg_temp.p3_ok('setup: shop_state row exists', v_n = 1);

  -- ---- preview: numbers ----
  v_r := public.preview_payroll('T3-A', '2031-03', '15th');
  perform pg_temp.p3_ok('preview A 15th: basic pay is half of monthly salary', (v_r->>'basic_pay')::numeric = 10000, v_r->>'basic_pay');
  perform pg_temp.p3_ok('preview A 15th: window is 1st-15th', v_r->>'commission_from' = '2031-03-01' and v_r->>'commission_to' = '2031-03-15');
  perform pg_temp.p3_ok('preview A 15th: gross 2100 (bad value counted as 0, outside dates excluded)', (v_r->>'period_gross')::numeric = 2100, v_r->>'period_gross');
  perform pg_temp.p3_ok('preview A 15th: bills 400', (v_r->>'period_bills')::numeric = 400, v_r->>'period_bills');
  perform pg_temp.p3_ok('preview A 15th: net 1700', (v_r->>'period_net')::numeric = 1700);
  perform pg_temp.p3_ok('preview A 15th: commission 10% = 170', (v_r->>'commission_amount')::numeric = 170, v_r->>'commission_amount');
  perform pg_temp.p3_ok('preview A 15th: net pay 10170 with no deductions', (v_r->>'net_pay')::numeric = 10170, v_r->>'net_pay');
  perform pg_temp.p3_ok('preview A 15th: not blocked', v_r->>'blocked_reason' is null, v_r->>'blocked_reason');
  perform pg_temp.p3_ok('preview A 15th: warns that the commission period has not ended', (v_r->'warnings')::text ilike '%not ended%');

  v_r := public.preview_payroll('T3-A', '2031-03', '30th');
  perform pg_temp.p3_ok('preview A 30th: window is 16th-end of month', v_r->>'commission_from' = '2031-03-16' and v_r->>'commission_to' = '2031-03-31');
  perform pg_temp.p3_ok('preview A 30th: negative net gives commission 0', (v_r->>'period_net')::numeric = -1000 and (v_r->>'commission_amount')::numeric = 0, v_r->>'period_net');

  v_r := public.preview_payroll('T3-B', '2031-03', '15th');
  perform pg_temp.p3_ok('preview B: rate 0 gives commission 0 and basic 5000', (v_r->>'commission_amount')::numeric = 0 and (v_r->>'basic_pay')::numeric = 5000);

  select w_to::text into v_err from public.payroll_default_window('2031-02', '30th');
  perform pg_temp.p3_ok('default window: February 30th payout ends on the 28th', v_err = '2031-02-28', v_err);

  select count(*) into v_before from public.payroll_runs;
  perform public.preview_payroll('T3-A', '2031-03', '15th');
  select count(*) into v_after from public.payroll_runs;
  perform pg_temp.p3_ok('preview writes nothing', v_before = v_after);

  perform pg_temp.p3_expect('preview: unknown employee refused', $q$select public.preview_payroll('NOPE','2031-03','15th')$q$, '%not found%');
  perform pg_temp.p3_expect('preview: bad month refused', $q$select public.preview_payroll('T3-A','2031-13','15th')$q$, '%Salary month%');
  perform pg_temp.p3_expect('preview: bad payout refused', $q$select public.preview_payroll('T3-A','2031-03','20th')$q$, '%15th or 30th%');
  perform pg_temp.p3_expect('preview: start after end refused', $q$select public.preview_payroll('T3-A','2031-03','15th','2031-03-10','2031-03-05')$q$, '%not be after%');
  perform pg_temp.p3_expect('preview: window over 45 days refused', $q$select public.preview_payroll('T3-A','2031-03','15th','2031-01-01','2031-03-15')$q$, '%45 days%');

  -- ---- expenses and deductions (Priority 2 functions) ----
  perform public.create_employee_expense(p_employee_ref => 'T3-A', p_category => 'Cash Advance', p_amount => 3000, p_description => 'P3 test advance A1', p_occurred_at => null);
  select id into v_expA from public.employee_expenses where employee_ref = 'T3-A' order by reference desc limit 1;
  perform public.decide_employee_expense(p_expense_id => v_expA, p_decision => 'approved', p_note => 'ok', p_authorization => 'P3 test signed authorization');
  perform public.apply_employee_deduction(v_expA, 1000, '2031-03', '15th', 'P3 test ded 1000');
  perform public.apply_employee_deduction(v_expA, 500, '2031-03', '15th', 'P3 test ded 500');
  select id into v_d500 from public.employee_deductions where expense_id = v_expA and amount = 500 and kind = 'deduction';
  perform public.reverse_employee_deduction(v_d500, 'P3 test reversal');
  perform public.apply_employee_deduction(v_expA, 200, '2031-03', '30th', 'P3 test ded for 30th');

  v_r := public.preview_payroll('T3-A', '2031-03', '15th');
  perform pg_temp.p3_ok('preview picks up only this payout''s deductions (1000 + 500 - 500)', (v_r->>'deductions_total')::numeric = 1000, v_r->>'deductions_total');
  perform pg_temp.p3_ok('preview net pay 9170', (v_r->>'net_pay')::numeric = 9170, v_r->>'net_pay');
  perform pg_temp.p3_ok('preview shows 5 lines (basic, commission, 2 deductions, 1 reversal)', jsonb_array_length(v_r->'lines') = 5, jsonb_array_length(v_r->'lines')::text);

  -- ---- processing ----
  perform pg_temp.p3_expect('process: stale expected net refused', $q$select public.process_payroll_run('T3-A','2031-03','15th','2031-03-15',null,null,null,9999)$q$, '%figures changed%');
  v_r := public.process_payroll_run('T3-A', '2031-03', '15th', '2031-03-15', null, null, 'P3 test', 9170);
  v_run := (v_r->>'id')::uuid;
  perform pg_temp.p3_ok('process: reference format PAY-YYYYMMDD-00000', v_r->>'reference' ~ '^PAY-\d{8}-\d{5}$', v_r->>'reference');
  perform pg_temp.p3_ok('process: net pay 9170 and status processed', (v_r->>'net_pay')::numeric = 9170 and v_r->>'status' = 'processed');
  perform pg_temp.p3_ok('process: snapshot of salary, rate and commission', (v_r->>'monthly_salary')::numeric = 20000 and (v_r->>'commission_rate')::numeric = 10 and (v_r->>'commission_amount')::numeric = 170);
  select count(*), coalesce(sum(amount),0) into v_n, v_x from public.payroll_run_lines where payroll_run_id = v_run;
  perform pg_temp.p3_ok('process: 5 lines saved', v_n = 5, v_n::text);
  perform pg_temp.p3_ok('process: lines add up to net pay', v_x = 9170, v_x::text);
  select count(*) into v_n from public.employee_deductions where payroll_run_id = v_run;
  perform pg_temp.p3_ok('process: 3 deduction rows locked to the run', v_n = 3, v_n::text);
  select count(*) into v_n from public.employee_deductions where employee_ref = 'T3-A' and payout_period = '30th' and payroll_run_id is null;
  perform pg_temp.p3_ok('process: the 30th deduction stays unlinked', v_n = 1, v_n::text);
  select count(*) into v_n from public.audit_logs where action = 'payroll.process' and related_id = v_run::text;
  perform pg_temp.p3_ok('process: audit log written', v_n = 1, v_n::text);

  perform pg_temp.p3_expect('process: duplicate payout refused', $q$select public.process_payroll_run('T3-A','2031-03','15th')$q$, '%already exists%');
  perform pg_temp.p3_expect('deduct: closed payout refused', format($q$select public.apply_employee_deduction(%L,100,'2031-03','15th','late')$q$, v_expA), '%already processed%');
  select id into v_dLocked from public.employee_deductions where payroll_run_id = v_run and kind = 'deduction' order by amount desc limit 1;
  perform pg_temp.p3_expect('reverse: locked deduction refused', format($q$select public.reverse_employee_deduction(%L,'too late')$q$, v_dLocked), '%processed payroll%');
  perform pg_temp.p3_expect('locked deduction cannot be edited', format($q$update public.employee_deductions set amount = 1 where id = %L$q$, v_dLocked), '%');
  perform pg_temp.p3_expect('payroll run cannot be edited', format($q$update public.payroll_runs set net_pay = 1 where id = %L$q$, v_run), '%append-only%');
  perform pg_temp.p3_expect('payroll run cannot be deleted', format($q$delete from public.payroll_runs where id = %L$q$, v_run), '%append-only%');
  perform pg_temp.p3_expect('payroll lines cannot be edited', format($q$update public.payroll_run_lines set amount = 1 where payroll_run_id = %L$q$, v_run), '%append-only%');

  -- ---- 30th payout of A, and overlap protection ----
  v_r := public.process_payroll_run('T3-A', '2031-03', '30th', '2031-03-30', null, null, null, 9800);
  v_run30 := (v_r->>'id')::uuid;
  perform pg_temp.p3_ok('process 30th: net pay 9800 (basic 10000, commission 0, deduction 200)', (v_r->>'net_pay')::numeric = 9800, v_r->>'net_pay');
  v_r := public.preview_payroll('T3-A', '2031-04', '15th', '2031-03-20', '2031-04-10');
  perform pg_temp.p3_ok('preview: overlapping commission period flagged', v_r->>'overlaps_reference' is not null and v_r->>'blocked_reason' ilike '%overlaps%', v_r->>'blocked_reason');
  perform pg_temp.p3_expect('process: overlapping commission period refused', $q$select public.process_payroll_run('T3-A','2031-04','15th',null,'2031-03-20','2031-04-10')$q$, '%overlaps%');

  -- ---- employee B: deductions and negative net ----
  perform public.create_employee_expense(p_employee_ref => 'T3-B', p_category => 'Cash Advance', p_amount => 4000, p_description => 'P3 test advance B1', p_occurred_at => null);
  select id into v_expB from public.employee_expenses where employee_ref = 'T3-B' order by reference desc limit 1;
  perform public.decide_employee_expense(p_expense_id => v_expB, p_decision => 'approved', p_note => null, p_authorization => 'P3 test signed authorization');
  perform public.apply_employee_deduction(v_expB, 2000, '2031-03', '15th', 'P3 B ded');
  v_r := public.process_payroll_run('T3-B', '2031-03', '15th', '2031-03-15');
  v_runB := (v_r->>'id')::uuid;
  perform pg_temp.p3_ok('process B: 5000 basic - 2000 deduction = 3000', (v_r->>'net_pay')::numeric = 3000, v_r->>'net_pay');

  perform public.create_employee_expense(p_employee_ref => 'T3-B', p_category => 'Emergency Advance', p_amount => 9000, p_description => 'P3 test advance B2', p_occurred_at => null);
  select id into v_expB2 from public.employee_expenses where employee_ref = 'T3-B' order by reference desc limit 1;
  perform public.decide_employee_expense(p_expense_id => v_expB2, p_decision => 'approved', p_note => null, p_authorization => 'P3 test signed authorization');
  perform public.apply_employee_deduction(v_expB2, 6000, '2031-03', '30th', 'P3 B big ded');
  v_r := public.preview_payroll('T3-B', '2031-03', '30th');
  perform pg_temp.p3_ok('preview B 30th: negative net pay is blocked', (v_r->>'net_pay')::numeric = -1000 and v_r->>'blocked_reason' ilike '%exceed basic pay%', v_r->>'blocked_reason');
  perform pg_temp.p3_expect('process B 30th: negative net pay refused', $q$select public.process_payroll_run('T3-B','2031-03','30th')$q$, '%exceed basic pay%');
  select count(*) into v_n from public.employee_deductions where employee_ref = 'T3-B' and payout_period = '30th' and payroll_run_id is null;
  perform pg_temp.p3_ok('refused run leaves its deductions unlinked', v_n = 1, v_n::text);

  -- ---- adjustments and listing ----
  v_r := public.add_payroll_adjustment(v_run, 250, 'P3 test bonus correction');
  perform pg_temp.p3_ok('adjustment: reference format ADJ-YYYYMMDD-00000', v_r->>'reference' ~ '^ADJ-\d{8}-\d{5}$', v_r->>'reference');
  perform pg_temp.p3_expect('adjustment: zero refused', format($q$select public.add_payroll_adjustment(%L,0,'zero')$q$, v_run), '%cannot be zero%');
  perform pg_temp.p3_expect('adjustment: missing reason refused', format($q$select public.add_payroll_adjustment(%L,10,'')$q$, v_run), '%reason is required%');
  perform pg_temp.p3_expect('adjustment: negative final net refused', format($q$select public.add_payroll_adjustment(%L,-99999,'too much')$q$, v_run), '%negative%');
  perform pg_temp.p3_expect('adjustment: unknown run refused', $q$select public.add_payroll_adjustment('00000000-0000-0000-0000-000000000000',10,'nope nope')$q$, '%not found%');
  perform pg_temp.p3_expect('adjustment cannot be deleted', format($q$delete from public.payroll_adjustments where payroll_run_id = %L$q$, v_run), '%append-only%');
  v_r := public.list_payroll_runs('2031-03', 'T3-A');
  perform pg_temp.p3_ok('list: both runs of A for March 2031', jsonb_array_length(v_r) = 2, jsonb_array_length(v_r)::text);
  select (e->>'final_net_pay')::numeric into v_x from jsonb_array_elements(v_r) e where e->>'payout_period' = '15th';
  perform pg_temp.p3_ok('list: final net pay includes the adjustment (9420)', v_x = 9420, v_x::text);
  select jsonb_array_length(e->'adjustments') into v_n from jsonb_array_elements(v_r) e where e->>'payout_period' = '15th';
  perform pg_temp.p3_ok('list: adjustment is shown on the run', v_n = 1, v_n::text);
  select count(*) into v_n from public.audit_logs where action = 'payroll.adjust';
  perform pg_temp.p3_ok('adjustment: audit log written', v_n >= 1, v_n::text);

  -- ---- who may do what ----
  update public.shop_members set role = 'manager' where shop_id = v_shop and user_id = v_admin;
  perform pg_temp.p3_expect('manager cannot preview payroll', $q$select public.preview_payroll('T3-A','2031-03','15th')$q$, '%administrator%');
  perform pg_temp.p3_expect('manager cannot process payroll', $q$select public.process_payroll_run('T3-B','2031-03','30th')$q$, '%administrator%');
  perform pg_temp.p3_expect('manager cannot adjust payroll', format($q$select public.add_payroll_adjustment(%L,10,'manager try')$q$, v_run), '%administrator%');
  perform pg_temp.p3_expect('manager cannot list payroll', $q$select public.list_payroll_runs()$q$, '%administrator%');
  execute 'set local role authenticated';
  begin select count(*) into v_n from public.payroll_runs; exception when others then v_n := -1; end;
  reset role;
  perform pg_temp.p3_ok('manager sees no payroll rows (row-level security)', v_n = 0, v_n::text);
  update public.shop_members set role = 'admin' where shop_id = v_shop and user_id = v_admin;

  execute 'set local role authenticated';
  begin select count(*) into v_n from public.payroll_runs; exception when others then v_n := -1; end;
  v_err := null;
  begin insert into public.payroll_runs(shop_id) values (v_shop); exception when others then v_err := sqlstate; end;
  reset role;
  perform pg_temp.p3_ok('admin can read payroll rows directly', v_n >= 3, v_n::text);
  perform pg_temp.p3_ok('nobody can insert payroll rows directly (permission denied)', v_err = '42501', v_err);

  execute 'set local role authenticated';
  v_err := null;
  begin perform public.payroll_calc(v_shop, 'T3-A', '2031-03', '15th'); exception when others then v_err := sqlstate; end;
  reset role;
  perform pg_temp.p3_ok('internal calculator is not callable by signed-in users', v_err = '42501', v_err);

  perform pg_temp.p3_as('11111111-1111-1111-1111-111111111111'::uuid);
  perform pg_temp.p3_expect('unknown user has no shop membership', $q$select public.preview_payroll('T3-A','2031-03','15th')$q$, '%membership%');
  perform pg_temp.p3_as(v_admin);

  select count(*) into v_n from public.v_deduction_integrity_problems;
  perform pg_temp.p3_ok('deduction integrity view reports 0 problems', v_n = 0, v_n::text);

  -- ---- verdict (always raises, so everything rolls back) ----
  select count(*) filter (where not ok), count(*) into v_fail, v_total from p3_res;
  if v_fail > 0 then
    select string_agg(format('[%s] %s (%s)', n, name, coalesce(detail,'')), E'\n' order by n) into v_list from p3_res where not ok;
    raise exception E'% OF % CHECKS FAILED:\n%', v_fail, v_total, v_list;
  end if;
  raise exception 'ALL % CHECKS PASSED (all test data rolled back)', v_total;
end $do$;
