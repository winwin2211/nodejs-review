#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
S="$REPO_ROOT/skill/scripts"
d=$(tmpdir)
repo="$d/repo"; base="$d/base"; mkdir -p "$repo" "$base" "$d/o1" "$d/o2" "$d/o3"

# head: placeOrder (line 7) over four metrics, a 5-param helper (MINOR), a 31-cognitive monster (BLOCKER), a magic number
cat > "$d/head.json" <<EOF
[
  {"filePath": "$repo/src/services/order_service.js", "messages": [
    {"ruleId": "sonarjs/cognitive-complexity", "severity": 2, "message": "Refactor this function to reduce its Cognitive Complexity from 18 to the 15 allowed.", "line": 7, "column": 23},
    {"ruleId": "complexity", "severity": 2, "message": "Function 'placeOrder' has a complexity of 14. Maximum allowed is 10.", "line": 7, "column": 23},
    {"ruleId": "max-lines-per-function", "severity": 2, "message": "Function 'placeOrder' has too many lines (91). Maximum allowed is 40.", "line": 7, "column": 23},
    {"ruleId": "max-params", "severity": 2, "message": "Function 'placeOrder' has too many parameters (7). Maximum allowed is 4.", "line": 7, "column": 23},
    {"ruleId": "max-depth", "severity": 2, "message": "Blocks are nested too deeply (4). Maximum allowed is 3.", "line": 30, "column": 9},
    {"ruleId": "no-magic-numbers", "severity": 1, "message": "No magic number: 100.", "line": 52, "column": 20},
    {"ruleId": "max-params", "severity": 2, "message": "Function 'helper' has too many parameters (5). Maximum allowed is 4.", "line": 120, "column": 17}
  ]},
  {"filePath": "$repo/src/services/legacy.js", "messages": [
    {"ruleId": "sonarjs/cognitive-complexity", "severity": 2, "message": "Refactor this function to reduce its Cognitive Complexity from 31 to the 15 allowed.", "line": 3, "column": 17},
    {"ruleId": "complexity", "severity": 2, "message": "Function 'monster' has a complexity of 22. Maximum allowed is 10.", "line": 3, "column": 17}
  ]}
]
EOF
# base: placeOrder already had cognitive 18 (pre-existing); nothing else
cat > "$d/base.json" <<EOF
[
  {"filePath": "$base/src/services/order_service.js", "messages": [
    {"ruleId": "sonarjs/cognitive-complexity", "severity": 2, "message": "Refactor this function to reduce its Cognitive Complexity from 18 to the 15 allowed.", "line": 5, "column": 23},
    {"ruleId": "complexity", "severity": 2, "message": "Function 'placeOrder' has a complexity of 14. Maximum allowed is 10.", "line": 5, "column": 23}
  ]}
]
EOF
# jscpd: one 20-line clone touching added lines of order_service.js
cat > "$d/jscpd.json" <<EOF
{"duplicates": [{"format": "javascript", "lines": 20, "tokens": 160,
  "firstFile": {"name": "$repo/src/services/order_service.js", "start": 40, "end": 59, "startLoc": {"line": 40, "column": 1}, "endLoc": {"line": 59, "column": 2}},
  "secondFile": {"name": "$repo/src/services/legacy.js", "start": 12, "end": 31, "startLoc": {"line": 12, "column": 1}, "endLoc": {"line": 31, "column": 2}},
  "fragment": "..."}]}
EOF
# added lines: placeOrder's body (10-60), helper's line 120, legacy untouched
{ for i in $(seq 10 60); do printf 'src/services/order_service.js\t%s\n' "$i"; done; printf 'src/services/order_service.js\t120\n'; } > "$d/added.tsv"

summary=$(bash "$S/metrics-report.sh" "$d/head.json" "$repo" "$d/base.json" "$base" "$d/jscpd.json" "$d/added.tsv" "$d/o1")
m="$d/o1/metrics.tsv"; p="$d/o1/metrics-preexisting.tsv"
assert_file "$m" "metrics.tsv written"; assert_file "$p" "metrics-preexisting.tsv written"
col() { awk -F'\t' -v f="$1" -v metric="$2" -v fn="$3" -v c="$4" '$1 == f && $3 == metric && ($7 == fn || fn == "*") { print $c }' "$5"; }
f=src/services/order_service.js
assert_eq "" "$(col $f sonarjs/cognitive-complexity placeOrder 6 "$m")" "cognitive 18 already over at base is not a finding"
assert_eq "preexisting" "$(col $f sonarjs/cognitive-complexity placeOrder 8 "$p")" "it is listed as pre-existing"
assert_eq "" "$(col $f complexity placeOrder 6 "$m")" "complexity 14 already over at base is not a finding"
assert_eq "MAJOR" "$(col $f max-lines-per-function placeOrder 6 "$m")" "91 lines is MAJOR (>80)"
assert_eq "91" "$(col $f max-lines-per-function placeOrder 4 "$m")" "value parsed from the message"
assert_eq "40" "$(col $f max-lines-per-function placeOrder 5 "$m")" "threshold column"
assert_eq "MAJOR" "$(col $f max-params placeOrder 6 "$m")" "7 params is MAJOR (>6)"
assert_eq "MINOR" "$(col $f max-params helper 6 "$m")" "5 params is MINOR (>4, <=6)"
assert_eq "MAJOR" "$(col $f max-depth '*' 6 "$m")" "depth 4 is MAJOR"
assert_eq "MINOR" "$(col $f no-magic-numbers '*' 6 "$m")" "magic number is MINOR"
assert_eq "100" "$(col $f no-magic-numbers '*' 4 "$m")" "magic number value is the literal"
assert_eq "new" "$(col $f max-lines-per-function placeOrder 8 "$m")" "origin new when not over at base"
assert_eq "BLOCKER" "$(col src/services/legacy.js sonarjs/cognitive-complexity monster 6 "$m")" "cognitive 31 is BLOCKER (>30)"
assert_eq "monster" "$(col src/services/legacy.js sonarjs/cognitive-complexity '*' 7 "$m")" "function name borrowed from the complexity row at the same line"
assert_eq "MAJOR" "$(col $f duplication '*' 6 "$m")" "duplication is MAJOR"
assert_eq "20" "$(col $f duplication '*' 4 "$m")" "duplication value is the clone's line count"
assert_contains "$(col $f duplication '*' 7 "$m")" "legacy.js:12" "duplication names the other side"
assert_contains "$summary" "over (1 blocker," "summary counts blockers"
n_total=$(grep -c . "$m"); assert_eq "$(printf '%s' "$summary" | sed -E 's/^([0-9]+) over.*/\1/')" "$n_total" "summary total equals the row count"

# no baseline: a function-level row is `hunk` only when an added line falls in its range;
# legacy.js has no added lines, so its rows are pre-existing (unknown, not blamed on the change)
bash "$S/metrics-report.sh" "$d/head.json" "$repo" - - - "$d/added.tsv" "$d/o2" >/dev/null
assert_eq "hunk" "$(col $f max-lines-per-function placeOrder 8 "$d/o2/metrics.tsv")" "no baseline: placeOrder's range holds added lines"
assert_eq "hunk" "$(col $f sonarjs/cognitive-complexity placeOrder 8 "$d/o2/metrics.tsv")" "no baseline: cognitive row kept via the range"
assert_eq "" "$(col src/services/legacy.js sonarjs/cognitive-complexity monster 6 "$d/o2/metrics.tsv")" "no baseline: untouched legacy is not a finding"
assert_eq "preexisting" "$(col src/services/legacy.js sonarjs/cognitive-complexity monster 8 "$d/o2/metrics-preexisting.tsv")" "no baseline: untouched legacy listed as pre-existing"
assert_eq "" "$(col $f duplication '*' 6 "$d/o2/metrics.tsv")" "no jscpd report: no duplication rows"

# empty head report
echo '[]' > "$d/empty.json"
s=$(bash "$S/metrics-report.sh" "$d/empty.json" "$repo" - - - "$d/added.tsv" "$d/o3")
assert_eq "0 over (0 blocker, 0 major, 0 minor)" "$s" "empty report summary"
assert_eq "" "$(cat "$d/o3/metrics.tsv")" "empty report -> empty tsv"

finish
