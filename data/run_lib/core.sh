# shellcheck shell=bash
# Core/shared logic extracted from data/run.
setup_terminal_styles() {
  if [[ -n "${NO_COLOR:-}" || "${TERM:-}" == "dumb" ]]; then
    return 0
  fi

  if [[ ! -t 1 && ! -t 2 ]]; then
    return 0
  fi

  COLOR_RESET=$'\033[0m'
  STYLE_DIM=$'\033[2m'
  STYLE_INFO=$'\033[36m'
  STYLE_WARN=$'\033[33m'
  STYLE_ERROR=$'\033[31m'
  STYLE_SUCCESS=$'\033[32m'
  STYLE_ACCENT=$'\033[35m'
  STYLE_DETAIL=$'\033[90m'
  STYLE_TARGET_MOBILE=$'\033[34m'
  STYLE_TARGET_VIDEOHUB_TV=$'\033[36m'
  STYLE_TARGET_SERIESHUB_TV=$'\033[35m'
  STYLE_TARGET_LIVEHUB_TV=$'\033[32m'
  STYLE_TARGET_DEFAULT=$'\033[37m'
}

print_log_line() {
  local stream="$1"
  local level="$2"
  local level_style="$3"
  local message="$4"
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

  if [[ "$stream" == "stderr" ]]; then
    printf '%b[%s]%b %b%-5s%b %s\n' "$STYLE_DIM" "$timestamp" "$COLOR_RESET" "$level_style" "$level" "$COLOR_RESET" "$message" >&2
  else
    printf '%b[%s]%b %b%-5s%b %s\n' "$STYLE_DIM" "$timestamp" "$COLOR_RESET" "$level_style" "$level" "$COLOR_RESET" "$message"
  fi
}

log() {
  print_log_line "stdout" "INFO" "$STYLE_INFO" "$*"
}

warn() {
  print_log_line "stderr" "WARN" "$STYLE_WARN" "$*"
}

die() {
  print_log_line "stderr" "ERROR" "$STYLE_ERROR" "$*"
  exit 1
}

log_success() {
  print_log_line "stdout" "OK" "$STYLE_SUCCESS" "$*"
}

log_detail() {
  print_log_line "stdout" "NOTE" "$STYLE_DETAIL" "$*"
}

style_for_target() {
  case "$(to_lower "$1")" in
    app-mobile:videohub) printf '%s\n' "$STYLE_TARGET_MOBILE" ;;
    app-tv:videohub) printf '%s\n' "$STYLE_TARGET_VIDEOHUB_TV" ;;
    app-tv:serieshub) printf '%s\n' "$STYLE_TARGET_SERIESHUB_TV" ;;
    app-tv:livehub) printf '%s\n' "$STYLE_TARGET_LIVEHUB_TV" ;;
    *) printf '%s\n' "$STYLE_TARGET_DEFAULT" ;;
  esac
}

print_target_line() {
  local channel_name="$1"
  local message="$2"
  local target_style
  target_style="$(style_for_target "$channel_name")"

  printf '%b[%s]%b %bDIST %b%b[%s]%b %s\n' \
    "$STYLE_DIM" "$(date '+%Y-%m-%d %H:%M:%S')" "$COLOR_RESET" \
    "$STYLE_ACCENT" "$COLOR_RESET" \
    "$target_style" "$channel_name" "$COLOR_RESET" \
    "$message"
}

print_command_preview() {
  local label="$1"
  shift
  local rendered
  rendered="$(render_command "$@")"

  log_detail "[DRY-RUN] $label: $rendered"
}

render_command() {
  local rendered=""

  if [[ $# -gt 0 ]]; then
    printf -v rendered ' %q' "$@"
    rendered="${rendered# }"
  fi

  printf '%s\n' "$rendered"
}

print_target_command_preview() {
  local channel_name="$1"
  local label="$2"
  shift 2
  local rendered=""

  rendered="$(render_command "$@")"
  print_target_line "$channel_name" "[DRY-RUN] $label: $rendered"
}

run_prefixed_command() {
  local channel_name="$1"
  shift
  local -a cmd=("$@")
  local exit_code=0

  set +e
  "${cmd[@]}" 2>&1 | while IFS= read -r line || [[ -n "$line" ]]; do
    print_target_line "$channel_name" "$line"
  done
  exit_code=${PIPESTATUS[0]}
  set -e

  return "$exit_code"
}

is_truthy() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

mask_secret() {
  local value="${1:-}"
  if [[ -z "$value" ]]; then
    printf ''
    return 0
  fi

  if [[ ${#value} -le 6 ]]; then
    printf '***'
  else
    printf '%s***%s' "${value:0:3}" "${value: -3}"
  fi
}

load_env_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$file"
    set +a
  fi
}

resolve_path() {
  local candidate="$1"
  local base="$2"

  case "$candidate" in
    /*) printf '%s\n' "$candidate" ;;
    *) printf '%s\n' "$base/$candidate" ;;
  esac
}

to_lower() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'
}

trim_value() {
  printf '%s' "${1:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

lower_first_char() {
  local value="${1:-}"
  if [[ -z "$value" ]]; then
    printf ''
    return 0
  fi

  printf '%s%s' "$(printf '%s' "${value:0:1}" | tr '[:upper:]' '[:lower:]')" "${value:1}"
}

module_kind_from_name() {
  local module_lc
  module_lc="$(to_lower "$1")"
  if [[ "$module_lc" == *"tv"* ]]; then
    printf 'tv\n'
  else
    printf 'mobile\n'
  fi
}

normalize_build_command() {
  local raw_command
  raw_command="$(trim_value "$1")"

  if [[ -z "$raw_command" ]]; then
    printf '\n'
    return 0
  fi

  if printf '%s' "$raw_command" | grep -Eq '(^|[[:space:]])(\./)?gradlew([[:space:]]|$)|(^|[[:space:]])gradle([[:space:]]|$)'; then
    printf '%s\n' "$raw_command"
    return 0
  fi

  if printf '%s' "$raw_command" | grep -Eq '(^|[[:space:]]):?[A-Za-z0-9._-]+:assemble[A-Za-z0-9_]+'; then
    printf './gradlew %s\n' "$raw_command"
    return 0
  fi

  printf '%s\n' "$raw_command"
}

merge_build_commands_single_gradlew() {
  local first_command
  local second_command
  first_command="$(trim_value "${1:-}")"
  second_command="$(trim_value "${2:-}")"

  local part
  local token
  local merged="./gradlew"
  local seen_tokens=$'\n'
  local -a tokens=()

  for part in "$first_command" "$second_command"; do
    [[ -n "$part" ]] || continue
    read -r -a tokens <<< "${part//$'\n'/ }"
    for token in "${tokens[@]}"; do
      case "$token" in
        "./gradlew"|"gradlew"|"gradle"|"&&"|"||"|";"|"|")
          continue
          ;;
      esac

      if [[ "$seen_tokens" == *$'\n'"$token"$'\n'* ]]; then
        continue
      fi

      merged+=" $token"
      seen_tokens+="${token}"$'\n'
    done
  done

  if [[ "$merged" == "./gradlew" ]]; then
    printf '\n'
    return 0
  fi

  printf '%s\n' "$merged"
}

apply_legacy_env_compat() {
  local legacy_used="false"
  local build_lc=""

  if [[ -n "${BUILD_COMMAND:-}" ]]; then
    build_lc="$(to_lower "$BUILD_COMMAND")"
    if [[ -z "${BUILD_COMMAND_TV:-}" && "$build_lc" == *":app-tv:assemble"* ]]; then
      BUILD_COMMAND_TV="$BUILD_COMMAND"
      legacy_used="true"
    fi
    if [[ -z "${BUILD_COMMAND_MOBILE:-}" && "$build_lc" == *":app-mobile:assemble"* ]]; then
      BUILD_COMMAND_MOBILE="$BUILD_COMMAND"
      legacy_used="true"
    fi
  fi

  if [[ -n "${FIREBASE_APP_ID_MOBILE:-}" && -z "${FIREBASE_APP_ID_VIDEOHUB_MOBILE:-}" ]]; then
    FIREBASE_APP_ID_VIDEOHUB_MOBILE="$FIREBASE_APP_ID_MOBILE"
    legacy_used="true"
  fi

  if [[ -n "${FIREBASE_APP_ID_TV:-}" && -z "${FIREBASE_APP_ID_VIDEOHUB_TV:-}" ]]; then
    FIREBASE_APP_ID_VIDEOHUB_TV="$FIREBASE_APP_ID_TV"
    legacy_used="true"
  fi

  if [[ -n "${FIREBASE_GROUPS_TV:-}" ]]; then
    [[ -n "${FIREBASE_GROUPS_VIDEOHUB_TV:-}" ]] || FIREBASE_GROUPS_VIDEOHUB_TV="$FIREBASE_GROUPS_TV"
    [[ -n "${FIREBASE_GROUPS_SERIESHUB_TV:-}" ]] || FIREBASE_GROUPS_SERIESHUB_TV="$FIREBASE_GROUPS_TV"
    [[ -n "${FIREBASE_GROUPS_LIVEHUB_TV:-}" ]] || FIREBASE_GROUPS_LIVEHUB_TV="$FIREBASE_GROUPS_TV"
    legacy_used="true"
  fi

  if [[ -n "${FIREBASE_TESTERS_TV:-}" ]]; then
    [[ -n "${FIREBASE_TESTERS_VIDEOHUB_TV:-}" ]] || FIREBASE_TESTERS_VIDEOHUB_TV="$FIREBASE_TESTERS_TV"
    [[ -n "${FIREBASE_TESTERS_SERIESHUB_TV:-}" ]] || FIREBASE_TESTERS_SERIESHUB_TV="$FIREBASE_TESTERS_TV"
    [[ -n "${FIREBASE_TESTERS_LIVEHUB_TV:-}" ]] || FIREBASE_TESTERS_LIVEHUB_TV="$FIREBASE_TESTERS_TV"
    legacy_used="true"
  fi

  if [[ -n "${ENABLE_TV_DISTRIBUTION:-}" ]]; then
    [[ -n "${ENABLE_VIDEOHUB_TV_DISTRIBUTION:-}" ]] || ENABLE_VIDEOHUB_TV_DISTRIBUTION="$ENABLE_TV_DISTRIBUTION"
    [[ -n "${ENABLE_SERIESHUB_TV_DISTRIBUTION:-}" ]] || ENABLE_SERIESHUB_TV_DISTRIBUTION="$ENABLE_TV_DISTRIBUTION"
    [[ -n "${ENABLE_LIVEHUB_TV_DISTRIBUTION:-}" ]] || ENABLE_LIVEHUB_TV_DISTRIBUTION="$ENABLE_TV_DISTRIBUTION"
    legacy_used="true"
  fi

  if [[ "$legacy_used" == "true" ]]; then
    warn "Detected legacy variable names in .env. Mapped them for backward compatibility."
    warn "Please migrate .env using .env.example field names."
  fi
}

split_variant_parts() {
  local variant="$1"
  local flavor="$variant"
  local build_type=""
  local suffix
  local suffixes=(
    "Production"
    "Release"
    "Debug"
    "Staging"
    "Qa"
    "Uat"
    "Beta"
    "Alpha"
    "Prod"
    "Internal"
    "Profile"
    "Benchmark"
  )

  for suffix in "${suffixes[@]}"; do
    if [[ "$variant" == *"$suffix" && "$variant" != "$suffix" ]]; then
      flavor="${variant%"$suffix"}"
      build_type="$(to_lower "$suffix")"
      printf '%s|%s\n' "$flavor" "$build_type"
      return 0
    fi
  done

  printf '%s|%s\n' "$flavor" "$build_type"
}

extract_brand_key() {
  local raw_flavor="$1"
  local flavor_lc
  flavor_lc="$(to_lower "$raw_flavor")"
  local suffix
  local changed
  local suffixes=(
    "development"
    "staging"
    "production"
    "internal"
    "release"
    "debug"
    "dev"
    "qa"
    "uat"
    "stg"
    "prod"
    "beta"
    "alpha"
  )

  while true; do
    changed="false"
    for suffix in "${suffixes[@]}"; do
      if [[ "$flavor_lc" == *"$suffix" && ${#flavor_lc} -gt ${#suffix} ]]; then
        flavor_lc="${flavor_lc%"$suffix"}"
        changed="true"
        break
      fi
    done
    if [[ "$changed" != "true" ]]; then
      break
    fi
  done

  if [[ -z "$flavor_lc" ]]; then
    flavor_lc="$(to_lower "$raw_flavor")"
  fi

  printf '%s\n' "$flavor_lc"
}

list_build_targets_from_command() {
  local command_text="$1"
  local normalized
  normalized="${command_text//$'\n'/ }"
  local token
  local module
  local variant
  local flavor
  local build_type
  local brand
  local fragment
  local target_key
  local module_kind
  local task_key
  local parsed=0
  local seen_tasks=$'\n'
  local -a tokens=()

  read -r -a tokens <<< "$normalized"
  for token in "${tokens[@]}"; do
    if [[ "$token" =~ ^:?([A-Za-z0-9._-]+):assemble([A-Za-z0-9_]+)$ ]]; then
      module="${BASH_REMATCH[1]}"
      variant="${BASH_REMATCH[2]}"
    else
      continue
    fi

    task_key="${module}:${variant}"
    if [[ "$seen_tasks" == *$'\n'"$task_key"$'\n'* ]]; then
      continue
    fi
    seen_tasks+="${task_key}"$'\n'

    IFS='|' read -r flavor build_type <<< "$(split_variant_parts "$variant")"
    brand="$(extract_brand_key "$flavor")"
    module_kind="$(module_kind_from_name "$module")"
    fragment="/$(lower_first_char "$flavor")/"
    if [[ -n "$build_type" ]]; then
      fragment="${fragment}${build_type}/"
    fi

    target_key="${module}:${brand}"
    printf '%s|%s|%s|%s|%s|%s\n' "$module" "$variant" "$brand" "$fragment" "$target_key" "$module_kind"
    parsed=1
  done

  if [[ "$parsed" -eq 0 ]]; then
    return 1
  fi
}

collect_target_apks() {
  local module="$1"
  local variant="$2"
  local brand="$3"
  local fragment="$4"
  local marker_file="$5"
  local allow_stale="$6"
  local output_dir="$ANDROID_REPO_PATH/$module/build/outputs/apk"
  local variant_lc
  variant_lc="$(to_lower "$variant")"
  local brand_lc
  brand_lc="$(to_lower "$brand")"
  local apk
  local -a apks=()
  local seen_apks=$'\n'

  while IFS= read -r apk; do
    [[ -n "$apk" ]] || continue
    if [[ "$seen_apks" != *$'\n'"$apk"$'\n'* ]]; then
      apks+=("$apk")
      seen_apks+="${apk}"$'\n'
    fi
  done < <(collect_apks_for_flavor "$output_dir" "$fragment" "$marker_file" "$allow_stale")

  if [[ ${#apks[@]} -eq 0 ]]; then
    while IFS= read -r apk; do
      [[ -n "$apk" ]] || continue
      local apk_lc
      apk_lc="$(to_lower "$apk")"
      if [[ "$apk_lc" != *"$variant_lc"* && -n "$brand_lc" && "$apk_lc" != *"$brand_lc"* ]]; then
        continue
      fi
      if [[ "$seen_apks" != *$'\n'"$apk"$'\n'* ]]; then
        apks+=("$apk")
        seen_apks+="${apk}"$'\n'
      fi
    done < <(collect_apks "$output_dir" "$marker_file" "$allow_stale")
  fi

  if [[ ${#apks[@]} -gt 0 ]]; then
    printf '%s\n' "${apks[@]}"
  fi
}

infer_target_from_apk_path() {
  local apk_path="$1"
  local module=""
  local flavor=""
  local build_type=""
  local brand=""
  local fragment=""
  local module_kind=""

  if [[ "$apk_path" =~ /([^/]+)/build/outputs/apk/([^/]+)/([^/]+)/ ]]; then
    module="${BASH_REMATCH[1]}"
    flavor="${BASH_REMATCH[2]}"
    build_type="${BASH_REMATCH[3]}"
    fragment="/${flavor}/${build_type}/"
  elif [[ "$apk_path" =~ /([^/]+)/build/outputs/apk/([^/]+)/ ]]; then
    module="${BASH_REMATCH[1]}"
    flavor="${BASH_REMATCH[2]}"
    fragment="/${flavor}/"
  else
    return 1
  fi

  brand="$(extract_brand_key "$flavor")"
  if [[ -z "$brand" || "$brand" == "release" || "$brand" == "debug" ]]; then
    return 1
  fi

  module_kind="$(module_kind_from_name "$module")"
  printf '%s|%s|%s|%s|%s|%s\n' "$module" "$flavor" "$brand" "$fragment" "${module}:${brand}" "$module_kind"
}

extract_merged_branch_from_subject() {
  local subject="$1"
  local ref=""
  local branch=""

  if [[ "$subject" =~ ^Merge[[:space:]]pull[[:space:]]request[[:space:]]#[0-9]+[[:space:]]from[[:space:]]([^[:space:]]+) ]]; then
    ref="${BASH_REMATCH[1]}"
    if [[ "$ref" == */* ]]; then
      branch="${ref#*/}"
    else
      branch="$ref"
    fi
    printf '%s\n' "$branch"
    return 0
  fi

  if [[ "$subject" =~ ^Merge[[:space:]]branch[[:space:]]\'([^\']+)\' ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  if [[ "$subject" =~ ^Merge[[:space:]]remote-tracking[[:space:]]branch[[:space:]]\'([^\']+)\' ]]; then
    ref="${BASH_REMATCH[1]}"
    if [[ "$ref" == */* ]]; then
      branch="${ref#*/}"
    else
      branch="$ref"
    fi
    printf '%s\n' "$branch"
    return 0
  fi

  return 1
}

list_recent_merged_branches() {
  local repo_path="$1"
  local from_commit="$2"
  local to_commit="$3"
  local limit="$4"
  local subjects=""

  if [[ -n "$from_commit" ]] && git -C "$repo_path" cat-file -e "${from_commit}^{commit}" >/dev/null 2>&1; then
    subjects="$(git -C "$repo_path" log --merges --format='%s' "${from_commit}..${to_commit}" 2>/dev/null || true)"
  else
    subjects="$(git -C "$repo_path" log --merges --format='%s' -n "$limit" "$to_commit" 2>/dev/null || true)"
  fi

  local seen=$'\n'
  local subject
  local branch
  while IFS= read -r subject; do
    [[ -n "$subject" ]] || continue
    branch="$(extract_merged_branch_from_subject "$subject" || true)"
    [[ -n "$branch" ]] || continue
    if [[ "$seen" == *$'\n'"$branch"$'\n'* ]]; then
      continue
    fi
    seen+="${branch}"$'\n'
    printf '%s\n' "$branch"
  done <<< "$subjects"
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --branch)
        [[ $# -ge 2 ]] || die "Missing value for --branch"
        # shellcheck disable=SC2034
        CLI_BRANCH="$2"
        shift 2
        ;;
      --interval)
        [[ $# -ge 2 ]] || die "Missing value for --interval"
        # shellcheck disable=SC2034
        CLI_INTERVAL="$2"
        shift 2
        ;;
      --force|--force-build)
        # shellcheck disable=SC2034
        FORCE_BUILD="true"
        # shellcheck disable=SC2034
        FORCE_BUILD_SCOPE="all"
        shift
        ;;
      --force-tv)
        # shellcheck disable=SC2034
        FORCE_BUILD="true"
        # shellcheck disable=SC2034
        FORCE_BUILD_SCOPE="tv"
        shift
        ;;
      --force-mobile)
        # shellcheck disable=SC2034
        FORCE_BUILD="true"
        # shellcheck disable=SC2034
        FORCE_BUILD_SCOPE="mobile"
        shift
        ;;
      --once)
        # shellcheck disable=SC2034
        RUN_ONCE="true"
        shift
        ;;
      --dry-run)
        DRY_RUN="true"
        shift
        ;;
      --print-config)
        # shellcheck disable=SC2034
        PRINT_CONFIG="true"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done
}

require_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 || die "Missing required command: $command_name"
}

ensure_java_runtime() {
  if command -v java >/dev/null 2>&1 && java -version >/dev/null 2>&1; then
    return 0
  fi

  local candidates=()
  if [[ -n "${JAVA_HOME:-}" ]]; then
    candidates+=("$JAVA_HOME")
  fi

  candidates+=(
    "$HOME/Applications/Android Studio.app/Contents/jbr/Contents/Home"
    "/Applications/Android Studio.app/Contents/jbr/Contents/Home"
    "$HOME/Applications/Android Studio.app/Contents/jre/Contents/Home"
    "/Applications/Android Studio.app/Contents/jre/Contents/Home"
  )

  if [[ -d "/Library/Java/JavaVirtualMachines" ]]; then
    local vm_home
    while IFS= read -r vm_home; do
      candidates+=("$vm_home")
    done < <(find /Library/Java/JavaVirtualMachines -maxdepth 3 -type d -name Home 2>/dev/null | sort)
  fi

  local home
  for home in "${candidates[@]}"; do
    if [[ -x "$home/bin/java" ]]; then
      export JAVA_HOME="$home"
      export PATH="$JAVA_HOME/bin:$PATH"
      if java -version >/dev/null 2>&1; then
        log "Using Java runtime from: $JAVA_HOME"
        return 0
      fi
    fi
  done

  die "Unable to locate Java Runtime. Set JAVA_HOME to a valid JDK and try again."
}

fetch_latest_branch_commit() {
  local repo_path="$1"
  local remote_name="$2"
  local branch="$3"

  git -C "$repo_path" fetch --quiet "$remote_name" "$branch:refs/remotes/$remote_name/$branch" || return 1
  git -C "$repo_path" rev-parse "refs/remotes/$remote_name/$branch^{commit}" 2>/dev/null || return 1
}

sync_branch_before_build() {
  local repo_path="$1"
  local remote_name="$2"
  local branch="$3"

  if is_truthy "$DRY_RUN"; then
    log "[DRY-RUN] Skip checkout/pull before build."
    return 0
  fi

  log "Sync branch before build: $remote_name/$branch"

  if ! git -C "$repo_path" fetch --quiet "$remote_name" "$branch:refs/remotes/$remote_name/$branch"; then
    warn "Cannot fetch $remote_name/$branch before build."
    return 1
  fi

  if git -C "$repo_path" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$repo_path" checkout -q "$branch" || return 1
  else
    git -C "$repo_path" checkout -q -B "$branch" "$remote_name/$branch" || return 1
  fi

  git -C "$repo_path" pull --ff-only "$remote_name" "$branch" >/dev/null || return 1
  return 0
}

get_state_value() {
  local key="$1"
  local state_file="$2"

  if [[ ! -f "$state_file" ]]; then
    printf ''
    return 0
  fi

  grep -E "^${key}=" "$state_file" | tail -n 1 | sed -E 's/^[^=]+=//; s/^"//; s/"$//' || true
}

save_state() {
  local state_file="$1"
  local branch="$2"
  local commit="$3"
  local commit_time="$4"

  if is_truthy "$DRY_RUN"; then
    log "[DRY-RUN] Skip updating state file"
    return 0
  fi

  cat > "$state_file" <<__STATE__
LAST_PROCESSED_BRANCH="$branch"
LAST_PROCESSED_COMMIT="$commit"
LAST_PROCESSED_COMMIT_TIME="$commit_time"
UPDATED_AT_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
__STATE__
}

collect_apks() {
  local output_dir="$1"
  local marker_file="$2"
  local allow_stale="$3"

  if [[ ! -d "$output_dir" ]]; then
    return 0
  fi

  find "$output_dir" -type f -name '*.apk' -newer "$marker_file" | sort

  if is_truthy "$allow_stale"; then
    local count
    count="$(find "$output_dir" -type f -name '*.apk' -newer "$marker_file" | wc -l | tr -d ' ')"
    if [[ "$count" == "0" ]]; then
      find "$output_dir" -type f -name '*.apk' | sort
    fi
  fi
}

collect_apks_for_flavor() {
  local output_dir="$1"
  local flavor_fragment="$2"
  local marker_file="$3"
  local allow_stale="$4"

  if [[ ! -d "$output_dir" ]]; then
    return 0
  fi

  find "$output_dir" -type f -name '*.apk' -path "*${flavor_fragment}*" -newer "$marker_file" | sort

  if is_truthy "$allow_stale"; then
    local count
    count="$(find "$output_dir" -type f -name '*.apk' -path "*${flavor_fragment}*" -newer "$marker_file" | wc -l | tr -d ' ')"
    if [[ "$count" == "0" ]]; then
      find "$output_dir" -type f -name '*.apk' -path "*${flavor_fragment}*" | sort
    fi
  fi
}
