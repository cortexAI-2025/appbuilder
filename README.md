# Android Build Pipeline — APK & AAB Automation

Automated CI/CD system that takes any GitHub Android project `.zip` archive and
produces a signed or unsigned **APK** and/or **AAB** with zero manual
intervention.

---

## Pipeline Phases

| Phase | Description |
|-------|-------------|
| 0 | Pre-flight checks (tools, paths) |
| 1 | Extract archive → detect & validate Android project |
| 2 | Bootstrap Android SDK + JDK if missing |
| 3 | `./gradlew clean assembleDebug bundleRelease` |
| 4 | Auto-fix common errors, retry once |
| 5 | Optional signing via `apksigner` / `jarsigner` |
| 6 | Emit JSON result + copy artifacts to output dir |

---

## Quick Start

### Local (Bash)

```bash
# Minimal — no signing
bash scripts/build.sh /path/to/project.zip

# With release signing
KEYSTORE_PATH=/path/to/release.jks \
KEYSTORE_ALIAS=mykey \
KEYSTORE_PASS=supersecret \
bash scripts/build.sh /path/to/project.zip
```

### Docker (Hermetic)

```bash
# Build image
docker build -t android-builder .

# Run pipeline
docker run --rm \
  -v /path/to/project.zip:/input/project.zip:ro \
  -v $(pwd)/output:/output \
  android-builder /input/project.zip
```

### GitHub Actions (workflow_dispatch)

1. Go to **Actions → Android Build Pipeline → Run workflow**
2. Paste the direct download URL of your `.zip` archive
3. Optionally enable `sign_release`

For signing, add these repository secrets:

| Secret | Description |
|--------|-------------|
| `KEYSTORE_PATH` | Path to the `.jks` file inside the runner |
| `KEYSTORE_ALIAS` | Key alias |
| `KEYSTORE_PASS` | Keystore password |
| `KEY_PASS` | Key password (if different) |

---

## Output JSON

```json
{
  "status": "SUCCESS | PARTIAL | FAILED",
  "apk": ["path/to/app-debug.apk"],
  "aab": ["path/to/app-release.aab"],
  "logs_summary": "Build finished. APKs: 1, AABs: 1, Errors: 0.",
  "errors": [],
  "build_duration_seconds": 142,
  "project_name": "MyAwesomeApp"
}
```

| Status | Meaning |
|--------|---------|
| `SUCCESS` | Both APK and AAB produced |
| `PARTIAL` | Debug APK only (release/AAB failed) |
| `FAILED` | No artifacts produced |

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ANDROID_HOME` | `~/android-sdk` | Android SDK root |
| `OUTPUT_DIR` | `/tmp/android_output` | Where artifacts are copied |
| `WORK_DIR` | `/tmp/android_build` | Extraction working directory |
| `BUILD_TIMEOUT` | `1200` | Gradle timeout in seconds |
| `KEYSTORE_PATH` | _(empty)_ | Path to signing keystore |
| `KEYSTORE_ALIAS` | _(empty)_ | Signing key alias |
| `KEYSTORE_PASS` | _(empty)_ | Keystore password |
| `KEY_PASS` | `$KEYSTORE_PASS` | Key password override |

---

## Script Structure

```
scripts/
  build.sh            Main pipeline orchestrator
  setup_env.sh        Android SDK + JDK bootstrap
  analyze_project.sh  Project structure validator
  sign_artifacts.sh   APK/AAB signing helpers
.github/workflows/
  android-build.yml   GitHub Actions CI/CD workflow
Dockerfile            Hermetic container build environment
```

---

## Build-Readiness Requirements

The pipeline validates that the project contains:

- `build.gradle` or `build.gradle.kts`
- `settings.gradle` or `settings.gradle.kts`
- `gradlew` executable
- An `app` module (or equivalent)

If any are missing, the pipeline exits immediately with:

```json
{
  "status": "FAILED",
  "errors": ["Project is not build-ready. Missing: gradlew"]
}
```

---

## Auto-Fix Capabilities

| Error Pattern | Auto-Fix |
|--------------|---------|
| Missing `platforms;android-XX` | Installs via `sdkmanager` |
| Missing `build-tools;X.X.X` | Installs via `sdkmanager` |
| `gradlew` not executable | `chmod +x gradlew` |
| Missing `gradle-wrapper.jar` | Restores from Gradle cache |

---

## Supported Project Types

- Android Native (Gradle)
- Kotlin DSL (`build.gradle.kts`)
- Java & Kotlin source projects
- Multi-module projects (app module auto-detected)
