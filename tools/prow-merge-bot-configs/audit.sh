#!/usr/bin/env bash
# Audit Prow merge bot configurations across OADP ecosystem repositories.
#
# Fetches _pluginconfig.yaml and _prowconfig.yaml from openshift/release on
# GitHub and produces a diff report showing inconsistencies between repos,
# flagging intentional vs unexpected differences.
#
# Also checks for PRs stuck in the Tide merge queue (have approved+lgtm but
# haven't merged) and reports what's blocking them, with Prow query links.
#
# No local checkout of openshift/release is required — files are fetched via
# curl from raw.githubusercontent.com. Merge queue checks require `gh` CLI.
#
# Usage:
#   ./audit.sh [--branch master] [--format text|markdown] [--skip-queue]
#
# Environment:
#   GITHUB_TOKEN  - optional, avoids GitHub API rate limits for raw content

set -euo pipefail

#
# Defaults
#
FORMAT="text"
BRANCH="master"
SKIP_QUEUE="false"
LOCAL_RELEASE=""
RAW_BASE="https://raw.githubusercontent.com/openshift/release"

#
# OADP repos grouped by type. This determines what "baseline" config is expected.
#
# upstream-rebase: Repos that are forks of upstream projects, rebased by rebasebot.
#   These intentionally allow force pushes and lack enforce_admins/review count
#   because rebasebot needs to force-push updated branches.
#
# oadp-owned: Repos maintained directly by the OADP team.
#   These should have enforce_admins, required_approving_review_count: 2, etc.
#   enforce_admins is required as a workaround for kubernetes-sigs/prow#134 —
#   without it, Tide bypasses GitHub's required_approving_review_count.
#
UPSTREAM_REBASE_REPOS=(
  "openshift/velero"
  "openshift/velero-plugin-for-aws"
  "openshift/velero-plugin-for-legacy-aws"
  "openshift/velero-plugin-for-gcp"
  "openshift/velero-plugin-for-microsoft-azure"
  "openshift/velero-plugin-for-csi"
  "openshift/restic"
)

OADP_OWNED_OPENSHIFT_REPOS=(
  "openshift/oadp-operator"
  "openshift/oadp-must-gather"
  "openshift/openshift-velero-plugin"
  "openshift/hypershift-oadp-plugin"
)

OADP_OWNED_MIGTOOLS_REPOS=(
  "migtools/filebrowser"
  "migtools/kubevirt-datamover-controller"
  "migtools/kubevirt-datamover-plugin"
  "migtools/kubevirt-velero-plugin"
  "migtools/oadp-cli"
  "migtools/oadp-non-admin"
  "migtools/oadp-vm-file-restore"
  "migtools/udistribution"
  "migtools/velero-plugin-for-vsm"
  "migtools/volume-snapshot-mover"
)

# Repos expected to have no prow config (no CI in OpenShift CI)
NO_PROW_CONFIG_REPOS=(
  "migtools/oadp-vmdp"
  "migtools/kopia"
)

#
# Parse arguments
#
while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)
      BRANCH="$2"
      shift 2
      ;;
    --format)
      FORMAT="$2"
      shift 2
      ;;
    --skip-queue)
      SKIP_QUEUE="true"
      shift
      ;;
    --local)
      LOCAL_RELEASE="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--branch master] [--format text|markdown] [--skip-queue] [--local <path>]"
      echo ""
      echo "Audits Prow merge bot configs across OADP ecosystem repositories."
      echo ""
      echo "Options:"
      echo "  --branch BRANCH   Branch of openshift/release to fetch from (default: master)"
      echo "  --format FORMAT   Output format: text or markdown (default: text)"
      echo "  --skip-queue      Skip merge queue status check (requires gh CLI)"
      echo "  --local PATH      Use a local openshift/release checkout instead of fetching via curl"
      echo ""
      echo "Environment:"
      echo "  GITHUB_TOKEN      Optional token to avoid GitHub rate limits (ignored with --local)"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: $0 [--branch master] [--format text|markdown] [--skip-queue] [--local <path>]" >&2
      exit 1
      ;;
  esac
done

#
# Temp directory for fetched configs — cleaned up on exit
#
CACHE_DIR="$(mktemp -d)"
cleanup() { rm -rf "$CACHE_DIR"; }
trap cleanup EXIT

#
# Validate --local path if provided
#
if [[ -n "$LOCAL_RELEASE" ]]; then
  if [[ ! -d "$LOCAL_RELEASE/core-services/prow/02_config" ]]; then
    echo "Error: --local path does not look like an openshift/release checkout" >&2
    echo "Expected to find: $LOCAL_RELEASE/core-services/prow/02_config" >&2
    exit 1
  fi
fi

#
# Fetch a file from GitHub raw content or copy from local checkout.
# Returns 0 if found, 1 if not found. File is cached in CACHE_DIR.
#
fetch_file() {
  local org="$1" repo="$2" filename="$3"
  local local_dir="$CACHE_DIR/$org/$repo"
  local local_path="$local_dir/$filename"

  # Return cached copy if already fetched
  if [[ -f "$local_path" ]]; then
    return 0
  fi
  if [[ -f "$local_path.404" ]]; then
    return 1
  fi

  mkdir -p "$local_dir"

  if [[ -n "$LOCAL_RELEASE" ]]; then
    # Copy from local checkout
    local src="$LOCAL_RELEASE/core-services/prow/02_config/$org/$repo/$filename"
    if [[ -f "$src" ]]; then
      cp "$src" "$local_path"
      return 0
    else
      touch "$local_path.404"
      return 1
    fi
  else
    # Fetch from GitHub
    local url="$RAW_BASE/$BRANCH/core-services/prow/02_config/$org/$repo/$filename"
    local curl_args=(-sfL -o "$local_path" -w "%{http_code}")
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
      curl_args+=(-H "Authorization: token $GITHUB_TOKEN")
    fi

    local http_code
    http_code="$(curl "${curl_args[@]}" "$url" 2>/dev/null)" || true

    if [[ "$http_code" == "200" && -f "$local_path" ]]; then
      return 0
    else
      rm -f "$local_path"
      touch "$local_path.404"
      return 1
    fi
  fi
}

#
# Color helpers (disabled for markdown output or non-terminal)
#
if [[ "$FORMAT" == "text" ]] && [[ -t 1 ]]; then
  RED='\033[0;31m'
  YELLOW='\033[0;33m'
  GREEN='\033[0;32m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  RED='' YELLOW='' GREEN='' CYAN='' BOLD='' RESET=''
fi

#
# Counters
#
ISSUES=0
WARNINGS=0
INFO=0

issue()   { ((ISSUES++))   || true; echo -e "${RED}[ISSUE]${RESET} $1"; }
warning() { ((WARNINGS++)) || true; echo -e "${YELLOW}[WARN]${RESET}  $1"; }
info()    { ((INFO++))     || true; echo -e "${CYAN}[INFO]${RESET}  $1"; }
ok()      { echo -e "${GREEN}[OK]${RESET}    $1"; }
section() { echo ""; echo -e "${BOLD}=== $1 ===${RESET}"; }

#
# YAML value extraction (simple grep-based, avoids yq dependency)
#
yaml_has() {
  grep -q "$2" "$1" 2>/dev/null
}

yaml_val() {
  grep -m1 "$2" "$1" 2>/dev/null | sed 's/.*: *//' | tr -d '"' || true
}

#
# File path helpers — resolve to cached files
#
pluginconfig_for() {
  local org="${1%%/*}" repo="${1##*/}"
  echo "$CACHE_DIR/$org/$repo/_pluginconfig.yaml"
}

prowconfig_for() {
  local org="${1%%/*}" repo="${1##*/}"
  echo "$CACHE_DIR/$org/$repo/_prowconfig.yaml"
}

#
# Fetch both config files for a repo. Returns 0 if at least one exists.
#
fetch_configs() {
  local org="${1%%/*}" repo="${1##*/}"
  local found=false
  fetch_file "$org" "$repo" "_pluginconfig.yaml" && found=true
  fetch_file "$org" "$repo" "_prowconfig.yaml" && found=true
  $found
}

#
# Check if a repo has config (both files fetched successfully)
#
has_config() {
  local f
  f="$(pluginconfig_for "$1")"
  [[ -f "$f" ]]
}

#
# Extract config properties
#
get_require_self_approval() {
  local f
  f="$(pluginconfig_for "$1")"
  if [[ ! -f "$f" ]]; then echo "MISSING_FILE"; return; fi
  if yaml_has "$f" "require_self_approval:"; then
    yaml_val "$f" "require_self_approval:"
  else
    echo "NOT_SET"
  fi
}

get_review_acts_as_lgtm() {
  local f
  f="$(pluginconfig_for "$1")"
  if [[ ! -f "$f" ]]; then echo "MISSING_FILE"; return; fi
  if yaml_has "$f" "review_acts_as_lgtm:"; then
    yaml_val "$f" "review_acts_as_lgtm:"
  else
    echo "NOT_SET"
  fi
}

has_lgtm_section() {
  local f
  f="$(pluginconfig_for "$1")"
  [[ -f "$f" ]] && grep -q "^lgtm:" "$f" 2>/dev/null
}

has_approve_section() {
  local f
  f="$(pluginconfig_for "$1")"
  [[ -f "$f" ]] && grep -q "^approve:" "$f" 2>/dev/null
}

has_approve_plugin() {
  local f
  f="$(pluginconfig_for "$1")"
  # Check that 'approve' appears in the plugins list section, not just the
  # top-level approve: config. Look for it under "plugins:" indented block.
  [[ -f "$f" ]] && awk '/^  *plugins:$/,/^[^ ]/' "$f" 2>/dev/null | grep -qF -- "- approve"
}

get_enforce_admins() {
  local f
  f="$(prowconfig_for "$1")"
  if [[ ! -f "$f" ]]; then echo "MISSING_FILE"; return; fi
  if yaml_has "$f" "enforce_admins:"; then
    yaml_val "$f" "enforce_admins:"
  else
    echo "NOT_SET"
  fi
}

get_review_count() {
  local f
  f="$(prowconfig_for "$1")"
  if [[ ! -f "$f" ]]; then echo "MISSING_FILE"; return; fi
  if yaml_has "$f" "required_approving_review_count:"; then
    yaml_val "$f" "required_approving_review_count:"
  else
    echo "NOT_SET"
  fi
}

get_allow_force_pushes() {
  local f
  f="$(prowconfig_for "$1")"
  if [[ ! -f "$f" ]]; then echo "MISSING_FILE"; return; fi
  if yaml_has "$f" "allow_force_pushes:"; then
    yaml_val "$f" "allow_force_pushes:"
  else
    echo "NOT_SET"
  fi
}

get_dismiss_stale_reviews() {
  local f
  f="$(prowconfig_for "$1")"
  if [[ ! -f "$f" ]]; then echo "MISSING_FILE"; return; fi
  if yaml_has "$f" "dismiss_stale_reviews:"; then
    yaml_val "$f" "dismiss_stale_reviews:"
  else
    echo "NOT_SET"
  fi
}

get_merge_method() {
  local f
  f="$(prowconfig_for "$1")"
  if [[ ! -f "$f" ]]; then echo "MISSING_FILE"; return; fi
  if yaml_has "$f" "merge_method:"; then
    grep -A1 "merge_method:" "$f" 2>/dev/null | grep "$1" | sed 's/.*: *//' | tr -d '"' || echo "NOT_SET"
  else
    echo "NOT_SET"
  fi
}

get_tide_branches() {
  local f
  f="$(prowconfig_for "$1")"
  if [[ ! -f "$f" ]]; then echo "MISSING_FILE"; return; fi
  # Extract includedBranches values from tide queries for this repo
  # Use subshell to avoid pipefail killing the script when grep finds no matches
  (awk '/includedBranches:/,/labels:|missingLabels:|repos:/' "$f" 2>/dev/null \
    | grep "^ *- " | sed 's/^ *- //' | grep -v 'includedBranches' | sort -u | tr '\n' ',' | sed 's/,$//') 2>/dev/null || true
}

has_keep_main_query_separate() {
  local f
  f="$(prowconfig_for "$1")"
  [[ -f "$f" ]] && grep -q "keep-main-query-separate" "$f" 2>/dev/null
}

#
# Audit a single repo
#
audit_repo() {
  local repo="$1"
  local repo_type="$2"  # upstream-rebase | oadp-owned-openshift | oadp-owned-migtools

  if ! has_config "$repo"; then
    issue "$repo: No prow config found in openshift/release"
    return
  fi

  local self_approve review_lgtm enforce review_count force_push dismiss_stale merge_method

  self_approve="$(get_require_self_approval "$repo")"
  review_lgtm="$(get_review_acts_as_lgtm "$repo")"
  enforce="$(get_enforce_admins "$repo")"
  review_count="$(get_review_count "$repo")"
  force_push="$(get_allow_force_pushes "$repo")"
  dismiss_stale="$(get_dismiss_stale_reviews "$repo")"
  merge_method="$(get_merge_method "$repo")"

  # --- Plugin config checks ---

  if ! has_approve_section "$repo"; then
    issue "$repo: Missing top-level 'approve:' config section in _pluginconfig.yaml"
  fi

  if ! has_lgtm_section "$repo"; then
    issue "$repo: Missing top-level 'lgtm:' config section in _pluginconfig.yaml"
  fi

  if ! has_approve_plugin "$repo"; then
    issue "$repo: 'approve' not listed in plugins"
  fi

  # require_self_approval
  if [[ "$self_approve" == "MISSING_FILE" ]]; then
    issue "$repo: _pluginconfig.yaml not found"
  elif [[ "$self_approve" == "NOT_SET" ]]; then
    warning "$repo: require_self_approval not explicitly set (defaults vary)"
  elif [[ "$self_approve" != "false" ]]; then
    info "$repo: require_self_approval=$self_approve (most OADP repos use false)"
  fi

  # review_acts_as_lgtm
  if [[ "$review_lgtm" == "true" ]]; then
    info "$repo: review_acts_as_lgtm=true (GitHub Approve review counts as /lgtm)"
  fi

  # --- Branch protection checks ---

  case "$repo_type" in
    upstream-rebase)
      # These repos SHOULD have allow_force_pushes for rebasebot
      if [[ "$force_push" != "true" ]]; then
        warning "$repo: Upstream rebase repo missing allow_force_pushes=true (needed for rebasebot)"
      else
        ok "$repo: allow_force_pushes=true (expected for upstream rebase repo)"
      fi
      # These repos typically do NOT have enforce_admins or review counts
      if [[ "$enforce" == "true" ]]; then
        info "$repo: enforce_admins=true on upstream rebase repo (unusual — may block rebasebot)"
      fi
      if [[ "$review_count" != "NOT_SET" ]]; then
        info "$repo: required_approving_review_count=$review_count on upstream rebase repo (may block rebasebot PRs)"
      fi
      ;;
    oadp-owned-openshift|oadp-owned-migtools)
      # These repos SHOULD have enforce_admins and review count
      if [[ "$enforce" != "true" ]]; then
        warning "$repo: Missing enforce_admins=true — Tide bypasses review count without it (prow#134)"
      fi
      if [[ "$review_count" == "NOT_SET" ]]; then
        warning "$repo: Missing required_approving_review_count (expected for OADP-owned repo)"
      elif [[ "$review_count" != "2" ]]; then
        info "$repo: required_approving_review_count=$review_count (most OADP repos use 2)"
      fi
      if [[ "$dismiss_stale" != "true" ]]; then
        warning "$repo: Missing dismiss_stale_reviews=true (expected for OADP-owned repo)"
      fi
      # Should NOT have force push
      if [[ "$force_push" == "true" ]]; then
        warning "$repo: allow_force_pushes=true on OADP-owned repo (unexpected unless rebasebot also manages this repo)"
      fi
      ;;
  esac

  # --- Merge method ---
  if [[ "$merge_method" != "NOT_SET" && -n "$merge_method" ]]; then
    info "$repo: merge_method=$merge_method"
  fi

  # --- keep-main-query-separate ---
  if has_keep_main_query_separate "$repo"; then
    info "$repo: Uses keep-main-query-separate label in Tide missingLabels"
  fi
}

#
# Cross-repo comparison: find values that differ from the majority
#
compare_field() {
  local field_name="$1"
  shift
  local repos=("$@")

  # Collect repo=value pairs into a temp file to avoid bash associative array issues
  local tmpfile
  tmpfile="$(mktemp)"
  trap "rm -f '$tmpfile'" RETURN

  for repo in "${repos[@]}"; do
    if ! has_config "$repo"; then continue; fi
    local val
    case "$field_name" in
      require_self_approval)    val="$(get_require_self_approval "$repo")" ;;
      review_acts_as_lgtm)      val="$(get_review_acts_as_lgtm "$repo")" ;;
      enforce_admins)           val="$(get_enforce_admins "$repo")" ;;
      review_count)             val="$(get_review_count "$repo")" ;;
      allow_force_pushes)       val="$(get_allow_force_pushes "$repo")" ;;
      dismiss_stale_reviews)    val="$(get_dismiss_stale_reviews "$repo")" ;;
      merge_method)             val="$(get_merge_method "$repo")" ;;
    esac
    echo "$repo=$val" >> "$tmpfile"
  done

  # Find the majority value
  local majority_val
  majority_val="$(awk -F= '{print $2}' "$tmpfile" | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')"

  # Report outliers
  local has_diff=false
  while IFS='=' read -r repo val; do
    if [[ "$val" != "$majority_val" ]]; then
      has_diff=true
      break
    fi
  done < "$tmpfile"

  if $has_diff; then
    echo ""
    echo "  $field_name (majority: $majority_val)"
    while IFS='=' read -r repo val; do
      if [[ "$val" != "$majority_val" ]]; then
        echo -e "    ${YELLOW}$repo${RESET}: $val (differs from majority: $majority_val)"
      fi
    done < "$tmpfile"
  fi
}

#
# Main
#

# --- Prefetch all configs ---
echo -e "${BOLD}Prow Merge Bot Configuration Audit${RESET}"
if [[ -n "$LOCAL_RELEASE" ]]; then
  echo "Source: $LOCAL_RELEASE (local checkout)"
else
  echo "Source: github.com/openshift/release @ $BRANCH"
fi
echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""
echo -n "Fetching configs..."

ALL_REPOS_TO_FETCH=(
  "${UPSTREAM_REBASE_REPOS[@]}"
  "${OADP_OWNED_OPENSHIFT_REPOS[@]}"
  "${OADP_OWNED_MIGTOOLS_REPOS[@]}"
  "${NO_PROW_CONFIG_REPOS[@]}"
)

FETCH_ERRORS=0
for repo in "${ALL_REPOS_TO_FETCH[@]}"; do
  fetch_configs "$repo" || ((FETCH_ERRORS++)) || true
done
echo " done (${#ALL_REPOS_TO_FETCH[@]} repos, $FETCH_ERRORS without configs)"

# --- Check repos with no expected config ---
section "Repos With No Prow Config (Expected)"
for repo in "${NO_PROW_CONFIG_REPOS[@]}"; do
  if has_config "$repo"; then
    warning "$repo: Has prow config but was expected to have none"
  else
    ok "$repo: No prow config (expected — not in OpenShift CI)"
  fi
done

# --- Audit upstream rebase repos ---
section "Upstream Rebase Repos (allow_force_pushes expected)"
echo "These repos are forks of upstream projects managed by rebasebot."
echo "They intentionally allow force pushes and typically lack strict branch protection."
echo ""
for repo in "${UPSTREAM_REBASE_REPOS[@]}"; do
  audit_repo "$repo" "upstream-rebase"
done

# --- Audit OADP-owned openshift/ repos ---
section "OADP-Owned Repos (openshift/ org)"
echo "These repos should have enforce_admins, review count, and dismiss_stale_reviews."
echo ""
for repo in "${OADP_OWNED_OPENSHIFT_REPOS[@]}"; do
  audit_repo "$repo" "oadp-owned-openshift"
done

# --- Audit OADP-owned migtools/ repos ---
section "OADP-Owned Repos (migtools/ org)"
echo "These repos should have enforce_admins, review count, and dismiss_stale_reviews."
echo "Note: migtools repos list plugins explicitly (no org-level inheritance)."
echo ""
for repo in "${OADP_OWNED_MIGTOOLS_REPOS[@]}"; do
  audit_repo "$repo" "oadp-owned-migtools"
done

# --- Cross-repo comparison ---
ALL_REPOS=(
  "${UPSTREAM_REBASE_REPOS[@]}"
  "${OADP_OWNED_OPENSHIFT_REPOS[@]}"
  "${OADP_OWNED_MIGTOOLS_REPOS[@]}"
)

section "Cross-Repo Field Comparison (Outliers)"
echo "Shows fields where a repo differs from the majority value within its group."

echo ""
echo -e "${BOLD}--- Upstream Rebase Repos ---${RESET}"
compare_field "require_self_approval" "${UPSTREAM_REBASE_REPOS[@]}"
compare_field "review_acts_as_lgtm" "${UPSTREAM_REBASE_REPOS[@]}"
compare_field "allow_force_pushes" "${UPSTREAM_REBASE_REPOS[@]}"
compare_field "merge_method" "${UPSTREAM_REBASE_REPOS[@]}"

echo ""
echo -e "${BOLD}--- OADP-Owned openshift/ Repos ---${RESET}"
compare_field "require_self_approval" "${OADP_OWNED_OPENSHIFT_REPOS[@]}"
compare_field "review_acts_as_lgtm" "${OADP_OWNED_OPENSHIFT_REPOS[@]}"
compare_field "enforce_admins" "${OADP_OWNED_OPENSHIFT_REPOS[@]}"
compare_field "review_count" "${OADP_OWNED_OPENSHIFT_REPOS[@]}"
compare_field "dismiss_stale_reviews" "${OADP_OWNED_OPENSHIFT_REPOS[@]}"
compare_field "allow_force_pushes" "${OADP_OWNED_OPENSHIFT_REPOS[@]}"
compare_field "merge_method" "${OADP_OWNED_OPENSHIFT_REPOS[@]}"

echo ""
echo -e "${BOLD}--- OADP-Owned migtools/ Repos ---${RESET}"
compare_field "require_self_approval" "${OADP_OWNED_MIGTOOLS_REPOS[@]}"
compare_field "review_acts_as_lgtm" "${OADP_OWNED_MIGTOOLS_REPOS[@]}"
compare_field "enforce_admins" "${OADP_OWNED_MIGTOOLS_REPOS[@]}"
compare_field "review_count" "${OADP_OWNED_MIGTOOLS_REPOS[@]}"
compare_field "dismiss_stale_reviews" "${OADP_OWNED_MIGTOOLS_REPOS[@]}"
compare_field "allow_force_pushes" "${OADP_OWNED_MIGTOOLS_REPOS[@]}"
compare_field "merge_method" "${OADP_OWNED_MIGTOOLS_REPOS[@]}"

# --- Tide branch coverage comparison ---
section "Tide Branch Coverage"
echo "Branches included in Tide merge queries for each repo:"
echo ""
for repo in "${ALL_REPOS[@]}"; do
  if ! has_config "$repo"; then continue; fi
  branches="$(get_tide_branches "$repo")"
  if [[ -n "$branches" ]]; then
    echo "  $repo:"
    echo "    $branches"
  else
    warning "$repo: No includedBranches found in Tide config (uses excludedBranches or all-branch query)"
  fi
done

# --- Merge queue status ---
if [[ "$SKIP_QUEUE" != "true" ]]; then
  section "Merge Queue Status"

  if ! command -v gh &>/dev/null; then
    warning "gh CLI not found — skipping merge queue check (use --skip-queue to suppress)"
  else
    echo "PRs with approved+lgtm labels that haven't merged yet."
    echo "Tide merges one PR at a time per branch per repo; others wait in queue."
    echo ""

    PROW_BASE="https://prow.ci.openshift.org"

    QUEUE_TOTAL=0

    for repo in "${ALL_REPOS[@]}"; do
      if ! has_config "$repo"; then continue; fi

      # Fetch open PRs with approved+lgtm (include reviews for ack check)
      pr_json="$(gh pr list --repo "$repo" --state open --label approved --label lgtm \
        --json number,headRefName,baseRefName,author,title,labels,statusCheckRollup,reviews \
        2>/dev/null)" || continue

      pr_count="$(echo "$pr_json" | jq 'length')"
      if [[ "$pr_count" == "0" ]]; then continue; fi

      org="${repo%%/*}"
      reponame="${repo##*/}"

      # Get required review count and enforce_admins for this repo from prow config
      required_reviews="$(get_review_count "$repo")"
      enforce="$(get_enforce_admins "$repo")"

      echo -e "  ${BOLD}$repo${RESET} ($pr_count PRs with approved+lgtm)"
      if [[ "$required_reviews" != "NOT_SET" && "$required_reviews" != "MISSING_FILE" ]]; then
        echo "  Required GitHub reviews: $required_reviews (enforce_admins: ${enforce})"
      fi

      # Prow Tide query link for this repo
      prow_tide_url="${PROW_BASE}/tide?query=is%3Apr+state%3Aopen+repo%3A${org}%2F${reponame}"
      echo "  Tide: $prow_tide_url"
      echo ""

      # Normalize statusCheckRollup into unified format:
      #   GitHub Checks API entries have: name, status (COMPLETED/IN_PROGRESS/QUEUED), conclusion (SUCCESS/FAILURE/...)
      #   GitHub commit status entries have: context, state (SUCCESS/PENDING/FAILURE/ERROR)
      # We normalize to: {check_name, check_state} where check_state is one of: SUCCESS, FAILURE, PENDING, IN_PROGRESS, ERROR
      NORMALIZE_CHECKS_JQ='[.statusCheckRollup[] |
        {
          check_name: (.name // .context),
          check_state: (
            if .status == "COMPLETED" then (.conclusion // "UNKNOWN")
            elif .status == "IN_PROGRESS" then "IN_PROGRESS"
            elif .status == "QUEUED" then "PENDING"
            elif .state != null then (if .state == "SUCCESS" then "SUCCESS" elif .state == "FAILURE" then "FAILURE" elif .state == "ERROR" then "ERROR" else "PENDING" end)
            elif .status != null then .status
            else "PENDING"
            end
          )
        }
      ]'

      # Pre-scan: identify PRs that will block the Tide queue due to insufficient
      # reviews. Tide picks the first eligible PR per branch; if that PR has
      # approved+lgtm but not enough GitHub reviews, enforce_admins causes the
      # merge API call to fail, blocking all PRs behind it on the same branch.
      # We build a lookup: base_branch -> "blocker PR numbers and review needs"
      # stored in a temp file as "base_branch|pr_num|reviews_short" lines.
      review_blockers_file="$(mktemp)"

      if [[ "$required_reviews" != "NOT_SET" && "$required_reviews" != "MISSING_FILE" && "$enforce" == "true" ]]; then
        echo "$pr_json" | jq -c '.[]' | while IFS= read -r _pr; do
          _base="$(echo "$_pr" | jq -r '.baseRefName')"
          _num="$(echo "$_pr" | jq -r '.number')"
          _approvals="$(echo "$_pr" | jq -r '[.reviews[] | select(.state == "APPROVED") | .author.login] | unique | length')"
          # Check tide state
          _tide="$(echo "$_pr" | jq -r "$NORMALIZE_CHECKS_JQ" | jq -r '[.[] | select(.check_name == "tide") | .check_state] | first // "NOT_REPORTED"')"
          # Only flag as a queue blocker if Tide considers it eligible (SUCCESS)
          # but it will fail due to insufficient reviews
          if (( _approvals < required_reviews )) && [[ "$_tide" == "SUCCESS" ]]; then
            _short=$((required_reviews - _approvals))
            echo "${_base}|${_num}|${_short}" >> "$review_blockers_file"
          fi
        done
      fi

      echo "$pr_json" | jq -c '.[]' | while IFS= read -r pr; do
        pr_num="$(echo "$pr" | jq -r '.number')"
        pr_author="$(echo "$pr" | jq -r '.author.login')"
        pr_title="$(echo "$pr" | jq -r '.title')"
        pr_branch="$(echo "$pr" | jq -r '.headRefName')"
        pr_base="$(echo "$pr" | jq -r '.baseRefName')"
        pr_labels="$(echo "$pr" | jq -r '[.labels[].name] | join(",")')"

        # Check GitHub approving reviews vs required count
        # Only the latest review per author counts; filter for APPROVED state
        approving_reviewers="$(echo "$pr" | jq -r '[.reviews[] | select(.state == "APPROVED") | .author.login] | unique | .[]')"
        approval_count=0
        if [[ -n "$approving_reviewers" ]]; then
          approval_count="$(echo "$approving_reviewers" | wc -l | tr -d ' ')"
        fi

        # Normalize checks
        checks="$(echo "$pr" | jq -c "$NORMALIZE_CHECKS_JQ")"

        # Separate by state (exclude 'tide' context — it's Tide's own status, not a CI check)
        failing="$(echo "$checks" | jq -r '[.[] | select(.check_state == "FAILURE" and .check_name != "tide") | .check_name] | sort | .[]')"
        errored="$(echo "$checks" | jq -r '[.[] | select(.check_state == "ERROR" and .check_name != "tide") | .check_name] | sort | .[]')"
        pending="$(echo "$checks" | jq -r '[.[] | select(.check_state == "PENDING" and .check_name != "tide") | .check_name] | sort | .[]')"
        in_progress="$(echo "$checks" | jq -r '[.[] | select(.check_state == "IN_PROGRESS" and .check_name != "tide") | .check_name] | sort | .[]')"
        succeeded="$(echo "$checks" | jq -r '[.[] | select(.check_state == "SUCCESS" and .check_name != "tide") | .check_name] | sort | .[]')"

        # Tide status
        tide_state="$(echo "$checks" | jq -r '[.[] | select(.check_name == "tide") | .check_state] | first // "NOT_REPORTED"')"

        # Determine blocking labels
        label_blockers=()
        for blocker_label in "do-not-merge/hold" "do-not-merge/work-in-progress" \
          "do-not-merge/invalid-owners-file" "needs-rebase" "jira/invalid-bug" \
          "backports/unvalidated-commits"; do
          if echo "$pr_labels" | grep -qF "$blocker_label"; then
            label_blockers+=("$blocker_label")
          fi
        done

        # Build Prow PR query URL
        encoded_branch="$(echo "$pr_branch" | sed 's/ /%20/g; s/:/%3A/g; s|/|%2F|g')"
        prow_pr_url="${PROW_BASE}/pr?query=is%3Apr+repo%3A${org}%2F${reponame}+author%3A${pr_author}+head%3A${encoded_branch}"

        # Check if insufficient reviews will block merge (prow#134 workaround)
        missing_reviews=false
        reviews_short=0
        if [[ "$required_reviews" != "NOT_SET" && "$required_reviews" != "MISSING_FILE" && "$enforce" == "true" ]]; then
          if (( approval_count < required_reviews )); then
            missing_reviews=true
            reviews_short=$((required_reviews - approval_count))
          fi
        fi

        # Determine overall status
        has_blockers=false
        if [[ ${#label_blockers[@]} -gt 0 || -n "$failing" || -n "$errored" || -n "$pending" || -n "$in_progress" || "$missing_reviews" == "true" ]]; then
          has_blockers=true
        fi

        if $has_blockers; then
          echo -e "    ${RED}#${pr_num}${RESET} [${pr_base}] ${pr_title}"
        else
          echo -e "    ${GREEN}#${pr_num}${RESET} [${pr_base}] ${pr_title}"
        fi
        echo "      Author: ${pr_author}"
        echo "      PR:     https://github.com/${repo}/pull/${pr_num}"
        echo "      Prow:   $prow_pr_url"

        # Blocking labels
        if [[ ${#label_blockers[@]} -gt 0 ]]; then
          for lbl in "${label_blockers[@]}"; do
            echo -e "      ${RED}BLOCKED${RESET}  label: $lbl"
          done
        fi

        # Insufficient GitHub reviews (enforce_admins blocks Tide merge)
        if [[ "$missing_reviews" == "true" ]]; then
          echo -e "      ${RED}REVIEWS${RESET}  ${approval_count}/${required_reviews} GitHub approvals (need $reviews_short more)"
          echo -e "               ${YELLOW}Tide will attempt merge but GitHub will reject (enforce_admins + prow#134)${RESET}"
          echo -e "               ${YELLOW}This PR may BLOCK other PRs behind it in the Tide queue for ${pr_base}${RESET}"
        elif [[ "$required_reviews" != "NOT_SET" && "$required_reviews" != "MISSING_FILE" ]]; then
          echo -e "      ${GREEN}REVIEWS${RESET}  ${approval_count}/${required_reviews} GitHub approvals"
        fi

        # Failed checks
        if [[ -n "$failing" ]]; then
          while IFS= read -r check_name; do
            echo -e "      ${RED}FAILED${RESET}   $check_name"
          done <<< "$failing"
        fi

        # Errored checks
        if [[ -n "$errored" ]]; then
          while IFS= read -r check_name; do
            echo -e "      ${RED}ERROR${RESET}    $check_name"
          done <<< "$errored"
        fi

        # In-progress checks (currently running — likely Tide retest)
        if [[ -n "$in_progress" ]]; then
          while IFS= read -r check_name; do
            echo -e "      ${YELLOW}RUNNING${RESET}  $check_name"
          done <<< "$in_progress"
        fi

        # Pending checks (not yet triggered)
        if [[ -n "$pending" ]]; then
          pending_count="$(echo "$pending" | wc -l | tr -d ' ')"
          if [[ "$pending_count" -le 5 ]]; then
            while IFS= read -r check_name; do
              echo -e "      ${YELLOW}PENDING${RESET}  $check_name"
            done <<< "$pending"
          else
            # Show first 3 and summarize the rest
            echo "$pending" | head -3 | while IFS= read -r check_name; do
              echo -e "      ${YELLOW}PENDING${RESET}  $check_name"
            done
            remaining=$((pending_count - 3))
            echo -e "      ${YELLOW}PENDING${RESET}  ... and $remaining more"
          fi
        fi

        # Tide context status
        if [[ "$tide_state" == "SUCCESS" ]]; then
          echo -e "      ${GREEN}TIDE${RESET}     merge criteria met — merging soon"
        elif [[ "$tide_state" == "PENDING" ]]; then
          # Check if any review-blocked PRs are ahead on the same branch
          branch_blockers=""
          if [[ -s "$review_blockers_file" ]]; then
            while IFS='|' read -r b_base b_num b_short; do
              if [[ "$b_base" == "$pr_base" && "$b_num" != "$pr_num" ]]; then
                branch_blockers="${branch_blockers:+$branch_blockers, }#${b_num} (needs ${b_short} more review(s) — https://github.com/${repo}/pull/${b_num})"
              fi
            done < "$review_blockers_file"
          fi

          if [[ -n "$branch_blockers" ]]; then
            echo -e "      ${CYAN}TIDE${RESET}     waiting — review-blocked PRs ahead in queue: ${YELLOW}${branch_blockers}${RESET}"
          else
            echo -e "      ${CYAN}TIDE${RESET}     waiting (another PR may be testing ahead in queue)"
          fi
        fi

        # All green — but may still be stuck behind a review-blocked PR
        if ! $has_blockers; then
          ready_blockers=""
          if [[ -s "$review_blockers_file" ]]; then
            while IFS='|' read -r b_base b_num b_short; do
              if [[ "$b_base" == "$pr_base" && "$b_num" != "$pr_num" ]]; then
                ready_blockers="${ready_blockers:+$ready_blockers, }#${b_num} (needs ${b_short} more review(s) — https://github.com/${repo}/pull/${b_num})"
              fi
            done < "$review_blockers_file"
          fi

          if [[ -n "$ready_blockers" ]]; then
            echo -e "      ${GREEN}READY${RESET}    All checks passed, no blocking labels — but review-blocked PRs may delay merge: ${YELLOW}${ready_blockers}${RESET}"
          else
            echo -e "      ${GREEN}READY${RESET}    All checks passed, no blocking labels — merge imminent"
          fi
        fi

        echo ""
      done

      rm -f "$review_blockers_file"

      ((QUEUE_TOTAL += pr_count))
    done

    if [[ "$QUEUE_TOTAL" == "0" ]]; then
      ok "No PRs stuck in merge queue across all repos"
    fi
  fi
fi

# --- Summary ---
section "Summary"
echo -e "Issues:   ${RED}$ISSUES${RESET}"
echo -e "Warnings: ${YELLOW}$WARNINGS${RESET}"
echo -e "Info:     ${CYAN}$INFO${RESET}"

if (( ISSUES > 0 )); then
  echo ""
  echo "Issues indicate missing or broken configuration that should be fixed."
fi
if (( WARNINGS > 0 )); then
  echo ""
  echo "Warnings indicate deviations from the expected pattern for the repo type."
  echo "Some may be intentional — review each case."
fi

exit 0
