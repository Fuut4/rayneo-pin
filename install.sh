#!/bin/zsh
# Install or update RayNeoPin. Run it again (or use "Check for Updates…" in the menu) to update:
#
#   curl -fsSL https://raw.githubusercontent.com/Fuut4/rayneo-pin/main/install.sh | zsh
#
# The Developer channel (new work first; remembered for later updates, and the app's
# Update Channel menu switches both ways; RAYNEOPIN_BRANCH=main goes back to Release):
#
#   curl -fsSL https://raw.githubusercontent.com/Fuut4/rayneo-pin/develop/install.sh | RAYNEOPIN_BRANCH=develop zsh
#
# Keeps the source in ~/Library/Application Support/RayNeoPin/src, builds it, installs the app
# to /Applications and relaunches it. Pass --force to rebuild even when already up to date.
set -euo pipefail

fail() { echo "✗ $1" >&2; exit 1; }

# Apple's Command Line Tools: git and the Swift compiler, working (license accepted, not broken
# by a macOS update).
tools_ok() { xcrun --find git >/dev/null 2>&1 && xcrun swiftc --version >/dev/null 2>&1; }

# Installs the Command Line Tools if they're missing, through Apple's own installer window, and
# waits for it. From the app's updater (no Terminal to explain things in), it only reports.
ensure_tools() {
  tools_ok && return 0
  local why=$(xcrun swiftc --version 2>&1 || true)
  if [[ "$why" == *license* ]]; then
    fail "Accept Xcode's license first: sudo xcodebuild -license accept"
  fi
  [[ -n "${RAYNEOPIN_FROM_APP:-}" ]] && fail "Apple's Command Line Tools are missing. Run the install command in Terminal once."
  if xcode-select -p >/dev/null 2>&1; then
    # Installed but unusable, usually after a macOS update.
    fail "Apple's Command Line Tools look damaged. Reinstall them:
  sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install
then run this command again."
  fi
  echo "RayNeoPin is built on your Mac with Apple's Command Line Tools (free, a few minutes)."
  echo "A macOS window will open: click Install and accept the license."
  xcode-select --install >/dev/null 2>&1 || true
  echo -n "Waiting for the installation to finish"
  local waited=0
  until tools_ok; do
    sleep 5
    waited=$((waited + 5))
    echo -n "."
    (( waited < 3600 )) || { echo; fail "The Command Line Tools didn't finish within an hour. Run this command again once they have."; }
  done
  echo " done."
}

# Everything runs inside main so zsh has read the whole script before the git
# reset below rewrites this file (and so a truncated curl download runs nothing).
main() {
  REPO=https://github.com/Fuut4/rayneo-pin.git
  SRC="$HOME/Library/Application Support/RayNeoPin/src"
  DEST=/Applications/RayNeoPin.app
  [[ -w /Applications ]] || DEST="$HOME/Applications/RayNeoPin.app"
  FORCE=0
  [[ "${1:-}" == "--force" ]] && FORCE=1

  # Everything that can be checked before downloading anything.
  [[ "$(uname -m)" == arm64 ]] || fail "RayNeoPin needs an Apple Silicon Mac (M1 or later)."
  local version=$(sw_vers -productVersion)
  (( ${version%%.*} >= 14 )) || fail "RayNeoPin needs macOS 14 Sonoma or later (this Mac runs $version)."
  ensure_tools

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
  # The old test branch became the Developer channel.
  [[ "$BRANCH" == "test/everything" ]] && BRANCH=develop
  git -C "$SRC" checkout --quiet -B "$BRANCH" "origin/$BRANCH"
  git -C "$SRC" reset --quiet --hard "origin/$BRANCH"

  NEW=$(git -C "$SRC" rev-parse --short HEAD)
  OLD=$(cat "$DEST/Contents/Resources/revision" 2>/dev/null || echo none)
  if [[ $FORCE == 0 && "$NEW" == "$OLD" ]]; then
    echo "RayNeoPin is up to date ($NEW, $BRANCH)."
    exit 0
  fi

  echo "==> 2/4 Building $NEW ($OLD → $NEW), about a minute…"
  # (build.sh signs it; see there for how the Screen Recording permission survives updates.)
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
