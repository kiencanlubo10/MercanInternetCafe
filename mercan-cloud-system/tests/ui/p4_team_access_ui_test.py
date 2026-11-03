"""Playwright UI test for P4 (sessions, Team & Access), against the mock Supabase client.
Run from the project folder:  python3 tests/ui/p4_team_access_ui_test.py
(proves the screens and calls; the SQL rules are proven by supabase/tests/p4_sessions_permissions_test.sql)"""
import os, sys, threading, http.server, socketserver, functools
from playwright.sync_api import sync_playwright

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
MOCK = open(os.path.join(os.path.dirname(__file__), 'mock_supabase_p3.js')).read()
os.environ.setdefault('PLAYWRIGHT_BROWSERS_PATH', '/opt/pw-browsers')
H = functools.partial(http.server.SimpleHTTPRequestHandler, directory=ROOT); H.log_message = lambda *a, **k: None
srv = socketserver.TCPServer(('127.0.0.1', 0), H); PORT = srv.server_address[1]
threading.Thread(target=srv.serve_forever, daemon=True).start()
results = []
def check(name, ok, detail=''):
    results.append((name, bool(ok), detail)); print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else '  -> ' + str(detail)))
def open_page(browser, query, width=1280):
    ctx = browser.new_context(viewport={'width': width, 'height': 900}); page = ctx.new_page(); errors = []
    page.on('pageerror', lambda e: errors.append(str(e)))
    page.on('dialog', lambda d: d.accept())
    page.route('**/cdn.jsdelivr.net/**', lambda r: r.fulfill(status=200, content_type='application/javascript', body=MOCK))
    page.goto(f'http://127.0.0.1:{PORT}/index.html?{query}')
    page.wait_for_function("document.getElementById('mainApp').style.display==='grid'"); page.wait_for_timeout(400)
    return ctx, page, errors
def calls(page, name): return [c for c in page.evaluate('__db.calls') if c['name'] == name]

with sync_playwright() as p:
    b = p.chromium.launch()
    ctx, page, errors = open_page(b, 'role=admin')
    check('session started with a key and device', len(calls(page, 'start_session')) == 1 and len(calls(page, 'start_session')[0]['args']['p_session_key']) >= 8)
    check('permissions loaded at sign-in', len(calls(page, 'my_permissions')) >= 1)
    page.click('button[data-page="settings"]'); page.wait_for_timeout(200)
    check('admin sees the Team & Access card', page.is_visible('#teamControlCard'))
    check('team list shows 2 people', page.locator('#teamList tbody tr').count() == 2, page.locator('#teamList tbody tr').count())
    check('username shown without the internal domain', 'cashier01' in page.inner_text('#teamList') and 'accounts.mercan.invalid' not in page.inner_text('#teamList'))
    check('admin row has no permission boxes or buttons', page.locator('#teamList tbody tr:first-child input').count() == 0 and page.locator('#teamList tbody tr:first-child button').count() == 0)
    check('staff row has 4 permission boxes, all unchecked', page.locator('#teamList tbody tr:nth-child(2) input[data-perm]').count() == 4 and page.locator('#teamList tbody tr:nth-child(2) input:checked').count() == 0)
    check('login history lists the sign-in', 'login' in page.inner_text('#loginList'))
    page.check('#teamList input[data-perm="sales"]'); page.wait_for_timeout(200)
    c = calls(page, 'set_member_permission')
    check('ticking Sales calls set_member_permission(true)', len(c) == 1 and c[0]['args'] == {'p_user': 'u-staff', 'p_permission': 'sales', 'p_allowed': True}, c)
    page.click('button[data-act="revoke"]'); page.wait_for_timeout(200)
    check('Sign out everywhere calls revoke_member_sessions', len(calls(page, 'revoke_member_sessions')) == 1)
    page.click('button[data-act="deactivate"]'); page.wait_for_timeout(200)
    check('Deactivate calls set_member_active(false)', [c['args'] for c in calls(page, 'set_member_active')] == [{'p_user': 'u-staff', 'p_active': False}])
    check('admin page has no read-only lock', not page.evaluate("document.body.classList.contains('read-only')"))
    page.evaluate("document.getElementById('shopName').value='P4 Test Shop';document.getElementById('settingsForm').requestSubmit()"); page.wait_for_timeout(1200)
    check('saves go through save_shop_state_p4', len(calls(page, 'save_shop_state_p4')) >= 1 and len(calls(page, 'save_shop_state')) == 0)
    page.click('#signOutBtn'); page.wait_for_timeout(300)
    check('sign-out ends the session first', len(calls(page, 'end_session')) == 1)
    check('no script errors (admin)', not errors, errors); ctx.close()

    ctx, page, errors = open_page(b, 'role=staff')
    page.click('button[data-page="settings"]'); page.wait_for_timeout(200)
    check('staff does not see the Team & Access card', not page.is_visible('#teamControlCard'))
    check('staff stays read-only', page.evaluate("document.body.classList.contains('read-only')"))
    check('staff makes no save calls', len(calls(page, 'save_shop_state_p4')) == 0)
    check('no script errors (staff)', not errors, errors); ctx.close()

    ctx, page, errors = open_page(b, 'role=manager')
    page.click('button[data-page="settings"]'); page.wait_for_timeout(200)
    check('manager is not read-only and sees no Team & Access', not page.evaluate("document.body.classList.contains('read-only')") and not page.is_visible('#teamControlCard'))
    ctx.close(); b.close()
fails = [r for r in results if not r[1]]
print(f'\n{len(results)-len(fails)}/{len(results)} UI checks passed'); sys.exit(1 if fails else 0)
