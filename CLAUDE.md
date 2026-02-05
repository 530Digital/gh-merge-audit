# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Single-file Bash tool (`GH-SOC2-Audit.sh`) that generates SOC2-style audit reports for merged GitHub pull requests. It queries the GitHub API for merged PRs within a date range, extracts metadata (author, approvers, issue-tracker tickets, commit subjects), and outputs CSV and optionally XLSX reports.

## Running

```bash
# ORG is required — set it to the GitHub org or username
ORG=my-org ./GH-SOC2-Audit.sh repo1 [repo2 ...]

# With environment overrides
ORG=my-org START_DATE=2025-01-01 END_DATE=2025-06-30 \
  TICKET_URL=https://myco.atlassian.net/browse/ \
  ./GH-SOC2-Audit.sh myrepo

# Strict modes (exit non-zero on data quality issues)
ORG=my-org STRICT=true STRICT_APPROVERS=true ./GH-SOC2-Audit.sh myrepo
```

**Required tools**: `gh` (authenticated), `jq`, `git`
**Optional**: `python3` + `openpyxl` (for XLSX output)

## Architecture

The script follows a linear ETL pipeline:

1. **Validate** dependencies (`need()`) and `gh auth` status; require `ORG` env var
2. **Clone/fetch** each repo to `$REPO_ROOT/<repo>/`
3. **Query** merged PRs via `gh api --paginate` on the pulls endpoint, filtered to `state=closed` + `merged_at != null`
4. **Process** each PR: extract merged date, author, commit subject (from `merge_commit_sha`, falling back to PR title), approvers (from reviews API), and ticket ID (via configurable `TICKET_PATTERN` regex in `extract_ticket()`)
5. **Output** CSV rows to `$OUT_DIR/` (defaults to `reports/` in the repo), then optionally convert to XLSX via embedded Python heredoc (`csv_to_xlsx()`)
6. **Report** data quality warnings and enforce strict mode exit codes (10=missing tickets, 11=missing subjects, 12=missing approvals)

## Key Details

- All org/company-specific values are configurable via environment variables (see README.md)
- `TICKET_PATTERN` defaults to `[A-Z]+-[0-9]+` (generic Jira-style); `TICKET_URL` is optional
- CSV escaping is handled by `escape()` which doubles quotes and wraps fields
- Date filtering uses string comparison on `YYYY-MM-DD` prefixes
- The script is read-only (no pushes or modifications to repos)
- Uses `set -euo pipefail` for strict Bash error handling

## Documentation

- Always update the README.md file after changes to the script are made if needed
