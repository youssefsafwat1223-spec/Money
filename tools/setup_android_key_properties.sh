#!/usr/bin/env bash
# Create app/android/key.properties with hidden password entry.
#
# WHY THIS IS A SCRIPT YOU RUN, NOT SOMETHING THE ASSISTANT RUNS
# The two passwords must never reach the transcript. `read -s` disables terminal
# echo, so they go from your keyboard into the file and nowhere else — not into
# chat, not into argv (visible in `ps`), not into shell history.
#
# Nothing here prints, logs or returns a password. The verification at the end
# checks that the four keys exist and are non-empty WITHOUT reading their values.
#
# Run from the repository root:
#     bash tools/setup_android_key_properties.sh

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$REPO/app/android/key.properties"
KEYSTORE="$HOME/qirsh-upload-keystore.jks"
ALIAS="qirsh-upload"

# Keep this shell's history out of it entirely.
unset HISTFILE 2>/dev/null || true
set +o history 2>/dev/null || true

if [ ! -f "$KEYSTORE" ]; then
  echo "error: keystore not found at $KEYSTORE" >&2
  exit 1
fi

if [ -f "$DEST" ]; then
  printf 'key.properties already exists. Overwrite? [y/N] '
  read -r reply
  case "$reply" in [yY]) ;; *) echo "aborted, nothing changed."; exit 0;; esac
fi

echo "Keystore: $KEYSTORE"
echo "Alias:    $ALIAS"
echo
echo "Passwords are hidden as you type and are never displayed or logged."
echo

printf 'Store password: '
read -rs STORE_PW; echo
printf 'Key password:   '
read -rs KEY_PW; echo

if [ -z "$STORE_PW" ] || [ -z "$KEY_PW" ]; then
  unset STORE_PW KEY_PW
  echo "error: empty password — nothing written." >&2
  exit 1
fi

# umask before creation so the file is never briefly world-readable.
umask 077
printf 'storeFile=%s\nstorePassword=%s\nkeyAlias=%s\nkeyPassword=%s\n' \
  "$KEYSTORE" "$STORE_PW" "$ALIAS" "$KEY_PW" > "$DEST"
chmod 600 "$DEST"

unset STORE_PW KEY_PW

echo
echo "Wrote $DEST"
echo "  permissions: $(stat -f '%Sp' "$DEST")"

# Structural check only — key names and non-emptiness, never values.
missing=0
for k in storeFile storePassword keyAlias keyPassword; do
  if grep -qE "^${k}=.+$" "$DEST"; then
    echo "  $k: present, non-empty"
  else
    echo "  $k: MISSING OR EMPTY"; missing=1
  fi
done

# The two non-secret values are safe to confirm exactly.
grep -q "^storeFile=$KEYSTORE$" "$DEST" && echo "  storeFile points at the keystore ✓"
grep -q "^keyAlias=$ALIAS$"     "$DEST" && echo "  keyAlias is $ALIAS ✓"

if git -C "$REPO" check-ignore -q "$DEST"; then
  echo "  gitignored ✓"
else
  echo "  WARNING: NOT gitignored — do not commit" >&2; missing=1
fi

echo
if [ "$missing" -eq 0 ]; then
  echo "Done. Next: ./gradlew signingReport (from app/android)."
else
  echo "Completed with problems — see above." >&2
  exit 1
fi
