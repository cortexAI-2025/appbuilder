# =============================================================================
# Dockerfile — Hermetic Android build environment
# Usage:
#   docker build -t android-builder .
#   docker run --rm \
#     -v /path/to/project.zip:/input/project.zip:ro \
#     -v /path/to/output:/output \
#     android-builder /input/project.zip
# =============================================================================

FROM ubuntu:22.04

LABEL maintainer="cortexai-2025/builder-aab-apk"
LABEL description="Hermetic Android APK/AAB build pipeline"

# ─── Prevent interactive prompts ─────────────────────────────────────────────
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# ─── Android SDK paths ───────────────────────────────────────────────────────
ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV PATH="${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${PATH}"

# ─── JDK version ─────────────────────────────────────────────────────────────
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64

# ─── System packages ─────────────────────────────────────────────────────────
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        openjdk-17-jdk-headless \
        wget \
        curl \
        unzip \
        zip \
        git \
        python3 \
        ca-certificates \
        libstdc++6 \
        zlib1g \
        shellcheck \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# ─── Download Android command-line tools ─────────────────────────────────────
ARG CMDLINE_TOOLS_VERSION=11076708
RUN mkdir -p "${ANDROID_HOME}/cmdline-tools" && \
    wget -q "https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS_VERSION}_latest.zip" \
        -O /tmp/cmdline-tools.zip && \
    unzip -q /tmp/cmdline-tools.zip -d "${ANDROID_HOME}/cmdline-tools" && \
    mv "${ANDROID_HOME}/cmdline-tools/cmdline-tools" "${ANDROID_HOME}/cmdline-tools/latest" && \
    rm /tmp/cmdline-tools.zip

# ─── Accept licences & install core SDK packages ─────────────────────────────
RUN yes | sdkmanager --sdk_root="${ANDROID_HOME}" --licenses > /dev/null 2>&1 || true && \
    sdkmanager --sdk_root="${ANDROID_HOME}" \
        "platforms;android-34" \
        "platforms;android-33" \
        "build-tools;34.0.0" \
        "build-tools;33.0.2" \
        "platform-tools" 2>&1 \
    | grep -v "^[#=]" || true

# ─── Copy pipeline scripts ────────────────────────────────────────────────────
WORKDIR /pipeline
COPY scripts/ ./scripts/
RUN chmod +x scripts/*.sh

# ─── Gradle cache warm-up (optional: speeds up first build) ──────────────────
ENV GRADLE_USER_HOME=/root/.gradle

# ─── Output directory ────────────────────────────────────────────────────────
RUN mkdir -p /output
ENV OUTPUT_DIR=/output
ENV WORK_DIR=/tmp/android_build

# ─── Entrypoint ──────────────────────────────────────────────────────────────
ENTRYPOINT ["bash", "/pipeline/scripts/build.sh"]
CMD ["--help"]

# ─── Health check: ensure sdkmanager is functional ───────────────────────────
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=1 \
    CMD sdkmanager --list --sdk_root="${ANDROID_HOME}" > /dev/null 2>&1 || exit 1
