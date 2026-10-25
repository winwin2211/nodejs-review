#!/usr/bin/env bash
# Copy the language-independent scripts from the go-review sibling, which is
# their source of truth. `--check` only reports drift (exit 1) and copies
# nothing. `--root DIR` checks or syncs DIR instead of this checkout (tests).
# Exit 2 is a usage error or a missing sibling.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SIB=${GO_REVIEW_DIR:-$ROOT/../go-review}
SHARED="skill/scripts/lib.sh skill/scripts/find-specs.sh skill/scripts/assert-clean.sh skill/scripts/gitlab-post.sh tests/lib.sh"

CHECK=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK=1; shift ;;
    --root) [[ $# -ge 2 && -d "$2" ]] || { echo "sync-shared.sh: --root needs an existing directory" >&2; exit 2; }; ROOT=$(cd "$2" && pwd); shift 2 ;;
    *) echo "usage: sync-shared.sh [--check] [--root DIR]" >&2; exit 2 ;;
  esac
done
[[ -d "$SIB" ]] || { echo "sync-shared.sh: go-review sibling not found at $SIB (set GO_REVIEW_DIR)" >&2; exit 2; }

rc=0
for f in $SHARED; do
  if [[ ! -f "$SIB/$f" ]]; then echo "sync-shared.sh: missing in sibling: $f" >&2; rc=1; continue; fi
  if [[ $CHECK -eq 1 ]]; then
    if [[ ! -f "$ROOT/$f" ]] || ! cmp -s "$SIB/$f" "$ROOT/$f"; then echo "differs: $f"; rc=1; fi
  else
    mkdir -p "$ROOT/$(dirname "$f")"
    cp "$SIB/$f" "$ROOT/$f"
    echo "synced $f"
  fi
done
exit $rc
