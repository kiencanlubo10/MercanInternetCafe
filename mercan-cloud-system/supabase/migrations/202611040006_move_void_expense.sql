-- Fix a record entered under the wrong employee: MOVE it to another employee, or VOID it (the safe "delete").
-- Admin only. Nothing is ever erased, so payroll lines and the audit log can always be explained.
--  * Both first reverse every active deduction on the record (normal reversal entries under the old
--    employee). If any deduction is already inside a processed payroll they refuse: use a payroll adjustment.
--  * MOVE: the record goes to the new employee and returns to Pending with the old authorization cleared
--    (a deduction authorization belongs to one employee). Approve it again with the new employee's
--    authorization, then deduct again. Nothing is re-deducted automatically.
--  * VOID: the record becomes Rejected with a "VOIDED: reason" note, no longer counts toward any balance,
--    and stays in the list as "voided". Voiding needs no new status, so existing rules are untouched.
alter table public.employee_expenses add column if not exists voided_at timestamptz;
alter table public.employee_expenses add column if not exists voided_by_name text;

create or replace function public.p5_reverse_active_deductions(p_expense_id uuid, p_why text)
returns integer language plpgsql security definer set search_path = public, auth as $$
declare v_locked text; v_d record; v_n integer := 0;
begin
  select string_agg(d.reference, ', ') into v_locked from public.employee_deductions d
   where d.expense_id = p_expense_id and d.kind = 'deduction' and d.payroll_run_id is not null
     and not exists (select 1 from public.employee_deductions r where r.reverses_id = d.id);
  if v_locked is not null then
    raise exception 'Deduction(s) % are already in a processed payroll. Fix those with a payroll adjustment first.', v_locked;
  end if;
  for v_d in select d.id from public.employee_deductions d
              where d.expense_id = p_expense_id and d.kind = 'deduction'
                and not exists (select 1 from public.employee_deductions r where r.reverses_id = d.id)
              order by d.created_at, d.id
  loop
    perform public.reverse_employee_deduction(v_d.id, left(p_why, 200));
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;
revoke all on function public.p5_reverse_active_deductions(uuid, text) from public, anon, authenticated;

create or replace function public.move_employee_expense(p_expense_id uuid, p_new_employee_ref text, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare v_shop uuid; v_old public.employee_expenses%rowtype; v_new public.employee_expenses%rowtype;
        v_emp public.employee_registry%rowtype; v_n integer;
begin
  v_shop := public.require_admin();
  if length(trim(coalesce(p_reason,''))) < 3 then raise exception 'A reason is required to move a record'; end if;
  select * into v_old from public.employee_expenses where id = p_expense_id and shop_id = v_shop for update;
  if not found then raise exception 'Expense not found'; end if;
  if v_old.approval_status = 'rejected' then raise exception 'Rejected or voided records cannot be moved'; end if;
  select * into v_emp from public.employee_registry where shop_id = v_shop and employee_ref = p_new_employee_ref;
  if not found then raise exception 'Employee not found. Open the Employees page once so the roster can sync.'; end if;
  if not v_emp.active then raise exception 'This employee is no longer on the active roster'; end if;
  if v_emp.employee_ref = v_old.employee_ref then raise exception 'Choose a different employee'; end if;

  v_n := public.p5_reverse_active_deductions(v_old.id, 'Moved to ' || v_emp.name || ': ' || trim(p_reason));
  update public.employee_expenses set
      employee_ref = v_emp.employee_ref, employee_name = v_emp.name,
      approval_status = 'pending', decided_by = null, decided_by_name = null, decided_at = null,
      decision_note = null, authorization_note = null,
      edited_at = now(), edited_by_name = public.app_username(auth.uid())
   where id = v_old.id returning * into v_new;
  perform public.write_audit(v_shop, 'expense.move',
     format('Moved %s from %s to %s: %s', v_old.reference, v_old.employee_name, v_emp.name, left(trim(p_reason),120)),
     'employee_expenses', v_old.id::text,
     jsonb_build_object('reason', left(trim(p_reason),200), 'from', v_old.employee_name, 'to', v_emp.name,
                        'deductions_reversed', v_n, 'was_status', v_old.approval_status));
  return to_jsonb(v_new) || jsonb_build_object('deductions_reversed', v_n);
end $$;

create or replace function public.void_employee_expense(p_expense_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare v_shop uuid; v_old public.employee_expenses%rowtype; v_new public.employee_expenses%rowtype; v_n integer;
begin
  v_shop := public.require_admin();
  if length(trim(coalesce(p_reason,''))) < 3 then raise exception 'A reason is required to void a record'; end if;
  select * into v_old from public.employee_expenses where id = p_expense_id and shop_id = v_shop for update;
  if not found then raise exception 'Expense not found'; end if;
  if v_old.approval_status = 'rejected' then raise exception 'This record is already rejected or voided and has no effect on pay'; end if;

  v_n := public.p5_reverse_active_deductions(v_old.id, 'Voided: ' || trim(p_reason));
  update public.employee_expenses set
      approval_status = 'rejected', decided_by = auth.uid(), decided_by_name = public.app_username(auth.uid()),
      decided_at = now(), decision_note = left('VOIDED: ' || trim(p_reason), 200), authorization_note = null,
      voided_at = now(), voided_by_name = public.app_username(auth.uid())
   where id = v_old.id returning * into v_new;
  perform public.write_audit(v_shop, 'expense.void',
     format('Voided %s (%s, %s): %s', v_old.reference, v_old.employee_name, v_old.amount, left(trim(p_reason),120)),
     'employee_expenses', v_old.id::text,
     jsonb_build_object('reason', left(trim(p_reason),200), 'amount', v_old.amount, 'deductions_reversed', v_n, 'was_status', v_old.approval_status));
  return to_jsonb(v_new) || jsonb_build_object('deductions_reversed', v_n);
end $$;

revoke all on function public.move_employee_expense(uuid, text, text) from public, anon;
revoke all on function public.void_employee_expense(uuid, text) from public, anon;
grant execute on function public.move_employee_expense(uuid, text, text) to authenticated;
grant execute on function public.void_employee_expense(uuid, text) to authenticated;
