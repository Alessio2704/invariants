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

V="${TAG#v}"
PREFIX="${INVARIANTS_PREFIX:-/usr/local/invariants}"

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

$SUDO /bin/sh -c "set -e
  mkdir -p '$PREFIX/versions/$V'
  cp '$WORK/.build/release/invariants' '$PREFIX/versions/$V/'

  if [ -d '$WORK/kits' ]; then
    mkdir -p '$PREFIX/versions/$V/kits'
    cp -R '$WORK/kits'/* '$PREFIX/versions/$V/kits/'

    for kit_dir in '$PREFIX/versions/$V/kits'/*; do
      [ -d \"\$kit_dir\" ] || continue
      kit_name=\"\$(basename \"\$kit_dir\")\"
      ln -sfn \"kits/\$kit_name\" \"$PREFIX/versions/$V/\$kit_name\"
    done
  fi

  ln -sfn '$PREFIX/versions/$V' '$PREFIX/current'
  mkdir -p /usr/local/bin
  ln -sfn '$PREFIX/current/invariants' /usr/local/bin/invariants
  chown -R root:wheel '$PREFIX' 2>/dev/null || true
  chmod -R go-w '$PREFIX' 2>/dev/null || true
"

echo "✓ Successfully installed invariants v$V to $PREFIX"
