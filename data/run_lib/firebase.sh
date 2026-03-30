# shellcheck shell=bash
# Firebase logic extracted from data/run.
setup_firebase_auth() {
  FIREBASE_AUTH_MODE="session"
  FIREBASE_AUTH_ARGS=()

  if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
    local creds_file
    creds_file="$(resolve_path "$GOOGLE_APPLICATION_CREDENTIALS" "$CONFIG_BASE_DIR")"
    [[ -f "$creds_file" ]] || die "GOOGLE_APPLICATION_CREDENTIALS file not found: $creds_file"
    export GOOGLE_APPLICATION_CREDENTIALS="$creds_file"
    FIREBASE_AUTH_MODE="service_account"
    log "Using GOOGLE_APPLICATION_CREDENTIALS for Firebase authentication"
    return 0
  fi

  if [[ -n "${FIREBASE_TOKEN:-}" ]]; then
    if [[ "$FIREBASE_TOKEN" == "firebase_ci_token" ]]; then
      warn "FIREBASE_TOKEN is placeholder and will be ignored"
      FIREBASE_AUTH_MODE="session"
      return 0
    fi

    FIREBASE_AUTH_MODE="token"
    FIREBASE_AUTH_ARGS=(--token "$FIREBASE_TOKEN")
    log "Using FIREBASE_TOKEN for Firebase authentication"
    return 0
  fi

  log "Using Firebase CLI session authentication"
}

firebase_auth_preflight() {
  local cmd=("$FIREBASE_CLI_BIN" "apps:list" "--project" "$FIREBASE_PROJECT_ID" "--json")

  if [[ ${#FIREBASE_AUTH_ARGS[@]} -gt 0 ]]; then
    cmd+=("${FIREBASE_AUTH_ARGS[@]}")
  fi

  if ! "${cmd[@]}" >/dev/null 2>&1; then
    die "Firebase authentication failed (mode=$FIREBASE_AUTH_MODE). Use GOOGLE_APPLICATION_CREDENTIALS or run 'firebase login --reauth'."
  fi
}

csv_merge_unique() {
  local merged=""
  local source
  local token
  local trimmed

  for source in "$@"; do
    [[ -n "$source" ]] || continue
    IFS=',' read -r -a raw_items <<< "$source"
    for token in "${raw_items[@]}"; do
      trimmed="$(printf '%s' "$token" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [[ -n "$trimmed" ]] || continue
      case ",$merged," in
        *,"$trimmed",*) ;;
        *)
          if [[ -z "$merged" ]]; then
            merged="$trimmed"
          else
            merged="$merged,$trimmed"
          fi
          ;;
      esac
    done
  done

  printf '%s\n' "$merged"
}

ensure_distribution_group() {
  local group_alias="$1"
  local group_name="$2"
  [[ -n "$group_alias" ]] || return 0

  local list_cmd=("$FIREBASE_CLI_BIN" "appdistribution:group:list" "--project" "$FIREBASE_PROJECT_ID")
  if [[ ${#FIREBASE_AUTH_ARGS[@]} -gt 0 ]]; then
    list_cmd+=("${FIREBASE_AUTH_ARGS[@]}")
  fi

  if is_truthy "$DRY_RUN"; then
    print_command_preview "Firebase command" "${list_cmd[@]}"
  else
    local list_output
    if ! list_output="$("${list_cmd[@]}" 2>&1)"; then
      warn "Cannot list App Distribution groups: $list_output"
      return 1
    fi

    if printf '%s\n' "$list_output" | grep -Eq "(^|[[:space:]])${group_alias}([[:space:]]|$)"; then
      return 0
    fi
  fi

  local create_cmd=("$FIREBASE_CLI_BIN" "appdistribution:group:create" "$group_name" "$group_alias" "--project" "$FIREBASE_PROJECT_ID")
  if [[ ${#FIREBASE_AUTH_ARGS[@]} -gt 0 ]]; then
    create_cmd+=("${FIREBASE_AUTH_ARGS[@]}")
  fi

  if is_truthy "$DRY_RUN"; then
    print_command_preview "Firebase command" "${create_cmd[@]}"
    return 0
  fi

  local create_output
  if ! create_output="$("${create_cmd[@]}" 2>&1)"; then
    if printf '%s' "$create_output" | grep -qi "already exists"; then
      return 0
    fi
    warn "Cannot create App Distribution group '$group_alias': $create_output"
    return 1
  fi

  log "Ensured Firebase group exists: $group_alias"
}

sync_testers_to_group() {
  local group_alias="$1"
  local testers_csv="$2"
  [[ -n "$group_alias" ]] || return 0

  local normalized_testers
  normalized_testers="$(csv_merge_unique "$testers_csv")"
  if [[ -z "$normalized_testers" ]]; then
    warn "No testers configured to add into group '$group_alias'"
    return 0
  fi

  IFS=',' read -r -a tester_list <<< "$normalized_testers"
  [[ ${#tester_list[@]} -gt 0 ]] || return 0

  local add_cmd=("$FIREBASE_CLI_BIN" "appdistribution:testers:add" "--group-alias" "$group_alias" "--project" "$FIREBASE_PROJECT_ID")
  if [[ ${#FIREBASE_AUTH_ARGS[@]} -gt 0 ]]; then
    add_cmd+=("${FIREBASE_AUTH_ARGS[@]}")
  fi
  add_cmd+=("${tester_list[@]}")

  if is_truthy "$DRY_RUN"; then
    print_command_preview "Firebase command" "${add_cmd[@]}"
    return 0
  fi

  local add_output
  if ! add_output="$("${add_cmd[@]}" 2>&1)"; then
    warn "Cannot add testers to group '$group_alias': $add_output"
    return 1
  fi

  log "Ensured testers are in Firebase group '$group_alias'"
}

normalize_distribution_group_alias() {
  local current_alias_lc
  current_alias_lc="$(to_lower "$(trim_value "${FIREBASE_DISTRIBUTION_GROUP_ALIAS:-}")")"

  if [[ -z "$current_alias_lc" ]]; then
    FIREBASE_DISTRIBUTION_GROUP_ALIAS="ottclouds-template"
    return 0
  fi

  if [[ "$current_alias_lc" == "ottclods-template" ]]; then
    warn "Detected legacy group alias 'ottclods-template'. Switching to 'ottclouds-template'."
    FIREBASE_DISTRIBUTION_GROUP_ALIAS="ottclouds-template"
    return 0
  fi
}

is_firebase_app_id() {
  [[ "${1:-}" =~ ^[0-9]+:[0-9]+:android:[A-Za-z0-9]+$ ]]
}

lookup_map_value() {
  local map_text="$1"
  local raw_key="$2"
  local key_lc
  key_lc="$(to_lower "$(trim_value "$raw_key")")"
  local normalized
  normalized="${map_text//$'\n'/;}"
  local -a entries=()
  local entry
  local left
  local right

  [[ -n "$key_lc" ]] || {
    printf ''
    return 0
  }

  if [[ -z "$normalized" ]]; then
    printf ''
    return 0
  fi

  IFS=';' read -r -a entries <<< "$normalized"
  if [[ ${#entries[@]} -eq 0 ]]; then
    printf ''
    return 0
  fi

  for entry in "${entries[@]}"; do
    entry="$(trim_value "$entry")"
    [[ -n "$entry" ]] || continue
    [[ "$entry" == *=* ]] || continue
    left="$(trim_value "${entry%%=*}")"
    right="$(trim_value "${entry#*=}")"
    if [[ "$(to_lower "$left")" == "$key_lc" ]]; then
      printf '%s\n' "$right"
      return 0
    fi
  done

  printf ''
}

ensure_firebase_apps_cache() {
  if [[ "$FIREBASE_APPS_CACHE_READY" == "true" ]]; then
    return 0
  fi

  local cmd=("$FIREBASE_CLI_BIN" "apps:list" "--project" "$FIREBASE_PROJECT_ID" "--json")
  if [[ ${#FIREBASE_AUTH_ARGS[@]} -gt 0 ]]; then
    cmd+=("${FIREBASE_AUTH_ARGS[@]}")
  fi

  local output
  if ! output="$("${cmd[@]}" 2>&1)"; then
    warn "Cannot fetch Firebase apps list: $output"
    return 1
  fi

  local json_payload
  json_payload="$(printf '%s\n' "$output" | sed -n '/^{/,$p')"
  if [[ -z "$json_payload" ]]; then
    warn "Firebase apps:list output is not valid JSON payload"
    return 1
  fi

  if ! printf '%s\n' "$json_payload" | jq -e '.status == "success" and (.result | type == "array")' >/dev/null 2>&1; then
    warn "Firebase apps:list JSON parse failed"
    return 1
  fi

  FIREBASE_APPS_JSON_CACHE="$json_payload"
  FIREBASE_APPS_CACHE_READY="true"
  return 0
}

resolve_app_id_by_display_name() {
  local display_name="$1"
  local display_lc
  display_lc="$(to_lower "$display_name")"

  ensure_firebase_apps_cache || return 1

  local exact=""
  local partial=""
  local app_id
  local app_display
  while IFS=$'\t' read -r app_id app_display; do
    [[ -n "$app_id" ]] || continue
    local app_display_lc
    app_display_lc="$(to_lower "$app_display")"
    if [[ "$app_display_lc" == "$display_lc" ]]; then
      exact="$app_id"
      break
    fi
    if [[ -z "$partial" && "$app_display_lc" == *"$display_lc"* ]]; then
      partial="$app_id"
    fi
  done < <(printf '%s\n' "$FIREBASE_APPS_JSON_CACHE" | jq -r '.result[] | select(.platform == "ANDROID") | [.appId, (.displayName // "")] | @tsv')

  if [[ -n "$exact" ]]; then
    printf '%s\n' "$exact"
    return 0
  fi

  if [[ -n "$partial" ]]; then
    printf '%s\n' "$partial"
    return 0
  fi

  return 1
}

auto_discover_app_id_for_target() {
  local module="$1"
  local brand="$2"
  local module_kind
  module_kind="$(module_kind_from_name "$module")"
  local brand_lc
  brand_lc="$(to_lower "$brand")"

  ensure_firebase_apps_cache || return 1

  local app_id
  local display_name
  local namespace
  local best_id=""
  local best_display=""
  local best_score=-999
  local score
  local display_lc
  local namespace_lc
  local has_tv
  local seen_ids=$'\n'

  while IFS=$'\t' read -r app_id display_name namespace; do
    [[ -n "$app_id" ]] || continue
    if [[ "$seen_ids" == *$'\n'"$app_id"$'\n'* ]]; then
      continue
    fi
    seen_ids+="${app_id}"$'\n'

    display_lc="$(to_lower "$display_name")"
    namespace_lc="$(to_lower "$namespace")"
    score=0

    if [[ "$display_lc" == *"$brand_lc"* ]]; then
      score=$((score + 20))
    fi
    if [[ "$namespace_lc" == *"$brand_lc"* ]]; then
      score=$((score + 40))
    fi
    if [[ "$score" -eq 0 ]]; then
      continue
    fi

    has_tv="false"
    if [[ "$display_lc" == *" tv"* || "$namespace_lc" == *".tv"* ]]; then
      has_tv="true"
    fi

    if [[ "$module_kind" == "tv" ]]; then
      if [[ "$has_tv" == "true" ]]; then
        score=$((score + 15))
      else
        score=$((score - 15))
      fi
    else
      if [[ "$has_tv" == "true" ]]; then
        score=$((score - 15))
      else
        score=$((score + 10))
      fi
    fi

    if [[ "$score" -gt "$best_score" ]]; then
      best_score="$score"
      best_id="$app_id"
      best_display="$display_name"
    fi
  done < <(printf '%s\n' "$FIREBASE_APPS_JSON_CACHE" | jq -r '.result[] | select(.platform == "ANDROID") | [.appId, (.displayName // ""), (.namespace // "")] | @tsv')

  if [[ -n "$best_id" ]]; then
    log "Auto-mapped Firebase app for ${module}:${brand} -> ${best_display} (${best_id})"
    printf '%s\n' "$best_id"
    return 0
  fi

  return 1
}

default_app_id_for_target_key() {
  local target_key="$1"
  case "$target_key" in
    app-mobile:videohub) printf '%s\n' "$FIREBASE_APP_ID_VIDEOHUB_MOBILE" ;;
    app-tv:videohub) printf '%s\n' "$FIREBASE_APP_ID_VIDEOHUB_TV" ;;
    app-tv:serieshub) printf '%s\n' "$FIREBASE_APP_ID_SERIESHUB_TV" ;;
    app-tv:livehub) printf '%s\n' "$FIREBASE_APP_ID_LIVEHUB_TV" ;;
    *) printf '' ;;
  esac
}

resolve_target_app_id() {
  local target_key="$1"
  local module="$2"
  local brand="$3"
  local module_kind
  module_kind="$(module_kind_from_name "$module")"
  local mapped_value=""
  local app_id=""

  mapped_value="$(lookup_map_value "$FIREBASE_TARGET_APP_MAP" "$target_key")"
  if [[ -z "$mapped_value" ]]; then
    mapped_value="$(lookup_map_value "$FIREBASE_TARGET_APP_MAP" "${brand}-${module_kind}")"
  fi
  if [[ -z "$mapped_value" ]]; then
    mapped_value="$(lookup_map_value "$FIREBASE_TARGET_APP_MAP" "$brand")"
  fi

  if [[ -n "$mapped_value" ]]; then
    if is_firebase_app_id "$mapped_value"; then
      printf '%s\n' "$mapped_value"
      return 0
    fi

    if app_id="$(resolve_app_id_by_display_name "$mapped_value")"; then
      printf '%s\n' "$app_id"
      return 0
    fi

    warn "Cannot resolve Firebase app mapping '$mapped_value' for target '$target_key'"
  fi

  app_id="$(default_app_id_for_target_key "$target_key")"
  if [[ -n "$app_id" ]]; then
    printf '%s\n' "$app_id"
    return 0
  fi

  if app_id="$(auto_discover_app_id_for_target "$module" "$brand")"; then
    printf '%s\n' "$app_id"
    return 0
  fi

  printf ''
}

default_groups_for_target_key() {
  local target_key="$1"
  case "$target_key" in
    app-mobile:videohub) printf '%s\n' "$FIREBASE_GROUPS_MOBILE" ;;
    app-tv:videohub) printf '%s\n' "$FIREBASE_GROUPS_VIDEOHUB_TV" ;;
    app-tv:serieshub) printf '%s\n' "$FIREBASE_GROUPS_SERIESHUB_TV" ;;
    app-tv:livehub) printf '%s\n' "$FIREBASE_GROUPS_LIVEHUB_TV" ;;
    *) printf '' ;;
  esac
}

default_testers_for_target_key() {
  local target_key="$1"
  case "$target_key" in
    app-mobile:videohub) printf '%s\n' "$FIREBASE_TESTERS_MOBILE" ;;
    app-tv:videohub) printf '%s\n' "$FIREBASE_TESTERS_VIDEOHUB_TV" ;;
    app-tv:serieshub) printf '%s\n' "$FIREBASE_TESTERS_SERIESHUB_TV" ;;
    app-tv:livehub) printf '%s\n' "$FIREBASE_TESTERS_LIVEHUB_TV" ;;
    *) printf '' ;;
  esac
}

resolve_target_groups() {
  local target_key="$1"
  local module="$2"
  local brand="$3"
  local module_kind
  module_kind="$(module_kind_from_name "$module")"
  local target_groups=""

  target_groups="$(lookup_map_value "$FIREBASE_TARGET_GROUPS_MAP" "$target_key")"
  if [[ -z "$target_groups" ]]; then
    target_groups="$(lookup_map_value "$FIREBASE_TARGET_GROUPS_MAP" "${brand}-${module_kind}")"
  fi
  if [[ -z "$target_groups" ]]; then
    target_groups="$(lookup_map_value "$FIREBASE_TARGET_GROUPS_MAP" "$brand")"
  fi
  if [[ -z "$target_groups" ]]; then
    target_groups="$(default_groups_for_target_key "$target_key")"
  fi

  printf '%s\n' "$target_groups"
}

resolve_target_testers() {
  local target_key="$1"
  local module="$2"
  local brand="$3"
  local module_kind
  module_kind="$(module_kind_from_name "$module")"
  local target_testers=""

  target_testers="$(lookup_map_value "$FIREBASE_TARGET_TESTERS_MAP" "$target_key")"
  if [[ -z "$target_testers" ]]; then
    target_testers="$(lookup_map_value "$FIREBASE_TARGET_TESTERS_MAP" "${brand}-${module_kind}")"
  fi
  if [[ -z "$target_testers" ]]; then
    target_testers="$(lookup_map_value "$FIREBASE_TARGET_TESTERS_MAP" "$brand")"
  fi
  if [[ -z "$target_testers" ]]; then
    target_testers="$(default_testers_for_target_key "$target_key")"
  fi

  printf '%s\n' "$target_testers"
}

is_target_distribution_enabled() {
  local target_key="$1"
  case "$target_key" in
    app-mobile:videohub)
      is_truthy "$ENABLE_MOBILE_DISTRIBUTION"
      return $?
      ;;
    app-tv:videohub)
      is_truthy "$ENABLE_VIDEOHUB_TV_DISTRIBUTION"
      return $?
      ;;
    app-tv:serieshub)
      is_truthy "$ENABLE_SERIESHUB_TV_DISTRIBUTION"
      return $?
      ;;
    app-tv:livehub)
      is_truthy "$ENABLE_LIVEHUB_TV_DISTRIBUTION"
      return $?
      ;;
    *)
      return 0
      ;;
  esac
}

distribute_apk_set() {
  local channel_name="$1"
  local app_id="$2"
  local groups="$3"
  local testers="$4"
  local release_notes="$5"
  shift 5
  local apks=("$@")

  if [[ ${#apks[@]} -eq 0 ]]; then
    log "No APK files found for $channel_name"
    return 0
  fi

  [[ -n "$app_id" ]] || die "Missing Firebase app id for $channel_name"

  local apk
  for apk in "${apks[@]}"; do
    local cmd=("$FIREBASE_CLI_BIN" "appdistribution:distribute" "$apk" "--app" "$app_id" "--project" "$FIREBASE_PROJECT_ID")

    if [[ -n "$release_notes" ]]; then
      cmd+=("--release-notes" "$release_notes")
    fi

    if [[ -n "$groups" ]]; then
      cmd+=("--groups" "$groups")
    fi

    if [[ -n "$testers" ]]; then
      cmd+=("--testers" "$testers")
    fi

    if [[ ${#FIREBASE_AUTH_ARGS[@]} -gt 0 ]]; then
      cmd+=("${FIREBASE_AUTH_ARGS[@]}")
    fi

    if is_truthy "$DRY_RUN"; then
      print_target_line "$channel_name" "Prepared Firebase distribution for $apk"
      print_target_command_preview "$channel_name" "Firebase command" "${cmd[@]}"
    else
      print_target_line "$channel_name" "Uploading $apk to Firebase App Distribution"
      run_prefixed_command "$channel_name" "${cmd[@]}" || return $?
    fi
  done

  print_target_line "$channel_name" "Completed ${#apks[@]} Firebase upload(s)"
}

register_distribution_job() {
  local pid="$1"
  local label="$2"
  DISTRIBUTION_PIDS+=("$pid")
  DISTRIBUTION_LABELS+=("$label")
}

clear_distribution_jobs() {
  DISTRIBUTION_PIDS=()
  DISTRIBUTION_LABELS=()
}

stop_running_distributions() {
  local reason="$1"
  local announced="false"
  local idx
  local pid
  local label

  for idx in "${!DISTRIBUTION_PIDS[@]}"; do
    pid="${DISTRIBUTION_PIDS[$idx]}"
    [[ -n "$pid" ]] || continue
    if ! is_pid_running "$pid"; then
      continue
    fi

    if [[ "$announced" != "true" ]]; then
      log "$reason"
      announced="true"
    fi

    label="${DISTRIBUTION_LABELS[$idx]:-distribution#$((idx + 1))}"
    warn "Stopping Firebase distribution job: $label"
    pkill -INT -P "$pid" 2>/dev/null || true
    kill -INT "$pid" 2>/dev/null || true
  done

  if [[ "$announced" == "true" ]]; then
    sleep 0.5
    for idx in "${!DISTRIBUTION_PIDS[@]}"; do
      pid="${DISTRIBUTION_PIDS[$idx]}"
      label="${DISTRIBUTION_LABELS[$idx]:-distribution#$((idx + 1))}"
      [[ -n "$pid" ]] || continue
      if is_pid_running "$pid"; then
        pkill -TERM -P "$pid" 2>/dev/null || true
        kill -TERM "$pid" 2>/dev/null || true
      fi
      if is_pid_running "$pid"; then
        warn "Firebase distribution job is still running. Forcing stop: $label"
        pkill -KILL -P "$pid" 2>/dev/null || true
        kill -KILL "$pid" 2>/dev/null || true
      fi
      wait "$pid" 2>/dev/null || true
    done
  fi

  clear_distribution_jobs
}

start_distribution_job() {
  local channel_name="$1"
  shift

  distribute_apk_set "$channel_name" "$@" &
  register_distribution_job "$!" "$channel_name"
  log "Started Firebase distribution job for $channel_name"
}

wait_for_distribution_jobs() {
  local total_jobs="${#DISTRIBUTION_PIDS[@]}"
  local failures=0
  local idx
  local pid
  local label
  local exit_code

  if [[ "$total_jobs" -eq 0 ]]; then
    return 0
  fi

  log "Waiting for $total_jobs Firebase distribution job(s) to finish..."

  for idx in "${!DISTRIBUTION_PIDS[@]}"; do
    pid="${DISTRIBUTION_PIDS[$idx]}"
    label="${DISTRIBUTION_LABELS[$idx]:-distribution#$((idx + 1))}"
    [[ -n "$pid" ]] || continue

    if wait "$pid"; then
      log_success "Firebase distribution completed for $label"
    else
      exit_code=$?
      warn "Firebase distribution failed for $label (exit=$exit_code)"
      failures=$((failures + 1))
    fi
  done

  clear_distribution_jobs

  if [[ "$failures" -gt 0 ]]; then
    return 1
  fi
}
