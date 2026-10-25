#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
S="$REPO_ROOT/skill/scripts"
d=$(tmpdir)
repo="$d/repo"; mkdir -p "$repo"

cat > "$d/eslint.json" <<EOF
[
  {"filePath": "$repo/src/a.js", "messages": [
    {"ruleId": "eqeqeq", "severity": 2, "message": "Expected '===' and instead saw '=='.", "line": 4, "column": 7},
    {"ruleId": "no-var", "severity": 2, "message": "Unexpected var, use let or const instead.", "line": 9, "column": 1}
  ], "errorCount": 2, "warningCount": 0},
  {"filePath": "$repo/src/b.js", "messages": [
    {"ruleId": "no-console", "severity": 1, "message": "Unexpected console statement.", "line": 2, "column": 3}
  ], "errorCount": 0, "warningCount": 1},
  {"filePath": "$repo/src/c.js", "messages": [], "errorCount": 0, "warningCount": 0}
]
EOF
printf 'src/a.js\t4\nsrc/a.js\t5\nsrc/zzz.js\t1\n' > "$d/added.tsv"

n=$(bash "$S/lint-changed.sh" "$d/eslint.json" "$d/added.tsv" "$repo" "$d/out.json")
assert_eq "1" "$n" "one message sits on an added line"
assert_file "$d/out.json" "filtered JSON written"
assert_eq "1" "$(jq 'length' "$d/out.json")" "only files with kept messages remain"
assert_eq "src/a.js" "$(jq -r '.[0].filePath' "$d/out.json")" "paths are repo-relative"
assert_eq "eqeqeq" "$(jq -r '.[0].messages[0].ruleId' "$d/out.json")" "the kept message is the one on line 4"
assert_eq "1" "$(jq '.[0].messages | length' "$d/out.json")" "line 9 (not added) is dropped"

# nothing added -> empty array, count 0
: > "$d/none.tsv"
n=$(bash "$S/lint-changed.sh" "$d/eslint.json" "$d/none.tsv" "$repo" "$d/out2.json")
assert_eq "0" "$n" "no added lines -> 0"
assert_eq "[]" "$(jq -c . "$d/out2.json")" "no added lines -> empty array"

# a deleted file in added.tsv never appears (it has no rows) and a file with messages but outside the repo root is kept relative to its own path
echo '[{"filePath": "/elsewhere/x.js", "messages": [{"ruleId": "no-var", "severity": 2, "message": "m", "line": 1, "column": 1}]}]' > "$d/outside.json"
printf '/elsewhere/x.js\t1\n' > "$d/outside.tsv"
n=$(bash "$S/lint-changed.sh" "$d/outside.json" "$d/outside.tsv" "$repo" "$d/out3.json")
assert_eq "1" "$n" "paths outside the root still match verbatim"

finish
