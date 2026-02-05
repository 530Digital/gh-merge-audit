# gh-merge-audit

A Bash script that generates SOC2-style audit reports for merged GitHub pull requests. For each PR merged within a date range, it extracts the merge date, commit subject, author, code-review approvers, and issue-tracker ticket, then writes CSV and XLSX reports.

## Prerequisites

**Required:**

| Tool | Purpose | Install |
|------|---------|---------|
| [gh](https://cli.github.com/) | GitHub API access | `brew install gh` |
| [jq](https://jqlang.github.io/jq/) | JSON parsing | `brew install jq` |
| git | Repository cloning/fetching | (usually pre-installed) |

You must be authenticated with `gh`:

```bash
gh auth login
```

**Optional (for XLSX output):**

```bash
python3 -m pip install --user openpyxl
```

## Usage

```bash
ORG=<github-org> ./GH-SOC2-Audit.sh <repo1> [repo2 ...]
```

Run `./GH-SOC2-Audit.sh --help` for full usage details.

### Examples

Audit a single repo with defaults:

```bash
ORG=my-org ./GH-SOC2-Audit.sh my-api
```

Audit multiple repos with a custom date range and Jira integration:

```bash
ORG=my-org \
  START_DATE=2025-01-01 \
  END_DATE=2025-06-30 \
  TICKET_URL=https://myco.atlassian.net/browse/ \
  ./GH-SOC2-Audit.sh api-service web-app worker
```

Audit with strict validation (exit non-zero on data quality issues):

```bash
ORG=my-org STRICT=true STRICT_APPROVERS=true ./GH-SOC2-Audit.sh my-repo
```

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `ORG` | Yes | — | GitHub organization or username that owns the repos |
| `START_DATE` | No | `2024-10-01` | Start of audit window (YYYY-MM-DD) |
| `END_DATE` | No | `2025-08-31` | End of audit window (YYYY-MM-DD) |
| `MAIN_BRANCH` | No | `main` | Base branch to query merged PRs against |
| `TICKET_PATTERN` | No | `[A-Z]+-[0-9]+` | Regex to extract ticket IDs from PR title/body |
| `TICKET_URL` | No | *(empty)* | Base URL prepended to ticket IDs (e.g. `https://myco.atlassian.net/browse/`). If unset, the raw ticket ID is used. |
| `REPO_ROOT` | No | `$HOME/Projects` | Directory where repos are cloned |
| `OUT_DIR` | No | `<script-dir>/reports` | Directory where reports are written |
| `STRICT` | No | `false` | Exit with error if any PR is missing a ticket or commit subject |
| `STRICT_APPROVERS` | No | `false` | Exit with error if any PR has no approved reviews |

Dates are validated on startup. Invalid formats or `START_DATE` after `END_DATE` will produce a clear error.

## Output

Reports are written to `$OUT_DIR` (default: `reports/` directory alongside the script):

```
GH-SOC2-<repo>-Audit-<start>-to-<end>.csv
GH-SOC2-<repo>-Audit-<start>-to-<end>.xlsx   (if python3 + openpyxl available)
```

CSV rows are sorted by merged date (ascending). The XLSX version includes auto-filtered headers, a frozen header row, and auto-sized columns.

### CSV Columns

| Column | Description |
|--------|-------------|
| Merged Date | Full ISO-8601 timestamp of the merge |
| Commit Subject | First line of the merge commit message (falls back to PR title) |
| PR URL | Link to the pull request on GitHub |
| Author | GitHub username of the PR author |
| Approvers | Semicolon-separated GitHub usernames who approved the PR |
| Ticket | Ticket ID or URL extracted from the PR title/body |

## Resume Support

If the script is interrupted (network failure, rate limit, Ctrl-C), simply re-run the same command. It detects the existing CSV and skips already-processed PRs, appending only new ones. Delete the CSV to force a full re-run.

## Rate Limiting

The script makes 2-3 GitHub API calls per PR. For authenticated users, the limit is 5,000 requests/hour. Before processing each repo, the script checks remaining quota and warns if it's low. If a rate limit is hit mid-run, API calls are retried with exponential backoff (up to 3 attempts). If the limit is exhausted, the script fails and can be resumed later.

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Missing dependency, `ORG` not set, `gh` not authenticated, or invalid dates |
| 2 | No repos specified |
| 10 | `STRICT=true` and PRs found with missing tickets |
| 11 | `STRICT=true` and PRs found with missing commit subjects |
| 12 | `STRICT_APPROVERS=true` and PRs found with no approved reviews |

## How It Works

1. Validates dependencies, dates, and `gh` authentication
2. For each repo: clones (or fetches if already cloned) to `$REPO_ROOT/<repo>/`
3. Queries all closed PRs merged into `$MAIN_BRANCH` via the GitHub API (with pagination)
4. Filters PRs to those merged within the `START_DATE`..`END_DATE` window
5. Skips PRs already in the CSV (resume mode)
6. For each new PR, extracts metadata via the GitHub API: merge commit subject, review approvals, and ticket ID from the PR title/body
7. Appends CSV rows, then sorts by merged date and optionally converts to XLSX

The script is **read-only** — it never pushes, writes, or modifies any repository.
