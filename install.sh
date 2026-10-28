#!/bin/zsh
# Install or update RayNeoPin. Run it again (or use "Check for Updates…" in the menu) to update:
#
#   curl -fsSL https://raw.githubusercontent.com/Fuut4/rayneo-pin/main/install.sh | zsh
#
# Another branch (remembered for later updates; RAYNEOPIN_BRANCH=main goes back):
#
#   curl -fsSL https://raw.githubusercontent.com/Fuut4/rayneo-pin/test/everything/install.sh | RAYNEOPIN_BRANCH=test/everything zsh
#
# Keeps the source in ~/Library/Application Support/RayNeoPin/src, builds it, installs the app
# to /Applications and relaunches it. Pass --force to rebuild even when already up to date.
set -euo pipefail

# Everything runs inside main so zsh has read the whole script before the git
# reset below rewrites this file (and so a truncated curl download runs nothing).
main() {
  REPO=https://github.com/Fuut4/rayneo-pin.git
  SRC="$HOME/Library/Application Support/RayNeoPin/src"
  DEST=/Applications/RayNeoPin.app
  [[ -w /Applications ]] || DEST="$HOME/Applications/RayNeoPin.app"
  FORCE=0
  [[ "${1:-}" == "--force" ]] && FORCE=1

  if ! xcode-select -p >/dev/null 2>&1; then
    echo "Xcode Command Line Tools are required. Install them with: xcode-select --install"
    exit 1
  fi

  # "==> step/total" lines are progress, shown by the app while it updates.
  echo "==> 1/4 Downloading the latest version…"
  if [[ -d "$SRC/.git" ]]; then
    BRANCH=${RAYNEOPIN_BRANCH:-$(git -C "$SRC" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)}
    git -C "$SRC" fetch --quiet origin
  else
    BRANCH=${RAYNEOPIN_BRANCH:-main}
    mkdir -p "${SRC:h}"
    git clone --quiet "$REPO" "$SRC"
  fi
  git -C "$SRC" checkout --quiet -B "$BRANCH" "origin/$BRANCH"
  git -C "$SRC" reset --quiet --hard "origin/$BRANCH"

  NEW=$(git -C "$SRC" rev-parse --short HEAD)
  OLD=$(cat "$DEST/Contents/Resources/revision" 2>/dev/null || echo none)
  if [[ $FORCE == 0 && "$NEW" == "$OLD" ]]; then
    echo "RayNeoPin is up to date ($NEW, $BRANCH)."
    exit 0
  fi

  echo "==> 2/4 Building $NEW ($OLD → $NEW), about a minute…"
  "$SRC/build.sh"

  # From the app's "Check for Updates…", the app restarts itself once the new copy is in place.
  # From Terminal, quit the running copy for sure, or the old version keeps running.
  if [[ -z "${RAYNEOPIN_FROM_APP:-}" ]]; then
    pkill -x RayNeoPin 2>/dev/null || true
    for _ in {1..20}; do pgrep -x RayNeoPin >/dev/null || break; sleep 0.25; done
    pkill -9 -x RayNeoPin 2>/dev/null || true
  fi
  echo "==> 3/4 Installing…"
  mkdir -p "${DEST:h}"
  rm -rf "$DEST"
  cp -R "$SRC/RayNeoPin.app" "$DEST"
  [[ -z "${RAYNEOPIN_FROM_APP:-}" ]] && open "$DEST"
  echo "RayNeoPin $NEW ($BRANCH) installed to $DEST ($OLD → $NEW)."
}

main "$@"
