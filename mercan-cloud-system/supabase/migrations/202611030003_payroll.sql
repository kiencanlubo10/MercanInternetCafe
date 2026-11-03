-- Priority 3: Payroll
-- One payroll run per employee per payout (15th or 30th) of a salary month.
-- Snapshots basic pay, commission and deductions at processing time.
-- Idempotent and non-destructive. Requires the Priority 1 and 2 migrations.
-- No SSS / PhilHealth / Pag-IBIG / tax lines (owner decision).

-- ---------------------------------------------------------------------------
-- 0. Safety check: Priority 2 must be installed and payroll_run_id must be uuid
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  select data_type into t from information_schema.columns
   where table_schema = 'public' and table_name = 'employee_deductions' and column_name = 'payroll_run_id';
  if t is null then
    raise exception 'Priority 2 is not installed: employee_deductions.payroll_run_id was not found';
  end if;
  if t <> 'uuid' then
    raise exception 'employee_deductions.payroll_run_id is % but this migration expects uuid. Stop and send this message back.', t;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Sequences and tables
-- ---------------------------------------------------------------------------
create sequence if not exists public.payroll_run_ref_seq;
create sequence if not exists public.payroll_adjustment_ref_seq;

create table if not exists public.payroll_runs (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete restrict,
  reference text not null unique,
  employee_ref text not null,
  employee_name text not null,
  salary_month text not null check (salary_month ~ '^\d{4}-(0[1-9]|1[0-2])$'),
  payout_period text not null check (payout_period in ('15th','30th')),
  status text not null default 'processed' check (status in ('processed','voided')),
  paid_on date not null,
  monthly_salary numeric(12,2) not null check (monthly_salary >= 0),
  basic_pay numeric(12,2) not null check (basic_pay >= 0),
  commission_rate numeric(5,2) not null check (commission_rate >= 0 and commission_rate <= 100),
  commission_from date not null,
  commission_to date not null,
  period_gross numeric(14,2) not null,
  period_bills numeric(14,2) not null,
  period_net numeric(14,2) not null,
  commission_amount numeric(12,2) not null check (commission_amount >= 0),
  deductions_total numeric(12,2) not null check (deductions_total >= 0),
  net_pay numeric(12,2) not null check (net_pay >= 0),
  notes text,
  processed_by uuid,
  processed_by_name text,
  processed_at timestamptz not null default now(),
  check (commission_from <= commission_to)
);

-- A voided run (future feature) would free its slot; until then every run is 'processed'.
create unique index if not exists payroll_runs_one_per_payout
  on public.payroll_runs (shop_id, employee_ref, salary_month, payout_period)
  where status = 'processed';
create index if not exists payroll_runs_month_idx on public.payroll_runs (shop_id, salary_month);

create table if not exists public.payroll_run_lines (
  id uuid primary key default gen_random_uuid(),
  payroll_run_id uuid not null references public.payroll_runs(id) on delete restrict,
  line_type text not null check (line_type in ('basic','commission','deduction','deduction_reversal')),
  description text not null,
  amount numeric(12,2) not null,              -- signed: earnings positive, deductions negative
  deduction_id uuid,
  created_at timestamptz not null default now()
);
create index if not exists payroll_run_lines_run_idx on public.payroll_run_lines (payroll_run_id);

create table if not exists public.payroll_adjustments (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete restrict,
  reference text not null unique,
  payroll_run_id uuid not null references public.payroll_runs(id) on delete restrict,
  amount numeric(12,2) not null check (amount <> 0),   -- signed: + adds pay, - reduces pay
  reason text not null check (length(trim(reason)) >= 3),
  created_by uuid,
  created_by_name text,
  created_at timestamptz not null default now()
);
create index if not exists payroll_adjustments_run_idx on public.payroll_adjustments (payroll_run_id);

-- Link deductions to the run that consumed them.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'employee_deductions_payroll_run_fk') then
    alter table public.employee_deductions
      add constraint employee_deductions_payroll_run_fk
      foreign key (payroll_run_id) references public.payroll_runs(id) on delete restrict;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Append-only protection (records are never edited or deleted)
-- ---------------------------------------------------------------------------
drop trigger if exists payroll_runs_append_only on public.payroll_runs;
create trigger payroll_runs_append_only before update or delete on public.payroll_runs
  for each row execute function public.prevent_mutation();
drop trigger if exists payroll_run_lines_append_only on public.payroll_run_lines;
create trigger payroll_run_lines_append_only before update or delete on public.payroll_run_lines
  for each row execute function public.prevent_mutation();
drop trigger if exists payroll_adjustments_append_only on public.payroll_adjustments;
create trigger payroll_adjustments_append_only before update or delete on public.payroll_adjustments
  for each row execute function public.prevent_mutation();

-- A deduction cannot be added to a payout that has already been processed:
-- it would never reach any payslip. Reversals are covered too (a reversal of a
-- locked deduction is already refused by reverse_employee_deduction).
create or replace function public.block_deduction_in_closed_payroll()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.payroll_runs r
              where r.shop_id = new.shop_id and r.employee_ref = new.employee_ref
                and r.salary_month = new.salary_month and r.payout_period = new.payout_period
                and r.status = 'processed') then
    raise exception 'Payroll for this employee, month and payout was already processed. Choose another payout or add a payroll adjustment.';
  end if;
  return new;
end $$;
drop trigger if exists employee_deductions_closed_period on public.employee_deductions;
create trigger employee_deductions_closed_period before insert on public.employee_deductions
  for each row execute function public.block_deduction_in_closed_payroll();

-- ---------------------------------------------------------------------------
-- 3. Security: RLS on, admin-only read, no direct writes
-- ---------------------------------------------------------------------------
alter table public.payroll_runs enable row level security;
alter table public.payroll_run_lines enable row level security;
alter table public.payroll_adjustments enable row level security;

drop policy if exists payroll_runs_admin_read on public.payroll_runs;
create policy payroll_runs_admin_read on public.payroll_runs
  for select to authenticated using (public.is_shop_admin(shop_id));
drop policy if exists payroll_run_lines_admin_read on public.payroll_run_lines;
create policy payroll_run_lines_admin_read on public.payroll_run_lines
  for select to authenticated using (
    exists (select 1 from public.payroll_runs r where r.id = payroll_run_id and public.is_shop_admin(r.shop_id)));
drop policy if exists payroll_adjustments_admin_read on public.payroll_adjustments;
create policy payroll_adjustments_admin_read on public.payroll_adjustments
  for select to authenticated using (public.is_shop_admin(shop_id));

revoke all on public.payroll_runs, public.payroll_run_lines, public.payroll_adjustments from anon, authenticated;
grant select on public.payroll_runs, public.payroll_run_lines, public.payroll_adjustments to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Helpers
-- ---------------------------------------------------------------------------
create or replace function public.payroll_safe_num(p text)
returns numeric language sql immutable as $$
  select case when p ~ '^\s*-?\d+(\.\d+)?\s*$' then trim(p)::numeric else 0 end;
$$;

-- Default commission window for a payout:
--   15th payout -> day 1 to day 15 of the salary month
--   30th payout -> day 16 to the last day of the salary month
create or replace function public.payroll_default_window(p_month text, p_period text)
returns table(w_from date, w_to date) language plpgsql immutable as $$
declare m0 date;
begin
  m0 := (p_month || '-01')::date;
  if p_period = '15th' then
    return query select m0, m0 + 14;
  else
    return query select m0 + 15, (m0 + interval '1 month')::date - 1;
  end if;
end $$;

-- Single source of truth for the numbers. Used by preview and by processing.
create or replace function public.payroll_calc(
  p_shop uuid, p_employee_ref text, p_month text, p_period text,
  p_from date default null, p_to date default null)
returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare
  v_reg public.employee_registry%rowtype;
  v_from date; v_to date;
  v_state jsonb;
  v_gross numeric := 0; v_bills numeric := 0; v_net numeric; v_comm numeric;
  v_basic numeric; v_ded numeric := 0; v_lines jsonb := '[]'::jsonb;
  v_net_pay numeric; v_today date; v_warn jsonb := '[]'::jsonb;
  v_existing text; v_overlap text; d record;
begin
  if p_month is null or p_month !~ '^\d{4}-(0[1-9]|1[0-2])$' then raise exception 'Salary month must look like 2026-11'; end if;
  if p_period not in ('15th','30th') then raise exception 'Payout period must be 15th or 30th'; end if;
  select * into v_reg from public.employee_registry where shop_id = p_shop and employee_ref = p_employee_ref;
  if not found then raise exception 'Employee not found in the payroll registry. Open the Employees page once so the roster syncs.'; end if;

  select w_from, w_to into v_from, v_to from public.payroll_default_window(p_month, p_period);
  v_from := coalesce(p_from, v_from); v_to := coalesce(p_to, v_to);
  if v_from > v_to then raise exception 'Commission period start must not be after its end'; end if;
  if v_to - v_from > 45 then raise exception 'Commission period is longer than 45 days'; end if;

  select state into v_state from public.shop_state where shop_id = p_shop;
  if v_state is not null and jsonb_typeof(v_state->'sales') = 'array' then
    select coalesce(sum(public.payroll_safe_num(s->>'morning') + public.payroll_safe_num(s->>'night')), 0)
      into v_gross
      from jsonb_array_elements(v_state->'sales') s
     where (s->>'date') >= v_from::text and (s->>'date') <= v_to::text;
  end if;
  if v_state is not null and jsonb_typeof(v_state->'expenses') = 'array' then
    select coalesce(sum(public.payroll_safe_num(x->>'amount')), 0)
      into v_bills
      from jsonb_array_elements(v_state->'expenses') x
     where (x->>'date') >= v_from::text and (x->>'date') <= v_to::text;
  end if;
  v_net  := v_gross - v_bills;
  v_comm := round(greatest(0, v_net) * v_reg.commission_rate / 100, 2);
  v_basic := round(v_reg.monthly_salary / 2, 2);

  v_lines := v_lines || jsonb_build_array(jsonb_build_object(
    'line_type','basic','description', 'Basic pay (half of monthly salary)','amount', v_basic));
  v_lines := v_lines || jsonb_build_array(jsonb_build_object(
    'line_type','commission','description',
      format('Commission %s%% of net sales %s to %s', v_reg.commission_rate, v_from, v_to),'amount', v_comm));

  for d in
    select id, reference, kind, amount, note from public.employee_deductions
     where shop_id = p_shop and employee_ref = p_employee_ref and salary_month = p_month
       and payout_period = p_period and payroll_run_id is null
     order by reference
  loop
    if d.kind = 'deduction' then
      v_ded := v_ded + d.amount;
      v_lines := v_lines || jsonb_build_array(jsonb_build_object('line_type','deduction','deduction_id',d.id,
        'description', d.reference || coalesce(' - ' || d.note, ''), 'amount', -d.amount));
    else
      v_ded := v_ded - d.amount;
      v_lines := v_lines || jsonb_build_array(jsonb_build_object('line_type','deduction_reversal','deduction_id',d.id,
        'description', d.reference || ' (reversal)' || coalesce(' - ' || d.note, ''), 'amount', d.amount));
    end if;
  end loop;

  v_net_pay := v_basic + v_comm - v_ded;
  v_today := (now() at time zone 'Asia/Manila')::date;

  select reference into v_existing from public.payroll_runs
   where shop_id = p_shop and employee_ref = p_employee_ref and salary_month = p_month
     and payout_period = p_period and status = 'processed';
  select reference into v_overlap from public.payroll_runs
   where shop_id = p_shop and employee_ref = p_employee_ref and status = 'processed'
     and not (salary_month = p_month and payout_period = p_period)
     and commission_from <= v_to and commission_to >= v_from limit 1;

  if v_to > v_today then
    v_warn := v_warn || to_jsonb('The commission period has not ended yet; sales recorded after payroll is processed will not be paid.'::text);
  end if;
  if v_reg.monthly_salary = 0 then
    v_warn := v_warn || to_jsonb('This employee has a monthly salary of 0.'::text);
  end if;
  if not v_reg.active then
    v_warn := v_warn || to_jsonb('This employee is inactive (removed from the roster).'::text);
  end if;

  return jsonb_build_object(
    'employee_ref', v_reg.employee_ref, 'employee_name', v_reg.name, 'active', v_reg.active,
    'salary_month', p_month, 'payout_period', p_period,
    'monthly_salary', v_reg.monthly_salary, 'basic_pay', v_basic,
    'commission_rate', v_reg.commission_rate, 'commission_from', v_from, 'commission_to', v_to,
    'period_gross', v_gross, 'period_bills', v_bills, 'period_net', v_net,
    'commission_amount', v_comm, 'deductions_total', v_ded, 'net_pay', v_net_pay,
    'lines', v_lines, 'warnings', v_warn,
    'already_processed', v_existing is not null, 'existing_reference', v_existing,
    'overlaps_reference', v_overlap,
    'blocked_reason',
      case when v_existing is not null then format('Payroll %s already exists for this employee, month and payout', v_existing)
           when v_overlap is not null then format('Commission period overlaps payroll %s (commission would be paid twice)', v_overlap)
           when v_net_pay < 0 then format('Deductions (%s) exceed basic pay plus commission (%s). Reverse or reduce deductions first.', v_ded, v_basic + v_comm)
           else null end);
end $$;
revoke all on function public.payroll_calc(uuid,text,text,text,date,date) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Public functions (admin only)
-- ---------------------------------------------------------------------------
create or replace function public.preview_payroll(
  p_employee_ref text, p_salary_month text, p_payout_period text,
  p_commission_from date default null, p_commission_to date default null)
returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare v_shop uuid;
begin
  v_shop := public.require_admin();
  return public.payroll_calc(v_shop, p_employee_ref, p_salary_month, p_payout_period, p_commission_from, p_commission_to);
end $$;

create or replace function public.process_payroll_run(
  p_employee_ref text, p_salary_month text, p_payout_period text,
  p_paid_on date default null, p_commission_from date default null, p_commission_to date default null,
  p_notes text default null, p_expected_net numeric default null)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare
  v_shop uuid; v_calc jsonb; v_run public.payroll_runs%rowtype; v_ref text; ln jsonb; v_ids uuid[];
  v_lines_sum numeric := 0; v_paid_on date;
begin
  v_shop := public.require_admin();
  -- Serialize concurrent runs for the same employee.
  perform 1 from public.employee_registry where shop_id = v_shop and employee_ref = p_employee_ref for update;
  v_calc := public.payroll_calc(v_shop, p_employee_ref, p_salary_month, p_payout_period, p_commission_from, p_commission_to);
  if v_calc->>'blocked_reason' is not null then raise exception '%', v_calc->>'blocked_reason'; end if;
  if p_expected_net is not null and round(p_expected_net, 2) <> (v_calc->>'net_pay')::numeric then
    raise exception 'The figures changed since the preview (now %, was %). Preview again before processing.',
      (v_calc->>'net_pay')::numeric, round(p_expected_net, 2);
  end if;
  v_paid_on := coalesce(p_paid_on, (now() at time zone 'Asia/Manila')::date);
  v_ref := 'PAY-' || to_char(now() at time zone 'Asia/Manila','YYYYMMDD') || '-' ||
           lpad(nextval('public.payroll_run_ref_seq')::text, 5, '0');

  begin
    insert into public.payroll_runs(shop_id, reference, employee_ref, employee_name, salary_month, payout_period,
        paid_on, monthly_salary, basic_pay, commission_rate, commission_from, commission_to,
        period_gross, period_bills, period_net, commission_amount, deductions_total, net_pay,
        notes, processed_by, processed_by_name)
    values (v_shop, v_ref, p_employee_ref, v_calc->>'employee_name', p_salary_month, p_payout_period,
        v_paid_on, (v_calc->>'monthly_salary')::numeric, (v_calc->>'basic_pay')::numeric,
        (v_calc->>'commission_rate')::numeric, (v_calc->>'commission_from')::date, (v_calc->>'commission_to')::date,
        (v_calc->>'period_gross')::numeric, (v_calc->>'period_bills')::numeric, (v_calc->>'period_net')::numeric,
        (v_calc->>'commission_amount')::numeric, (v_calc->>'deductions_total')::numeric, (v_calc->>'net_pay')::numeric,
        nullif(left(trim(coalesce(p_notes,'')),200),''), auth.uid(), public.app_username(auth.uid()))
    returning * into v_run;
  exception when unique_violation then
    raise exception 'Payroll already exists for this employee, month and payout';
  end;

  v_ids := '{}';
  for ln in select * from jsonb_array_elements(v_calc->'lines') loop
    insert into public.payroll_run_lines(payroll_run_id, line_type, description, amount, deduction_id)
    values (v_run.id, ln->>'line_type', ln->>'description', (ln->>'amount')::numeric, nullif(ln->>'deduction_id','')::uuid);
    v_lines_sum := v_lines_sum + (ln->>'amount')::numeric;
    if ln->>'deduction_id' is not null then v_ids := v_ids || (ln->>'deduction_id')::uuid; end if;
  end loop;
  if v_lines_sum <> v_run.net_pay then
    raise exception 'Internal check failed: payroll lines (%) do not add up to net pay (%)', v_lines_sum, v_run.net_pay;
  end if;

  if array_length(v_ids, 1) > 0 then
    update public.employee_deductions set payroll_run_id = v_run.id where id = any(v_ids) and payroll_run_id is null;
  end if;

  perform public.write_audit(v_shop, 'payroll.process',
    format('Processed %s for %s: %s %s payout, net pay %s (basic %s, commission %s, deductions %s)',
      v_ref, v_run.employee_name, p_salary_month, p_payout_period, v_run.net_pay, v_run.basic_pay,
      v_run.commission_amount, v_run.deductions_total),
    'payroll_runs', v_run.id::text,
    jsonb_build_object('net_pay', v_run.net_pay, 'commission_from', v_run.commission_from, 'commission_to', v_run.commission_to));
  return to_jsonb(v_run);
end $$;

create or replace function public.add_payroll_adjustment(p_run_id uuid, p_amount numeric, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare v_shop uuid; v_run public.payroll_runs%rowtype; v_amt numeric(12,2); v_adj public.payroll_adjustments%rowtype;
        v_current numeric; v_ref text;
begin
  v_shop := public.require_admin();
  v_amt := round(coalesce(p_amount, 0), 2);
  if v_amt = 0 then raise exception 'Adjustment amount cannot be zero'; end if;
  if length(trim(coalesce(p_reason,''))) < 3 then raise exception 'A reason is required for a payroll adjustment'; end if;
  select * into v_run from public.payroll_runs where id = p_run_id and shop_id = v_shop for update;
  if not found then raise exception 'Payroll run not found'; end if;
  if v_run.status <> 'processed' then raise exception 'Only processed payroll can be adjusted'; end if;
  select v_run.net_pay + coalesce(sum(amount), 0) into v_current from public.payroll_adjustments where payroll_run_id = v_run.id;
  if v_current + v_amt < 0 then
    raise exception 'This adjustment would make the final net pay negative (currently %)', v_current;
  end if;
  v_ref := 'ADJ-' || to_char(now() at time zone 'Asia/Manila','YYYYMMDD') || '-' ||
           lpad(nextval('public.payroll_adjustment_ref_seq')::text, 5, '0');
  insert into public.payroll_adjustments(shop_id, reference, payroll_run_id, amount, reason, created_by, created_by_name)
  values (v_shop, v_ref, v_run.id, v_amt, left(trim(p_reason),200), auth.uid(), public.app_username(auth.uid()))
  returning * into v_adj;
  perform public.write_audit(v_shop, 'payroll.adjust',
    format('Adjusted %s for %s by %s: %s', v_run.reference, v_run.employee_name, v_amt, left(trim(p_reason),120)),
    'payroll_adjustments', v_adj.id::text, jsonb_build_object('run', v_run.reference, 'amount', v_amt));
  return to_jsonb(v_adj);
end $$;

create or replace function public.list_payroll_runs(
  p_month text default null, p_employee_ref text default null, p_limit integer default 100, p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare v_shop uuid; v_out jsonb;
begin
  v_shop := public.require_admin();
  if p_month is not null and p_month !~ '^\d{4}-(0[1-9]|1[0-2])$' then raise exception 'Invalid month'; end if;
  select coalesce(jsonb_agg(rec order by (rec->>'processed_at') desc), '[]'::jsonb) into v_out from (
    select to_jsonb(r) || jsonb_build_object(
      'adjustments_total', coalesce((select sum(a.amount) from public.payroll_adjustments a where a.payroll_run_id = r.id), 0),
      'final_net_pay', r.net_pay + coalesce((select sum(a.amount) from public.payroll_adjustments a where a.payroll_run_id = r.id), 0),
      'lines', coalesce((select jsonb_agg(jsonb_build_object('line_type', l.line_type, 'description', l.description, 'amount', l.amount)
                          order by l.created_at, l.id) from public.payroll_run_lines l where l.payroll_run_id = r.id), '[]'::jsonb),
      'adjustments', coalesce((select jsonb_agg(jsonb_build_object('reference', a.reference, 'amount', a.amount, 'reason', a.reason,
                          'created_by_name', a.created_by_name, 'created_at', a.created_at) order by a.created_at, a.id)
                          from public.payroll_adjustments a where a.payroll_run_id = r.id), '[]'::jsonb)) as rec
      from public.payroll_runs r
     where r.shop_id = v_shop
       and (p_month is null or r.salary_month = p_month)
       and (p_employee_ref is null or r.employee_ref = p_employee_ref)
     order by r.processed_at desc
     limit greatest(1, least(coalesce(p_limit,100), 500)) offset greatest(0, coalesce(p_offset,0))
  ) q;
  return v_out;
end $$;

-- ---------------------------------------------------------------------------
-- 6. Grants
-- ---------------------------------------------------------------------------
revoke all on function public.preview_payroll(text,text,text,date,date) from public, anon;
revoke all on function public.process_payroll_run(text,text,text,date,date,date,text,numeric) from public, anon;
revoke all on function public.add_payroll_adjustment(uuid,numeric,text) from public, anon;
revoke all on function public.list_payroll_runs(text,text,integer,integer) from public, anon;
grant execute on function public.preview_payroll(text,text,text,date,date) to authenticated;
grant execute on function public.process_payroll_run(text,text,text,date,date,date,text,numeric) to authenticated;
grant execute on function public.add_payroll_adjustment(uuid,numeric,text) to authenticated;
grant execute on function public.list_payroll_runs(text,text,integer,integer) to authenticated;
