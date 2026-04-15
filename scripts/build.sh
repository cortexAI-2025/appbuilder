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
ZIP_FILE="${1:-}"
WORK_DIR="${WORK_DIR:-/tmp/android_build}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/android_output}"
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
import json, sys
data = {
    "status":       "$BUILD_STATUS",
    "apk":          $apk_json,
    "aab":          $aab_json,
    "logs_summary": "$LOGS_SUMMARY",
    "errors":       $err_json,
    "build_duration_seconds": $duration,
    "project_name": "$(basename "${ZIP_FILE:-unknown}" .zip)"
}
print(json.dumps(data, indent=2))
EOF
}

# =============================================================================
# PHASE 0 — Pre-flight
# =============================================================================
preflight() {
    log "Phase 0 — Pre-flight checks"

    [[ -z "$ZIP_FILE" ]] && die "Usage: $0 <path-to-project.zip>"
    [[ -f "$ZIP_FILE" ]] || die "ZIP not found: $ZIP_FILE"

    mkdir -p "$WORK_DIR" "$OUTPUT_DIR"

    for cmd in unzip java python3; do
        command -v "$cmd" &>/dev/null || die "Required tool missing: $cmd"
    done

    ok "Pre-flight passed."
}

# =============================================================================
# PHASE 1 — Extract & Analyse
# =============================================================================
extract_and_analyse() {
    log "Phase 1 — Extracting archive: $ZIP_FILE"

    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
    unzip -q "$ZIP_FILE" -d "$WORK_DIR"

    # Flatten single-root directories (GitHub zips add a repo-name/ wrapper)
    local entries=( "$WORK_DIR"/* )
    if [[ ${#entries[@]} -eq 1 && -d "${entries[0]}" ]]; then
        PROJECT_DIR="${entries[0]}"
    else
        PROJECT_DIR="$WORK_DIR"
    fi
    log "Project root: $PROJECT_DIR"

    log "Phase 1 — Analysing project structure"
    # shellcheck source=./analyze_project.sh
    source "$(dirname "$0")/analyze_project.sh"
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

    chmod +x gradlew

    # ── Clean ──────────────────────────────────────────────────────────────────
    log "Running: ./gradlew clean"
    if ! timeout "$BUILD_TIMEOUT" ./gradlew clean \
            -PANDROID_HOME="$ANDROID_HOME" \
            --no-daemon --stacktrace 2>&1 \
        | tee "$OUTPUT_DIR/clean.log"; then
        warn "Clean step had warnings (continuing)"
    fi

    # ── APK Debug ─────────────────────────────────────────────────────────────
    log "Running: ./gradlew assembleDebug"
    local apk_rc=0
    timeout "$BUILD_TIMEOUT" ./gradlew assembleDebug \
            -PANDROID_HOME="$ANDROID_HOME" \
            --no-daemon --stacktrace 2>&1 \
        | tee "$OUTPUT_DIR/assembleDebug.log" || apk_rc=$?

    if [[ $apk_rc -ne 0 ]]; then
        ERRORS+=("assembleDebug failed (exit $apk_rc)")
        parse_gradle_errors "$OUTPUT_DIR/assembleDebug.log"
        apply_auto_fixes "$OUTPUT_DIR/assembleDebug.log"

        log "Retrying assembleDebug after auto-fix…"
        timeout "$BUILD_TIMEOUT" ./gradlew assembleDebug \
                -PANDROID_HOME="$ANDROID_HOME" \
                --no-daemon --stacktrace 2>&1 \
            | tee "$OUTPUT_DIR/assembleDebug_retry.log" \
            || die "assembleDebug failed after auto-fix. See $OUTPUT_DIR/assembleDebug_retry.log"
    fi

    collect_apks

    # ── AAB Release ───────────────────────────────────────────────────────────
    log "Running: ./gradlew bundleRelease"
    local aab_rc=0
    timeout "$BUILD_TIMEOUT" ./gradlew bundleRelease \
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
    local proj_name; proj_name=$(basename "$(dirname "$0")/../.." 2>/dev/null || echo "app")

    while IFS= read -r -d '' apk; do
        local dest="$OUTPUT_DIR/$(basename "$apk")"
        cp "$apk" "$dest"
        local size; size=$(du -sh "$dest" | cut -f1)
        APK_PATHS+=("$dest")
        ok "APK: $dest  ($size)"
    done < <(find "$PROJECT_DIR" -path "*/build/outputs/apk/*/*.apk" -print0 2>/dev/null)

    [[ ${#APK_PATHS[@]} -eq 0 ]] && die "No APK found after assembleDebug."
}

collect_aabs() {
    while IFS= read -r -d '' aab; do
        local dest="$OUTPUT_DIR/$(basename "$aab")"
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
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    preflight
    extract_and_analyse
    setup_environment
    run_build
    sign_artifacts
    finalise
}

main "$@"
