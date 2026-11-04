-- Edit advances / expense records (admin only, same as add / approve / deduct / reverse).
-- Rules:
--  * Editable: category, amount, description, date. The employee cannot be changed (reject and re-enter instead).
--  * Rejected records cannot be edited. Records with any deduction applied cannot be edited
--    (reverse the deduction first; deductions locked by a processed payroll stay locked).
--  * Changing the AMOUNT of an approved record sends it back to Pending (authorization cleared),
--    so the new amount is approved again. Other edits keep the approval.
--  * A reason is required. Before/after values go to the audit log; the row shows who edited it and when.
alter table public.employee_expenses add column if not exists edited_at timestamptz;
alter table public.employee_expenses add column if not exists edited_by_name text;

create or replace function public.edit_employee_expense(
  p_expense_id uuid, p_category text, p_amount numeric, p_description text,
  p_occurred_at timestamptz, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare
  v_shop uuid; v_old public.employee_expenses%rowtype; v_new public.employee_expenses%rowtype;
  v_cat text; v_amt numeric(12,2); v_desc text; v_when timestamptz; v_reset boolean;
begin
  v_shop := public.require_admin();
  if length(trim(coalesce(p_reason,''))) < 3 then raise exception 'A reason is required to edit a record'; end if;
  select * into v_old from public.employee_expenses where id = p_expense_id and shop_id = v_shop for update;
  if not found then raise exception 'Expense not found'; end if;
  if v_old.approval_status = 'rejected' then
    raise exception 'Rejected records cannot be edited. Record a new expense instead.';
  end if;
  if v_old.deducted_amount > 0 then
    raise exception '% has % already deducted. Reverse the deductions first, then edit.', v_old.reference, v_old.deducted_amount;
  end if;

  v_cat  := coalesce(p_category, v_old.category);
  v_amt  := round(coalesce(p_amount, v_old.amount), 2);
  v_desc := left(trim(coalesce(p_description, v_old.description)), 300);
  v_when := coalesce(p_occurred_at, v_old.occurred_at);
  if v_cat not in ('Cash Advance','Personal Borrowing','Emergency Advance','Other Employee Expenses') then
    raise exception 'Choose a valid expense category';
  end if;
  if v_amt <= 0 then raise exception 'Amount must be greater than zero'; end if;
  if length(v_desc) = 0 then raise exception 'A description or reason is required'; end if;
  if p_occurred_at is not null and p_occurred_at > now() + interval '1 day' then
    raise exception 'The date cannot be in the future';
  end if;
  if v_cat = v_old.category and v_amt = v_old.amount and v_desc = v_old.description and v_when = v_old.occurred_at then
    raise exception 'Nothing was changed';
  end if;

  v_reset := v_old.approval_status = 'approved' and v_amt <> v_old.amount;
  update public.employee_expenses set
      category = v_cat, amount = v_amt, description = v_desc, occurred_at = v_when,
      edited_at = now(), edited_by_name = public.app_username(auth.uid()),
      approval_status = case when v_reset then 'pending' else approval_status end,
      decided_by = case when v_reset then null else decided_by end,
      decided_by_name = case when v_reset then null else decided_by_name end,
      decided_at = case when v_reset then null else decided_at end,
      decision_note = case when v_reset then null else decision_note end,
      authorization_note = case when v_reset then null else authorization_note end
   where id = v_old.id returning * into v_new;

  perform public.write_audit(v_shop, 'expense.edit',
     format('Edited %s (%s): %s', v_old.reference, v_old.employee_name, left(trim(p_reason),120)),
     'employee_expenses', v_old.id::text,
     jsonb_build_object('reason', left(trim(p_reason),200), 'approval_reset', v_reset,
       'before', jsonb_build_object('category', v_old.category, 'amount', v_old.amount, 'description', v_old.description,
                                    'occurred_at', v_old.occurred_at, 'approval_status', v_old.approval_status),
       'after',  jsonb_build_object('category', v_new.category, 'amount', v_new.amount, 'description', v_new.description,
                                    'occurred_at', v_new.occurred_at, 'approval_status', v_new.approval_status)));
  return to_jsonb(v_new) || jsonb_build_object('approval_reset', v_reset);
end $$;

revoke all on function public.edit_employee_expense(uuid, text, numeric, text, timestamptz, text) from public, anon;
grant execute on function public.edit_employee_expense(uuid, text, numeric, text, timestamptz, text) to authenticated;
