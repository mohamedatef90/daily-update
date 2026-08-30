#!/bin/zsh
# Avoid pipefail — curl|grep pipelines otherwise exit 23 (SIGPIPE) with no output.
set -eu

SCRIPT_NAME="${0:t}"

get_app_version() {
  plist_value "$1" CFBundleShortVersionString
}

plist_value() {
  local app="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$app/Contents/Info.plist" 2>/dev/null || true
}

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

compare_versions() {
  local current="$1"
  local latest="$2"
  if [[ -z "$current" || -z "$latest" ]]; then
    echo OK
    return
  fi
  if [[ "$current" == "$latest" ]]; then
    echo OK
    return
  fi
  if [[ "$(printf '%s\n' "$current" "$latest" | sort -V | tail -1)" == "$latest" && "$current" != "$latest" ]]; then
    echo UPDATE
    echo "latest: $latest"
  else
    echo OK
  fi
}

fetch_sparkle_version() {
  local feed="$1"
  curl -fsSL "$feed" 2>/dev/null | grep -m1 'sparkle:shortVersionString' 2>/dev/null | sed -E 's/.*>([^<]+)<.*/\1/' || true
}

brew_cask_latest() {
  local cask="$1"
  brew info --cask "$cask" 2>/dev/null | head -1 | sed -E 's/.*\): ([^ (,]+).*/\1/' || true
}

brew_cask_exists() {
  local cask="$1"
  brew info --cask "$cask" 2>/dev/null | head -1 | grep -q '^==>' 2>/dev/null
}

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'
}

cmd_auto() {
  local app
  app="$(find_app "$@")" || { echo OK; return 0; }

  local feed bundle_id name current latest
  feed="$(plist_value "$app" SUFeedURL)"
  if [[ -n "$feed" ]]; then
    cmd_sparkle_feed "$feed" "$app"
    return 0
  fi

  bundle_id="$(plist_value "$app" CFBundleIdentifier)"
  name="${app:t:r}"
  current="$(get_app_version "$app")"

  local -a slugs=()
  if [[ -n "$bundle_id" ]]; then
    slugs+=("$(slugify "${bundle_id##*.}")")
    slugs+=("$(slugify "${bundle_id#*.}")")
  fi
  slugs+=("$(slugify "$name")")
  local trimmed="${name% IDE}"
  trimmed="${trimmed% App}"
  slugs+=("$(slugify "$trimmed")")

  local slug seen="|" best_latest=""
  for slug in "${slugs[@]}"; do
    [[ -z "$slug" ]] && continue
    [[ "$seen" == *"|$slug|"* ]] && continue
    seen="${seen}${slug}|"
    if brew_cask_exists "$slug"; then
      latest="$(brew_cask_latest "$slug")"
      if [[ -n "$latest" ]]; then
        if [[ -z "$best_latest" ]] || [[ "$(printf '%s\n' "$best_latest" "$latest" | sort -V | tail -1)" == "$latest" ]]; then
          best_latest="$latest"
        fi
      fi
    fi
  done

  if [[ -n "$best_latest" ]]; then
    compare_versions "$current" "$best_latest"
    return 0
  fi

  echo OK
}

cmd_brew_cask() {
  local cask="$1"
  shift
  local app
  app="$(find_app "$@")" || { echo OK; return 0; }
  local current latest
  current="$(get_app_version "$app")"
  latest="$(brew_cask_latest "$cask")"
  compare_versions "$current" "$latest"
}

cmd_sparkle_feed() {
  local feed="$1"
  shift
  local app
  app="$(find_app "$@")" || { echo OK; return 0; }
  local current latest
  current="$(get_app_version "$app")"
  latest="$(fetch_sparkle_version "$feed")"
  if [[ -z "$latest" ]]; then
    echo OK
    return 0
  fi
  compare_versions "$current" "$latest"
}

cmd_sparkle_plist() {
  local app
  app="$(find_app "$@")" || { echo OK; return 0; }
  local feed
  feed="$(plist_value "$app" SUFeedURL)"
  if [[ -z "$feed" ]]; then
    echo OK
    return 0
  fi
  cmd_sparkle_feed "$feed" "$app"
}

cmd_brew_or_sparkle() {
  local cask="$1"
  local feed="$2"
  shift 2
  local app
  app="$(find_app "$@")" || { echo OK; return 0; }
  if brew list --cask "$cask" >/dev/null 2>&1; then
    if brew outdated --cask "$cask" 2>/dev/null | grep -q "$cask"; then
      echo UPDATE
      echo "latest: $(brew_cask_latest "$cask")"
    else
      echo OK
    fi
    return 0
  fi
  if [[ -n "$feed" ]]; then
    cmd_sparkle_feed "$feed" "$app"
    return 0
  fi
  cmd_brew_cask "$cask" "$app"
}

usage() {
  echo "Usage: $SCRIPT_NAME brew-cask <cask> <app-path>..." >&2
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
    [[ $# -ge 2 ]] || usage
    cmd_brew_cask "$@"
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
