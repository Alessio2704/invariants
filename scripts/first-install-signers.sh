#!/bin/sh
set -eu

# Candidate public keys
HOME_DIR="${HOME:-/Users/$(whoami)}"
KEY="${1:-}"

# 1. If not explicitly passed, query git config user.signingkey
if [ -z "$KEY" ]; then
  GIT_SIGNING_KEY="$(git config --get user.signingkey 2>/dev/null || true)"
  if [ -n "$GIT_SIGNING_KEY" ]; then
    case "$GIT_SIGNING_KEY" in
      ~/*) EXPANDED_KEY="$HOME_DIR/${GIT_SIGNING_KEY#\~/}" ;;
      *) EXPANDED_KEY="$GIT_SIGNING_KEY" ;;
    esac
    if [ -f "$EXPANDED_KEY" ]; then
      KEY="$EXPANDED_KEY"
    fi
  fi
fi

# 2. If still not found and interactive, prompt user to select from ~/.ssh/*.pub
if [ -z "$KEY" ] && [ -t 0 ]; then
  CANDIDATES=""
  for pub_candidate in "$HOME_DIR/.ssh/"*.pub; do
    if [ -f "$pub_candidate" ]; then
      CANDIDATES="$CANDIDATES $pub_candidate"
    fi
  done
  if [ -n "$CANDIDATES" ]; then
    echo "Discovered SSH public keys:" >&2
    i=1
    for c in $CANDIDATES; do
      echo "  [$i] $c" >&2
      i=$((i + 1))
    done
    printf "Select key number [1-$((i - 1))] or enter path: " >&2
    read -r CHOICE
    if [ -n "$CHOICE" ]; then
      case "$CHOICE" in
        [1-9]*)
          idx=1
          for c in $CANDIDATES; do
            if [ "$idx" -eq "$CHOICE" ]; then
              KEY="$c"
              break
            fi
            idx=$((idx + 1))
          done
          ;;
        *)
          case "$CHOICE" in
            ~/*) KEY="$HOME_DIR/${CHOICE#\~/}" ;;
            *) KEY="$CHOICE" ;;
          esac
          ;;
      esac
    fi
  fi
fi

if [ -z "$KEY" ] || [ ! -f "$KEY" ]; then
  echo "Error: Could not determine SSH signing key." >&2
  echo "Configure git:  git config --global user.signingkey /path/to/key.pub" >&2
  echo "Or pass path:   $0 /path/to/key.pub" >&2
  exit 1
fi

KEY_CONTENT="$(cat "$KEY")"
TMP_SIGNERS="$(mktemp)"
printf "owner namespaces=\"invariants\" %s\n" "$KEY_CONTENT" > "$TMP_SIGNERS"

echo "Discovered public key for invariants signing:" >&2
echo "  File: $KEY" >&2
/usr/bin/ssh-keygen -lf "$KEY" >&2

printf "%s\n" "$TMP_SIGNERS"
