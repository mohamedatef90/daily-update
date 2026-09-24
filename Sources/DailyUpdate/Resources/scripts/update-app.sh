#!/bin/zsh
# Install or upgrade macOS apps via Homebrew cask or Sparkle download. If an app
# is managed by its own updater, hand control back to that app instead of trying
# to install a conflicting Homebrew cask over it.
set -eu

SCRIPT_NAME="${0:t}"

find_app() {
  for app in "$@"; do
    app="${app/#\~/$HOME}"
    if [[ -d "$app" ]]; then
      echo "$app"
      return 0
    fi
  done
  return 1
}

plist_value() {
  local app="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$app/Contents/Info.plist" 2>/dev/null || true
}

brew_cask_exists() {
  local cask="$1"
  brew info --cask "$cask" 2>/dev/null | head -1 | grep -q '^==>' 2>/dev/null
}

upgrade_or_install_cask() {
  local cask="$1"
  if brew list --cask "$cask" >/dev/null 2>&1; then
    brew upgrade --cask "$cask"
  else
    brew install --cask "$cask"
  fi
}

handoff_to_app_updater() {
  local app="$1"
  if [[ "${DAILY_UPDATE_TEST_MODE:-0}" != "1" ]]; then
    open "$app"
  fi
  echo "IN_APP_UPDATE: Sparkle direct install is disabled. Opened ${app:t} so its built-in updater can apply the update safely."
}

fetch_latest_sparkle_url() {
  local feed="$1"
  local chunk arch
  chunk="$(curl -fsSL "$feed" 2>/dev/null | sed -n '1,/<\/item>/p' | sed -n '/<item>/,/<\/item>/p' | head -40)" || return 1
  [[ -n "$chunk" ]] || return 1

  arch="$(uname -m)"
  if echo "$chunk" | grep -q 'sparkle:hardwareRequirements'; then
    if [[ "$arch" == "arm64" ]] && ! echo "$chunk" | grep -q 'arm64'; then
      echo "No Sparkle build for $arch in feed" >&2
      return 1
    fi
    if [[ "$arch" == "x86_64" ]] && echo "$chunk" | grep -q 'sparkle:hardwareRequirements>arm64<' && ! echo "$chunk" | grep -q 'x86_64'; then
      echo "No Sparkle build for $arch in feed" >&2
      return 1
    fi
  fi

  echo "$chunk" | grep -m1 '<enclosure url=' | sed -E 's/.*url="([^"]+)".*/\1/'
}

quit_app_if_running() {
  local app_name="$1"
  osascript -e "tell application \"$app_name\" to quit" 2>/dev/null || true
  sleep 2
}

install_downloaded_app() {
  local archive="$1"
  local target_app="$2"
  local tmpdir extracted_app mount staged

  tmpdir="$(mktemp -d)"
  trap "rm -rf '$tmpdir'" EXIT

  case "${archive:t}" in
    *.zip|*.ZIP)
      unzip -q "$archive" -d "$tmpdir/extract"
      extracted_app="$(find "$tmpdir/extract" -name '*.app' -print -quit)"
      ;;
    *.dmg|*.DMG)
      mount="$tmpdir/mount"
      mkdir "$mount"
      hdiutil attach -nobrowse -quiet -mountpoint "$mount" "$archive"
      extracted_app="$(find "$mount" -maxdepth 3 -name '*.app' -print -quit)"
      [[ -n "$extracted_app" ]] || { echo "No .app found in DMG" >&2; return 1; }
      staged="$tmpdir/staged.app"
      ditto "$extracted_app" "$staged"
      hdiutil detach "$mount" -quiet 2>/dev/null || hdiutil detach "$mount" -force -quiet 2>/dev/null || true
      extracted_app="$staged"
      ;;
    *.pkg|*.PKG)
      echo "PKG installers are not supported yet — use Homebrew if available" >&2
      return 1
      ;;
    *)
      echo "Unsupported download type: ${archive:t}" >&2
      return 1
      ;;
  esac

  [[ -n "$extracted_app" && -d "$extracted_app" ]] || { echo "No .app found in download" >&2; return 1; }

  quit_app_if_running "${target_app:t:r}"
  mkdir -p "${target_app:h}"
  rm -rf "$target_app"
  ditto "$extracted_app" "$target_app"
}

download_and_install_sparkle() {
  local feed="$1"
  local target_app="$2"
  [[ -n "$feed" && -n "$target_app" ]] || true
  echo "Sparkle direct install is disabled until signature verification is implemented." >&2
  return 1
}

cmd_brew_cask() {
  local cask="$1"
  [[ -n "$cask" ]] || { echo "Missing cask name" >&2; return 1; }
  if ! brew_cask_exists "$cask"; then
    echo "Homebrew cask '$cask' not found" >&2
    return 1
  fi
  upgrade_or_install_cask "$cask"
}

cmd_sparkle_feed() {
  local feed="$1"
  shift
  local app
  app="$(find_app "$@")" || { echo "App not found" >&2; return 1; }
  handoff_to_app_updater "$app"
}

cmd_sparkle_plist() {
  local app feed
  app="$(find_app "$@")" || { echo "App not found" >&2; return 1; }
  feed="$(plist_value "$app" SUFeedURL)"
  [[ -n "$feed" ]] || { echo "No Sparkle feed in app plist" >&2; return 1; }
  handoff_to_app_updater "$app"
}

cmd_brew_or_sparkle() {
  local cask="$1"
  local feed="$2"
  shift 2
  local app
  app="$(find_app "$@")" || { echo "App not found" >&2; return 1; }

  if brew list --cask "$cask" >/dev/null 2>&1; then
    brew upgrade --cask "$cask"
    return 0
  fi

  handoff_to_app_updater "$app"
}

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'
}

resolve_brew_cask_for_app() {
  local app="$1"
  local bundle_id name trimmed slug seen="|"
  local -a slugs
  slugs=()

  bundle_id="$(plist_value "$app" CFBundleIdentifier)"
  name="${app:t:r}"

  if [[ -n "$bundle_id" ]]; then
    slugs+=("$(slugify "${bundle_id##*.}")")
    slugs+=("$(slugify "${bundle_id#*.}")")
  fi
  slugs+=("$(slugify "$name")")
  trimmed="${name% IDE}"
  trimmed="${trimmed% App}"
  slugs+=("$(slugify "$trimmed")")

  for slug in "${slugs[@]}"; do
    [[ -z "$slug" ]] && continue
    [[ "$seen" == *"|$slug|"* ]] && continue
    seen="${seen}${slug}|"
    if brew_cask_exists "$slug"; then
      echo "$slug"
      return 0
    fi
  done
  return 1
}

cmd_auto() {
  local app cask feed
  app="$(find_app "$@")" || { echo "App not found" >&2; return 1; }

  if cask="$(resolve_brew_cask_for_app "$app")" && brew list --cask "$cask" >/dev/null 2>&1; then
    brew upgrade --cask "$cask"
    return 0
  fi

  feed="$(plist_value "$app" SUFeedURL)"
  if [[ -n "$feed" ]]; then
    handoff_to_app_updater "$app"
    return 0
  fi

  handoff_to_app_updater "$app"
}

cmd_smart() {
  local cask="$1"
  shift
  local app feed
  app="$(find_app "$@")" || { echo "App not found" >&2; return 1; }

  if brew list --cask "$cask" >/dev/null 2>&1; then
    brew upgrade --cask "$cask"
    return 0
  fi

  feed="$(plist_value "$app" SUFeedURL)"
  if [[ -n "$feed" ]]; then
    handoff_to_app_updater "$app"
    return 0
  fi

  handoff_to_app_updater "$app"
}

usage() {
  echo "Usage: $SCRIPT_NAME brew-cask <cask>" >&2
  echo "       $SCRIPT_NAME smart <cask> <app-path>..." >&2
  echo "       $SCRIPT_NAME sparkle-feed <feed-url> <app-path>..." >&2
  echo "       $SCRIPT_NAME sparkle-plist <app-path>..." >&2
  echo "       $SCRIPT_NAME brew-or-sparkle <cask> <feed-url> <app-path>..." >&2
  echo "       $SCRIPT_NAME auto <app-path>..." >&2
  exit 2
}

[[ $# -ge 1 ]] || usage

case "$1" in
  brew-cask)
    shift
    [[ $# -ge 1 ]] || usage
    cmd_brew_cask "$@"
    ;;
  smart)
    shift
    [[ $# -ge 2 ]] || usage
    cmd_smart "$@"
    ;;
  sparkle-feed)
    shift
    [[ $# -ge 2 ]] || usage
    cmd_sparkle_feed "$@"
    ;;
  sparkle-plist)
    shift
    [[ $# -ge 1 ]] || usage
    cmd_sparkle_plist "$@"
    ;;
  brew-or-sparkle)
    shift
    [[ $# -ge 3 ]] || usage
    cmd_brew_or_sparkle "$@"
    ;;
  auto)
    shift
    [[ $# -ge 1 ]] || usage
    cmd_auto "$@"
    ;;
  *)
    usage
    ;;
esac

exit 0
