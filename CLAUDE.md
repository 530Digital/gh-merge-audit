# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Single-file Bash tool (`gh-merge-audit.sh`) that generates SOC2-style audit reports for merged GitHub pull requests. It queries the GitHub API for merged PRs within a date range, extracts metadata (author, approvers, issue-tracker tickets, commit subjects), and outputs CSV and optionally XLSX reports.

## Running

```bash
# ORG is required — set it to the GitHub org or username
ORG=my-org ./gh-merge-audit.sh repo1 [repo2 ...]

# Show full usage
./gh-merge-audit.sh --help

# With environment overrides
ORG=my-org START_DATE=2025-01-01 END_DATE=2025-06-30 \
  TICKET_URL=https://myco.atlassian.net/browse/ \
  ./gh-merge-audit.sh myrepo

# Strict modes (exit non-zero on data quality issues)
ORG=my-org STRICT=true STRICT_APPROVERS=true ./gh-merge-audit.sh myrepo
```

**Required tools**: `gh` (authenticated), `jq`, `git`
**Optional**: `python3` + `openpyxl` (for XLSX output)

## Architecture

The script follows a linear ETL pipeline:

1. **Parse args** — handle `--help`, validate `ORG` is set
2. **Validate** — check dependencies (`need()`), `gh auth` status, date format/range
3. **Clone/fetch** each repo via `gh repo clone` to `$REPO_ROOT/<repo>/` (supports GHE via `GH_HOST`)
4. **Check rate limit** — warn if GitHub API quota is low
5. **Resume detection** — if output CSV exists, extract already-processed PR URLs
6. **Query** merged PRs via `gh_api --paginate` piped through `jq -c`, filtered to `merged_at != null`
7. **Process** each PR with progress display: extract merged date, author, commit subject (from `merge_commit_sha`, falling back to PR title), approvers (from reviews API via `jq -s` to handle pagination correctly), and ticket ID(s) (via configurable `TICKET_PATTERN` regex in `extract_tickets()` — supports multiple per PR)
8. **Sort** CSV rows by merged date, then optionally convert to XLSX via embedded Python heredoc (`csv_to_xlsx()`)
9. **Report** data quality warnings and enforce strict mode exit codes (10=missing tickets, 11=missing subjects, 12=missing approvals)

## Key Details

- All org/company-specific values are configurable via environment variables (see README.md)
- `TICKET_PATTERN` defaults to `[A-Z]+-[0-9]+` (generic Jira-style); `TICKET_URL` is optional
- `gh_api()` wraps `gh api` with retry + exponential backoff on rate limit errors; uses a temp file for stderr to avoid mixing error output into response data
- `REPORT_PREFIX` controls output filenames (default: `audit`)
- Resume: re-running appends to existing CSV, skipping PRs already present (matched by URL)
- CSV escaping is handled by `escape()` which doubles quotes and wraps fields
- Date validation uses regex for format and lexicographic comparison for range
- The script is read-only (no pushes or modifications to repos)
- Uses `set -euo pipefail` for strict Bash error handling
- All `(( VAR += 1 ))` instead of `((VAR++))` to avoid `set -e` exit on zero-valued post-increment

## Documentation

- Always update the README.md file after changes to the script are made if needed
