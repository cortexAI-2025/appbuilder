#!/usr/bin/env bash
# =============================================================================
# sign_artifacts.sh — APK / AAB signing helpers
# Sourced by build.sh — do not execute directly
# =============================================================================

_sign_log()  { echo -e "${CYAN:-}[sign]${RESET:-} $*"; }
_sign_warn() { echo -e "${YELLOW:-}[sign WARN]${RESET:-} $*"; }
_sign_die()  { echo -e "${RED:-}[sign FAIL]${RESET:-} $*" >&2; exit 1; }

# Env vars expected to be set before sourcing:
#   KEYSTORE_PATH   — path to .jks / .keystore file
#   KEYSTORE_ALIAS  — key alias
#   KEYSTORE_PASS   — store + key password (or set KEY_PASS separately)

KEY_PASS="${KEY_PASS:-${KEYSTORE_PASS:-}}"

# =============================================================================
# sign_apk <apk_path>
#   Signs the APK in-place using apksigner (preferred) or jarsigner fallback.
# =============================================================================
sign_apk() {
    local apk="$1"
    [[ -f "$apk" ]] || { _sign_warn "APK not found: $apk"; return; }

    _sign_log "Signing APK: $(basename "$apk")"

    local apksigner
    apksigner=$(find "${ANDROID_HOME}/build-tools" -name "apksigner" -type f \
                | sort -rV | head -1 || true)

    if [[ -n "$apksigner" ]]; then
        _sign_with_apksigner "$apksigner" "$apk"
    else
        _sign_warn "apksigner not found — falling back to jarsigner"
        _sign_with_jarsigner "$apk"
    fi
}

# =============================================================================
# sign_aab <aab_path>
#   Signs the AAB using jarsigner (apksigner does not support AAB).
# =============================================================================
sign_aab() {
    local aab="$1"
    [[ -f "$aab" ]] || { _sign_warn "AAB not found: $aab"; return; }

    _sign_log "Signing AAB: $(basename "$aab")"
    _sign_with_jarsigner "$aab"
}

# ─── apksigner ────────────────────────────────────────────────────────────────
_sign_with_apksigner() {
    local apksigner="$1"
    local artifact="$2"
    local signed="${artifact%.apk}-signed.apk"

    "$apksigner" sign \
        --ks        "$KEYSTORE_PATH" \
        --ks-key-alias  "$KEYSTORE_ALIAS" \
        --ks-pass   "pass:${KEYSTORE_PASS}" \
        --key-pass  "pass:${KEY_PASS}" \
        --out       "$signed" \
        "$artifact" 2>&1

    if [[ -f "$signed" ]]; then
        mv "$signed" "$artifact"
        _sign_log "apksigner: signed successfully → $(basename "$artifact")"

        # Verify
        "$apksigner" verify "$artifact" 2>&1 && _sign_log "Signature verified." \
            || _sign_warn "Signature verification failed."
    else
        _sign_warn "apksigner produced no output — artifact may be unsigned."
    fi
}

# ─── jarsigner ───────────────────────────────────────────────────────────────
_sign_with_jarsigner() {
    local artifact="$1"

    jarsigner \
        -verbose \
        -keystore     "$KEYSTORE_PATH" \
        -storepass    "$KEYSTORE_PASS" \
        -keypass      "$KEY_PASS" \
        -sigalg       SHA256withRSA \
        -digestalg    SHA-256 \
        "$artifact" \
        "$KEYSTORE_ALIAS" 2>&1

    # Verify
    jarsigner -verify "$artifact" 2>&1 \
        && _sign_log "jarsigner: $(basename "$artifact") signed & verified." \
        || _sign_warn "jarsigner verification failed for $(basename "$artifact")."
}

# =============================================================================
# generate_debug_keystore
#   Creates a throwaway debug keystore when none is provided but signing
#   is still desired (e.g. for sideloading during QA).
# =============================================================================
generate_debug_keystore() {
    local ks_path="${1:-/tmp/debug.keystore}"
    local alias="${2:-androiddebugkey}"
    local pass="${3:-android}"

    _sign_log "Generating ephemeral debug keystore at $ks_path"
    keytool \
        -genkeypair \
        -v \
        -keystore    "$ks_path" \
        -alias       "$alias" \
        -keyalg      RSA \
        -keysize     2048 \
        -validity    10000 \
        -storepass   "$pass" \
        -keypass     "$pass" \
        -dname       "CN=Android Debug,O=Android,C=US" 2>&1

    KEYSTORE_PATH="$ks_path"
    KEYSTORE_ALIAS="$alias"
    KEYSTORE_PASS="$pass"
    KEY_PASS="$pass"
    export KEYSTORE_PATH KEYSTORE_ALIAS KEYSTORE_PASS KEY_PASS
    _sign_log "Debug keystore ready."
}
