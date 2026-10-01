#!/usr/bin/env bash
# Installs msixrun to ${PREFIX:-~/.local}/bin
set -euo pipefail

URL="https://raw.githubusercontent.com/aaron777collins/msixrun/main/msixrun"
BIN_DIR="${PREFIX:-$HOME/.local}/bin"
DEST="$BIN_DIR/msixrun"

command -v curl >/dev/null 2>&1 || { echo "install: curl is required" >&2; exit 1; }

mkdir -p "$BIN_DIR"
curl -fsSL "$URL" -o "$DEST"
chmod +x "$DEST"
echo "Installed msixrun to $DEST"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "Note: $BIN_DIR is not on your PATH. Add it with:"
     echo "  echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.bashrc && source ~/.bashrc" ;;
esac
