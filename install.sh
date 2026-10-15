#!/bin/sh
set -eu

if [ $# -lt 1 ]; then
  echo "Usage: ./install.sh <tag> (e.g. ./install.sh v1.0.0)" >&2
  exit 1
fi

TAG="$1"
V="${TAG#v}"
PREFIX="${INVARIANTS_PREFIX:-/usr/local/invariants}"
SIGNERS="$PREFIX/allowed_signers"

if [ ! -f "$SIGNERS" ]; then
  SIGNERS="$(./scripts/first-install-signers.sh)"
fi

echo "Verifying tag signature for $TAG..."
/usr/bin/git -c gpg.ssh.allowedSignersFile="$SIGNERS" tag -v "$TAG" || {
  echo "✗ $TAG not signed by a trusted key in $SIGNERS" >&2
  exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Extracting $TAG archive..."
/usr/bin/git archive "$TAG" | tar -x -C "$WORK"

echo "Building release binary..."
/usr/bin/xcrun swift build -c release --only-use-versions-from-resolved-file --package-path "$WORK"

echo "Running test suite on release candidate..."
/usr/bin/xcrun swift test --package-path "$WORK"

echo "Building TypeScript kit..."
(cd "$WORK/kit-ts" && npm ci --ignore-scripts && npm test && npm run build)

echo "Installing version $V to $PREFIX..."
if [ "${PREFIX#/usr/local/invariants}" != "$PREFIX" ]; then
  SUDO="sudo"
else
  SUDO=""
fi

$SUDO /bin/sh -c "set -e
  mkdir -p '$PREFIX/versions/$V' '$PREFIX/floors'
  cp '$WORK/.build/release/invariants' '$PREFIX/versions/$V/'
  mkdir -p '$PREFIX/versions/$V/kit-swift/Sources'
  cp -R '$WORK/Sources/InvariantKit' '$PREFIX/versions/$V/kit-swift/Sources/'
  cp '$WORK/templates/kit-swift/Package.swift' '$PREFIX/versions/$V/kit-swift/Package.swift'
  cp '$WORK/Package.resolved' '$PREFIX/versions/$V/kit-swift/Package.resolved'
  mkdir -p '$PREFIX/versions/$V/kit-ts'
  cp -R '$WORK/kit-ts/dist' '$WORK/kit-ts/node_modules' '$PREFIX/versions/$V/kit-ts/'
  [ -f '$PREFIX/allowed_signers' ] || cp '$SIGNERS' '$PREFIX/allowed_signers'
  ln -sfn '$PREFIX/versions/$V' '$PREFIX/current'
  mkdir -p /usr/local/bin
  ln -sfn '$PREFIX/current/invariants' /usr/local/bin/invariants
  chown -R root:wheel '$PREFIX' 2>/dev/null || true
  chmod -R go-w '$PREFIX' 2>/dev/null || true
"

echo "✓ Successfully installed invariants v$V to $PREFIX"
