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
#   ./audit.sh [--branch main] [--format text|markdown|interactive] [--skip-queue] [--local <path>]
#
# Environment:
#   GITHUB_TOKEN  - optional, avoids GitHub API rate limits for raw content
#                   auto-detected from `gh auth token` when gh CLI is available

set -euo pipefail

#
# Defaults
#
FORMAT=""
BRANCH="main"
SKIP_QUEUE="false"
LOCAL_RELEASE=""
RAW_BASE="https://raw.githubusercontent.com/openshift/release"

# Auto-detect GITHUB_TOKEN from gh CLI if not already set
if [[ -z "${GITHUB_TOKEN:-}" ]] && command -v gh &>/dev/null; then
  GITHUB_TOKEN="$(gh auth token 2>/dev/null)" || true
fi

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
  "migtools/oadp-vmdp"
  "migtools/kopia"
)

# Repos expected to have no prow config (no CI in OpenShift CI)
NO_PROW_CONFIG_REPOS=(
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
      echo "Usage: $0 [--branch main] [--format text|markdown|interactive] [--skip-queue] [--local <path>]"
      echo ""
      echo "Audits Prow merge bot configs across OADP ecosystem repositories."
      echo ""
      echo "Options:"
      echo "  --branch BRANCH   Branch of openshift/release to fetch from (default: main)"
      echo "  --format FORMAT   Output format: text, markdown, or interactive"
      echo "                    (default: interactive in terminal, text otherwise)"
      echo "  --skip-queue      Skip merge queue status check (requires gh CLI)"
      echo "  --local PATH      Use a local openshift/release checkout instead of fetching via curl"
      echo ""
      echo "Interactive mode keys:"
      echo "  j/k, ↑/↓          Navigate up/down"
      echo "  Enter/Space        Toggle section expand/collapse"
      echo "  e/c                Expand/collapse all sections"
      echo "  g/G                Jump to top/bottom"
      echo "  f                  Toggle fullscreen (hide/show status bar)"
      echo "  m                  Check merge queue for repo under cursor"
      echo "  M                  Check merge queue for all repos (background)"
      echo "  r                  Refresh all (re-run full audit)"
      echo "  R                  Refresh repo under cursor only"
      echo "  q                  Quit (prints output to terminal)"
      echo ""
      echo "Mouse support:"
      echo "  Left click         Toggle section / click [r]efresh / click [m] for merge queue"
      echo "  Right click        Refresh repo under cursor"
      echo "  Scroll wheel       Navigate up/down"
      echo ""
      echo "Environment:"
      echo "  GITHUB_TOKEN      Optional token to avoid GitHub rate limits (ignored with --local)"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: $0 [--branch main] [--format text|markdown|interactive] [--skip-queue] [--local <path>]" >&2
      exit 1
      ;;
  esac
done

#
# Bash 4+ required for interactive mode (fractional read -t, associative arrays)
#
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  if [[ "$FORMAT" == "interactive" ]]; then
    echo "Error: Interactive mode requires bash 4+ (you have bash ${BASH_VERSION})." >&2
    echo "  Install newer bash:  brew install bash" >&2
    echo "  Or use text output:  $0 --format text" >&2
    exit 1
  fi
  if [[ -z "$FORMAT" && -t 1 ]]; then
    echo "Warning: bash ${BASH_VERSION} detected — interactive TUI requires bash 4+." >&2
    echo "  Install newer bash:  brew install bash" >&2
    echo "  Falling back to --format text." >&2
    FORMAT="text"
  fi
fi

#
# Auto-detect format: interactive TUI if terminal + no explicit --format, else text
#
if [[ -z "$FORMAT" ]]; then
  if [[ -t 1 ]]; then
    FORMAT="interactive"
  else
    FORMAT="text"
  fi
fi

#
# Temp directory for fetched configs — cleaned up on exit
#
CACHE_DIR="$(mktemp -d)"
cleanup() {
  # Kill spinner if still running (read PID from file for subshell compatibility)
  if [[ -n "${_SPINNER_PID_FILE:-}" && -f "$_SPINNER_PID_FILE" ]]; then
    local pid
    pid="$(cat "$_SPINNER_PID_FILE" 2>/dev/null)" || true
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
    fi
  fi
  rm -rf "$CACHE_DIR"
}
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
if [[ "$FORMAT" != "markdown" ]] && [[ -t 1 ]]; then
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
# Rate limit tracking (global, updated by fetch_rate_limit)
#
_RATE_REMAINING=""
_RATE_LIMIT=""
_RATE_RESET=""
_RATE_RESET_HUMAN=""

fetch_rate_limit() {
  _RATE_REMAINING=""
  _RATE_LIMIT=""
  _RATE_RESET=""
  _RATE_RESET_HUMAN=""

  if ! command -v gh &>/dev/null || ! command -v jq &>/dev/null; then
    return 0
  fi

  local rate_json
  rate_json="$(gh api rate_limit 2>/dev/null)" || return 0

  _RATE_REMAINING="$(echo "$rate_json" | jq -r '.resources.core.remaining' 2>/dev/null)" || true
  _RATE_LIMIT="$(echo "$rate_json" | jq -r '.resources.core.limit' 2>/dev/null)" || true
  _RATE_RESET="$(echo "$rate_json" | jq -r '.resources.core.reset' 2>/dev/null)" || true

  if [[ -n "$_RATE_RESET" && "$_RATE_RESET" != "null" ]]; then
    # macOS: date -r EPOCH; Linux: date -d @EPOCH
    _RATE_RESET_HUMAN="$(date -u -r "$_RATE_RESET" +%H:%M 2>/dev/null)" \
      || _RATE_RESET_HUMAN="$(date -u -d "@$_RATE_RESET" +%H:%M 2>/dev/null)" \
      || _RATE_RESET_HUMAN=""
  fi
}

#
# TUI interactive viewer — collapsible sections, keyboard navigation
#
tui_viewer() {
  local input_file="$1"
  _TUI_INPUT_FILE="$input_file"  # global copy for trap handler
  _TUI_ACTION="quit"
  _REFRESH_REPO=""
  _MERGE_QUEUE_REPO=""
  local -a lines=()
  local -a is_header=()       # 1 if line is a section header, 0 otherwise
  local -a section_id=()      # section index for each line (-1 if before first section)
  local -a collapsed=()       # 1 if section is collapsed
  local -a line_repo_cache=() # cached repo name per line (empty if none)
  local num_sections=0
  local current_section=-1

  # Detect a repo name (org/repo) on a given line of text
  detect_repo_on_line() {
    local text="$1"
    local all_repos=(
      "${UPSTREAM_REBASE_REPOS[@]}"
      "${OADP_OWNED_OPENSHIFT_REPOS[@]}"
      "${OADP_OWNED_MIGTOOLS_REPOS[@]}"
      ${NO_PROW_CONFIG_REPOS[@]+"${NO_PROW_CONFIG_REPOS[@]}"}
    )
    local repo
    for repo in "${all_repos[@]}"; do
      if [[ "$text" == *"$repo"* ]]; then
        echo "$repo"
        return 0
      fi
    done
    return 1
  }

  # Parse input into lines and identify section headers
  local strip_ansi_re=$'s/\033\[[0-9;]*m//g'
  while IFS= read -r line || [[ -n "$line" ]]; do
    lines+=("$line")
    local stripped
    stripped="$(echo "$line" | sed "$strip_ansi_re")"
    # Cache repo detection per line
    local _detected_repo=""
    _detected_repo="$(detect_repo_on_line "$stripped")" || true
    line_repo_cache+=("$_detected_repo")
    if [[ "$stripped" =~ ^===\ .+\ ===$ ]]; then
      is_header+=("1")
      current_section=$num_sections
      section_id+=("$current_section")
      collapsed+=("0")
      ((num_sections++)) || true
    else
      is_header+=("0")
      section_id+=("$current_section")
    fi
  done < "$input_file"

  local total=${#lines[@]}
  if (( total == 0 )); then
    return 0
  fi

  # Build visible lines list based on collapsed state
  local -a visible=()   # indices into lines[]
  build_visible() {
    visible=()
    local i sid
    for (( i = 0; i < total; i++ )); do
      if [[ "${is_header[$i]}" == "1" ]]; then
        visible+=("$i")
      elif [[ "${section_id[$i]}" == "-1" ]]; then
        # Lines before first section — always visible
        visible+=("$i")
      else
        sid="${section_id[$i]}"
        if [[ "${collapsed[$sid]}" == "0" ]]; then
          visible+=("$i")
        fi
      fi
    done
  }

  build_visible

  if [[ ${#visible[@]} -eq 0 ]]; then
    return 0
  fi

  # Track file line count for live reload (merge queue appends in background)
  local _last_line_count=$total

  # Reload new lines from input file if it has grown (preserves collapse state)
  reload_if_changed() {
    local current_count
    current_count="$(wc -l < "$input_file" 2>/dev/null | tr -d ' ')" || return
    # Account for final line without trailing newline (matches initial parse behavior)
    if [[ -s "$input_file" ]] && [[ "$(tail -c1 "$input_file" 2>/dev/null)" != "" ]]; then
      current_count=$(( current_count + 1 ))
    fi
    if [[ "$current_count" -le "$_last_line_count" ]]; then
      return
    fi

    # Read only new lines using process substitution (avoids subshell)
    local new_line
    while IFS= read -r new_line || [[ -n "$new_line" ]]; do
      lines+=("$new_line")
      local stripped
      stripped="$(echo "$new_line" | sed "$strip_ansi_re")"
      # Cache repo detection for new line
      local _detected_repo=""
      _detected_repo="$(detect_repo_on_line "$stripped")" || true
      line_repo_cache+=("$_detected_repo")
      if [[ "$stripped" =~ ^===\ .+\ ===$ ]]; then
        is_header+=("1")
        current_section=$num_sections
        section_id+=("$current_section")
        collapsed+=("0")
        ((num_sections++)) || true
      else
        is_header+=("0")
        section_id+=("$current_section")
      fi
    done < <(tail -n "+$((_last_line_count + 1))" "$input_file" 2>/dev/null)

    total=${#lines[@]}
    _last_line_count=$current_count
    build_visible
    clamp_cursor
  }

  local cursor=0
  local scroll=0
  local _fullscreen=0
  local term_rows term_cols view_rows
  term_rows="$(tput lines 2>/dev/null)" || term_rows=24
  term_cols="$(tput cols 2>/dev/null)" || term_cols=80
  view_rows=$(( term_rows - 2 ))  # reserve 1 for status bar, 1 for padding

  # Enter alternate screen, hide cursor, enable mouse
  tput smcup 2>/dev/null || true
  tput civis 2>/dev/null || true
  printf '\x1b[?1000h\x1b[?1006h' 2>/dev/null || true  # SGR mouse reporting

  # Restore terminal on exit
  TUI_CLEANUP_DONE=0
  tui_restore_term() {
    if [[ "${TUI_CLEANUP_DONE:-0}" == "0" ]]; then
      TUI_CLEANUP_DONE=1
      printf '\x1b[?1000l\x1b[?1006l' 2>/dev/null || true  # disable mouse
      tput cnorm 2>/dev/null || true
      tput rmcup 2>/dev/null || true
    fi
  }
  # On unexpected exit: restore terminal, print output, then chain to original cleanup
  tui_trap() {
    tui_restore_term
    cat "${_TUI_INPUT_FILE:-}" 2>/dev/null || true
    cleanup 2>/dev/null || true
  }
  trap tui_trap EXIT INT TERM

  # Read interactive input from the terminal directly
  exec 4</dev/tty

  # Update terminal size (called on SIGWINCH and at start)
  local _term_dirty=1
  update_term_size() { _term_dirty=1; }
  trap update_term_size WINCH

  render() {
    # Only re-read terminal size when it changed
    if [[ $_term_dirty -eq 1 ]]; then
      term_rows="$(tput lines 2>/dev/null)" || term_rows=24
      term_cols="$(tput cols 2>/dev/null)" || term_cols=80
      if [[ $_fullscreen -eq 1 ]]; then
        view_rows=$term_rows
      else
        view_rows=$(( term_rows - 2 ))
      fi
      if [[ $view_rows -lt 1 ]]; then view_rows=1; fi
      _term_dirty=0
    fi

    # Adjust scroll to keep cursor visible
    if [[ $cursor -lt $scroll ]]; then
      scroll=$cursor
    elif [[ $cursor -ge $(( scroll + view_rows )) ]]; then
      scroll=$(( cursor - view_rows + 1 ))
    fi

    local max_scroll=$(( ${#visible[@]} - view_rows ))
    if [[ $max_scroll -lt 0 ]]; then max_scroll=0; fi
    if [[ $scroll -gt $max_scroll ]]; then scroll=$max_scroll; fi

    # Build full frame in buffer, then write at once (reduces flicker)
    local buf=""
    buf+='\033[2J\033[H'

    # [m] button is 3 chars + 1 space padding, right-aligned
    _mq_btn_col=$(( term_cols - 3 ))  # 1-based column where [m] starts
    _row_repo=()

    local row vi li line prefix max_line_len display_line sid
    max_line_len=$(( term_cols - 7 ))  # leave room for " [m]" at right edge
    for (( row = 0; row < view_rows; row++ )); do
      vi=$(( scroll + row ))
      if [[ $vi -ge ${#visible[@]} ]]; then
        buf+=$'\n'
        continue
      fi
      li="${visible[$vi]}"
      line="${lines[$li]}"

      if [[ "${is_header[$li]}" == "1" ]]; then
        sid="${section_id[$li]}"
        if [[ "${collapsed[$sid]}" == "1" ]]; then
          prefix="▶ "
        else
          prefix="▼ "
        fi
      else
        prefix="  "
      fi

      # Use cached repo detection for [m] button
      local line_repo="${line_repo_cache[$li]:-}"
      local screen_row=$(( row + 1 ))  # 1-based for mouse coords

      # Truncate to terminal width (leaving space for [m] button if repo detected)
      if [[ -n "$line_repo" ]]; then
        display_line="${line:0:$max_line_len}"
        _row_repo[$screen_row]="$line_repo"
      else
        display_line="${line:0:$(( term_cols - 3 ))}"
      fi

      if [[ $vi -eq $cursor ]]; then
        if [[ -n "$line_repo" ]]; then
          buf+="\033[7m${prefix}${display_line}\033[0m"
          # Right-align [m] button
          buf+="\033[${screen_row};${_mq_btn_col}H\033[36m[m]\033[0m"$'\n'
        else
          buf+="\033[7m${prefix}${display_line}\033[0m"$'\n'
        fi
      else
        if [[ -n "$line_repo" ]]; then
          buf+="${prefix}${display_line}"
          buf+="\033[${screen_row};${_mq_btn_col}H\033[36m[m]\033[0m"$'\n'
        else
          buf+="${prefix}${display_line}"$'\n'
        fi
      fi
    done

    # Status bar at bottom (hidden in fullscreen mode)
    if [[ $_fullscreen -eq 0 ]]; then
      buf+="\033[${term_rows};1H"

      local status_left=" ↑↓/jk: nav │ click: toggle │ e/c: all"
      local status_rate=""
      if [[ -n "${_RATE_REMAINING:-}" && -n "${_RATE_LIMIT:-}" ]]; then
        if [[ "${_RATE_REMAINING:-0}" -le 0 ]] 2>/dev/null; then
          status_rate=" │ \033[31mAPI: ${_RATE_REMAINING}/${_RATE_LIMIT}"
          if [[ -n "${_RATE_RESET_HUMAN:-}" ]]; then
            status_rate+=" until ${_RATE_RESET_HUMAN}UTC"
          fi
          status_rate+="\033[0m\033[7m"
        elif [[ "${_RATE_REMAINING:-0}" -lt 100 ]] 2>/dev/null; then
          status_rate=" │ \033[33mAPI: ${_RATE_REMAINING}/${_RATE_LIMIT}"
          if [[ -n "${_RATE_RESET_HUMAN:-}" ]]; then
            status_rate+=" resets ${_RATE_RESET_HUMAN}UTC"
          fi
          status_rate+="\033[0m\033[7m"
        else
          status_rate=" │ API: ${_RATE_REMAINING}/${_RATE_LIMIT}"
        fi
      fi

      local status_loading=""
      if [[ -n "${_MERGE_QUEUE_BG_PID:-}" ]] && kill -0 "$_MERGE_QUEUE_BG_PID" 2>/dev/null; then
        status_loading=" │ \033[33mloading...\033[0m\033[7m"
      fi
      local status_right=" │ m: queue │ M: all${status_loading} │ [r]efresh │ q: quit "
      buf+="\033[7m${status_left}${status_rate}${status_right}\033[0m"

      # Compute refresh button click target from full prefix before "[r]efresh"
      local status_before_refresh="${status_left}${status_rate} │ m: queue │ M: all${status_loading} │ "
      local status_before_plain
      status_before_plain="$(printf '%b' "$status_before_refresh" | sed "$strip_ansi_re")"
      _status_bar_row=$term_rows
      _refresh_col_start=$(( ${#status_before_plain} + 1 ))  # 1-based column
      _refresh_col_end=$(( _refresh_col_start + 8 ))          # "[r]efresh" = 9 chars
    fi

    printf '%b' "$buf"
  }

  render

  # Helper to clamp cursor to visible bounds
  clamp_cursor() {
    if [[ $cursor -ge ${#visible[@]} ]]; then
      cursor=$(( ${#visible[@]} - 1 ))
    fi
    if [[ $cursor -lt 0 ]]; then cursor=0; fi
  }

  # Returns 0 to continue, 1 to quit
  local _quit=0
  handle_key() {
    local key="$1"
    case "$key" in
      q)
        _TUI_ACTION="quit"
        _quit=1
        ;;
      r)
        _TUI_ACTION="refresh"
        _REFRESH_REPO=""
        _quit=1
        ;;
      R)
        # Single-repo refresh: detect repo from current line
        if [[ $cursor -lt ${#visible[@]} ]]; then
          local cur_li="${visible[$cursor]}"
          local cur_line="${lines[$cur_li]}"
          local stripped
          stripped="$(echo "$cur_line" | sed "$strip_ansi_re")"
          local detected=""
          detected="$(detect_repo_on_line "$stripped")" || true
          if [[ -n "$detected" ]]; then
            _TUI_ACTION="refresh"
            _REFRESH_REPO="$detected"
            _quit=1
          fi
        fi
        ;;
      j)
        if [[ $cursor -lt $(( ${#visible[@]} - 1 )) ]]; then
          cursor=$(( cursor + 1 ))
        fi
        ;;
      k)
        if [[ $cursor -gt 0 ]]; then
          cursor=$(( cursor - 1 ))
        fi
        ;;
      g)
        cursor=0
        scroll=0
        ;;
      G)
        cursor=$(( ${#visible[@]} - 1 ))
        ;;
      f)
        if [[ $_fullscreen -eq 0 ]]; then _fullscreen=1; else _fullscreen=0; fi
        _term_dirty=1
        ;;
      e)
        local si
        for (( si = 0; si < num_sections; si++ )); do
          collapsed[$si]="0"
        done
        build_visible
        clamp_cursor
        ;;
      c)
        local si
        for (( si = 0; si < num_sections; si++ )); do
          collapsed[$si]="1"
        done
        build_visible
        clamp_cursor
        ;;
      m)
        # Single-repo merge queue check: detect repo from current line
        if [[ $cursor -lt ${#visible[@]} ]]; then
          local cur_li="${visible[$cursor]}"
          local cur_line="${lines[$cur_li]}"
          local stripped
          stripped="$(echo "$cur_line" | sed "$strip_ansi_re")"
          local detected=""
          detected="$(detect_repo_on_line "$stripped")" || true
          if [[ -n "$detected" ]]; then
            _TUI_ACTION="merge_queue"
            _MERGE_QUEUE_REPO="$detected"
            _quit=1
          fi
        fi
        ;;
      M)
        # Check merge queue for all repos
        _TUI_ACTION="merge_queue_all"
        _quit=1
        ;;
      "" | " ")  # Enter or Space
        if [[ $cursor -lt ${#visible[@]} ]]; then
          local vi_line="${visible[$cursor]}"
          if [[ "${is_header[$vi_line]}" == "1" ]]; then
            local sid="${section_id[$vi_line]}"
            if [[ "${collapsed[$sid]}" == "1" ]]; then
              collapsed[$sid]="0"
            else
              collapsed[$sid]="1"
            fi
            build_visible
            clamp_cursor
          fi
        fi
        ;;
    esac
  }



  # Click target tracking (set by render, read by handle_mouse)
  local _status_bar_row=0
  local _refresh_col_start=0
  local _refresh_col_end=0
  # Per-row merge queue button: maps screen row (1-based) to repo name
  local -a _row_repo=()
  local _mq_btn_col=0  # column where [m] buttons start (set by render)

  # Handle mouse events (SGR format: button;col;row)
  handle_mouse() {
    local params="$1" terminator="$2"
    # Only act on press events (M), ignore release (m)
    [[ "$terminator" != "M" ]] && return

    local button col row
    IFS=';' read -r button col row <<< "$params"

    # Validate numeric
    [[ "$button" =~ ^[0-9]+$ && "$col" =~ ^[0-9]+$ && "$row" =~ ^[0-9]+$ ]] || return

    case "$button" in
      64) handle_key k ;;  # Scroll wheel up
      65) handle_key j ;;  # Scroll wheel down
      0)  # Left click
        # Check refresh button in status bar
        if [[ $row -eq $_status_bar_row && $col -ge $_refresh_col_start && $col -le $_refresh_col_end ]]; then
          _TUI_ACTION="refresh"
          _REFRESH_REPO=""
          _quit=1
          return
        fi
        # Check [m] merge queue button on repo lines
        if [[ $col -ge $_mq_btn_col && $col -le $(( _mq_btn_col + 2 )) && -n "${_row_repo[$row]:-}" ]]; then
          _TUI_ACTION="merge_queue"
          _MERGE_QUEUE_REPO="${_row_repo[$row]}"
          _quit=1
          return
        fi
        # Map click to visible line
        local clicked_vi=$(( scroll + row - 1 ))  # row is 1-based
        if [[ $clicked_vi -ge 0 && $clicked_vi -lt ${#visible[@]} ]]; then
          cursor=$clicked_vi
          local clicked_li="${visible[$clicked_vi]}"
          if [[ "${is_header[$clicked_li]}" == "1" ]]; then
            local sid="${section_id[$clicked_li]}"
            if [[ "${collapsed[$sid]}" == "1" ]]; then
              collapsed[$sid]="0"
            else
              collapsed[$sid]="1"
            fi
            build_visible
            clamp_cursor
          fi
        fi
        ;;
      2)  # Right click — single-repo refresh
        local clicked_vi=$(( scroll + row - 1 ))
        if [[ $clicked_vi -ge 0 && $clicked_vi -lt ${#visible[@]} ]]; then
          local clicked_li="${visible[$clicked_vi]}"
          local clicked_line="${lines[$clicked_li]}"
          local stripped
          stripped="$(echo "$clicked_line" | sed "$strip_ansi_re")"
          local detected_repo=""
          detected_repo="$(detect_repo_on_line "$stripped")" || true
          if [[ -n "$detected_repo" ]]; then
            _TUI_ACTION="refresh"
            _REFRESH_REPO="$detected_repo"
            _quit=1
          fi
        fi
        ;;
    esac
  }

  # Parse escape sequences and dispatch
  handle_escape() {
    local seq=""
    IFS= read -rsn1 -t 0.3 -u4 seq || true
    if [[ "$seq" == "[" ]]; then
      IFS= read -rsn1 -t 0.3 -u4 seq || true
      case "$seq" in
        A) handle_key k ;;   # Up arrow
        B) handle_key j ;;   # Down arrow
        C|D) ;;              # Left/Right arrow — ignore
        '<')  # SGR mouse event: \x1b[<button;col;rowM/m
          local sgr_buf="" sgr_char="" sgr_count=0
          while (( sgr_count++ < 32 )) && IFS= read -rsn1 -t 0.1 -u4 sgr_char; do
            if [[ "$sgr_char" == "M" || "$sgr_char" == "m" ]]; then
              handle_mouse "$sgr_buf" "$sgr_char"
              break
            fi
            sgr_buf+="$sgr_char"
          done
          ;;
        M)  # Legacy X10 mouse — consume 3 bytes individually
          local _x10_i=0
          while (( _x10_i++ < 3 )); do IFS= read -rsn1 -t 0.1 -u4 _ || break; done
          ;;
        *)  # Unknown CSI — drain (limit to 32 chars)
          local _csi_drain=0
          while (( _csi_drain++ < 32 )) && IFS= read -rsn1 -t 0.1 -u4 _ 2>/dev/null; do :; done
          ;;
      esac
    elif [[ "$seq" == "O" ]]; then
      IFS= read -rsn1 -t 0.3 -u4 seq || true
      case "$seq" in
        A) handle_key k ;; B) handle_key j ;; *) ;;
      esac
    fi
  }

  # Main input loop — read from /dev/tty via fd 4
  # Uses timeout so we can periodically check for new file content (background merge queue)
  local key=""
  while true; do
    if IFS= read -rsn1 -t 0.5 -u4 key 2>/dev/null; then
      if [[ "$key" == $'\x1b' ]]; then
        handle_escape
      else
        handle_key "$key"
      fi
      [[ $_quit -eq 1 ]] && break

      # Drain queued input before re-rendering (prevents scroll flood, max 64 events)
      local _drain=0
      while (( _drain++ < 64 )) && IFS= read -rsn1 -t 0.01 -u4 key 2>/dev/null; do
        if [[ "$key" == $'\x1b' ]]; then
          handle_escape
        else
          handle_key "$key"
        fi
        [[ $_quit -eq 1 ]] && break
      done
      [[ $_quit -eq 1 ]] && break
    fi

    # Check for new content from background processes
    reload_if_changed

    render
  done

  exec 4<&-

  # Restore terminal, then print output to scrollback (before cleanup deletes temp dir)
  tui_restore_term
  cat "$input_file"

  # Restore original cleanup trap (tui_trap no longer needed)
  trap cleanup EXIT
}

#
# Interactive mode: capture stdout to temp file for TUI viewer
#
TUI_OUTPUT=""
_SPINNER_PID_FILE=""

_start_spinner() {
  _stop_spinner
  local msg="$1"
  (
    while true; do
      printf '\r\033[K  %s   ' "$msg" >&3
      sleep 0.3
      printf '\r\033[K  %s.  ' "$msg" >&3
      sleep 0.3
      printf '\r\033[K  %s.. ' "$msg" >&3
      sleep 0.3
      printf '\r\033[K  %s...' "$msg" >&3
      sleep 0.3
    done
  ) &
  local pid=$!
  disown "$pid" 2>/dev/null || true
  # Write PID to file so subshells (pipelines) can track it
  if [[ -n "${_SPINNER_PID_FILE:-}" ]]; then
    echo "$pid" > "$_SPINNER_PID_FILE"
  fi
}

_stop_spinner() {
  if [[ -n "${_SPINNER_PID_FILE:-}" && -f "$_SPINNER_PID_FILE" ]]; then
    local pid
    pid="$(cat "$_SPINNER_PID_FILE" 2>/dev/null)" || true
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
      printf '\r\033[K' >&3 2>/dev/null || true
    fi
    rm -f "$_SPINNER_PID_FILE"
  fi
}

if [[ "$FORMAT" == "interactive" ]]; then
  TUI_OUTPUT="$CACHE_DIR/tui-output.txt"
  _SPINNER_PID_FILE="$CACHE_DIR/.spinner-pid"
  exec 3>&1 1>"$TUI_OUTPUT"

  # Override section() to show loading progress on terminal
  section() {
    _stop_spinner
    echo ""; echo -e "${BOLD}=== $1 ===${RESET}"
    _start_spinner "$1"
  }

  # Show current repo/PR being processed under the section spinner
  _show_status() {
    _stop_spinner
    _start_spinner "$1"
  }

  _start_spinner "Initializing audit"
else
  _show_status() { :; }
fi

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
# Check if a repo has config (at least one of the files exists)
#
has_config() {
  local plugin prow
  plugin="$(pluginconfig_for "$1")"
  prow="$(prowconfig_for "$1")"
  [[ -f "$plugin" || -f "$prow" ]]
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

fetch_rate_limit

run_audit() {
# Reset counters for refresh
ISSUES=0; WARNINGS=0; INFO=0

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
  ${NO_PROW_CONFIG_REPOS[@]+"${NO_PROW_CONFIG_REPOS[@]}"}
)

FETCH_ERRORS=0
for repo in "${ALL_REPOS_TO_FETCH[@]}"; do
  _show_status "Fetching configs: $repo"
  fetch_configs "$repo" || ((FETCH_ERRORS++)) || true
done
echo " done (${#ALL_REPOS_TO_FETCH[@]} repos, $FETCH_ERRORS without configs)"

# --- Check repos with no expected config ---
section "Repos With No Prow Config (Expected)"
for repo in ${NO_PROW_CONFIG_REPOS[@]+"${NO_PROW_CONFIG_REPOS[@]}"}; do
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
  _show_status "Checking $repo"
  audit_repo "$repo" "upstream-rebase"
done

# --- Audit OADP-owned openshift/ repos ---
section "OADP-Owned Repos (openshift/ org)"
echo "These repos should have enforce_admins, review count, and dismiss_stale_reviews."
echo ""
for repo in "${OADP_OWNED_OPENSHIFT_REPOS[@]}"; do
  _show_status "Checking $repo"
  audit_repo "$repo" "oadp-owned-openshift"
done

# --- Audit OADP-owned migtools/ repos ---
section "OADP-Owned Repos (migtools/ org)"
echo "These repos should have enforce_admins, review count, and dismiss_stale_reviews."
echo "Note: migtools repos list plugins explicitly (no org-level inheritance)."
echo ""
for repo in "${OADP_OWNED_MIGTOOLS_REPOS[@]}"; do
  _show_status "Checking $repo"
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

# --- Summary (config audit only — merge queue updates these counters too) ---
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

if [[ "$FORMAT" == "interactive" && "$SKIP_QUEUE" != "true" ]]; then
  echo ""
  echo "Press m on a repo line to check its merge queue, or M to check all repos."
fi
}

#
# Check merge queue for a single repo. Outputs results to stdout.
# Usage: check_merge_queue_repo "org/repo"
#
check_merge_queue_repo() {
  local repo="$1"
  if ! has_config "$repo"; then return; fi
  if ! command -v gh &>/dev/null; then
    echo -e "  ${YELLOW}WARNING${RESET} gh CLI not found — cannot check merge queue"
    return
  fi

  local org="${repo%%/*}"
  local reponame="${repo##*/}"

  _show_status "Merge queue: $repo"

  # Fetch open PRs with approved+lgtm (include reviews for ack check)
  local pr_json
  pr_json="$(gh pr list --repo "$repo" --state open --label approved --label lgtm \
    --json number,headRefName,baseRefName,author,title,labels,statusCheckRollup,reviews \
    2>/dev/null)" || return

  local pr_count
  pr_count="$(echo "$pr_json" | jq 'length')"
  if [[ "$pr_count" == "0" ]]; then
    echo -e "  ${BOLD}$repo${RESET}: No PRs in merge queue"
    return
  fi

  # Get required review count and enforce_admins for this repo from prow config
  local required_reviews enforce
  required_reviews="$(get_review_count "$repo")"
  enforce="$(get_enforce_admins "$repo")"

  echo -e "  ${BOLD}$repo${RESET} ($pr_count PRs with approved+lgtm)"
  if [[ "$required_reviews" != "NOT_SET" && "$required_reviews" != "MISSING_FILE" ]]; then
    echo "  Required GitHub reviews: $required_reviews (enforce_admins: ${enforce})"
  fi

  # Prow Tide query link for this repo
  local PROW_BASE="https://prow.ci.openshift.org"
  local prow_tide_url="${PROW_BASE}/tide?query=is%3Apr+state%3Aopen+repo%3A${org}%2F${reponame}"
  echo "  Tide: $prow_tide_url"
  echo ""

  # Normalize statusCheckRollup into unified format
  local NORMALIZE_CHECKS_JQ='[.statusCheckRollup[] |
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

  # Pre-scan for review blockers
  local review_blockers_file
  review_blockers_file="$(mktemp)"

  if [[ "$required_reviews" != "NOT_SET" && "$required_reviews" != "MISSING_FILE" && "$enforce" == "true" ]]; then
    echo "$pr_json" | jq -c '.[]' | while IFS= read -r _pr; do
      local _base _num _approvals _tide _short
      _base="$(echo "$_pr" | jq -r '.baseRefName')"
      _num="$(echo "$_pr" | jq -r '.number')"
      _approvals="$(echo "$_pr" | jq -r '
        [.reviews[] | {login: .author.login, state: .state, at: .submittedAt}]
        | group_by(.login) | map(sort_by(.at) | last)
        | map(select(.state == "APPROVED")) | length')"
      _tide="$(echo "$_pr" | jq -r "$NORMALIZE_CHECKS_JQ" | jq -r '[.[] | select(.check_name == "tide") | .check_state] | first // "NOT_REPORTED"')"
      if (( _approvals < required_reviews )) && [[ "$_tide" == "SUCCESS" ]]; then
        _short=$((required_reviews - _approvals))
        echo "${_base}|${_num}|${_short}" >> "$review_blockers_file"
      fi
    done
  fi

  echo "$pr_json" | jq -c '.[]' | while IFS= read -r pr; do
    local pr_num pr_author pr_title pr_branch pr_base pr_labels
    pr_num="$(echo "$pr" | jq -r '.number')"
    _show_status "Merge queue: $repo #$pr_num"
    pr_author="$(echo "$pr" | jq -r '.author.login')"
    pr_title="$(echo "$pr" | jq -r '.title')"
    pr_branch="$(echo "$pr" | jq -r '.headRefName')"
    pr_base="$(echo "$pr" | jq -r '.baseRefName')"
    pr_labels="$(echo "$pr" | jq -r '[.labels[].name] | join(",")')"

    # Check GitHub approving reviews vs required count
    local approving_reviewers approval_count
    approving_reviewers="$(echo "$pr" | jq -r '
      [.reviews[] | {login: .author.login, state: .state, at: .submittedAt}]
      | group_by(.login)
      | map(sort_by(.at) | last)
      | map(select(.state == "APPROVED") | .login)
      | .[]')"
    approval_count=0
    if [[ -n "$approving_reviewers" ]]; then
      approval_count="$(echo "$approving_reviewers" | wc -l | tr -d ' ')"
    fi

    # Normalize checks
    local checks failing errored pending in_progress tide_state
    checks="$(echo "$pr" | jq -c "$NORMALIZE_CHECKS_JQ")"

    failing="$(echo "$checks" | jq -r '[.[] | select(.check_state == "FAILURE" and .check_name != "tide") | .check_name] | sort | .[]')"
    errored="$(echo "$checks" | jq -r '[.[] | select(.check_state == "ERROR" and .check_name != "tide") | .check_name] | sort | .[]')"
    pending="$(echo "$checks" | jq -r '[.[] | select(.check_state == "PENDING" and .check_name != "tide") | .check_name] | sort | .[]')"
    in_progress="$(echo "$checks" | jq -r '[.[] | select(.check_state == "IN_PROGRESS" and .check_name != "tide") | .check_name] | sort | .[]')"

    tide_state="$(echo "$checks" | jq -r '[.[] | select(.check_name == "tide") | .check_state] | first // "NOT_REPORTED"')"

    # Determine blocking labels
    local label_blockers=()
    for blocker_label in "do-not-merge/hold" "do-not-merge/work-in-progress" \
      "do-not-merge/invalid-owners-file" "needs-rebase" "jira/invalid-bug" \
      "backports/unvalidated-commits"; do
      if echo "$pr_labels" | grep -qF "$blocker_label"; then
        label_blockers+=("$blocker_label")
      fi
    done

    # Build Prow PR query URL
    local encoded_branch prow_pr_url
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
}

#
# Run merge queue check for all repos (used in text/markdown mode)
#
run_all_merge_queues() {
  section "Merge Queue Status"

  if ! command -v gh &>/dev/null; then
    warning "gh CLI not found — skipping merge queue check (use --skip-queue to suppress)"
    return
  fi

  echo "PRs with approved+lgtm labels that haven't merged yet."
  echo "Tide merges one PR at a time per branch per repo; others wait in queue."
  echo ""

  for repo in "${ALL_REPOS[@]}"; do
    if ! has_config "$repo"; then continue; fi
    check_merge_queue_repo "$repo"
  done
}

run_audit

# In non-interactive mode, run merge queue inline
if [[ "$FORMAT" != "interactive" && "$SKIP_QUEUE" != "true" ]]; then
  run_all_merge_queues
fi

# Launch TUI viewer if interactive mode (with refresh loop)
if [[ "$FORMAT" == "interactive" && -n "$TUI_OUTPUT" ]]; then
  _stop_spinner
  exec 1>&3 3>&-

  # Spinners use fd 3 which is now closed — redefine to no-ops for merge queue calls
  _show_status() { :; }
  section() { echo ""; echo -e "${BOLD}=== $1 ===${RESET}"; }

  # Track background merge queue PID
  _MERGE_QUEUE_BG_PID=""

  _kill_bg_merge_queue() {
    if [[ -n "${_MERGE_QUEUE_BG_PID:-}" ]]; then
      kill "$_MERGE_QUEUE_BG_PID" 2>/dev/null || true
      wait "$_MERGE_QUEUE_BG_PID" 2>/dev/null || true
      _MERGE_QUEUE_BG_PID=""
    fi
  }

  while true; do
    tui_viewer "$TUI_OUTPUT"

    _kill_bg_merge_queue

    case "${_TUI_ACTION:-quit}" in
      refresh)
        # Clear cache for refresh
        if [[ -n "${_REFRESH_REPO:-}" ]]; then
          rm -rf "$CACHE_DIR/${_REFRESH_REPO%%/*}/${_REFRESH_REPO##*/}" 2>/dev/null || true
        else
          find "$CACHE_DIR" -name "*.yaml" -delete 2>/dev/null || true
          find "$CACHE_DIR" -name "*.404" -delete 2>/dev/null || true
        fi

        # Re-run audit with output captured (re-enable spinners on fd 3)
        : > "$TUI_OUTPUT"
        exec 3>&1 1>"$TUI_OUTPUT"
        section() { _stop_spinner; echo ""; echo -e "${BOLD}=== $1 ===${RESET}"; _start_spinner "$1"; }
        fetch_rate_limit
        _start_spinner "Refreshing audit"
        run_audit
        _stop_spinner
        exec 1>&3 3>&-
        # Restore no-op overrides (fd 3 closed again)
        _show_status() { :; }
        section() { echo ""; echo -e "${BOLD}=== $1 ===${RESET}"; }
        ;;
      merge_queue)
        # Single-repo merge queue check: append results to output file
        if [[ -n "${_MERGE_QUEUE_REPO:-}" ]]; then
          (
            echo ""
            echo -e "${BOLD}=== Merge Queue: ${_MERGE_QUEUE_REPO} ===${RESET}"
            check_merge_queue_repo "${_MERGE_QUEUE_REPO}"
          ) >> "$TUI_OUTPUT"
        fi
        ;;
      merge_queue_all)
        # All-repo merge queue check: run in background, append results progressively
        (
          echo ""
          echo -e "${BOLD}=== Merge Queue Status ===${RESET}"
          echo "PRs with approved+lgtm labels that haven't merged yet."
          echo "Tide merges one PR at a time per branch per repo; others wait in queue."
          echo ""
          for repo in "${ALL_REPOS[@]}"; do
            if ! has_config "$repo"; then continue; fi
            check_merge_queue_repo "$repo"
          done
          echo "Merge queue check complete."
        ) >> "$TUI_OUTPUT" &
        _MERGE_QUEUE_BG_PID=$!
        disown "$_MERGE_QUEUE_BG_PID" 2>/dev/null || true
        ;;
      *)
        break
        ;;
    esac
  done

  _kill_bg_merge_queue
fi

exit 0
