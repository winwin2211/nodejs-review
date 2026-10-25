#!/usr/bin/env bash
# Keep only the ESLint messages that sit on an added line of the diff.
#
#   lint-changed.sh ESLINT.json ADDED.tsv ROOT OUT.json   -> prints the kept count
#
# ESLint reports absolute paths; they are made relative to ROOT so they match
# added-lines.tsv (file<TAB>line, repo-relative). Files left with no messages
# are dropped from OUT.json.
set -euo pipefail
IN=${1:?usage: lint-changed.sh ESLINT.json ADDED.tsv ROOT OUT.json}
ADDED=${2:?}; ROOT=${3:?}; OUTF=${4:?}
ROOT=$(cd "$ROOT" && pwd -P)

added=$(awk -F'\t' 'NF >= 2 { print $1 "\t" $2 }' "$ADDED" |
  jq -Rs 'split("\n") | map(select(length > 0) | split("\t")) | group_by(.[0]) | map({key: .[0][0], value: map(.[1] | tonumber)}) | from_entries')

jq --arg root "$ROOT/" --argjson added "$added" '
  map(
    .filePath as $abs
    | (if ($abs | startswith($root)) then ($abs | ltrimstr($root)) else $abs end) as $rel
    | { filePath: $rel, messages: [ .messages[] | .line as $ln | select((($added[$rel] // []) | index($ln)) != null) ] }
  )
  | map(select(.messages | length > 0))
' "$IN" > "$OUTF"
jq '[.[].messages | length] | add // 0' "$OUTF"
