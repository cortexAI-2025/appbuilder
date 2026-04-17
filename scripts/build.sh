#!/usr/bin/env bash
# =============================================================================
# Android Build Pipeline — build.sh
# Automated APK / AAB builder for GitHub-hosted Android projects
# =============================================================================
set -euo pipefail

# ─── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')]${RESET} $*"; }
ok()   { echo -e "${GREEN}[OK]${RESET} $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
die()  { echo -e "${RED}[FAIL]${RESET} $*" >&2; exit 1; }

# ─── Defaults / overridable env ───────────────────────────────────────────────
REPO_URL="${1:-}"
BASE_DIR="$(readlink -f "android_working_dir")"
WORK_DIR="${WORK_DIR:-$BASE_DIR/build}"
OUTPUT_DIR="${OUTPUT_DIR:-$BASE_DIR/output}"
KEYSTORE_PATH="${KEYSTORE_PATH:-}"
KEYSTORE_ALIAS="${KEYSTORE_ALIAS:-}"
KEYSTORE_PASS="${KEYSTORE_PASS:-}"
ANDROID_HOME="${ANDROID_HOME:-${HOME}/android-sdk}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-1200}"   # 20 min

START_TIME=$(date +%s)
BUILD_STATUS="FAILED"
declare -a APK_PATHS=()
declare -a AAB_PATHS=()
declare -a ERRORS=()
LOGS_SUMMARY=""

# ─── Cleanup trap ─────────────────────────────────────────────────────────────
cleanup() {
    local end_time; end_time=$(date +%s)
    local duration=$(( end_time - START_TIME ))
    emit_json "$duration"
}
trap cleanup EXIT

# ─── Helper: emit final JSON ───────────────────────────────────────────────────
emit_json() {
    local duration="${1:-0}"
    local apk_json aab_json err_json

    apk_json=$(printf '%s\n' "${APK_PATHS[@]+"${APK_PATHS[@]}"}" \
               | python3 -c "import sys,json; print(json.dumps([l.rstrip() for l in sys.stdin if l.strip()]))")
    aab_json=$(printf '%s\n' "${AAB_PATHS[@]+"${AAB_PATHS[@]}"}" \
               | python3 -c "import sys,json; print(json.dumps([l.rstrip() for l in sys.stdin if l.strip()]))")
    err_json=$(printf '%s\n' "${ERRORS[@]+"${ERRORS[@]}"}" \
               | python3 -c "import sys,json; print(json.dumps([l.rstrip() for l in sys.stdin if l.strip()]))")

    python3 - <<EOF
import json, sys, os
data = {
    "status":       os.environ.get("BUILD_STATUS", "FAILED"),
    "apk":          $apk_json,
    "aab":          $aab_json,
    "logs_summary": os.environ.get("LOGS_SUMMARY", ""),
    "errors":       $err_json,
    "build_duration_seconds": int("$duration"),
    "project_name": os.path.basename(os.environ.get("REPO_URL", "ManusApp")).replace(".git", "")
}
print(json.dumps(data, indent=2))
EOF
}

# =============================================================================
# PHASE 0 — Pre-flight
# =============================================================================
preflight() {
    log "Phase 0 — Pre-flight checks"

    # REPO_URL is now optional (scaffolding fallback)

    mkdir -p "$WORK_DIR" "$OUTPUT_DIR"

    for cmd in git java python3; do
        command -v "$cmd" &>/dev/null || die "Required tool missing: $cmd"
    done

    ok "Pre-flight passed."
}

# =============================================================================
# PHASE 1 — Extract & Analyse
# =============================================================================
extract_and_analyse() {
    # If the WORK_DIR already contains a project (e.g. cloned by workflow), use it.
    # Otherwise, check if we need to clone or scaffold.

    if [[ ! -d "$WORK_DIR" ]]; then
        mkdir -p "$WORK_DIR"
    fi

    if [[ -n "$(ls -A "$WORK_DIR" 2>/dev/null)" ]]; then
        log "Phase 1 — Working directory not empty. Using existing files."
    elif [[ -n "$REPO_URL" ]]; then
        log "Phase 1 — Cloning repository: $REPO_URL"
        if git clone --depth 1 "$REPO_URL" "$WORK_DIR"; then
            ok "Successfully cloned repository."
        else
            warn "Failed to clone repository. Scaffolding will proceed."
        fi
    else
        log "Phase 1 — No project found and no Repository URL provided. Scaffolding will proceed."
    fi

    PROJECT_DIR="$WORK_DIR"
    log "Final Project root: $PROJECT_DIR"

    log "Phase 1 — Analysing project structure & potential scaffolding"
    # shellcheck source=./analyze_project.sh
    source "$(dirname "$0")/analyze_project.sh"

    # Forçage du Scaffolding : si le dossier app/src n'existe pas, lance scaffold_android_project
    if [[ ! -d "$PROJECT_DIR/app/src" ]]; then
        log "Force scaffolding: app/src not found in $PROJECT_DIR"
        scaffold_android_project "$PROJECT_DIR"
    fi

    analyze_project "$PROJECT_DIR"
}

# =============================================================================
# PHASE 2 — Environment
# =============================================================================
setup_environment() {
    log "Phase 2 — Setting up Android build environment"
    # shellcheck source=./setup_env.sh
    source "$(dirname "$0")/setup_env.sh"
    setup_android_env
}

# =============================================================================
# PHASE 3 — Build
# =============================================================================
run_build() {
    log "Phase 3 — Starting build"

    cd "$PROJECT_DIR"
    log "🔍 Debug: Final file structure before build..."
    find . -maxdepth 3
    export PATH="$PROJECT_DIR:$PATH"

    # Determine Gradle command
    local gradle_cmd="./gradlew"
    if [[ ! -f "gradlew" ]]; then
        warn "gradlew not found in project. Falling back to system gradle."
        gradle_cmd="gradle"
    else
        chmod +x gradlew
        gradle_cmd="./gradlew"
    fi

    # ── Clean ──────────────────────────────────────────────────────────────────
    log "Running: $gradle_cmd clean"
    if ! timeout "$BUILD_TIMEOUT" $gradle_cmd clean \
            -PANDROID_HOME="$ANDROID_HOME" \
            --no-daemon --stacktrace 2>&1 \
        | tee "$OUTPUT_DIR/clean.log"; then
        warn "Clean step had warnings (continuing)"
    fi

    # ── APK Debug ─────────────────────────────────────────────────────────────
    log "Running: $gradle_cmd assembleDebug"
    local apk_rc=0
    timeout "$BUILD_TIMEOUT" $gradle_cmd assembleDebug \
            -PANDROID_HOME="$ANDROID_HOME" \
            --no-daemon --stacktrace 2>&1 \
        | tee "$OUTPUT_DIR/assembleDebug.log" || apk_rc=$?

    if [[ $apk_rc -ne 0 ]]; then
        ERRORS+=("assembleDebug failed (exit $apk_rc)")

        log "Listing available Gradle tasks for debugging..."
        $gradle_cmd tasks --all > "$OUTPUT_DIR/available_tasks.log" 2>&1 || true

        parse_gradle_errors "$OUTPUT_DIR/assembleDebug.log"
        apply_auto_fixes "$OUTPUT_DIR/assembleDebug.log"

        log "Retrying assembleDebug after auto-fix…"
        timeout "$BUILD_TIMEOUT" $gradle_cmd assembleDebug \
                -PANDROID_HOME="$ANDROID_HOME" \
                --no-daemon --stacktrace 2>&1 \
            | tee "$OUTPUT_DIR/assembleDebug_retry.log" \
            || die "assembleDebug failed after auto-fix. See $OUTPUT_DIR/assembleDebug_retry.log"
    fi

    collect_apks

    # ── AAB Release ───────────────────────────────────────────────────────────
    log "Running: $gradle_cmd bundleRelease"
    local aab_rc=0
    timeout "$BUILD_TIMEOUT" $gradle_cmd bundleRelease \
            -PANDROID_HOME="$ANDROID_HOME" \
            --no-daemon --stacktrace 2>&1 \
        | tee "$OUTPUT_DIR/bundleRelease.log" || aab_rc=$?

    if [[ $aab_rc -ne 0 ]]; then
        warn "bundleRelease failed — falling back to debug APK only."
        ERRORS+=("bundleRelease failed (exit $aab_rc) — debug APK only")
        BUILD_STATUS="PARTIAL"
    else
        collect_aabs
    fi
}

# ─── Collect outputs ──────────────────────────────────────────────────────────
collect_apks() {
    local proj_name; proj_name=$(basename "$PROJECT_DIR" 2>/dev/null || echo "app")
    [[ "$proj_name" == "build" ]] && proj_name="ManusApp"

    while IFS= read -r -d '' apk; do
        local ext="${apk##*.}"
        local filename=$(basename "$apk")
        local dest="$OUTPUT_DIR/${proj_name}-${filename}"
        cp "$apk" "$dest"
        local size; size=$(du -sh "$dest" | cut -f1)
        APK_PATHS+=("$dest")
        ok "APK: $dest  ($size)"
    done < <(find "$PROJECT_DIR" -path "*/build/outputs/apk/*/*.apk" -print0 2>/dev/null)

    [[ ${#APK_PATHS[@]} -eq 0 ]] && die "No APK found after assembleDebug."
}

collect_aabs() {
    local proj_name; proj_name=$(basename "$PROJECT_DIR" 2>/dev/null || echo "app")
    [[ "$proj_name" == "build" ]] && proj_name="ManusApp"

    while IFS= read -r -d '' aab; do
        local filename=$(basename "$aab")
        local dest="$OUTPUT_DIR/${proj_name}-${filename}"
        cp "$aab" "$dest"
        local size; size=$(du -sh "$dest" | cut -f1)
        AAB_PATHS+=("$dest")
        ok "AAB: $dest  ($size)"
    done < <(find "$PROJECT_DIR" -path "*/build/outputs/bundle/*/*.aab" -print0 2>/dev/null)
}

# =============================================================================
# PHASE 4 — Error Parsing & Auto-fixes
# =============================================================================
parse_gradle_errors() {
    local log_file="$1"
    log "Phase 4 — Parsing Gradle errors from $log_file"

    grep -E "(^> |\* What went wrong:|error:|FAILED|Could not resolve)" "$log_file" \
        | head -40 \
        | while IFS= read -r line; do
            ERRORS+=("$line")
          done || true
}

apply_auto_fixes() {
    local log_file="$1"
    log "Phase 4 — Attempting auto-fixes"

    # Fix: missing SDK platform
    if grep -q "failed to find target with hash string 'android-" "$log_file" 2>/dev/null; then
        local api_level
        api_level=$(grep -oP "android-\K[0-9]+" "$log_file" | head -1)
        if [[ -n "$api_level" ]]; then
            warn "Installing missing platform: android-${api_level}"
            "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" \
                "platforms;android-${api_level}" --sdk_root="$ANDROID_HOME" 2>&1 || true
        fi
    fi

    # Fix: missing build-tools
    if grep -q "Build-Tools .* is missing" "$log_file" 2>/dev/null; then
        local bt_ver
        bt_ver=$(grep -oP "Build-Tools \K[\d.]+" "$log_file" | head -1)
        if [[ -n "$bt_ver" ]]; then
            warn "Installing missing build-tools: ${bt_ver}"
            "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" \
                "build-tools;${bt_ver}" --sdk_root="$ANDROID_HOME" 2>&1 || true
        fi
    fi

    # Fix: gradlew not executable (shouldn't reach here but belt & braces)
    chmod +x "$PROJECT_DIR/gradlew" 2>/dev/null || true
}

# =============================================================================
# PHASE 5 — Signing
# =============================================================================
sign_artifacts() {
    log "Phase 5 — Signing artifacts"

    if [[ -z "$KEYSTORE_PATH" ]]; then
        warn "No keystore provided — skipping signing."
        return
    fi

    [[ -f "$KEYSTORE_PATH" ]] || { warn "Keystore not found at $KEYSTORE_PATH — skipping."; return; }

    source "$(dirname "$0")/sign_artifacts.sh"

    for aab in "${AAB_PATHS[@]+"${AAB_PATHS[@]}"}"; do
        sign_aab "$aab"
    done
    for apk in "${APK_PATHS[@]+"${APK_PATHS[@]}"}"; do
        sign_apk "$apk"
    done
}

# =============================================================================
# PHASE 6 — Finalise
# =============================================================================
finalise() {
    if [[ ${#AAB_PATHS[@]} -gt 0 && ${#APK_PATHS[@]} -gt 0 ]]; then
        BUILD_STATUS="SUCCESS"
    elif [[ ${#APK_PATHS[@]} -gt 0 ]]; then
        [[ "$BUILD_STATUS" != "PARTIAL" ]] && BUILD_STATUS="PARTIAL"
    else
        BUILD_STATUS="FAILED"
    fi

    LOGS_SUMMARY="Build finished. APKs: ${#APK_PATHS[@]}, AABs: ${#AAB_PATHS[@]}, Errors: ${#ERRORS[@]}."
    log "Phase 6 — Status: ${BUILD_STATUS}"

    export BUILD_STATUS LOGS_SUMMARY REPO_URL
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    log "🔍 Debug: Listing files in current directory..."
    ls -R . | head -n 100

    preflight
    extract_and_analyse
    setup_environment
    run_build
    sign_artifacts
    finalise
}

main "$@"
