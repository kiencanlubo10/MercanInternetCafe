# Mercan Internet Cafe — Cloud Financial Manager

This is the cloud-connected upgrade of the uploaded Computer Shop Financial Manager. It preserves the existing dashboard, daily morning/night cash sales, bills and expenses, employee commission rates, salary payouts, reports, CSV export and JSON backup workflows. It adds Supabase email/password authentication and shared cloud persistence.

## Included

- Supabase Auth sign-in and first-admin registration.
- Shared Mercan Internet Cafe shop with `Asia/Manila` timezone and `PHP` currency.
- Row Level Security so only shop members can read shop records.
- Admin, manager and staff roles. Admin/manager can save; staff is read-only.
- Admin-only **Settings & Backup → Team access** panel to add an existing registered account by email as manager or staff.
- Revision-checked cloud writes. If two managers edit at once, the later conflicting save is rejected rather than silently overwriting the other user's work.
- The app keeps the original financial calculations: gross sales = morning + night; net sales = gross less bills; commissions are based on positive net sales; salary payouts remain tracked separately.

## Setup in Supabase

1. Open your Supabase project.
2. Go to **SQL Editor → New query**.
3. Open `supabase/migrations/202611020001_initial.sql`, copy the entire file, paste it into SQL Editor and click **Run**.
4. Confirm the query completes successfully.

## Configure and run

The `config.js` file in this project already contains the Project URL and the browser-safe Publishable key you supplied. A publishable key is designed to be visible in browser code; never replace it with a secret or `service_role` key.

- Open `index.html` through a static web server, or deploy the project root to Vercel.
- No build command is required; this is a static HTML/CSS/JavaScript app.
- Create the first account in the app. If Supabase email confirmation is enabled, confirm the email, then sign in. The first account that initializes the shop becomes its admin.

## Add team members

1. Each employee/manager creates their own account in the app and confirms their email if required.
2. The admin signs in, opens **Settings & Backup → Team access**, enters the employee's registered email, selects `Staff` or `Manager`, and clicks **Add team member**.
3. The invited user can then sign in and access the shared shop. Staff accounts are read-only; manager accounts can edit records.

## Deploy to Vercel

Import the GitHub repository in Vercel and deploy the project root. This is a static site, so leave the build command empty and use the project root as the output directory. Ensure `config.js` is included in the deployed files.

## Important notes

- If the app finds existing legacy records in the same browser storage, it uses them to initialize the first cloud state. You can also use the JSON restore tool to import a backup.
- The original app's records are stored as one JSONB state document in Supabase to preserve its existing interface. This is a practical first cloud release, not yet a normalized, row-per-transaction accounting ledger.
- Revision checks prevent silent concurrent overwrites, but a conflicting save requires refreshing the app before editing again.
- The first authenticated account to initialize the empty Supabase project becomes the shop admin. Keep access to that email account secure.
- Download periodic JSON backups. Scheduled backups, audit history, granular permissions and normalized transaction tables are suitable next upgrades.
- Do not store passwords, payment card data or other secrets in the shop records.
