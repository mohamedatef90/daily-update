#!/bin/zsh
# Install the built DailyUpdate.app into ~/Applications, replacing any previous copy.
#
# The new bundle is copied next to the destination under a temporary name first, so a
# failed copy never touches the installed app. The swap is then two renames: the old copy
# is moved aside, the new one moved into place, and the old copy is removed. If the second
# rename fails, the old copy is put back.
#
# Usage:
#   ./scripts/build-app.sh      # build DailyUpdate.app in the repo root
#   ./scripts/install-app.sh    # copy it to ~/Applications/DailyUpdate.app
#
# Override the destination folder with DAILY_UPDATE_INSTALL_DIR (mainly for testing).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/DailyUpdate.app"
DEST_DIR="${DAILY_UPDATE_INSTALL_DIR:-$HOME/Applications}"
DEST="$DEST_DIR/DailyUpdate.app"
TMP="$DEST_DIR/.DailyUpdate.app.new.$$"
OLD="$DEST_DIR/.DailyUpdate.app.old.$$"

if [[ ! -x "$SRC/Contents/MacOS/DailyUpdate" ]]; then
    echo "No built app at $SRC. Run ./scripts/build-app.sh first." >&2
    exit 1
fi

mkdir -p "$DEST_DIR"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

echo "Copying to $DEST ..."
ditto "$SRC" "$TMP"
if [[ ! -x "$TMP/Contents/MacOS/DailyUpdate" ]]; then
    echo "The copy is incomplete; the installed app was not changed." >&2
    exit 1
fi

if [[ -e "$DEST" ]]; then
    mv "$DEST" "$OLD"
fi
if ! mv "$TMP" "$DEST"; then
    echo "Could not move the new copy into place; restoring the previous app." >&2
    [[ -e "$OLD" ]] && mv "$OLD" "$DEST"
    exit 1
fi
rm -rf "$OLD"

echo "Installed: $DEST"
if pgrep -f "$DEST/Contents/MacOS/DailyUpdate" >/dev/null 2>&1; then
    echo "Daily Update is running. Quit and reopen it to use the new version."
fi
echo "If Launch at login is on, turn it off and on again in Settings so it points to this copy."
