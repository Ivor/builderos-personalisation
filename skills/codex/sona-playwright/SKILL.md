---
name: sona-playwright
description: Log in to the local Sona development app with Playwright and verify browser flows. Use when Codex needs to authenticate a customer user or internal admin in Sona at localhost:4000, prepare local auth/permissions/feature flags for a Sona page, navigate to Sona pages with playwright-cli, verify the landing URL/title, or record a Sona browser walkthrough.
---

# Sona Playwright Login

Use this skill for local Sona browser verification. Default to headless `playwright-cli`; pass `--headed` only when the user explicitly asks for a visible browser or a demo recording.

Keep status updates brief while driving the browser. For a simple login verification, the proof is the final URL and page title returned by `playwright-cli run-code`.

## Execution Context

Run commands from the Sona backend root when possible:

```bash
/Users/ivorpaul/code/sona/backend
```

For database setup snippets:

- Prefer a Sona Tidewave `project_eval` tool when it is available and clearly connected to the Sona backend.
- Do not use a Raffy Tidewave MCP server for Sona database setup.
- If Sona Tidewave is unavailable, run the same Elixir code with:

```bash
mix run -e '<ELIXIR_CODE>'
```

Use `playwright-cli` for browser automation. If a session name is needed:

```bash
S=login-$$
```

## Video Recording

If the prompt mentions a video, screencast, demo, walkthrough, or recording, read `references/video-recording.md` before writing commands. Demo recordings require a config file, visible cursor injection, `window.confirm` handling, and wrapped `run-code` checks.

## Choose Login Flow

Use the internal admin flow if the prompt mentions "internal admin" or the target page is under `/internal_admin/`. Read `references/internal-admin.md`.

Use the customer user flow for regular Sona pages such as holidays, shifts, job titles, customer admin pages, HR employee pages, forecast, home, and embedded app pages.

If the prompt mentions a specific employee or an HR sub-page under `/orgs/:org_id/user_management/employees/:employee_id/...`, read `references/hr-pages.md` after the customer setup.

## Customer User Flow

### Step 1: Prepare a Local User

Skip this step when the user provides known-working credentials and only asks to verify login.

Otherwise, run the following as one Sona eval. Replace `<KEYWORD>` with the shortest distinctive page stem, such as `holid`, `job_title`, or `cancellation`. The snippet finds a unique email-auth user, sets password `TestPass1234`, grants broad local access, enables matching feature flags, and returns `{email, org_id}`.

```elixir
import Ecto.Query; alias Backend.Repo
%{rows: [[email, user_id, org_id, ou_id, _ep_id, org_unit_id]]} = Repo.query!("SELECT uas.strategy_key, u.id::text, ou.organisation_id::text, ou.id::text, ep.id::text, (SELECT ogu.id::text FROM org_units ogu WHERE ogu.organisation_id = ou.organisation_id LIMIT 1) FROM users u JOIN organisation_users ou ON ou.user_id = u.id JOIN users_auth_strategies uas ON uas.user_id = u.id AND uas.strategy_type = 1 AND uas.deleted_at IS NULL JOIN employment_periods ep ON ep.organisation_user_id = ou.id WHERE uas.strategy_key IN (SELECT strategy_key FROM users_auth_strategies WHERE strategy_type = 1 AND deleted_at IS NULL GROUP BY strategy_key HAVING count(*) = 1) LIMIT 1")
alias Backend.Accounts.Password
existing = Repo.one(from(p in Password, where: p.user_id == ^user_id))
if existing, do: existing |> Ecto.Changeset.change(%{hashed_password: Bcrypt.hash_pwd_salt("TestPass1234")}) |> Repo.update!(), else: %Password{user_id: user_id, organisation_id: org_id, hashed_password: Bcrypt.hash_pwd_salt("TestPass1234")} |> Repo.insert!()
Repo.get!(Backend.Organisations.OrganisationUser, ou_id) |> Ecto.Changeset.change(%{role: "organisation_admin"}) |> Repo.update!()
Repo.transaction(fn -> Repo.query!("INSERT INTO carbonite_default.transactions (inserted_at, meta) VALUES (now(), '{\"type\": \"dev_setup\"}')"); Repo.get!(Backend.Accounts.User, user_id) |> Ecto.Changeset.change(%{roles: ["organisation_admin", "manager"]}) |> Repo.update!() end)
for p <- ["manager_write_access", "organisation_admin"], do: Backend.AccessPolicies.create_user_access_policy(%{user_id: user_id, organisation_id: org_id, access_policy_internal_identifier: p, org_unit_id: org_unit_id})
try do Backend.Dev.RouteAccess.grant_access!(user_id, "<KEYWORD>") rescue _ -> :ok end
%{rows: fr} = Repo.query!("SELECT column_name FROM information_schema.columns WHERE table_name = 'feature_sets' AND data_type = 'boolean' AND column_name LIKE $1", ["%<KEYWORD>%"])
flags = fr |> List.flatten() |> Enum.map(&{String.to_atom(&1), true})
if flags != [], do: Repo.update_all(from(f in Backend.Organisations.FeatureSet, where: f.organisation_id == ^org_id), set: flags)
{email, org_id}
```

### Step 2: Log In and Navigate

Use the `{email, org_id}` returned above, or the credentials provided by the user. URL patterns:

- Admin pages: `/orgs/<ORG_ID>/admin/<path>`
- Non-admin pages: `/orgs/<ORG_ID>/<path>`

If the path is unclear, use:

```bash
mix phx.routes | rg -i "<keyword>" | head -5
```

Basic login and optional navigation:

```bash
S=login-$$
playwright-cli -s=$S open "http://localhost:4000/users/log_in"
playwright-cli -s=$S run-code "async (page) => { await page.waitForSelector('#user_email', {timeout:5000}); await page.fill('#user_email', '<EMAIL>'); await page.fill('#user_password', '<PASSWORD>'); await Promise.all([page.waitForNavigation({timeout:10000}).catch(()=>{}), page.click('button[type=submit]')]); await page.goto('http://localhost:4000/orgs/<ORG_ID>/<PAGE_PATH>', {waitUntil:'domcontentloaded',timeout:15000}); return page.url() + ' | ' + await page.title(); }"
```

For login-only verification, omit `page.goto(...)` and report the post-submit `page.url()` and title.

Use the body text only to diagnose blockers. Do not treat unrelated post-login widget errors as authentication failures if the URL changed to an authenticated org page.

## Stuck

If login redirects back to `/users/log_in`, report the URL and any visible validation text. If a page shows "Not authorised" after two navigation attempts, stop and report what was tried. Do not spiral into broad source reads unless the browser error requires it.
