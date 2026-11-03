"""Playwright UI test for the Payroll Runs screen, against the mock Supabase client.
Run from the project folder:  python3 tests/ui/p3_payroll_ui_test.py
(proves the screens; the SQL rules are proven by supabase/tests/p3_payroll_test.sql)"""
import os, sys, threading, http.server, socketserver, functools, re
from playwright.sync_api import sync_playwright

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
MOCK = open(os.path.join(os.path.dirname(__file__), 'mock_supabase_p3.js')).read()
os.environ.setdefault('PLAYWRIGHT_BROWSERS_PATH', '/opt/pw-browsers')

H = functools.partial(http.server.SimpleHTTPRequestHandler, directory=ROOT)
H.log_message = lambda *a, **k: None
srv = socketserver.TCPServer(('127.0.0.1', 0), H)
PORT = srv.server_address[1]
threading.Thread(target=srv.serve_forever, daemon=True).start()

results = []
def check(name, ok, detail=''):
    results.append((name, bool(ok), detail))
    print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else '  -> ' + str(detail)))

def open_page(browser, query='role=admin', width=1280):
    ctx = browser.new_context(viewport={'width': width, 'height': 900})
    page = ctx.new_page()
    errors = []
    page.on('pageerror', lambda e: errors.append(str(e)))
    page.on('console', lambda m: errors.append(m.text) if m.type == 'error' and 'Failed to load resource' not in m.text else None)
    page.route('**/cdn.jsdelivr.net/**', lambda r: r.fulfill(status=200, content_type='application/javascript', body=MOCK))
    page.goto(f'http://127.0.0.1:{PORT}/index.html?{query}')
    page.wait_for_function("document.getElementById('mainApp').style.display==='grid'")
    page.wait_for_timeout(300)
    return ctx, page, errors

def goto_payruns(page):
    page.click('#navPayruns')
    page.wait_for_selector('#prStatus table')

with sync_playwright() as p:
    browser = p.chromium.launch()

    # ---------- admin flow ----------
    ctx, page, errors = open_page(browser)
    check('admin sees the Payroll Runs menu item', page.is_visible('#navPayruns'))
    goto_payruns(page)
    check('page title is Payroll runs', page.inner_text('#pageTitle') == 'Payroll Runs')
    check('both employees listed in the form', page.eval_on_selector_all('#prEmp option', 'o=>o.map(x=>x.textContent)') == ['Alpha Cruz', 'Bravo Reyes'])
    check('status grid shows 4 "Not processed" cells', page.locator('#prStatus .pill.unpaid').count() == 4)
    check('history starts empty', 'No records found' in page.inner_text('#prRuns'))

    page.select_option('#prEmp', 'emp-a'); page.fill('#prMonth', '2026-10'); page.select_option('#prPeriod', '15th')
    page.click('#prPreviewBtn'); page.wait_for_selector('#prPreview table')
    txt = page.inner_text('#prPreview')
    check('preview shows commission period 2026-10-01 to 2026-10-15', '2026-10-01 to 2026-10-15' in txt, txt[:200])
    check('preview shows net pay ₱9,160.00', '₱9,160.00' in txt, txt)
    check('preview lists 3 lines (basic, commission, deduction)', page.locator('#prPreview tbody tr').count() == 3)
    check('deduction line is shown negative', '−₱1,000.00' in txt)
    check('Process button is offered', page.is_visible('#prProcessBtn'))
    check('preview wrote nothing', len(page.evaluate('__db.runs')) == 0)

    page.select_option('#prPeriod', '30th')
    check('changing an input clears the preview', page.inner_html('#prPreview').strip() == '')
    page.select_option('#prPeriod', '15th')
    page.click('#prPreviewBtn'); page.wait_for_selector('#prProcessBtn')
    page.click('#prProcessBtn'); page.wait_for_selector('#fmForm')
    check('confirm dialog shows the net pay', '₱9,160.00' in page.inner_text('.modal'))
    page.fill('input[name=paid]', '2026-10-15'); page.fill('input[name=notes]', 'UI test')
    page.click('#fmSubmit'); page.wait_for_selector('#prNotice:not(.hidden)')
    check('success notice names the PAY reference', re.search(r'PAY-\d{8}-\d{5}', page.inner_text('#prNotice')) is not None, page.inner_text('#prNotice'))
    call = [c for c in page.evaluate('__db.calls') if c['name'] == 'process_payroll_run'][0]['args']
    check('process call carries the previewed net pay for the stale-figures guard', call['p_expected_net'] == 9160 and call['p_paid_on'] == '2026-10-15', call)
    page.wait_for_timeout(300)
    check('status grid now shows 15th processed for the month', page.locator('#prStatus .pill.paid').count() == 1)
    check('history has one row with final net ₱9,160.00', page.locator('#prRuns tbody tr').count() == 1 and '₱9,160.00' in page.inner_text('#prRuns'))
    check('stats show 1 payroll run', page.inner_text('#prStats').startswith('Payroll runs') and '\n1\n' in '\n' + page.inner_text('#prStats'))
    check('deduction was locked to the run', page.evaluate("__db.deductions.find(d=>d.id==='d1').run") is not None)

    page.click('#prPreviewBtn'); page.wait_for_selector('#prPreview .note')
    check('second preview for the same payout is blocked', 'already exists' in page.inner_text('#prPreview') and not page.is_visible('#prProcessBtn'))

    page.select_option('#prEmp', 'emp-b'); page.select_option('#prPeriod', '30th')
    page.click('#prPreviewBtn'); page.wait_for_selector('#prPreview .note')
    check('negative net pay is blocked with a clear reason', 'exceed basic pay' in page.inner_text('#prPreview') and not page.is_visible('#prProcessBtn'), page.inner_text('#prPreview'))

    page.click('#prRuns button:has-text("Details")'); page.wait_for_selector('.modal')
    d = page.inner_text('.modal')
    check('details modal shows payslip lines and commission snapshot', 'Basic pay' in d and 'Commission 10%' in d and 'gross ₱2,000.00' in d, d[:300])
    page.click('#prClose')
    check('details modal closes', page.locator('.modal').count() == 0)

    page.click('#prRuns button:has-text("Adjust")'); page.wait_for_selector('#fmForm')
    page.fill('input[name=amt]', '-99999'); page.fill('textarea[name=why]', 'too big')
    page.click('#fmSubmit'); page.wait_for_function("document.getElementById('fmError').textContent.length>0")
    check('rejected adjustment shows the database message inside the dialog', 'negative' in page.inner_text('#fmError'), page.inner_text('#fmError'))
    page.fill('input[name=amt]', '250'); page.fill('textarea[name=why]', 'Bonus correction')
    page.click('#fmSubmit'); page.wait_for_function("document.getElementById('prNotice').textContent.includes('ADJ-')")
    page.wait_for_timeout(300)
    check('adjustment updates the final net pay to ₱9,410.00', '₱9,410.00' in page.inner_text('#prRuns'), page.inner_text('#prRuns')[:300])
    check('adjustment shown as +₱250.00', '+₱250.00' in page.inner_text('#prRuns'))

    page.fill('#prFMonth', '2026-09'); page.dispatch_event('#prFMonth', 'change'); page.wait_for_timeout(300)
    check('history month filter hides other months', 'No records found' in page.inner_text('#prRuns'))
    page.click('#prAllMonths'); page.wait_for_timeout(300)
    check('"All months" shows the run again', page.locator('#prRuns tbody tr').count() == 1)

    # original pages still render
    for pg in ['dashboard', 'sales', 'expenses', 'employees', 'payroll', 'reports', 'settings']:
        page.click(f'#nav button[data-page={pg}]')
    check('all original pages still open without errors', not errors, errors)
    ctx.close()

    # ---------- setup message when the migration is missing ----------
    ctx, page, errors = open_page(browser, 'role=admin&missing=1')
    page.click('#navPayruns'); page.wait_for_selector('#prSetup:not(.hidden)')
    check('missing migration shows a "Setup needed" message', 'Setup needed' in page.inner_text('#prSetup') and '202611030003_payroll.sql' in page.inner_text('#prSetup'))
    ctx.close()

    # ---------- staff ----------
    ctx, page, errors = open_page(browser, 'role=staff')
    check('staff does not see the Payroll Runs menu item', not page.is_visible('#navPayruns'))
    page.evaluate("go('payruns')"); page.wait_for_selector('#prSetup:not(.hidden)')
    check('staff opening the page directly is told it is admin-only', 'administrator' in page.inner_text('#prSetup'))
    ctx.close()

    # ---------- phone layout ----------
    ctx, page, errors = open_page(browser, 'role=admin', width=390)
    goto_payruns(page)
    page.select_option('#prEmp', 'emp-a'); page.fill('#prMonth', '2026-10')
    page.click('#prPreviewBtn'); page.wait_for_selector('#prPreview table')
    sw = page.evaluate('document.documentElement.scrollWidth'); iw = page.evaluate('window.innerWidth')
    check('no sideways page scroll on a 390px phone', sw <= iw + 1, f'{sw} > {iw}')
    ctx.close()
    browser.close()

fails = [r for r in results if not r[1]]
print(f'\n{len(results)-len(fails)}/{len(results)} UI checks passed')
sys.exit(1 if fails else 0)
