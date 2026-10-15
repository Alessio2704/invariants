#!/bin/sh
set -eu

# Candidate public keys
HOME_DIR="${HOME:-/Users/$(whoami)}"
KEY="${1:-}"

if [ -z "$KEY" ]; then
  # Check FIDO2 / Touch ID key, any Secretive key, or standard Ed25519 key
  if [ -f "$HOME_DIR/.ssh/id_ed25519_sk.pub" ]; then
    KEY="$HOME_DIR/.ssh/id_ed25519_sk.pub"
  else
    # Find any secretive public key
    SECRETIVE_KEY="$(find "$HOME_DIR/.ssh" -maxdepth 1 -name "secretive_*.pub" 2>/dev/null | head -n 1 || true)"
    if [ -n "$SECRETIVE_KEY" ] && [ -f "$SECRETIVE_KEY" ]; then
      KEY="$SECRETIVE_KEY"
    elif [ -f "$HOME_DIR/.ssh/id_ed25519.pub" ]; then
      KEY="$HOME_DIR/.ssh/id_ed25519.pub"
    elif [ -f "$HOME_DIR/.ssh/id_ecdsa_sk.pub" ]; then
      KEY="$HOME_DIR/.ssh/id_ecdsa_sk.pub"
    fi
  fi
fi

if [ -z "$KEY" ] || [ ! -f "$KEY" ]; then
  echo "Error: No public key found in ~/.ssh (id_ed25519_sk.pub, secretive_*.pub, id_ed25519.pub)" >&2
  echo "Usage: $0 [path/to/public_key.pub]" >&2
  exit 1
fi

KEY_CONTENT="$(cat "$KEY")"
TMP_SIGNERS="$(mktemp)"
printf "owner namespaces=\"invariants\" %s\n" "$KEY_CONTENT" > "$TMP_SIGNERS"

echo "Discovered public key for invariants signing:" >&2
echo "  File: $KEY" >&2
/usr/bin/ssh-keygen -lf "$KEY" >&2

printf "%s\n" "$TMP_SIGNERS"
