---
name: code-reviewer
description: Review local changes or GitHub PRs using Sona's code-review workflow. Use when the user asks to review code, review a PR, run the Sona code reviewer, reconcile PR comments, or check changes against project CLAUDE.md/AGENTS.md/REVIEW.md/CONTRIBUTING.md conventions. Auto-detects local vs PR mode when possible.
metadata:
  short-description: Sona code review workflow
---

# Sona Code Reviewer

Use this skill to review code changes with the Sona reviewer contract. It is adapted from the Sona marketplace Claude `code-reviewer` agent. Preserve the same review standards, but follow Codex tool rules: do not spawn subagents unless the user explicitly asks for delegated or parallel agent work.

## Core Contract

- Identify the work as a Sona code review.
- Review only the relevant diff, not unrelated worktree noise.
- Read project convention files before judging compliance: `CLAUDE.md`, `.claude/CLAUDE.md`, `AGENTS.md`, `REVIEW.md`, and `CONTRIBUTING.md` or `.github/CONTRIBUTING.md` when present.
- Do not apply private/global user instructions as review criteria. Only use repo-local convention files plus objective correctness, security, reliability, and test risk.
- Findings require confidence >= 80.
- Classify findings:
  - `Normal`: confidence 91-100, should be fixed before merge.
  - `Nit`: confidence 80-90, worth fixing but not blocking.
  - `Pre-existing`: real issue not introduced by this diff.
- Lead with findings. If there are no issues, say so clearly and mention residual test/risk limits.
- Never approve, request changes, or block a PR on behalf of the human. In GitHub review mode, use review event `COMMENT`.

## Mode Detection

1. If the user specifies `review pr #N`, use PR mode for that PR.
2. Otherwise, if `gh` is installed and authenticated, check whether the current branch has an open PR with `gh pr view --json number -q '.number'`.
3. If a PR exists, use PR mode. If not, use local mode.
4. If `gh` is missing or unauthenticated, use local mode unless the user explicitly requested a PR review, in which case report the blocker.

Local mode reviews the branch diff against the default remote base (`origin/HEAD`, then `origin/main`, `origin/master`, `origin/develop`, `origin/trunk`, `origin/next`). If the user explicitly asks to include staged or unstaged changes, include them and state that scope.

PR mode reviews the PR diff from GitHub, reads the PR title/body, and fetches existing review comments for deduplication and reconciliation.

## Preflight

Run these checks early:

```bash
if command -v gh >/dev/null 2>&1; then
  gh auth token >/dev/null 2>&1 && echo GH_AUTHED || echo GH_UNAUTHED
  command -v jq >/dev/null 2>&1 && echo JQ_AVAILABLE || echo JQ_MISSING
else
  echo GH_MISSING
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
echo "REPO_ROOT=$REPO_ROOT"
test -f "$REPO_ROOT/CLAUDE.md" && echo CLAUDE_MD=root || echo CLAUDE_MD=missing
test -f "$REPO_ROOT/.claude/CLAUDE.md" && echo DOTCLAUDE_MD=found || echo DOTCLAUDE_MD=missing
test -f "$REPO_ROOT/AGENTS.md" && echo AGENTS_MD=found || echo AGENTS_MD=missing
test -f "$REPO_ROOT/REVIEW.md" && echo REVIEW_MD=found || echo REVIEW_MD=missing
```

If `jq` is missing in PR mode, inline comments are unavailable; fall back to one PR conversation comment if posting.

## Diff Scope

Skip noise unless the user asks otherwise:

- Lock files: `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `Gemfile.lock`, `composer.lock`, `Cargo.lock`, `poetry.lock`, `Pipfile.lock`, `go.sum`, `flake.lock`, `pubspec.lock`, `packages.lock.json`.
- Generated/build/vendor/minified files: `*.gen.*`, `*.generated.*`, `*.pb.*`, `dist/**`, `build/**`, `.next/**`, `out/**`, `target/**`, `_build/**`, `vendor/**`, `third_party/**`, `node_modules/**`, `*.min.js`, `*.min.css`, `*.map`.
- Binary assets: snapshots, images, fonts, PDFs.
- IDE/tool noise: `.idea/**`, `.vscode/**`, `*.DS_Store`.

Never skip hand-written migration/data-migration files, convention files, or files explicitly referenced by convention files. If `REVIEW.md` contains a `## Skip` section, apply those repo-specific exclusions too.

## Review Lenses

First build a short comprehension note:

- What changed and why.
- Main data/control flow.
- Contracts or schemas touched.
- External effects: database, network, jobs, permissions, deployment.
- Tests added or changed.
- Specific strengths that reduce risk.

Then review through these lenses. With no explicit delegation request, do this yourself and keep notes concise. If the user explicitly asks for parallel agents, delegate bounded lenses in parallel and merge results.

- Conventions: violations of repo-local `CLAUDE.md`, `AGENTS.md`, `REVIEW.md`, or `CONTRIBUTING.md`.
- Bugs: wrong behavior, broken edge cases, bad assumptions, data loss, incorrect migrations.
- Security: authorization, tenant isolation, secrets, injection, unsafe external input paths.
- Silent failures: swallowed errors, ignored failed writes, fire-and-forget work, partial success reported as success.
- Tests: missing coverage for new logic, weak assertions, mutation-surviving tests.
- Deployment: migration order, rollback, config/env, background job compatibility, operational blast radius.
- Cross-file impact: changed contracts and every caller/reader/writer of those contracts.
- Adversarial scenarios: concurrency, idempotency, retries, nil/empty/extreme inputs, partial failure.
- Code health: needless complexity, dependency direction issues, overly broad abstractions.
- Flaky tests: timing, async races, order dependence, external service coupling.

## Existing PR Comments

In PR mode, fetch existing inline comments, conversation comments, and review bodies. Reconcile them before posting:

- If an existing comment raises a code issue and you are >=80 confident it is correct, reply agreeing with evidence.
- If you are >=80 confident it is wrong, reply disagreeing with specific code or convention evidence.
- If confidence is below 80, do not reply.
- If a comment already has a `<!-- code-reviewer-bot -->` reply, do not duplicate.
- If a finding is already covered by an existing comment, do not repost it as a new finding.

When posting replies or comments, include:

```markdown
<!-- code-reviewer-bot -->
```

For generated public comments, include a short visible note that the comment was generated by code-reviewer and should be reviewed before acting.

## Output

Local mode format:

```markdown
## Sona Code Review Report

Branch: <branch>
Base: <base>
Changed files: <count>
Files reviewed: <count>

### Normal Issues

[file path, ~line N] | <category> | confidence: <N>
<specific explanation>

Fix prompt:
> <self-contained prompt>

### Nit Issues

...

### Pre-existing Issues

...

### Strengths

...

### Summary

Normal: <N>
Nit: <N>
Pre-existing: <N>
Assessment: PASS / WARN / FAIL
```

Omit empty sections except the summary. Use `PASS` for no issues, `WARN` for nit-only issues, and `FAIL` when there is at least one normal issue. Pre-existing issues do not affect the assessment.

PR mode:

- Prefer a single GitHub review with inline comments for exact diff lines.
- Use review event `COMMENT`.
- Use body-only findings for unmappable issues such as test gaps, deployment risk, and pre-existing issues.
- If there are no issues and no replies, post a short clean confirmation unless an earlier watermarked clean confirmation already exists.

## Fix Prompt Rules

Every fix prompt must be self-contained enough for another agent to apply without reading the review context:

- Repo-relative file path.
- Function/class/block anchor.
- Approximate line number with a note that lines may have shifted.
- Verbatim current code or unique text to find.
- Desired change.
- Why the change is needed.
- Scope guard: `Do not make other changes.`

Prefer GitHub suggestion blocks only for exact contiguous replacements where the current line content and replacement are known. Otherwise use a fix prompt.

## Posting Mechanics

Use `gh api` plus `jq` for inline review comments when available. Use `gh pr comment --body-file` for fallback single-comment output. Rate-limit public write calls with about one second between posts.

Always deduplicate before posting. The watermark `<!-- code-reviewer-bot -->` is mandatory in every generated PR review body, inline comment, reply, and clean confirmation.
