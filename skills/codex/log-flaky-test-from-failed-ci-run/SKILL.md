---
name: log-flaky-test-from-failed-ci-run
description: Investigate a failed GitHub Actions CI job for sona-is/sona, verify whether the failure is genuinely flaky, then update an existing TF-board Jira ticket or create a new one. Use when the user provides a failed GitHub Actions job URL and asks to "log a flaky test", "log this flake", "file a flaky", "log this failed CI run as flaky", or similar. Do not use for non-CI failures or for failures without evidence of flakiness.
---

# Log Flaky Test from Failed CI Run

## Core Rule

Never create a Jira ticket unless flakiness is confirmed. A flaky test needs evidence that the same test/job passed after failing, or clear evidence of intermittent failures on recent `master` builds. If the failure looks genuine, already fixed, or unclear, stop and report that instead of filing.

## Inputs

The user should provide a failed GitHub Actions job URL:

```text
https://github.com/sona-is/sona/actions/runs/<RUN_ID>/job/<JOB_ID>
```

If there is no URL, ask for the failed job URL before proceeding.

## Workflow

### 1. Verify Jira Access

Use the available Jira MCP tools before investigating deeply:

- Call `jira_search` with a harmless TF query such as `project = TF ORDER BY created DESC` and `limit: 1`.
- If Jira access fails, tell the user Jira/Atlassian is not authenticated and stop.

### 2. Extract Job Details

Parse the job ID from `/job/<JOB_ID>`.

Fetch the job:

```sh
gh api repos/sona-is/sona/actions/jobs/<JOB_ID> \
  | jq '{id, conclusion, run_id, name, started_at, html_url, run_attempt}'
```

Record:

- `run_id`
- job `name`
- `conclusion`
- `started_at`
- full job URL

### 3. Confirm Flakiness

Check reruns in the same workflow:

```sh
gh api "repos/sona-is/sona/actions/runs/<RUN_ID>/jobs?per_page=100" \
  | jq '.jobs[] | select(.name == "<JOB_NAME>") | {id, name, conclusion, run_attempt, html_url}'
```

Flakiness is confirmed if the same job name has a later `run_attempt` with `"conclusion": "success"`.

If no successful rerun exists, check recent `master` builds for the same workflow:

```sh
gh run list --repo sona-is/sona --branch master --workflow "Backend CI" --limit 5 --json databaseId,conclusion,createdAt
```

If the failure is older than a few days, inspect git history for likely fixes to the failing test or related code:

```sh
git log --oneline --since="<FAILURE_DATE>" -- test/path/to/test_file.exs lib/path/to/related_code.ex | head -10
git show <COMMIT_HASH> --stat
```

Use this decision table:

| Evidence | Action |
|---|---|
| Same job succeeded on a later run attempt | Continue |
| Same test fails intermittently while recent `master` builds pass | Continue |
| A later commit appears to have fixed the failure | Stop; report the fix commit |
| Failure is consistent or clearly caused by the PR | Stop; report it as a real failure |
| Evidence is unclear | Ask the user before filing |

### 4. Extract Failure Details

Prefer annotations:

```sh
gh api repos/sona-is/sona/check-runs/<JOB_ID>/annotations --paginate | jq '.'
```

Look for entries with `"annotation_level": "failure"`.

If annotations are insufficient, fetch logs:

```sh
curl -sL -H "Authorization: token $(gh auth token)" \
  "https://api.github.com/repos/sona-is/sona/actions/jobs/<JOB_ID>/logs" \
  -o /tmp/job-logs.txt

grep -i "failure\\|error\\|assert" /tmp/job-logs.txt | head -50
```

Extract:

- test module
- specific test name
- error type and message
- file and line number
- short relevant stack trace

Ignore noisy secondary symptoms unless they are the root cause:

- `RequestLogger` errors
- `Postgrex.Protocol disconnected`
- broad application warnings unrelated to the assertion/crash

### 5. Search Existing TF Tickets

Search open TF tickets before creating anything:

```jql
project = TF AND text ~ "<TestModuleName>" AND status != Done
```

Use `jira_search` with that JQL. If needed, search again with key error terms.

### 6. Update or Create Jira Ticket

If a matching open ticket exists, update it with `jira_update_issue` by appending an occurrence to the description:

```text
----

h3. Additional Occurrence - <DATE>
[GitHub Actions Job|<full job URL>]

* Re-run attempt <N> succeeded, confirming flakiness
* Error: <brief error summary>
```

If no matching ticket exists, create a TF ticket with `jira_create_issue`:

- project: `TF`
- issue type: usually `Task` unless the TF project requires another type
- summary: `<TestModuleName> - <Brief error description>`

Description:

```text
h3. Failed Job
[GitHub Actions Job|<full job URL>]

h3. Error
{code}
<relevant error and stack trace>
{code}

h3. Test
* Module: <test module>
* Test: <test name if identifiable>
* File: <file:line if available>

h3. Flakiness Evidence
<why this is confirmed flaky, e.g. "Run attempt 2 succeeded for the same job">

h3. Analysis
<brief likely cause or pattern>
```

### 7. Report Back

Tell the user:

- identified failing test
- how flakiness was confirmed
- whether an existing ticket was updated or a new ticket was created
- ticket key/link
- if no ticket was created, why
