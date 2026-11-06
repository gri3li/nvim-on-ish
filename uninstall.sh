#!/bin/sh
# uninstall.sh — remove what install.sh created.
# Your config (~/.config/nvim) and plugins (~/.local/share/nvim) are kept.
# Host tools (patchelf, gcc, musl-dev) are kept; remove them with apk if unwanted.

set -eu

PREFIX=${PREFIX:-/opt/nvim-on-ish}
BINDIR=${BINDIR:-/usr/local/bin}
NAME=${NAME:-nvim12}

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

case "$PREFIX" in
  ""|/|/usr|/usr/*|/bin|/lib|/etc) echo "refusing to remove PREFIX=$PREFIX" >&2; exit 1 ;;
esac

if [ -f "$BINDIR/$NAME" ] && grep -q "$PREFIX" "$BINDIR/$NAME"; then
  rm -f "$BINDIR/$NAME"
  echo "removed $BINDIR/$NAME"
fi

if [ -d "$PREFIX" ]; then
  rm -rf "$PREFIX"
  echo "removed $PREFIX"
fi

rm -f "${TMPDIR:-/tmp}"/nvim12-*.sock
echo "done"
