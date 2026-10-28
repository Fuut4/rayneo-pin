#!/bin/zsh
# Install or update RayNeoPin. Run it again (or use "Buscar actualización…" in the menu) to update:
#
#   curl -fsSL https://raw.githubusercontent.com/Fuut4/rayneo-pin/main/install.sh | zsh
#
# Keeps the source in ~/Library/Application Support/RayNeoPin/src, builds it, installs the app
# to /Applications and relaunches it. Pass --force to rebuild even when already up to date.
set -euo pipefail

REPO=https://github.com/Fuut4/rayneo-pin.git
SRC="$HOME/Library/Application Support/RayNeoPin/src"
DEST=/Applications/RayNeoPin.app
[[ -w /Applications ]] || DEST="$HOME/Applications/RayNeoPin.app"
FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Hacen falta las Command Line Tools de Xcode. Instalalas con: xcode-select --install"
  exit 1
fi

if [[ -d "$SRC/.git" ]]; then
  git -C "$SRC" fetch --quiet origin
  git -C "$SRC" reset --quiet --hard origin/HEAD
else
  mkdir -p "${SRC:h}"
  git clone --quiet "$REPO" "$SRC"
fi

NEW=$(git -C "$SRC" rev-parse --short HEAD)
OLD=$(cat "$DEST/Contents/Resources/revision" 2>/dev/null || echo none)
if [[ $FORCE == 0 && "$NEW" == "$OLD" ]]; then
  echo "RayNeoPin ya está actualizado ($NEW)."
  exit 0
fi

echo "Compilando RayNeoPin $NEW…"
"$SRC/build.sh"

pkill -x RayNeoPin 2>/dev/null && sleep 1 || true
mkdir -p "${DEST:h}"
rm -rf "$DEST"
cp -R "$SRC/RayNeoPin.app" "$DEST"
open "$DEST"
echo "RayNeoPin $NEW instalado en $DEST ($OLD → $NEW)."
