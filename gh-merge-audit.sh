#!/usr/bin/env bash
set -euo pipefail

# ============================================
# PR Audit Report Generator (Squash Merge Safe)
# ============================================
# - Produces CSV and XLSX with columns (in order):
#   Merged Date, Commit Subject, PR URL, Author, Approvers, Ticket
# - Read-only: only uses git clone/fetch and GitHub API (gh).
# - Supports resume: re-running skips already-processed PRs.
#
# Usage:
#   ORG=<github-org> ./gh-merge-audit.sh [--help] repo1 [repo2 ...]
#
# Required ENV:
#   ORG=<github-org>        GitHub organization or user that owns the repos
#
# Optional ENV:
#   START_DATE=YYYY-MM-DD   (default: 2024-10-01)
#   END_DATE=YYYY-MM-DD     (default: 2025-08-31)
#   MAIN_BRANCH=main        (default: main)
#   TICKET_PATTERN=<regex>  (default: [A-Z]+-[0-9]+  — matches Jira-style keys)
#   TICKET_URL=<base-url>   (e.g. https://yourco.atlassian.net/browse/)
#   REPORT_PREFIX=<string>  (default: audit  — output filename prefix)
#   REPO_ROOT=<path>        (default: $HOME/Projects)
#   OUT_DIR=<path>          (default: <script-dir>/reports)
#   STRICT=true             (fail if missing ticket or fallback subject)
#   STRICT_APPROVERS=true   (fail if any PR has no APPROVED reviews)
#
# XLSX requirements:
#   python3 + openpyxl  (python3 -m pip install --user openpyxl)
# ============================================

# ---- Help ----
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'USAGE'
Usage: ORG=<github-org> gh-merge-audit.sh [--help] <repo1> [repo2 ...]

PR Audit Report Generator — produces CSV/XLSX reports of merged pull requests
for SOC2-style compliance auditing. Supports resume on re-run.

Required:
  ORG                GitHub organization or username that owns the repos

Optional environment variables:
  START_DATE         Audit window start, YYYY-MM-DD          (default: 2024-10-01)
  END_DATE           Audit window end, YYYY-MM-DD            (default: 2025-08-31)
  MAIN_BRANCH        Base branch to query                    (default: main)
  TICKET_PATTERN     Regex for ticket IDs in PR title/body   (default: [A-Z]+-[0-9]+)
  TICKET_URL         Base URL prepended to ticket IDs        (default: empty)
  REPORT_PREFIX      Prefix for output filenames             (default: audit)
  REPO_ROOT          Directory where repos are cloned        (default: $HOME/Projects)
  OUT_DIR            Directory where reports are written      (default: <script-dir>/reports)
  STRICT             Fail if missing tickets or subjects      (default: false)
  STRICT_APPROVERS   Fail if any PR has no approved reviews   (default: false)

Prerequisites:
  gh (authenticated), jq, git
  Optional: python3 + openpyxl (for XLSX output)

GitHub Enterprise: Set GH_HOST for your instance (used by gh cli).
Repos are cloned via 'gh repo clone', respecting your gh protocol config.
USAGE
  exit 0
fi

# ---- Dependency checks ----
need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ Missing dependency: $1" >&2; exit 1; }; }
need gh; need jq; need git

if [[ -z "${ORG:-}" ]]; then
  echo "❌ ORG is required. Set it to your GitHub organization or username." >&2
  echo "   Example: ORG=my-org $0 repo1 repo2" >&2
  echo "   Run $0 --help for full usage." >&2
  exit 1
fi

REPOS=("$@")

START_DATE="${START_DATE:-2024-10-01}"
END_DATE="${END_DATE:-2025-08-31}"
MAIN_BRANCH="${MAIN_BRANCH:-main}"
TICKET_PATTERN="${TICKET_PATTERN:-[A-Z]+-[0-9]+}"
TICKET_URL="${TICKET_URL:-}"
REPORT_PREFIX="${REPORT_PREFIX:-audit}"

# ---- Date validation ----
validate_date() {
  local d="$1" label="$2"
  if ! [[ "$d" =~ ^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$ ]]; then
    echo "❌ $label='$d' is not a valid YYYY-MM-DD date." >&2
    exit 1
  fi
}
validate_date "$START_DATE" "START_DATE"
validate_date "$END_DATE" "END_DATE"

if [[ "$START_DATE" > "$END_DATE" ]]; then
  echo "❌ START_DATE ($START_DATE) is after END_DATE ($END_DATE)." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Where repos live on disk
REPO_ROOT="${REPO_ROOT:-$HOME/Projects}"
# Where reports are written
OUT_DIR="${OUT_DIR:-$SCRIPT_DIR/reports}"
mkdir -p "$OUT_DIR" "$REPO_ROOT"

# Ensure gh is authenticated
if ! gh auth status >/dev/null 2>&1; then
  echo "❌ GitHub CLI not authenticated. Run: gh auth login" >&2
  exit 1
fi

if [[ ${#REPOS[@]} -eq 0 ]]; then
  echo "Usage: ORG=<github-org> $0 <repo1> [repo2 repo3 ...]" >&2
  echo "Run $0 --help for full usage." >&2
  exit 2
fi

# ---- Helpers ----
extract_tickets() { grep -oE "$TICKET_PATTERN" <<<"$1" | sort -u | paste -sd ';' - || true; }

escape() {
  local s="${1//\"/\"\"}"
  printf "\"%s\"" "$s"
}

# gh api wrapper with retry and exponential backoff for rate limits and transient errors
gh_api() {
  local max_retries=5 delay=5
  for (( attempt=1; attempt<=max_retries; attempt++ )); do
    local err_file
    err_file=$(mktemp)
    local output=""
    if output=$(gh api "$@" 2>"$err_file"); then
      rm -f "$err_file"
      printf '%s' "$output"
      return 0
    fi
    local err
    err=$(<"$err_file")
    rm -f "$err_file"
    if [[ "$err" == *"rate limit"* || "$err" == *"secondary rate limit"* || "$err" == *"abuse detection"* ]]; then
      echo "⚠️  Rate limited; waiting ${delay}s (attempt $attempt/$max_retries)..." >&2
      sleep "$delay"
      (( delay *= 2 ))
    elif [[ "$err" == *"connection reset"* || "$err" == *"connection refused"* || \
            "$err" == *"EOF"* || "$err" == *"timeout"* || \
            "$err" == *"TLS handshake"* || "$err" == *"Service Unavailable"* || \
            "$err" == *"Bad Gateway"* || "$err" == *"broken pipe"* ]]; then
      echo "⚠️  Network error; retrying in ${delay}s (attempt $attempt/$max_retries)..." >&2
      sleep "$delay"
      (( delay *= 2 ))
    else
      printf '%s' "$err" >&2
      return 1
    fi
  done
  echo "❌ API call failed after $max_retries retries." >&2
  return 1
}

csv_to_xlsx() {
  # csv_to_xlsx <csv_path> <xlsx_path>
  local csv_path="$1" xlsx_path="$2"

  if ! command -v python3 >/dev/null 2>&1; then
    echo "⚠️  XLSX conversion skipped; python3 not found." >&2
    return 0
  fi

  # Run an embedded Python script. On macOS, avoid `|| {}` after heredoc.
  python3 - "$csv_path" "$xlsx_path" <<'PY'
import sys, csv
csv_path, xlsx_path = sys.argv[1], sys.argv[2]
try:
    from openpyxl import Workbook
    from openpyxl.utils import get_column_letter
except Exception:
    # Signal to shell that openpyxl is missing
    print("MISSING_OPENPYXL")
    sys.exit(9)

wb = Workbook()
ws = wb.active
ws.title = "PR Audit"

with open(csv_path, newline='', encoding='utf-8') as f:
    reader = csv.reader(f)
    for row in reader:
        ws.append(row)

# Filter over used range & freeze header row
ws.auto_filter.ref = ws.dimensions
ws.freeze_panes = 'A2'

# Simple column width pass
for col_idx in range(1, ws.max_column + 1):
    max_len = 10
    for row in ws.iter_rows(min_row=1, max_row=ws.max_row, min_col=col_idx, max_col=col_idx):
        cell = row[0]
        v = "" if cell.value is None else str(cell.value)
        max_len = max(max_len, len(v))
    ws.column_dimensions[get_column_letter(col_idx)].width = min(max_len + 2, 60)

wb.save(xlsx_path)
PY
  status=$?
  if [[ $status -eq 9 ]]; then
    echo "⚠️  XLSX conversion skipped; install openpyxl: python3 -m pip install --user openpyxl" >&2
  elif [[ $status -ne 0 ]]; then
    echo "⚠️  XLSX conversion failed with status $status; keeping CSV." >&2
  else
    echo "✅ Wrote XLSX: $xlsx_path"
  fi
}

# ---- Main ----
for REPO in "${REPOS[@]}"; do
  echo "============================================"
  echo " Running audit for repo: $REPO"
  echo " Repo root: $REPO_ROOT"
  echo " Date window: $START_DATE .. $END_DATE"
  echo " Columns: Merged Date, Commit Subject, PR URL, Author, Approvers, Ticket"
  echo "============================================"

  # Check API rate limit before starting this repo
  RATE_REMAINING=$(gh api /rate_limit --jq '.resources.core.remaining' 2>/dev/null || echo "unknown")
  if [[ "$RATE_REMAINING" != "unknown" ]] && (( RATE_REMAINING < 500 )); then
    echo "⚠️  GitHub API rate limit is low: $RATE_REMAINING requests remaining." >&2
  fi

  OUT_CSV="$OUT_DIR/${REPORT_PREFIX}-${REPO}-${START_DATE}-to-${END_DATE}.csv"
  OUT_XLSX="$OUT_DIR/${REPORT_PREFIX}-${REPO}-${START_DATE}-to-${END_DATE}.xlsx"

  # Resume support: detect existing CSV and extract already-processed PR URLs
  RESUME=false
  EXISTING_URLS=""
  if [[ -f "$OUT_CSV" ]] && (( $(wc -l < "$OUT_CSV") > 1 )); then
    RESUME=true
    EXISTING_URLS=$(grep -oE 'https://[^"]+/pull/[0-9]+' "$OUT_CSV" || true)
    RESUME_COUNT=$(echo "$EXISTING_URLS" | grep -c . || true)
    echo "Resuming: found $RESUME_COUNT existing rows in $OUT_CSV"
  else
    echo "Merged Date,Commit Subject,PR URL,Author,Approvers,Ticket" > "$OUT_CSV"
  fi

  REPO_PATH="$REPO_ROOT/$REPO"
  if [[ ! -d "$REPO_PATH/.git" ]]; then
    echo "Cloning $ORG/$REPO into $REPO_PATH ..."
    gh repo clone "$ORG/$REPO" "$REPO_PATH" -- --quiet
  else
    echo "Using existing clone at $REPO_PATH"
  fi

  pushd "$REPO_PATH" >/dev/null
  git fetch --all --prune --quiet

  echo "Querying merged PRs for $ORG/$REPO (base=$MAIN_BRANCH)..."
  PR_LIST=$(gh_api \
    -H "Accept: application/vnd.github+json" \
    "/repos/$ORG/$REPO/pulls?state=closed&base=$MAIN_BRANCH&per_page=100" \
    --paginate \
    | jq -c '.[] | select(.merged_at != null)')

  # Progress counters
  TOTAL=0
  [[ -n "$PR_LIST" ]] && TOTAL=$(printf '%s\n' "$PR_LIST" | wc -l | tr -d ' ')
  IDX=0
  COUNT=0
  SKIPPED=0
  WARN_MISSING_TICKET=0
  WARN_MISSING_APPROVERS=0
  WARN_MISSING_SUBJECT=0

  while IFS= read -r pr; do
    [[ -z "$pr" ]] && continue
    (( IDX += 1 ))
    MERGED_AT=$(jq -r '.merged_at' <<<"$pr")     # full ISO timestamp
    MERGED_DATE="${MERGED_AT:0:10}"              # YYYY-MM-DD

    # Filter by date window
    if [[ "$MERGED_DATE" < "$START_DATE" || "$MERGED_DATE" > "$END_DATE" ]]; then
      continue
    fi

    PR_URL=$(jq -r '.html_url' <<<"$pr")
    PR_NUMBER=$(jq -r '.number' <<<"$pr")

    # Progress
    printf "  [%d/%d] PR #%s ...\\r" "$IDX" "$TOTAL" "$PR_NUMBER"

    # Skip if already processed (resume mode)
    if [[ "$RESUME" == true ]] && echo "$EXISTING_URLS" | grep -qF "$PR_URL"; then
      (( SKIPPED += 1 ))
      continue
    fi

    AUTHOR=$(jq -r '.user.login' <<<"$pr")
    TITLE=$(jq -r '.title' <<<"$pr")
    BODY=$(jq -r '.body // ""' <<<"$pr")
    MERGE_SHA=$(jq -r '.merge_commit_sha // empty' <<<"$pr")

    # Ticket extraction — searches title and body, deduplicates multiple matches
    RAW_TICKETS="$(extract_tickets "$TITLE $BODY")"
    if [[ -n "$RAW_TICKETS" ]]; then
      if [[ -n "$TICKET_URL" ]]; then
        # Prepend base URL to each ticket ID
        TICKET=$(echo "$RAW_TICKETS" | tr ';' '\n' | sed "s|^|${TICKET_URL}|" | paste -sd ';' -)
      else
        TICKET="$RAW_TICKETS"
      fi
    else
      TICKET=""
      (( WARN_MISSING_TICKET += 1 ))
      echo "⚠️  Missing ticket for PR #$PR_NUMBER ($PR_URL)" >&2
    fi

    # Approvers (use jq -s to correctly merge across paginated responses)
    APPROVERS=$(gh_api \
      -H "Accept: application/vnd.github+json" \
      --paginate "/repos/$ORG/$REPO/pulls/$PR_NUMBER/reviews" \
      | jq -s -r '[.[][] | select(.state=="APPROVED") | .user.login] | unique | join(";")')
    if [[ -z "$APPROVERS" ]]; then
      (( WARN_MISSING_APPROVERS += 1 ))
      echo "⚠️  No APPROVED reviews for PR #$PR_NUMBER ($PR_URL)" >&2
    fi

    # Exact commit subject via merge_commit_sha
    COMMIT_SUBJECT=""
    if [[ -n "$MERGE_SHA" ]]; then
      COMMIT_SUBJECT=$(gh_api \
        -H "Accept: application/vnd.github+json" \
        "/repos/$ORG/$REPO/commits/$MERGE_SHA" \
        --jq '.commit.message | split("\n")[0]' \
        || true)

      # Sanity: merge commit on origin/main
      if ! git merge-base --is-ancestor "$MERGE_SHA" "origin/$MAIN_BRANCH"; then
        echo "⚠️  merge_commit_sha $MERGE_SHA for PR #$PR_NUMBER is not an ancestor of origin/$MAIN_BRANCH" >&2
      fi
    fi

    # Fallback to PR title
    if [[ -z "$COMMIT_SUBJECT" ]]; then
      COMMIT_SUBJECT="$TITLE"
      (( WARN_MISSING_SUBJECT += 1 ))
      echo "ℹ️  Using PR title as commit subject for PR #$PR_NUMBER; merge_commit_sha missing/unavailable" >&2
    fi

    # Write row: Merged Date, Commit Subject, PR URL, Author, Approvers, Ticket
    echo "$(
      printf "%s,%s,%s,%s,%s,%s" \
        "$(escape "$MERGED_AT")" \
        "$(escape "$COMMIT_SUBJECT")" \
        "$(escape "$PR_URL")" \
        "$(escape "$AUTHOR")" \
        "$(escape "$APPROVERS")" \
        "$(escape "$TICKET")"
    )" >> "$OUT_CSV"

    (( COUNT += 1 ))
  done < <(printf '%s\n' "$PR_LIST")

  # Clear progress line
  printf "%-60s\\r" ""

  popd >/dev/null

  # Sort CSV by Merged Date (column 1), preserving header
  if (( COUNT > 1 )) || [[ "$RESUME" == true ]]; then
    head -1 "$OUT_CSV" > "$OUT_CSV.tmp"
    tail -n +2 "$OUT_CSV" | sort -t',' -k1,1 >> "$OUT_CSV.tmp"
    mv "$OUT_CSV.tmp" "$OUT_CSV"
  fi

  TOTAL_ROWS=$(( $(wc -l < "$OUT_CSV") - 1 ))
  echo "✔ Completed CSV: $OUT_CSV (rows: $TOTAL_ROWS, new: $COUNT, skipped/resumed: $SKIPPED)"
  echo "   Data quality (new PRs): missing_tickets=$WARN_MISSING_TICKET, missing_approvals=$WARN_MISSING_APPROVERS, subject_from_title=$WARN_MISSING_SUBJECT" >&2

  # Strict modes (optional)
  if [[ "${STRICT:-false}" == "true" ]]; then
    if (( WARN_MISSING_TICKET > 0 )); then
      echo "❌ STRICT: $WARN_MISSING_TICKET PR(s) missing tickets" >&2
      exit 10
    fi
    if (( WARN_MISSING_SUBJECT > 0 )); then
      echo "❌ STRICT: $WARN_MISSING_SUBJECT PR(s) missing explicit commit subjects (used PR title fallback)" >&2
      exit 11
    fi
  fi
  if [[ "${STRICT_APPROVERS:-false}" == "true" ]]; then
    if (( WARN_MISSING_APPROVERS > 0 )); then
      echo "❌ STRICT_APPROVERS: $WARN_MISSING_APPROVERS PR(s) missing APPROVED reviews" >&2
      exit 12
    fi
  fi

  # Convert CSV -> XLSX (filters + freeze header)
  echo "Creating XLSX workbook ..."
  csv_to_xlsx "$OUT_CSV" "$OUT_XLSX"
done

echo "All reports finished."
