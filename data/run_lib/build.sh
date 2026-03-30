# shellcheck shell=bash
# Build execution and cycle logic extracted from data/run.
stop_running_build() {
  local reason="$1"
  local build_pid="${BUILD_PID:-}"
  local build_pgid="${BUILD_PGID:-}"
  local gradle_repo_path="${ANDROID_REPO_PATH:-}"

  if [[ -n "$build_pid" ]]; then
    if is_pid_running "$build_pid"; then
      log "$reason"

      if [[ -n "$build_pgid" ]]; then
        kill -INT "-$build_pgid" 2>/dev/null || true
        sleep 0.5
        if is_pid_running "$build_pid"; then
          kill -TERM "-$build_pgid" 2>/dev/null || true
        fi
      else
        kill -INT "$build_pid" 2>/dev/null || true
        sleep 0.5
        if is_pid_running "$build_pid"; then
          kill -TERM "$build_pid" 2>/dev/null || true
        fi
      fi

      if [[ -n "$gradle_repo_path" && -x "$gradle_repo_path/gradlew" ]]; then
        (
          cd "$gradle_repo_path" || exit 1
          ./gradlew --stop >/dev/null 2>&1 || true
        )
      fi

      if is_pid_running "$build_pid"; then
        warn "Build process is still running after SIGINT/SIGTERM. Forcing kill."
        if [[ -n "$build_pgid" ]]; then
          kill -KILL "-$build_pgid" 2>/dev/null || true
        else
          kill -KILL "$build_pid" 2>/dev/null || true
        fi
      fi
    fi
    # Always wait to reap the child if it already exited.
    wait "$build_pid" 2>/dev/null || true
  fi

  BUILD_PID=""
  BUILD_PGID=""
}

on_signal() {
  trap - INT TERM
  if is_truthy "$SIGNAL_EXITING"; then
    exit 130
  fi
  SIGNAL_EXITING="true"
  SHUTDOWN_REQUESTED="true"
  stop_running_build "Shutdown requested. Stopping current build process immediately..."
  stop_running_distributions "Shutdown requested. Stopping Firebase distribution jobs..."
  stop_release_notes_lookup_job "Shutdown requested. Stopping release-notes lookup job..."
  exit 130
}

start_build_background() {
  local repo_path="$1"
  local command_text="$2"
  local resolved_pgid=""

  if command -v setsid >/dev/null 2>&1; then
    (
      cd "$repo_path" || exit 1
      exec setsid bash -lc "$command_text"
    ) &
    BUILD_PID="$!"
    resolved_pgid="$(ps -o pgid= -p "$BUILD_PID" 2>/dev/null | tr -d '[:space:]' || true)"
    BUILD_PGID="${resolved_pgid:-$BUILD_PID}"
  else
    (
      cd "$repo_path" || exit 1
      exec bash -lc "$command_text"
    ) &
    BUILD_PID="$!"
    BUILD_PGID=""
  fi
}

is_pid_running() {
  local pid="$1"

  [[ -n "$pid" ]] || return 1
  if ! kill -0 "$pid" 2>/dev/null; then
    return 1
  fi

  local stat
  stat="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
  [[ -n "$stat" ]] || return 1

  case "$stat" in
    Z*|*Z*) return 1 ;;
    *) return 0 ;;
  esac
}

run_build_with_preemption() {
  local repo_path="$1"
  local command_text="$2"
  local target_commit="$3"

  PREEMPT_COMMIT=""

  if is_truthy "$DRY_RUN"; then
    log "[DRY-RUN] Build command: $command_text"
    return 0
  fi

  log "Running build command in $repo_path"
  start_build_background "$repo_path" "$command_text"

  local elapsed_seconds=0
  while true; do
    if ! is_pid_running "$BUILD_PID"; then
      break
    fi

    sleep 1

    if is_truthy "$SHUTDOWN_REQUESTED"; then
      stop_running_build "Shutdown requested during build."
      return 130
    fi

    elapsed_seconds=$((elapsed_seconds + 1))
    if [[ "$elapsed_seconds" -lt "$CHECK_INTERVAL_SECONDS" ]]; then
      continue
    fi
    elapsed_seconds=0

    local newest_commit
    if ! newest_commit="$(fetch_latest_branch_commit "$ANDROID_REPO_PATH" "$GIT_REMOTE_NAME" "$DEPLOY_GIT_BRANCH")"; then
      warn "Cannot fetch branch while build is running. Keep current build and retry check in next cycle."
      continue
    fi

    if [[ "$newest_commit" != "$target_commit" ]]; then
      PREEMPT_COMMIT="$newest_commit"
      stop_running_build "Detected newer commit $newest_commit while building $target_commit. Cancelling current build..."
      return 2
    fi
  done

  local build_exit=0
  wait "$BUILD_PID" || build_exit=$?
  BUILD_PID=""
  BUILD_PGID=""

  if [[ "$build_exit" -ne 0 ]]; then
    return 1
  fi

  return 0
}

run_single_cycle() {
  local force_this_cycle="$1"
  LAST_CYCLE_DID_BUILD="false"
  local force_scope="${FORCE_BUILD_SCOPE:-auto}"
  stop_release_notes_lookup_job >/dev/null 2>&1 || true

  local latest_commit
  if ! latest_commit="$(fetch_latest_branch_commit "$ANDROID_REPO_PATH" "$GIT_REMOTE_NAME" "$DEPLOY_GIT_BRANCH")"; then
    warn "Cannot fetch branch '$DEPLOY_GIT_BRANCH' from '$GIT_REMOTE_NAME'."
    return 11
  fi

  local last_processed_commit
  last_processed_commit="$(get_state_value 'LAST_PROCESSED_COMMIT' "$STATE_FILE")"

  local should_build="false"
  if is_truthy "$force_this_cycle"; then
    should_build="true"
    log "Force build mode enabled for this cycle."
  elif [[ -z "$last_processed_commit" ]]; then
    should_build="true"
    log "No state found for branch $DEPLOY_GIT_BRANCH. First cycle will build latest commit."
  elif [[ "$latest_commit" != "$last_processed_commit" ]]; then
    should_build="true"
    log "New commit detected on $GIT_REMOTE_NAME/$DEPLOY_GIT_BRANCH"
    log "Previous: $last_processed_commit"
    log "Latest  : $latest_commit"
  fi

  if ! is_truthy "$should_build"; then
    log "No new commit on $GIT_REMOTE_NAME/$DEPLOY_GIT_BRANCH"
    return 0
  fi

  local target_commit="$latest_commit"
  local baseline_commit="$last_processed_commit"
  while true; do
    stop_release_notes_lookup_job >/dev/null 2>&1 || true

    if ! sync_branch_before_build "$ANDROID_REPO_PATH" "$GIT_REMOTE_NAME" "$DEPLOY_GIT_BRANCH"; then
      warn "Cannot sync branch before build. Will retry in next cycle."
      return 25
    fi

    if ! is_truthy "$DRY_RUN"; then
      local pulled_head
      pulled_head="$(git -C "$ANDROID_REPO_PATH" rev-parse HEAD)"
      if [[ "$pulled_head" != "$target_commit" ]]; then
        log "Pulled newer HEAD before build: $target_commit -> $pulled_head"
        target_commit="$pulled_head"
      fi
    fi

    local target_commit_time
    local target_commit_subject
    local target_commit_body

    target_commit_time="$(git -C "$ANDROID_REPO_PATH" show -s --format=%cI "$target_commit")"
    target_commit_subject="$(git -C "$ANDROID_REPO_PATH" show -s --format=%s "$target_commit")"
    target_commit_body="$(git -C "$ANDROID_REPO_PATH" show -s --format=%B "$target_commit")"

    log "Target commit: $target_commit"
    log "Commit time  : $target_commit_time"
    log "Commit title : $target_commit_subject"

    local -a recent_merged_branches=()
    local should_build_tv="false"
    local should_build_mobile="false"
    local merged_branch
    if is_truthy "$force_this_cycle"; then
      case "$force_scope" in
        tv)
          should_build_tv="true"
          log "Force TV mode enabled. Build/distribute TV apps from configured branch $DEPLOY_GIT_BRANCH."
          ;;
        mobile)
          should_build_mobile="true"
          log "Force mobile mode enabled. Build/distribute mobile apps from configured branch $DEPLOY_GIT_BRANCH."
          ;;
        all|auto|"")
          should_build_tv="true"
          should_build_mobile="true"
          log "Force full mode enabled. Build/distribute all apps from configured branch $DEPLOY_GIT_BRANCH."
          ;;
        *)
          die "Unsupported FORCE_BUILD_SCOPE: $force_scope"
          ;;
      esac
    else
      while IFS= read -r merged_branch; do
        [[ -n "$merged_branch" ]] && recent_merged_branches+=("$merged_branch")
      done < <(list_recent_merged_branches "$ANDROID_REPO_PATH" "$baseline_commit" "$target_commit" "$MAX_MERGE_COMMITS_SCAN")

      if [[ ${#recent_merged_branches[@]} -gt 0 ]]; then
        log "Detected merged branch names in latest range:"
        for merged_branch in "${recent_merged_branches[@]}"; do
          log_detail "$merged_branch"
        done

        for merged_branch in "${recent_merged_branches[@]}"; do
          local merged_branch_lc
          merged_branch_lc="$(to_lower "$merged_branch")"
          if [[ "$merged_branch_lc" == *"app-tv"* ]]; then
            should_build_tv="true"
          fi
          if [[ "$merged_branch_lc" == *"app-mobile"* ]]; then
            should_build_mobile="true"
          fi
        done
      else
        log "No merge-branch name detected from recent merge commits."
      fi

      if [[ "$should_build_tv" != "true" && "$should_build_mobile" != "true" ]]; then
        log "No merged branch contains 'app-tv' or 'app-mobile'. Marking latest commit as processed without build."
        save_state "$STATE_FILE" "$DEPLOY_GIT_BRANCH" "$target_commit" "$target_commit_time"
        LAST_CYCLE_DID_BUILD="false"
        return 0
      fi
    fi

    local selected_effective_build_command=""
    if [[ "$should_build_tv" == "true" ]]; then
      [[ -n "$EFFECTIVE_BUILD_COMMAND_TV" ]] || die "BUILD_COMMAND_TV is empty. Please set BUILD_COMMAND_TV in .env."
      selected_effective_build_command="$EFFECTIVE_BUILD_COMMAND_TV"
      if is_truthy "$force_this_cycle"; then
        log "Trigger TV build in force mode."
      else
        log "Trigger TV build due to merged branch keyword 'app-tv'."
      fi
    fi
    if [[ "$should_build_mobile" == "true" ]]; then
      [[ -n "$EFFECTIVE_BUILD_COMMAND_MOBILE" ]] || die "BUILD_COMMAND_MOBILE is empty. Please set BUILD_COMMAND_MOBILE in .env."
      if [[ -n "$selected_effective_build_command" ]]; then
        selected_effective_build_command="$selected_effective_build_command && $EFFECTIVE_BUILD_COMMAND_MOBILE"
      else
        selected_effective_build_command="$EFFECTIVE_BUILD_COMMAND_MOBILE"
      fi
      if is_truthy "$force_this_cycle"; then
        log "Trigger mobile build in force mode."
      else
        log "Trigger mobile build due to merged branch keyword 'app-mobile'."
      fi
    fi

    if is_truthy "$force_this_cycle" && [[ "$should_build_tv" == "true" && "$should_build_mobile" == "true" ]]; then
      selected_effective_build_command="$(merge_build_commands_single_gradlew "$EFFECTIVE_BUILD_COMMAND_TV" "$EFFECTIVE_BUILD_COMMAND_MOBILE")"
      selected_effective_build_command="$(trim_value "$selected_effective_build_command")"
      [[ -n "$selected_effective_build_command" ]] || die "Cannot merge BUILD_COMMAND_TV and BUILD_COMMAND_MOBILE for force mode."
      log "Force mode merged TV + mobile tasks into one Gradle command."
    fi

    [[ -n "$selected_effective_build_command" ]] || die "No effective build command selected for current cycle."

    local merged_branches_context=""
    if [[ ${#recent_merged_branches[@]} -gt 0 ]]; then
      merged_branches_context="$(printf '%s\n' "${recent_merged_branches[@]}")"
    fi

    if is_truthy "$BACKLOG_TASK_LOOKUP_ENABLED"; then
      start_release_notes_lookup_job "$target_commit_subject" "$target_commit_body" "$merged_branches_context"
    fi

    local build_marker_file="$STATE_DIR/build_marker"
    touch "$build_marker_file"

    if run_build_with_preemption "$ANDROID_REPO_PATH" "$selected_effective_build_command" "$target_commit"; then
      :
    else
      local build_status=$?
      if [[ "$build_status" -eq 2 ]]; then
        stop_release_notes_lookup_job "Build preempted. Restarting release-notes lookup for newer commit."
        target_commit="$PREEMPT_COMMIT"
        log "Restarting build with newer commit: $target_commit"
        continue
      fi

      if [[ "$build_status" -eq 130 ]]; then
        stop_release_notes_lookup_job
        return 130
      fi

      warn "Build command failed for commit $target_commit"
      stop_release_notes_lookup_job
      return 21
    fi

    local mobile_output_dir
    local tv_output_dir
    mobile_output_dir="$(resolve_path "$MOBILE_APK_OUTPUT_DIR" "$ANDROID_REPO_PATH")"
    tv_output_dir="$(resolve_path "$TV_APK_OUTPUT_DIR" "$ANDROID_REPO_PATH")"

    local all_mobile_apks=()
    while IFS= read -r apk_file; do
      [[ -n "$apk_file" ]] && all_mobile_apks+=("$apk_file")
    done < <(collect_apks "$mobile_output_dir" "$build_marker_file" "$ALLOW_STALE_APK_FALLBACK")

    local all_tv_apks=()
    while IFS= read -r apk_file; do
      [[ -n "$apk_file" ]] && all_tv_apks+=("$apk_file")
    done < <(collect_apks "$tv_output_dir" "$build_marker_file" "$ALLOW_STALE_APK_FALLBACK")

    if ! is_truthy "$DRY_RUN"; then
      if [[ ${#all_mobile_apks[@]} -eq 0 && ${#all_tv_apks[@]} -eq 0 ]]; then
        warn "No APK files found after build"
        stop_release_notes_lookup_job
        return 22
      fi
    fi

    local -a build_targets=()
    local target_line
    while IFS= read -r target_line; do
      [[ -n "$target_line" ]] && build_targets+=("$target_line")
    done < <(list_build_targets_from_command "$selected_effective_build_command" || true)

    if [[ ${#build_targets[@]} -eq 0 ]]; then
      warn "Cannot parse assemble targets from BUILD_COMMAND. Trying to infer targets from APK paths."
      local inferred_seen=$'\n'
      local inferred_line
      local inferred_key
      local apk_path
      for apk_path in "${all_mobile_apks[@]}" "${all_tv_apks[@]}"; do
        inferred_line="$(infer_target_from_apk_path "$apk_path" || true)"
        [[ -n "$inferred_line" ]] || continue
        IFS='|' read -r _ _ _ _ inferred_key _ <<< "$inferred_line"
        if [[ "$inferred_seen" == *$'\n'"$inferred_key"$'\n'* ]]; then
          continue
        fi
        inferred_seen+="${inferred_key}"$'\n'
        build_targets+=("$inferred_line")
      done
    fi

    if [[ ${#build_targets[@]} -eq 0 ]]; then
      warn "No build targets detected from BUILD_COMMAND or APK outputs."
      if is_truthy "$FAIL_IF_APK_NOT_FOUND"; then
        stop_release_notes_lookup_job
        return 23
      fi
    fi

    local default_release_notes="Automated distribution\nBranch: $DEPLOY_GIT_BRANCH\nCommit: $target_commit\nTitle: $target_commit_subject\nCommit time: $target_commit_time"
    local backlog_release_notes=""
    if is_truthy "$BACKLOG_TASK_LOOKUP_ENABLED"; then
      backlog_release_notes="$(collect_release_notes_from_lookup_job "$BACKLOG_NOTES_JOB_WAIT_SECONDS" || true)"
      if [[ -n "$backlog_release_notes" ]]; then
        log "Using generated Backlog release notes from async lookup job."
      fi
    fi

    local release_notes
    if [[ -n "${FIREBASE_RELEASE_NOTES_FILE:-}" || -n "${FIREBASE_RELEASE_NOTES:-}" ]]; then
      release_notes="$(read_release_notes "$default_release_notes" "$backlog_release_notes")"
    elif is_truthy "$BACKLOG_TASK_LOOKUP_ENABLED"; then
      release_notes="$backlog_release_notes"
      if [[ -z "$release_notes" ]]; then
        log "No task IDs provided yet. Firebase distribution will proceed without release notes text."
      fi
    else
      release_notes="$(read_release_notes "$default_release_notes" "$backlog_release_notes")"
    fi

    local any_recipients_configured="false"
    local target_module
    local target_variant
    local target_brand
    local target_fragment
    local target_key
    local target_module_kind
    local target_distribution_enabled
    local target_groups_raw
    local target_testers_raw
    local groups_effective
    local testers_effective
    local app_id
    local -a target_apks=()
    local total_target_apk_count=0
    local distribution_job_count=0
    clear_distribution_jobs

    if is_truthy "$ENABLE_DISTRIBUTION" && [[ -n "$FIREBASE_DISTRIBUTION_GROUP_ALIAS" ]]; then
      if ! ensure_distribution_group "$FIREBASE_DISTRIBUTION_GROUP_ALIAS" "$FIREBASE_DISTRIBUTION_GROUP_NAME"; then
        stop_release_notes_lookup_job
        return 27
      fi
    fi

    for target_line in "${build_targets[@]}"; do
      # shellcheck disable=SC2034
      IFS='|' read -r target_module target_variant target_brand target_fragment target_key target_module_kind <<< "$target_line"
      target_apks=()
      while IFS= read -r apk_file; do
        [[ -n "$apk_file" ]] && target_apks+=("$apk_file")
      done < <(collect_target_apks "$target_module" "$target_variant" "$target_brand" "$target_fragment" "$build_marker_file" "$ALLOW_STALE_APK_FALLBACK")

      if [[ ${#target_apks[@]} -gt 0 ]]; then
        total_target_apk_count=$((total_target_apk_count + ${#target_apks[@]}))
        log "APK files for target $target_key (${target_module}:assemble${target_variant}):"
        for apk_file in "${target_apks[@]}"; do
          log_detail "$apk_file"
        done
      else
        log "No APK files found for target $target_key (${target_module}:assemble${target_variant})"
      fi

      target_distribution_enabled="false"
      if is_truthy "$ENABLE_DISTRIBUTION" && is_target_distribution_enabled "$target_key"; then
        target_distribution_enabled="true"
      fi

      if [[ "${target_distribution_enabled}" == "true" ]]; then
        if ! is_truthy "$DRY_RUN" && is_truthy "$FAIL_IF_APK_NOT_FOUND" && [[ ${#target_apks[@]} -eq 0 ]]; then
          stop_running_distributions "Aborting Firebase distribution jobs due to missing APK(s)."
          warn "APK missing for required distribution target $target_key"
          stop_release_notes_lookup_job
          return 24
        fi

        if [[ ${#target_apks[@]} -eq 0 ]]; then
          continue
        fi

        app_id="$(resolve_target_app_id "$target_key" "$target_module" "$target_brand")"
        if [[ -z "$app_id" ]]; then
          stop_running_distributions "Aborting Firebase distribution jobs due to unresolved Firebase app id."
          warn "Cannot resolve Firebase app id for target $target_key"
          stop_release_notes_lookup_job
          return 25
        fi

        target_groups_raw="$(resolve_target_groups "$target_key" "$target_module" "$target_brand")"
        target_testers_raw="$(resolve_target_testers "$target_key" "$target_module" "$target_brand")"
        groups_effective="$(csv_merge_unique "$FIREBASE_DISTRIBUTION_GROUP_ALIAS" "$target_groups_raw")"
        testers_effective="$(csv_merge_unique "$FIREBASE_TESTERS_GLOBAL" "$target_testers_raw")"

        if [[ -n "$groups_effective" || -n "$testers_effective" ]]; then
          any_recipients_configured="true"
        fi

        if [[ -n "$FIREBASE_DISTRIBUTION_GROUP_ALIAS" && -n "$testers_effective" ]]; then
          if ! sync_testers_to_group "$FIREBASE_DISTRIBUTION_GROUP_ALIAS" "$testers_effective"; then
            stop_running_distributions "Aborting Firebase distribution jobs because tester synchronization failed."
            stop_release_notes_lookup_job
            return 28
          fi
        fi

        start_distribution_job "$target_key" "$app_id" "$groups_effective" "$testers_effective" "$release_notes" "${target_apks[@]}"
        distribution_job_count=$((distribution_job_count + 1))
      else
        if is_truthy "$ENABLE_DISTRIBUTION"; then
          log "Distribution disabled for target $target_key"
        fi
      fi
    done

    if [[ "$total_target_apk_count" -eq 0 && ${#build_targets[@]} -gt 0 ]] && ! is_truthy "$DRY_RUN"; then
      warn "No APK files matched detected build targets"
      stop_release_notes_lookup_job
      return 26
    fi

    if ! wait_for_distribution_jobs; then
      stop_release_notes_lookup_job
      return 29
    fi

    if is_truthy "$ENABLE_DISTRIBUTION"; then
      if [[ "$any_recipients_configured" != "true" ]]; then
        warn "No Firebase groups/testers configured. Distribution may fail if recipients are required."
      fi
    else
      log "Firebase distribution is disabled"
    fi

    save_state "$STATE_FILE" "$DEPLOY_GIT_BRANCH" "$target_commit" "$target_commit_time"
    # shellcheck disable=SC2034
    LAST_CYCLE_DID_BUILD="true"
    log "Build/distribution cycle completed successfully."
    stop_release_notes_lookup_job
    return 0
  done
}
