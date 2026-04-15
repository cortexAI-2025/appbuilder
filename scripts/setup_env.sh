#!/usr/bin/env bash
# =============================================================================
# setup_env.sh — Android SDK / JDK environment bootstrapper
# Sourced by build.sh — do not execute directly
# =============================================================================

# ─── Constants ────────────────────────────────────────────────────────────────
CMDLINE_TOOLS_VERSION="11076708"   # commandlinetools-linux-11076708_latest.zip
CMDLINE_TOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS_VERSION}_latest.zip"
DEFAULT_ANDROID_HOME="${HOME}/android-sdk"
SDK_PACKAGES=(
    "platforms;android-34"
    "platforms;android-33"
    "build-tools;34.0.0"
    "build-tools;33.0.2"
    "platform-tools"
)

# ─── Logging guards ───────────────────────────────────────────────────────────
_log()  { echo -e "${CYAN:-}[setup_env]${RESET:-} $*"; }
_warn() { echo -e "${YELLOW:-}[setup_env WARN]${RESET:-} $*"; }
_die()  { echo -e "${RED:-}[setup_env FAIL]${RESET:-} $*" >&2; exit 1; }

# =============================================================================
setup_android_env() {
    _log "Checking Java installation..."
    _ensure_java

    ANDROID_HOME="${ANDROID_HOME:-$DEFAULT_ANDROID_HOME}"
    export ANDROID_HOME
    export ANDROID_SDK_ROOT="$ANDROID_HOME"
    export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"

    _log "ANDROID_HOME=$ANDROID_HOME"

    if [[ -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]]; then
        _log "sdkmanager already present — skipping download."
    else
        _install_cmdline_tools
    fi

    _accept_licenses
    _install_sdk_packages
    _verify_sdk
}

# ─── Java check / install ─────────────────────────────────────────────────────
_ensure_java() {
    if command -v java &>/dev/null; then
        local ver
        ver=$(java -version 2>&1 | awk -F '"' '/version/{print $2}' | cut -d. -f1)
        if [[ "$ver" -ge 11 ]]; then
            _log "Java $ver found: $(command -v java)"
            return
        fi
        _warn "Java $ver is too old; need >= 11."
    fi

    _log "Installing OpenJDK 17..."
    if command -v apt-get &>/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq openjdk-17-jdk-headless wget unzip curl zip
    elif command -v brew &>/dev/null; then
        brew install --quiet openjdk@17
        export PATH="/opt/homebrew/opt/openjdk@17/bin:$PATH"
    else
        _die "Cannot install Java: no known package manager found."
    fi
}

# ─── Download & install sdkmanager CLI tools ─────────────────────────────────
_install_cmdline_tools() {
    _log "Downloading Android command-line tools..."
    local tmp_zip; tmp_zip=$(mktemp /tmp/cmdline-tools-XXXXXX.zip)

    wget -q --show-progress "$CMDLINE_TOOLS_URL" -O "$tmp_zip" \
        || curl -fsSL "$CMDLINE_TOOLS_URL" -o "$tmp_zip" \
        || _die "Failed to download command-line tools."

    mkdir -p "$ANDROID_HOME/cmdline-tools"
    unzip -q "$tmp_zip" -d "$ANDROID_HOME/cmdline-tools"
    # Rename extracted directory to 'latest'
    mv "$ANDROID_HOME/cmdline-tools/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest" 2>/dev/null \
        || mv "$ANDROID_HOME/cmdline-tools/"cmdline-tools-* "$ANDROID_HOME/cmdline-tools/latest" 2>/dev/null \
        || true
    rm -f "$tmp_zip"

    chmod +x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
    _log "sdkmanager installed at $ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
}

# ─── Accept all SDK licences non-interactively ───────────────────────────────
_accept_licenses() {
    _log "Accepting Android SDK licences..."
    yes | "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" \
        --sdk_root="$ANDROID_HOME" --licenses 2>&1 \
        | grep -v "^[#=]" || true
}

# ─── Install required SDK packages ───────────────────────────────────────────
_install_sdk_packages() {
    _log "Installing SDK packages: ${SDK_PACKAGES[*]}"
    "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" \
        --sdk_root="$ANDROID_HOME" \
        "${SDK_PACKAGES[@]}" 2>&1 \
        | grep -v "^[#=]" || true
}

# ─── Verify SDK is usable ─────────────────────────────────────────────────────
_verify_sdk() {
    if [[ ! -d "$ANDROID_HOME/platforms/android-34" && ! -d "$ANDROID_HOME/platforms/android-33" ]]; then
        _warn "No target platform found after SDK install — build may fail."
    else
        _log "SDK verified. Available platforms:"
        ls "$ANDROID_HOME/platforms/" 2>/dev/null || true
    fi

    if [[ ! -d "$ANDROID_HOME/build-tools" ]]; then
        _warn "No build-tools found after SDK install."
    else
        _log "Build-tools available: $(ls "$ANDROID_HOME/build-tools/" 2>/dev/null | tr '\n' ' ')"
    fi
}
