#!/bin/sh
set -eu

if command -v invariants >/dev/null 2>&1; then
  INSTALLED_V="$(invariants --version 2>/dev/null || echo 'installed')"
  echo "✓ Invariants is already installed on this machine (${INSTALLED_V})."
  echo "To upgrade to the latest version, run:"
  echo "    invariants upgrade"
  echo "To manage your keys or repository invariants, run:"
  echo "    invariants key status"
  exit 0
fi

if [ $# -lt 1 ]; then
  echo "Usage: ./install.sh <tag> (e.g. ./install.sh v1.0.0)" >&2
  exit 1
fi

TAG="$1"
V="${TAG#v}"
PREFIX="${INVARIANTS_PREFIX:-/usr/local/invariants}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Extracting $TAG archive..."
/usr/bin/git archive "$TAG" | tar -x -C "$WORK"

echo "Building release binary..."
/usr/bin/xcrun swift build -c release --only-use-versions-from-resolved-file --package-path "$WORK"

echo "Running test suite on release candidate..."
/usr/bin/xcrun swift test --package-path "$WORK"

echo "Building TypeScript kit..."
if [ -d "$WORK/kits/kit-ts" ]; then
  KIT_TS_DIR="$WORK/kits/kit-ts"
else
  KIT_TS_DIR="$WORK/kit-ts"
fi
(cd "$KIT_TS_DIR" && npm ci --ignore-scripts && npm test && npm run build)

echo "Installing version $V to $PREFIX..."
if [ "${PREFIX#/usr/local/invariants}" != "$PREFIX" ]; then
  SUDO="sudo"
else
  SUDO=""
fi

$SUDO /bin/sh -c "set -e
  mkdir -p '$PREFIX/versions/$V'
  cp '$WORK/.build/release/invariants' '$PREFIX/versions/$V/'
  mkdir -p '$PREFIX/versions/$V/kits/kit-swift/Sources'
  cp -R '$WORK/kits/kit-swift/Sources/InvariantKit' '$PREFIX/versions/$V/kits/kit-swift/Sources/'
  cp '$WORK/kits/kit-swift/Package.swift' '$PREFIX/versions/$V/kits/kit-swift/Package.swift'
  cp '$WORK/Package.resolved' '$PREFIX/versions/$V/kits/kit-swift/Package.resolved'
  mkdir -p '$PREFIX/versions/$V/kits/kit-ts'
  if [ -d '$WORK/kits/kit-ts' ]; then
    cp -R '$WORK/kits/kit-ts/dist' '$WORK/kits/kit-ts/node_modules' '$PREFIX/versions/$V/kits/kit-ts/'
  else
    cp -R '$WORK/kit-ts/dist' '$WORK/kit-ts/node_modules' '$PREFIX/versions/$V/kits/kit-ts/'
  fi
  ln -sfn 'kits/kit-swift' '$PREFIX/versions/$V/kit-swift'
  ln -sfn 'kits/kit-ts' '$PREFIX/versions/$V/kit-ts'
  ln -sfn '$PREFIX/versions/$V' '$PREFIX/current'
  mkdir -p /usr/local/bin
  ln -sfn '$PREFIX/current/invariants' /usr/local/bin/invariants
  chown -R root:wheel '$PREFIX' 2>/dev/null || true
  chmod -R go-w '$PREFIX' 2>/dev/null || true
"

echo "✓ Successfully installed invariants v$V to $PREFIX"
