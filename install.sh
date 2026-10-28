#!/bin/sh
set -eu

if command -v invariants >/dev/null 2>&1; then
  INSTALLED_V="$(invariants --version 2>/dev/null || echo 'installed')"
  echo "✓ Invariants is already installed on this machine (${INSTALLED_V})."
  echo "To upgrade to the latest version, run:"
  echo "    invariants self-update"
  echo "To manage your keys or repository invariants, run:"
  echo "    invariants key status"
  exit 0
fi

REPO_URL="${INVARIANTS_REPO:-https://github.com/Alessio2704/invariants.git}"

# If a tag or branch is provided as an argument, use it; otherwise auto-detect latest release tag or default to main
TAG="${1:-}"
if [ -z "$TAG" ]; then
  LATEST_TAG=$(/usr/bin/git ls-remote --tags --refs --sort='v:refname' "$REPO_URL" 2>/dev/null | tail -n1 | sed 's/.*\///')
  TAG="${LATEST_TAG:-main}"
fi

# Strict character validation for TAG to prevent command injection
if ! expr "$TAG" : '^[0-9a-zA-Z._/-]*$' >/dev/null 2>&1; then
  echo "Error: Invalid tag format '$TAG'" >&2
  exit 1
fi

V="${TAG#v}"
PREFIX="${INVARIANTS_PREFIX:-/usr/local/invariants}"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Cloning Invariants ($TAG) from $REPO_URL..."
/usr/bin/git clone --depth 1 --branch "$TAG" "$REPO_URL" "$WORK"

echo "Building release binary..."
/usr/bin/xcrun swift build -c release --only-use-versions-from-resolved-file --package-path "$WORK"

if [ -d "$WORK/kits/kit-ts" ] && command -v npm >/dev/null 2>&1; then
  echo "Installing TypeScript kit runtime dependencies..."
  (cd "$WORK/kits/kit-ts" && npm ci --omit=dev --ignore-scripts 2>/dev/null || npm install --omit=dev --ignore-scripts) || true
fi

echo "Installing version $V to $PREFIX..."
if [ "${PREFIX#/usr/local/invariants}" != "$PREFIX" ]; then
  SUDO="sudo"
else
  SUDO=""
fi

$SUDO /bin/sh -c 'set -e
  prefix="$1"
  v="$2"
  work="$3"
  bin_dir="$4"

  mkdir -p "$prefix/versions/$v"
  cp "$work/.build/release/invariants" "$prefix/versions/$v/"

  if [ -d "$work/kits" ]; then
    mkdir -p "$prefix/versions/$v/kits"
    cp -R "$work/kits"/* "$prefix/versions/$v/kits/"

    for kit_dir in "$prefix/versions/$v/kits"/*; do
      [ -d "$kit_dir" ] || continue
      kit_name="$(basename "$kit_dir")"
      ln -sfn "kits/$kit_name" "$prefix/versions/$v/$kit_name"
    done
  fi

  ln -sfn "$prefix/versions/$v" "$prefix/current"
  mkdir -p "$bin_dir"
  ln -sfn "$prefix/current/invariants" "$bin_dir/invariants"
  chown -R root:wheel "$prefix" 2>/dev/null || true
  chmod -R go-w "$prefix" 2>/dev/null || true
' _ "$PREFIX" "$V" "$WORK" "$BIN_DIR"

echo "✓ Successfully installed invariants v$V to $PREFIX"
