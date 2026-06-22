# HR / User Management Pages

Employee-specific pages under `/orgs/:org_id/user_management/employees/:employee_id/...`

## URL Patterns

```
/orgs/<ORG_ID>/user_management/employees/<EMPLOYEE_OU_ID>/overview
/orgs/<ORG_ID>/user_management/employees/<EMPLOYEE_OU_ID>/holidays
/orgs/<ORG_ID>/user_management/employees/<EMPLOYEE_OU_ID>/absence_management
/orgs/<ORG_ID>/user_management/employees/<EMPLOYEE_OU_ID>/shifts
/orgs/<ORG_ID>/user_management/employees/<EMPLOYEE_OU_ID>/documents
```

Note: the URL uses the employee's **organisation_user ID** (not user ID).

## Auth Layers

HR pages have 3 auth layers beyond the standard setup:

### 1. `assign_employee` on_mount hook
Calls `UserManagement.get_user_profile(current_org, current_user, employee_id)`. This checks that the logged-in user can view the target employee. Requires both users to share an org unit, and the logged-in user must have `administrative_site = true` on their `users_org_units` record.

### 2. Feature flags
- `new_authorization_system` (required)
- `holiday_enabled`, `holiday_v2_enabled` (for holidays tab)
- `absence_management_enabled` (for absence tab)
- `user_management_enabled` (for the HR section itself)

### 3. Permission namespace
Uses `Backend.AccessPolicies.Authorize` with namespace `"user_management"`. The `manager_write_access` access policy from the standard setup covers this.

## Setup Code

Run this as a second Sona eval after the standard Step 1 setup. Replace `<FIRST>`, `<LAST>` with the target employee's name. Modify Step 1's last line to `{email, org_id, ou_id, org_unit_id}` so you have all 4 values.

Important DB details:
- Table is `users_org_units` (NOT `user_org_units`)
- It uses `user_id` column (NOT `organisation_user_id`) — look up user_id from the organisation_users table
- Raw SQL parameters need binary UUIDs via `Ecto.UUID.dump!/1`
- Inserts require a Carbonite transaction wrapper
- No unique constraint on `(user_id, org_unit_id)` — check existence before inserting

```elixir
import Ecto.Query; alias Backend.Repo
org_id = "<ORG_ID>"; login_ou_id = "<LOGIN_OU_ID>"; org_unit_id = "<ORG_UNIT_ID>"

# Find target employee by name
%{rows: [[emp_ou_id, emp_user_id]]} = Repo.query!(
  "SELECT ou.id::text, u.id::text FROM organisation_users ou JOIN users u ON u.id = ou.user_id WHERE u.first_name ILIKE $1 AND u.last_name ILIKE $2 AND ou.organisation_id = $3 LIMIT 1",
  ["<FIRST>", "<LAST>", Ecto.UUID.dump!(org_id)])

# Get logged-in user's user_id from their OU
%{rows: [[login_user_id]]} = Repo.query!(
  "SELECT user_id::text FROM organisation_users WHERE id = $1",
  [Ecto.UUID.dump!(login_ou_id)])

# Ensure both users have users_org_units records (with Carbonite transaction)
Repo.transaction(fn ->
  Repo.query!("INSERT INTO carbonite_default.transactions (inserted_at, meta) VALUES (now(), '{\"type\": \"dev_setup\"}')")
  org_unit_bin = Ecto.UUID.dump!(org_unit_id)
  for {uid, admin} <- [{login_user_id, true}, {emp_user_id, false}] do
    user_bin = Ecto.UUID.dump!(uid)
    %{rows: existing} = Repo.query!("SELECT id FROM users_org_units WHERE user_id = $1 AND org_unit_id = $2", [user_bin, org_unit_bin])
    case existing do
      [] -> Repo.query!("INSERT INTO users_org_units (id, user_id, org_unit_id, administrative_site, inserted_at, updated_at) VALUES (gen_random_uuid(), $1, $2, $3, now(), now())", [user_bin, org_unit_bin, admin])
      _ when admin -> Repo.query!("UPDATE users_org_units SET administrative_site = true WHERE user_id = $1 AND org_unit_id = $2", [user_bin, org_unit_bin])
      _ -> :ok
    end
  end
end)

# Enable HR feature flags
for flag <- ~w(new_authorization_system user_management_enabled holiday_enabled holiday_v2_enabled absence_management_enabled)a do
  Repo.update_all(from(f in Backend.Organisations.FeatureSet, where: f.organisation_id == ^org_id), set: [{flag, true}])
end

emp_ou_id
```

The returned `emp_ou_id` is the employee's organisation_user ID — use it in the URL.
