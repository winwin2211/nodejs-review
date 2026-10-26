#!/usr/bin/env bash
# Print the tsc error lines of HEAD that are absent at BASE.
#
#   typecheck-diff.sh HEAD.txt BASE.txt|-
#
# Errors are compared by file, code and message, never by line number, so an
# unrelated edit above an old error does not make it look new. Each base error
# accounts for one head error: a second caller broken the same way is new. `-` means no
# baseline: every head error is printed. Only `--pretty false` error lines
# count; summary lines and continuation lines are ignored.
set -euo pipefail
HEAD_F=${1:?usage: typecheck-diff.sh HEAD.txt BASE.txt|-}
BASE_F=${2:?usage: typecheck-diff.sh HEAD.txt BASE.txt|-}
[[ "$BASE_F" == "-" ]] && BASE_F=/dev/null
# FILENAME, not NR == FNR: an empty base file (no baseline) has no records, so
# NR == FNR would also hold for the head file's first lines.
awk -v basefile="$BASE_F" '
  function key(l,   f, m) { f = l; sub(/\(.*$/, "", f); m = l; sub(/^[^(]*\([0-9]+,[0-9]+\): /, "", m); return f "|" m }
  function is_err(l) { return l ~ /^[^(]+\([0-9]+,[0-9]+\): error TS[0-9]+: / }
  FILENAME == basefile { if (is_err($0)) base[key($0)]++; next }
  is_err($0) { k = key($0); if (base[k] > 0) base[k]--; else print }
' "$BASE_F" "$HEAD_F"
