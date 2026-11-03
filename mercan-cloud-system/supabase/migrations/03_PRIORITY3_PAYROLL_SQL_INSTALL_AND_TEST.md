# Priority 3 — Payroll (database part): install and test

Status: SQL written and reviewed by reading only. NOT yet run. The payroll screen (UI) is built after this passes.

## Run order (Supabase → SQL Editor, one file at a time)
1. `supabase/migrations/202611030003_payroll.sql` — expect "Success. No rows returned".
2. `supabase/tests/p3_payroll_test.sql` — expect the red error line:
   `ALL 66 CHECKS PASSED (all test data rolled back)`.
   Any other message lists the failed checks: send it back unchanged.
   The test creates fake employees T3-A / T3-B and fake March 2031 sales, then rolls everything back.

## What the migration adds
- Tables: `payroll_runs`, `payroll_run_lines`, `payroll_adjustments` (append-only, admin-only read, no direct writes).
- Functions (admin only): `preview_payroll`, `process_payroll_run`, `add_payroll_adjustment`, `list_payroll_runs`.
- A trigger that refuses new deductions for a payout that is already processed.
- `employee_deductions.payroll_run_id` now points to the payroll run that consumed the deduction.

## Rules built in
- One processed run per employee + salary month + payout (15th or 30th).
- Basic pay = monthly salary / 2. No SSS, PhilHealth, Pag-IBIG or tax.
- Commission = max(0, net sales after bills in the commission period) x employee rate. It is calculated on the server from the saved shop data and frozen in the run.
- Deductions: all unlinked deductions (and reversals) for that employee, month and payout are included and locked.
- Net pay = basic + commission - deductions. If this is negative the run is refused.
- Corrections after processing are new signed adjustments, never edits.

## Assumption to confirm
The commission period for each payout: 15th payout = days 1-15 of the salary month, 30th payout = day 16 to month end. The preview lets you override the dates. Tell me if you want a different rule (for example whole-month commission paid on the 30th).
