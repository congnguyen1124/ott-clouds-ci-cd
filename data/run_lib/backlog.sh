# shellcheck shell=bash
# Backlog + release-notes logic extracted from data/run.
BACKLOG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKLOG_PYTHON_DIR="${BACKLOG_LIB_DIR}/py"
BACKLOG_PLAY_SESSION_SCRIPT="${BACKLOG_PYTHON_DIR}/extract_backlog_play_session_token.py"

extract_backlog_task_ids_from_text() {
  local text="$1"
  local project_key="${BACKLOG_PROJECT_KEY:-OTT_TPL}"
  local project_key_lc=""
  project_key_lc="$(to_lower "$project_key")"
  local seen=$'\n'
  local match=""
  local prefix=""
  local task_id=""

  while IFS= read -r match; do
    [[ -n "$match" ]] || continue
    prefix=""
    task_id=""

    if [[ "$match" =~ ^\[([A-Za-z0-9_]+)-([0-9]+)\]$ ]]; then
      prefix="${BASH_REMATCH[1]}"
      task_id="${BASH_REMATCH[2]}"
    elif [[ "$match" =~ ^([A-Za-z0-9_]+)-([0-9]+)$ ]]; then
      prefix="${BASH_REMATCH[1]}"
      task_id="${BASH_REMATCH[2]}"
    elif [[ "$match" =~ ^-([0-9]+)-$ ]]; then
      task_id="${BASH_REMATCH[1]}"
    fi

    [[ -n "$task_id" ]] || continue
    if [[ -n "$prefix" && "$(to_lower "$prefix")" != "$project_key_lc" ]]; then
      continue
    fi

    if [[ "$seen" == *$'\n'"$task_id"$'\n'* ]]; then
      continue
    fi
    seen+="${task_id}"$'\n'
    printf '%s\n' "$task_id"
  done < <(
    {
      printf '%s\n' "$text" | grep -oE '\[[A-Za-z0-9_]+-[0-9]+\]|[A-Za-z0-9_]+-[0-9]+' || true
      printf '%s\n' "$text" | grep -oE -- '-[0-9]+-' || true
    }
  )
}

collect_backlog_task_ids_from_context() {
  local seen=$'\n'
  local context=""
  local task_id=""

  for context in "$@"; do
    [[ -n "$context" ]] || continue
    while IFS= read -r task_id; do
      [[ -n "$task_id" ]] || continue
      if [[ "$seen" == *$'\n'"$task_id"$'\n'* ]]; then
        continue
      fi
      seen+="${task_id}"$'\n'
      printf '%s\n' "$task_id"
    done < <(extract_backlog_task_ids_from_text "$context")
  done
}

extract_backlog_play_session_token() {
  local chrome_profile_dir="$1"
  local backlog_host="$2"
  local cookies_db="$chrome_profile_dir/Cookies"

  [[ -f "$cookies_db" ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  command -v security >/dev/null 2>&1 || return 1
  command -v openssl >/dev/null 2>&1 || return 1

  [[ -f "$BACKLOG_PLAY_SESSION_SCRIPT" ]] || return 1

  COOKIE_DB="$cookies_db" BACKLOG_HOST="$backlog_host" python3 "$BACKLOG_PLAY_SESSION_SCRIPT"
}

fetch_backlog_issue_title() {
  local backlog_space_key="$1"
  local backlog_project_key="$2"
  local task_id="$3"
  local play_session_token="$4"
  local issue_key="${backlog_project_key}-${task_id}"
  local issue_url="https://${backlog_space_key}.backlog.com/view/${issue_key}"
  local html=""
  local title=""

  if ! html="$(curl -fsSL "$issue_url" -H "Cookie: PLAY_SESSION=$play_session_token" 2>/dev/null)"; then
    return 1
  fi

  title="$(printf '%s' "$html" | grep -oE '<title>[^<]+' | head -n 1 | sed -E 's/^<title>//; s/[[:space:]]*\|[[:space:]]*Show issue[[:space:]]*\|[[:space:]]*Backlog$//')"
  title="$(trim_value "$title")"
  [[ -n "$title" ]] || return 1
  [[ "$title" != "Redirect - Nulab Apps" ]] || return 1
  printf '%s\n' "$title"
}

resolve_backlog_task_titles() {
  local backlog_space_key="$1"
  local backlog_project_key="$2"
  local chrome_profile_dir="$3"
  shift 3
  local -a task_ids=("$@")
  local play_session_token=""
  local task_id=""
  local task_title=""
  local has_any="false"

  [[ ${#task_ids[@]} -gt 0 ]] || return 0

  if ! play_session_token="$(extract_backlog_play_session_token "$chrome_profile_dir" "${backlog_space_key}.backlog.com")"; then
    warn "Cannot read Backlog PLAY_SESSION from Chrome profile: $chrome_profile_dir"
    return 1
  fi

  for task_id in "${task_ids[@]}"; do
    task_title="$(fetch_backlog_issue_title "$backlog_space_key" "$backlog_project_key" "$task_id" "$play_session_token" || true)"
    if [[ -n "$task_title" ]]; then
      has_any="true"
      printf '%s\n' "$task_title"
    else
      warn "Cannot fetch Backlog issue title for ${backlog_project_key}-${task_id}"
    fi
  done

  [[ "$has_any" == "true" ]]
}

render_release_notes_from_template() {
  local template_file="$1"
  shift
  local -a task_titles=("$@")
  local payload=""
  local title=""

  [[ -f "$template_file" ]] || return 1

  for title in "${task_titles[@]}"; do
    [[ -n "$title" ]] || continue
    if [[ -z "$payload" ]]; then
      payload="$title"
    else
      payload+=$'\n'"$title"
    fi
  done

  if [[ -z "$payload" ]]; then
    cat "$template_file"
    return 0
  fi

  TASK_TITLES_PAYLOAD="$payload" awk '
BEGIN {
  task_count = split(ENVIRON["TASK_TITLES_PAYLOAD"], tasks, /\n/)
  task_index = 1
  found_placeholder = 0
  last_prefix = "    - "
}
{
  if (index($0, "...") > 0) {
    found_placeholder = 1
    if (match($0, /^[[:space:]]*-[[:space:]]*/)) {
      last_prefix = substr($0, 1, RLENGTH)
    } else if (match($0, /^[[:space:]]*/)) {
      last_prefix = substr($0, 1, RLENGTH) "- "
    } else {
      last_prefix = "- "
    }

    if (task_index <= task_count && tasks[task_index] != "") {
      print last_prefix tasks[task_index]
      task_index++
    }
    next
  }

  print
}
END {
  if (found_placeholder) {
    for (i = task_index; i <= task_count; i++) {
      if (tasks[i] != "") {
        print last_prefix tasks[i]
      }
    }
  } else if (task_count > 0) {
    print ""
    print "Features:"
    for (i = 1; i <= task_count; i++) {
      if (tasks[i] != "") {
        print "    - " tasks[i]
      }
    }
  }
}
' "$template_file"
}

parse_manual_task_ids_input() {
  local raw_input="$1"
  local seen=$'\n'
  local task_id=""

  while IFS= read -r task_id; do
    [[ -n "$task_id" ]] || continue
    if [[ "$seen" == *$'\n'"$task_id"$'\n'* ]]; then
      continue
    fi
    seen+="${task_id}"$'\n'
    printf '%s\n' "$task_id"
  done < <(printf '%s\n' "$raw_input" | grep -oE '[0-9]+' || true)
}

prompt_manual_backlog_task_ids() {
  local commit_subject="$1"
  local timeout_seconds="${BACKLOG_MANUAL_TASK_PROMPT_TIMEOUT_SECONDS:-0}"
  local manual_input=""

  if ! is_truthy "$BACKLOG_MANUAL_TASK_PROMPT_ENABLED"; then
    return 1
  fi

  if [[ ! -t 0 && ! -t 1 ]]; then
    warn "Manual task prompt skipped because no interactive terminal is attached."
    return 1
  fi

  if ! exec 3<>/dev/tty; then
    warn "Manual task prompt skipped because /dev/tty is not accessible."
    return 1
  fi

  [[ "$timeout_seconds" =~ ^[0-9]+$ ]] || timeout_seconds=0

  printf '\n[%s] INFO  No [%s-xxxx] or [-xxxx-] pattern detected from pull title/context for commit:\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$BACKLOG_PROJECT_KEY" >&3
  printf '[%s] INFO  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$commit_subject" >&3
  printf '[%s] INFO  Enter manual task IDs (example: 6542,457,3248)' "$(date '+%Y-%m-%d %H:%M:%S')" >&3
  if [[ "$timeout_seconds" -gt 0 ]]; then
    printf ' within %ss' "$timeout_seconds" >&3
  fi
  printf ': ' >&3

  if [[ "$timeout_seconds" -gt 0 ]]; then
    if ! IFS= read -r -t "$timeout_seconds" manual_input <&3; then
      printf '\n[%s] WARN  Manual task input timeout (%ss). Continue without manual tasks.\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$timeout_seconds" >&3
      exec 3>&-
      exec 3<&-
      return 1
    fi
  else
    if ! IFS= read -r manual_input <&3; then
      exec 3>&-
      exec 3<&-
      return 1
    fi
  fi

  exec 3>&-
  exec 3<&-
  manual_input="$(trim_value "$manual_input")"
  [[ -n "$manual_input" ]] || return 1
  printf '%s\n' "$manual_input"
}

build_backlog_release_notes_from_context() {
  local commit_subject="$1"
  local commit_body="$2"
  local merged_branches_context="$3"
  local backlog_space_key="${BACKLOG_SPACE_KEY:-stvn}"
  local backlog_project_key="${BACKLOG_PROJECT_KEY:-OTT_TPL}"
  local backlog_chrome_profile_dir="${BACKLOG_CHROME_PROFILE_DIR:-$HOME/Library/Application Support/Google/Chrome/Profile 1}"
  local -a task_ids=()
  local task_id=""
  local manual_input=""
  local -a task_titles=()
  local task_title=""
  local notes_template_file=""

  while IFS= read -r task_id; do
    [[ -n "$task_id" ]] && task_ids+=("$task_id")
  done < <(collect_backlog_task_ids_from_context "$commit_subject" "$commit_body" "$merged_branches_context")

  if [[ ${#task_ids[@]} -eq 0 ]]; then
    manual_input="$(prompt_manual_backlog_task_ids "$commit_subject" || true)"
    if [[ -n "$manual_input" ]]; then
      while IFS= read -r task_id; do
        [[ -n "$task_id" ]] && task_ids+=("$task_id")
      done < <(parse_manual_task_ids_input "$manual_input")
    fi
  fi

  [[ ${#task_ids[@]} -gt 0 ]] || return 1

  while IFS= read -r task_title; do
    [[ -n "$task_title" ]] && task_titles+=("$task_title")
  done < <(resolve_backlog_task_titles "$backlog_space_key" "$backlog_project_key" "$backlog_chrome_profile_dir" "${task_ids[@]}" || true)

  [[ ${#task_titles[@]} -gt 0 ]] || return 1

  notes_template_file="$(resolve_path "$FIREBASE_RELEASE_NOTES_TEMPLATE_FILE" "$CONFIG_BASE_DIR")"
  if [[ ! -f "$notes_template_file" ]]; then
    warn "Release notes template file not found: $notes_template_file"
    return 1
  fi

  render_release_notes_from_template "$notes_template_file" "${task_titles[@]}"
}

stop_release_notes_lookup_job() {
  local reason="${1:-}"
  local pid="${NOTES_JOB_PID:-}"
  local output_file="${NOTES_JOB_OUTPUT_FILE:-}"

  if [[ -n "$pid" ]] && is_pid_running "$pid"; then
    [[ -n "$reason" ]] && log "$reason"
    kill -TERM "$pid" 2>/dev/null || true
  fi

  if [[ -n "$pid" ]]; then
    wait "$pid" 2>/dev/null || true
  fi

  NOTES_JOB_PID=""

  if [[ -n "$output_file" && -f "$output_file" ]]; then
    rm -f "$output_file"
  fi
  NOTES_JOB_OUTPUT_FILE=""
}

start_release_notes_lookup_job() {
  local commit_subject="$1"
  local commit_body="$2"
  local merged_branches_context="$3"
  local output_file=""

  stop_release_notes_lookup_job >/dev/null 2>&1 || true

  output_file="$STATE_DIR/release_notes_lookup_${DEPLOY_GIT_BRANCH//\//_}_$$.tmp"
  NOTES_JOB_OUTPUT_FILE="$output_file"

  (
    if ! build_backlog_release_notes_from_context "$commit_subject" "$commit_body" "$merged_branches_context" > "$output_file"; then
      rm -f "$output_file" 2>/dev/null || true
    fi
  ) &
  NOTES_JOB_PID="$!"
  log "Started background release-notes lookup job (pid=$NOTES_JOB_PID)."
}

collect_release_notes_from_lookup_job() {
  local wait_seconds="${1:-0}"
  local pid="${NOTES_JOB_PID:-}"
  local output_file="${NOTES_JOB_OUTPUT_FILE:-}"
  local elapsed=0

  [[ -n "$pid" ]] || return 1
  [[ -n "$output_file" ]] || return 1
  [[ "$wait_seconds" =~ ^[0-9]+$ ]] || wait_seconds=0

  while is_pid_running "$pid"; do
    if [[ "$elapsed" -ge "$wait_seconds" ]]; then
      warn "Release-notes lookup still running. Continue with fallback notes."
      stop_release_notes_lookup_job
      return 1
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  wait "$pid" 2>/dev/null || true
  NOTES_JOB_PID=""

  if [[ -s "$output_file" ]]; then
    cat "$output_file"
    rm -f "$output_file" 2>/dev/null || true
    NOTES_JOB_OUTPUT_FILE=""
    return 0
  fi

  rm -f "$output_file" 2>/dev/null || true
  NOTES_JOB_OUTPUT_FILE=""
  return 1
}

read_release_notes() {
  local default_notes="$1"
  local generated_notes="${2:-}"

  if [[ -n "${FIREBASE_RELEASE_NOTES_FILE:-}" ]]; then
    local notes_file
    notes_file="$(resolve_path "$FIREBASE_RELEASE_NOTES_FILE" "$CONFIG_BASE_DIR")"
    [[ -f "$notes_file" ]] || die "FIREBASE_RELEASE_NOTES_FILE not found: $notes_file"
    cat "$notes_file"
    return 0
  fi

  if [[ -n "${FIREBASE_RELEASE_NOTES:-}" ]]; then
    printf '%s\n' "$FIREBASE_RELEASE_NOTES"
    return 0
  fi

  if [[ -n "$generated_notes" ]]; then
    printf '%s\n' "$generated_notes"
    return 0
  fi

  printf '%s\n' "$default_notes"
}
