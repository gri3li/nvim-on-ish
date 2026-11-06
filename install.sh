#!/bin/sh
# install.sh — install a modern Neovim (from Alpine v3.24) on iSH
# without upgrading iSH's base system.
#
# Usage (as root inside iSH, from the repo directory):
#   ./install.sh
#
# Environment overrides:
#   PREFIX         isolated root for nvim and its libs  (default: /opt/nvim-on-ish)
#   ALPINE_BRANCH  Alpine branch to take nvim from      (default: v3.24)
#   ALPINE_MIRROR  Alpine mirror                        (default: https://dl-cdn.alpinelinux.org/alpine)
#   BINDIR         where to put the launcher            (default: /usr/local/bin)
#   NAME           launcher name                        (default: nvim12)
#
# Re-running the script upgrades nvim inside PREFIX and re-applies patches.

set -eu

PREFIX=${PREFIX:-/opt/nvim-on-ish}
ALPINE_BRANCH=${ALPINE_BRANCH:-v3.24}
ALPINE_MIRROR=${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}
BINDIR=${BINDIR:-/usr/local/bin}
NAME=${NAME:-nvim12}

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_URL=$ALPINE_MIRROR/$ALPINE_BRANCH
NV=$PREFIX/usr/bin/nvim
LPEG_ABS=/usr/lib/lua/5.1/lpeg.so

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- sanity checks -----------------------------------------------------------

[ "$(id -u)" = 0 ] || die "run as root (iSH's default user is root)"
[ -f /etc/alpine-release ] || die "this script expects iSH's Alpine userland"
case "$(uname -m)" in
  i?86) ;;
  *) warn "unexpected arch $(uname -m); this was written for iSH (i686)" ;;
esac
for f in shim.c nvim12.in; do
  [ -f "$REPO_DIR/$f" ] || die "missing $f next to install.sh"
done

say "Base system: Alpine $(cat /etc/alpine-release); taking nvim from $ALPINE_BRANCH"

# --- 1. host build tools (from iSH's own repos) -------------------------------

say "Installing host tools: patchelf gcc musl-dev"
apk add --no-cache patchelf gcc musl-dev >/dev/null

# --- 2. nvim + deps into an isolated root ------------------------------------

mkdir -p "$PREFIX/etc/apk"
cp -r /etc/apk/keys "$PREFIX/etc/apk/"

APK_ROOT="apk --root $PREFIX --arch x86 -X $REPO_URL/main -X $REPO_URL/community --no-cache --no-scripts"

if [ -x "$NV" ]; then
  say "Upgrading neovim in $PREFIX"
  $APK_ROOT upgrade
else
  say "Installing neovim into $PREFIX"
  $APK_ROOT --initdb add neovim
fi

[ -x "$NV" ] || die "neovim was not installed into $PREFIX"

# --- 3. patch the nvim binary ------------------------------------------------

# Alpine links lpeg by absolute path, which ignores LD_LIBRARY_PATH and would
# pick iSH's /usr/lib (or nothing). Make it a plain soname.
if patchelf --print-needed "$NV" | grep -qx "$LPEG_ABS"; then
  say "Patching nvim: $LPEG_ABS -> lpeg.so"
  patchelf --replace-needed "$LPEG_ABS" lpeg.so "$NV"
fi

# Load our shim into every nvim process (TUI client and server).
if ! patchelf --print-needed "$NV" | grep -qx libshim.so; then
  say "Patching nvim: adding libshim.so"
  patchelf --add-needed libshim.so "$NV"
fi

# --- 4. build the shim -------------------------------------------------------

say "Building libshim.so"
mkdir -p "$PREFIX/shim"
cp "$REPO_DIR/shim.c" "$PREFIX/shim/shim.c"
gcc -shared -fPIC -O2 -o "$PREFIX/shim/libshim.so" "$PREFIX/shim/shim.c" -ldl

# --- 5. launcher ---------------------------------------------------------------

say "Installing launcher $BINDIR/$NAME"
mkdir -p "$BINDIR"
sed "s|@PREFIX@|$PREFIX|g" "$REPO_DIR/nvim12.in" > "$BINDIR/$NAME"
chmod +x "$BINDIR/$NAME"

# --- 6. smoke test -----------------------------------------------------------

say "Smoke test"
if ver=$("$BINDIR/$NAME" --version 2>&1 | head -n 1) && case "$ver" in NVIM*) true ;; *) false ;; esac; then
  say "OK: $ver"
else
  printf '%s\n' "$ver" >&2
  die "smoke test failed; see README.md -> Troubleshooting"
fi

cat <<EOF

Done. Run:  $NAME file.txt
Optional:   echo "alias nvim=$NAME" >> ~/.profile   (or ~/.zshrc)
Uninstall:  PREFIX=$PREFIX BINDIR=$BINDIR NAME=$NAME $REPO_DIR/uninstall.sh
EOF
