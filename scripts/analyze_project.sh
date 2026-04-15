#!/usr/bin/env bash
# =============================================================================
# analyze_project.sh — Android project structure validator
# Sourced by build.sh — do not execute directly
# =============================================================================

_ap_log()  { echo -e "${CYAN:-}[analyze]${RESET:-} $*"; }
_ap_warn() { echo -e "${YELLOW:-}[analyze WARN]${RESET:-} $*"; }
_ap_die()  { echo -e "${RED:-}[analyze FAIL]${RESET:-} $*" >&2; exit 1; }

# =============================================================================
# analyze_project <project_dir>
#   Sets PROJECT_DIR (confirmed), PROJECT_TYPE, PROJECT_NAME
# =============================================================================
analyze_project() {
    local dir="${1:?project dir required}"
    _ap_log "Analysing: $dir"

    # ── 1. Detect project type ────────────────────────────────────────────────
    _detect_project_type "$dir"

    # ── 2. Check build-readiness ─────────────────────────────────────────────
    _check_build_readiness "$dir"

    # ── 3. Extract metadata ───────────────────────────────────────────────────
    _extract_metadata "$dir"

    # ── 4. Validate Gradle wrapper ────────────────────────────────────────────
    _validate_gradle_wrapper "$dir"

    # ── 5. Resolve compileSdk / targetSdk ────────────────────────────────────
    _resolve_sdk_versions "$dir"

    _ap_log "Analysis complete. Project: $PROJECT_NAME | Type: $PROJECT_TYPE"
}

# ─── Scaffold a minimal Android WebView project ─────────────────────────────
scaffold_android_project() {
    local dir="$1"
    _ap_warn "No Android project detected. Scaffolding a WebView wrapper from scratch..."

    mkdir -p "$dir/app/src/main/java/com/example/webview"
    mkdir -p "$dir/app/src/main/res/values"
    mkdir -p "$dir/gradle/wrapper"

    # 1. Root settings.gradle
    echo "rootProject.name = 'ScaffoldedApp'" > "$dir/settings.gradle"
    echo "include ':app'" >> "$dir/settings.gradle"

    # 2. Root build.gradle
    cat <<EOF > "$dir/build.gradle"
buildscript {
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        classpath 'com.android.tools.build:gradle:8.2.2'
    }
}
allprojects {
    repositories {
        google()
        mavenCentral()
    }
}
EOF

    # 3. App build.gradle
    cat <<EOF > "$dir/app/build.gradle"
plugins {
    id 'com.android.application'
}
android {
    namespace 'com.example.webview'
    compileSdk 34
    defaultConfig {
        applicationId "com.example.webview"
        minSdk 21
        targetSdk 34
        versionCode 1
        versionName "1.0"
    }
    buildTypes {
        release {
            minifyEnabled false
        }
    }
}
EOF

    # 4. AndroidManifest.xml
    cat <<EOF > "$dir/app/src/main/AndroidManifest.xml"
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.microsoft.com/apk/res/android">
    <uses-permission android:name="android.permission.INTERNET" />
    <application
        android:label="WebView App"
        android:theme="@android:style/Theme.NoTitleBar.Fullscreen">
        <activity
            android:name=".MainActivity"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
EOF

    # 5. MainActivity.java
    cat <<EOF > "$dir/app/src/main/java/com/example/webview/MainActivity.java"
package com.example.webview;
import android.app.Activity;
import android.os.Bundle;
import android.webkit.WebView;
import android.webkit.WebViewClient;

public class MainActivity extends Activity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        WebView webView = new WebView(this);
        webView.getSettings().setJavaScriptEnabled(true);
        webView.setWebViewClient(new WebViewClient());
        // Load the provided content or a default page
        webView.loadUrl("https://github.com/cortexAI-2025/appbuilder");
        setContentView(webView);
    }
}
EOF

    # 6. Inject gradlew from our repo if available
    if [[ -f "./gradlew" ]]; then
        cp ./gradlew "$dir/gradlew"
        cp -r ./gradle "$dir/gradle"
        chmod +x "$dir/gradlew"
    fi

    PROJECT_TYPE="ANDROID_NATIVE_JAVA"
    _ap_log "Scaffolding complete."
}

# ─── Detect Android Native / Kotlin / Java ───────────────────────────────────
_detect_project_type() {
    local dir="$1"
    PROJECT_TYPE="UNKNOWN"

    if [[ -f "$dir/build.gradle" || -f "$dir/build.gradle.kts" ]]; then
        PROJECT_TYPE="ANDROID_NATIVE"
    else
        # Check subdirectories (monorepo / nested project layout)
        if find "$dir" -maxdepth 3 \
                \( -name "build.gradle" -o -name "build.gradle.kts" \) \
                -print -quit 2>/dev/null | grep -q .; then
            PROJECT_TYPE="ANDROID_NATIVE"
        fi
    fi

    if [[ "$PROJECT_TYPE" == "UNKNOWN" ]]; then
        scaffold_android_project "$dir"
    fi

    # Kotlin vs Java
    if find "$dir" -name "*.kt" -print -quit 2>/dev/null | grep -q .; then
        PROJECT_TYPE="${PROJECT_TYPE}_KOTLIN"
    elif find "$dir" -name "*.java" -print -quit 2>/dev/null | grep -q .; then
        PROJECT_TYPE="${PROJECT_TYPE}_JAVA"
    fi

    _ap_log "Project type: $PROJECT_TYPE"
}

# ─── Check build-readiness ────────────────────────────────────────────────────
_check_build_readiness() {
    local dir="$1"
    local missing=()

    # 1. Handle settings.gradle
    if [[ ! -f "$dir/settings.gradle" && ! -f "$dir/settings.gradle.kts" ]]; then
        _ap_warn "settings.gradle missing! Creating a default one."
        echo "rootProject.name = '$(basename "$dir")'" > "$dir/settings.gradle"
    fi

    # 2. Gradlew check
    if [[ ! -f "$dir/gradlew" ]]; then
        _ap_warn "gradlew not found — will use system Gradle engine."
    fi

    # 3. App module detection & auto-include
    local main_module="app"
    if [[ ! -d "$dir/app" ]]; then
        _ap_warn "No 'app' directory found. Searching for Android application module..."
        local potential_app
        potential_app=$(grep -r "com.android.application" "$dir" --include="*.gradle*" -l | head -1)
        if [[ -n "$potential_app" ]]; then
            main_module=$(basename "$(dirname "$potential_app")")
            _ap_log "Detected application module: $main_module"
        else
            missing+=("Android application module (plugin com.android.application)")
        fi
    fi

    # 4. Ensure module is in settings.gradle
    if [[ -f "$dir/settings.gradle" ]]; then
        if ! grep -q "include .:$main_module." "$dir/settings.gradle" && [[ "$main_module" != "." ]]; then
            _ap_warn "Module ':$main_module' not found in settings.gradle. Appending it."
            echo "include ':$main_module'" >> "$dir/settings.gradle"
        fi
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        local msg="Project is not build-ready. Missing: ${missing[*]}"
        _ap_die "$(python3 - <<EOF
import json
print(json.dumps({
  "status": "FAILED",
  "apk": [], "aab": [],
  "logs_summary": "$msg",
  "errors": $(printf '%s\n' "${missing[@]}" | python3 -c "import sys,json; print(json.dumps([l.strip() for l in sys.stdin]))")
}, indent=2))
EOF
)"
    fi

    _ap_log "Build-readiness check passed."
}

# ─── Extract project metadata ─────────────────────────────────────────────────
_extract_metadata() {
    local dir="$1"
    PROJECT_DIR="$dir"
    PROJECT_NAME="$(basename "$dir")"

    # Try to read applicationId from build.gradle
    local app_gradle="$dir/app/build.gradle"
    [[ ! -f "$app_gradle" ]] && app_gradle=$(find "$dir" -maxdepth 4 -name "build.gradle" \
        | xargs grep -l "applicationId" 2>/dev/null | head -1 || true)

    if [[ -n "$app_gradle" && -f "$app_gradle" ]]; then
        local app_id
        app_id=$(grep -oP 'applicationId\s+["'"'"']\K[^"'"'"']+' "$app_gradle" | head -1 || true)
        [[ -n "$app_id" ]] && _ap_log "applicationId: $app_id"

        local version_name
        version_name=$(grep -oP 'versionName\s+["'"'"']\K[^"'"'"']+' "$app_gradle" | head -1 || true)
        [[ -n "$version_name" ]] && _ap_log "versionName: $version_name"
    fi
}

# ─── Validate Gradle wrapper integrity ───────────────────────────────────────
_validate_gradle_wrapper() {
    local dir="$1"

    # Ensure wrapper properties exist
    local props="$dir/gradle/wrapper/gradle-wrapper.properties"
    if [[ ! -f "$props" ]]; then
        _ap_warn "gradle-wrapper.properties not found — Gradle version unknown."
        return
    fi

    local gradle_version
    gradle_version=$(grep -oP "gradle-\K[\d.]+" "$props" | head -1 || echo "unknown")
    _ap_log "Gradle wrapper version: $gradle_version"

    # Ensure the JAR is present
    if [[ ! -f "$dir/gradle/wrapper/gradle-wrapper.jar" ]]; then
        _ap_warn "gradle-wrapper.jar missing — attempting to restore from Gradle cache."
        local cached_jar
        cached_jar=$(find "$HOME/.gradle/wrapper/dists" -name "gradle-wrapper.jar" \
                     -print -quit 2>/dev/null || true)
        if [[ -n "$cached_jar" ]]; then
            cp "$cached_jar" "$dir/gradle/wrapper/gradle-wrapper.jar"
            _ap_log "Restored gradle-wrapper.jar from cache."
        else
            _ap_warn "Could not restore gradle-wrapper.jar — build may fail."
        fi
    fi
}

# ─── Resolve SDK versions from build.gradle ──────────────────────────────────
_resolve_sdk_versions() {
    local dir="$1"
    local app_gradle="$dir/app/build.gradle"
    [[ ! -f "$app_gradle" ]] && return

    COMPILE_SDK=$(grep -oP 'compileSdk(Version)?\s+\K\d+' "$app_gradle" | head -1 || echo "34")
    MIN_SDK=$(grep -oP 'minSdk(Version)?\s+\K\d+' "$app_gradle" | head -1 || echo "21")
    TARGET_SDK=$(grep -oP 'targetSdk(Version)?\s+\K\d+' "$app_gradle" | head -1 || echo "34")

    export COMPILE_SDK MIN_SDK TARGET_SDK
    _ap_log "compileSdk=$COMPILE_SDK  minSdk=$MIN_SDK  targetSdk=$TARGET_SDK"

    # Inject required platform into SDK_PACKAGES for setup_env.sh to install
    if [[ "${SDK_PACKAGES[*]:-}" != *"platforms;android-${COMPILE_SDK}"* ]]; then
        SDK_PACKAGES+=("platforms;android-${COMPILE_SDK}")
    fi
}
