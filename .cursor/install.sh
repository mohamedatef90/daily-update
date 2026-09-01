#!/usr/bin/env bash
# Idempotent install of the open-source Swift toolchain for Linux.
#
# IMPORTANT: Daily Update is a macOS-only SwiftUI/AppKit app. It cannot be
# built or run on Linux because it depends on Apple-only frameworks (SwiftUI,
# AppKit, ServiceManagement, UserNotifications, UniformTypeIdentifiers) and
# macOS-only tools (sips, iconutil, PlistBuddy, brew). This toolchain enables
# editing, syntax checking, LSP, and compiling pure-Foundation Swift logic in a
# Cloud Agent. Producing a runnable app still requires a macOS build host.
set -euo pipefail

SWIFT_VERSION="6.1"
SWIFT_TAG="swift-${SWIFT_VERSION}-RELEASE"
SWIFT_PLATFORM="ubuntu24.04"
SWIFT_PLATFORM_DIR="ubuntu2404"
SWIFT_ARCHIVE="${SWIFT_TAG}-${SWIFT_PLATFORM}.tar.gz"
SWIFT_URL="https://download.swift.org/swift-${SWIFT_VERSION}-release/${SWIFT_PLATFORM_DIR}/${SWIFT_TAG}/${SWIFT_ARCHIVE}"
SWIFT_PREFIX="/opt/swift"

log() { printf '[install] %s\n' "$*"; }

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    fi
fi

install_apt_deps() {
    log "Installing system dependencies for the Swift toolchain..."
    export DEBIAN_FRONTEND=noninteractive
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq --no-install-recommends \
        binutils git gnupg2 libc6-dev libcurl4-openssl-dev libedit2 \
        libgcc-13-dev libncurses6 libncursesw6 libpython3-dev libsqlite3-0 \
        libstdc++-13-dev libxml2-dev libz3-dev pkg-config tzdata unzip \
        zlib1g-dev curl ca-certificates >/dev/null
}

install_swift() {
    if [ -x "${SWIFT_PREFIX}/usr/bin/swift" ]; then
        log "Swift toolchain already present at ${SWIFT_PREFIX}; skipping download."
    else
        local tmp
        tmp="$(mktemp -d)"
        log "Downloading ${SWIFT_URL}"
        curl -fL --retry 3 -o "${tmp}/swift.tar.gz" "${SWIFT_URL}"
        $SUDO mkdir -p "${SWIFT_PREFIX}"
        log "Extracting toolchain to ${SWIFT_PREFIX}"
        $SUDO tar xzf "${tmp}/swift.tar.gz" -C "${SWIFT_PREFIX}" --strip-components=1
        rm -rf "${tmp}"
    fi
    $SUDO ln -sf "${SWIFT_PREFIX}/usr/bin/swift" /usr/local/bin/swift
    $SUDO ln -sf "${SWIFT_PREFIX}/usr/bin/swiftc" /usr/local/bin/swiftc
}

install_apt_deps
install_swift

log "Swift toolchain ready:"
swift --version
