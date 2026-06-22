# Internal Admin Login

Internal admin accounts are completely separate from regular users — different table, different login page, different auth.

## Step 1: Find or Create Account (one Sona eval)

This finds an existing internal admin account, or creates one if none exist. Returns `email` for the login step.

Password must be 12+ chars with uppercase, lowercase, and a digit.

```elixir
alias Backend.Repo
account = Repo.one(from(a in "internal_admin_accounts", where: a.enabled == true, select: %{email: a.email}, limit: 1))
if account do
  Repo.query!("UPDATE internal_admin_accounts SET hashed_password = $1 WHERE email = $2", [Bcrypt.hash_pwd_salt("TestPass1234!"), account.email])
  account.email
else
  {:ok, account} = Backend.InternalAdminAccounts.register_internal_admin_account(%{"email" => "dev-admin@sona.test", "password" => "TestPass1234!"})
  Repo.query!("UPDATE internal_admin_accounts SET permissions = $1 WHERE id = $2", [["edit_internal_admin_permissions", "edit_standard_form_templates", "edit_permission_roles", "edit_global_configurations", "edit_protected_feature_flags", "manage_oban_dashboard"], Ecto.UUID.dump!(account.id)])
  account.email
end
```

## Step 2: Log In + Navigate (playwright-cli)

Run headless by default. Pass `--headed` only when the user explicitly asks for a visible browser.

Login URL: `/internal_admin/internal_admin_accounts/log_in`
Form fields: `internal_admin_account[email]`, `internal_admin_account[password]`

```bash
S=login-$$ && playwright-cli -s=$S open "http://localhost:4000/internal_admin/internal_admin_accounts/log_in" && playwright-cli -s=$S run-code "async (page) => { await page.waitForSelector('#login_form', {timeout:5000}); await page.fill('input[name=\"internal_admin_account[email]\"]', '<EMAIL>'); await page.fill('input[name=\"internal_admin_account[password]\"]', 'TestPass1234!'); await Promise.all([page.waitForNavigation({timeout:10000}).catch(()=>{}), page.click('button[type=submit]')]); await page.goto('http://localhost:4000/<PAGE_PATH>', {waitUntil:'domcontentloaded',timeout:15000}); return page.url() + ' | ' + await page.title(); }"
```

## URL Patterns

All internal admin pages are under `/internal_admin/`:

| Category | Path |
|----------|------|
| Dashboard (orgs list) | `/internal_admin/` |
| Organisation details | `/internal_admin/orgs/<ORG_ID>` |
| Org features/flags | `/internal_admin/orgs/<ORG_ID>/features` |
| Org users | `/internal_admin/orgs/<ORG_ID>/users` |
| Org integrations | `/internal_admin/orgs/<ORG_ID>/integrations` |
| Global user search | `/internal_admin/users` |
| Feature flags | `/internal_admin/feature_flags` |
| Data integrity checks | `/internal_admin/checks/data_integrity` |
| Tools | `/internal_admin/tools` |
| Sandboxes | `/internal_admin/tools/sandboxes` |
| Analytics | `/internal_admin/analytics` |
| Payroll audit | `/internal_admin/payroll_audit` |
| Configuration | `/internal_admin/configuration` |
| Admin accounts | `/internal_admin/internal_admin_accounts` |
| Oban dashboard | `/internal_admin/live_dashboard` |

If the path isn't obvious, run `mix phx.routes | grep -i "internal_admin.*<keyword>" | head -5`.

## Impersonation

To impersonate a regular user after logging in as internal admin, use a separate `run-code` call. The impersonation URL triggers a POST-based login that creates a user session, then redirects. The playwright script needs to navigate to the URL and wait for the redirect to settle.

First, find a user to impersonate with a Sona eval:
```elixir
%{rows: [[user_id, org_id]]} = Backend.Repo.query!(
  "SELECT u.id::text, ou.organisation_id::text FROM users u JOIN organisation_users ou ON ou.user_id = u.id LIMIT 1")
{user_id, org_id}
```

Then navigate to the impersonation URL and wait for the redirect to complete:
```bash
playwright-cli -s=$S run-code "async (page) => { await page.goto('http://localhost:4000/internal_admin/users/impersonate/<USER_ID>', {waitUntil:'domcontentloaded',timeout:15000}); await page.waitForTimeout(2000); return page.url() + ' | ' + await page.title(); }"
```

After impersonation succeeds, the browser is now logged in as that user. Navigate to customer pages using the regular URL patterns (e.g., `/orgs/<ORG_ID>/holidays`).

## Permissions

6 available permissions (all granted in the setup code above):
- `edit_internal_admin_permissions` — manage admin accounts
- `edit_standard_form_templates` — edit form templates
- `edit_permission_roles` — edit permission roles
- `edit_global_configurations` — edit global configs
- `edit_protected_feature_flags` — edit protected feature flags
- `manage_oban_dashboard` — access oban/live dashboard

The `run-code` output shows URL and title. That is the proof for the browser step.
