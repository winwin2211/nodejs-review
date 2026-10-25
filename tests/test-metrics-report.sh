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

# with a baseline, rows without a function name are matched by their source line,
# not by file alone: an old violation must not hide a new one in the same file
mkdir -p "$repo/src" "$base/src" "$d/o4"
printf '%s\n' 'export function a(x) {' '  if (old) { return 42 }' '}' 'items.map((v) => {' '  return v' '})' > "$base/src/svc.js"
printf '%s\n' '// added' '// added' 'export function a(x) {' '  if (old) { return 42 }' '}' 'items.map((v) => {' '  return v' '})' 'export function b(y) {' '  if (fresh) { return 7 }' '}' 'other.map((w) => {' '  return w' '})' > "$repo/src/svc.js"
cat > "$d/base4.json" <<EOF
[{"filePath": "$base/src/svc.js", "messages": [
  {"ruleId": "max-depth", "severity": 2, "message": "Blocks are nested too deeply (4). Maximum allowed is 3.", "line": 2, "column": 3},
  {"ruleId": "no-magic-numbers", "severity": 1, "message": "No magic number: 42.", "line": 2, "column": 22},
  {"ruleId": "complexity", "severity": 2, "message": "Arrow function has a complexity of 12. Maximum allowed is 10.", "line": 4, "column": 11}
]}]
EOF
cat > "$d/head4.json" <<EOF
[{"filePath": "$repo/src/svc.js", "messages": [
  {"ruleId": "max-depth", "severity": 2, "message": "Blocks are nested too deeply (4). Maximum allowed is 3.", "line": 4, "column": 3},
  {"ruleId": "no-magic-numbers", "severity": 1, "message": "No magic number: 42.", "line": 4, "column": 22},
  {"ruleId": "complexity", "severity": 2, "message": "Arrow function has a complexity of 12. Maximum allowed is 10.", "line": 6, "column": 11},
  {"ruleId": "max-depth", "severity": 2, "message": "Blocks are nested too deeply (4). Maximum allowed is 3.", "line": 10, "column": 3},
  {"ruleId": "no-magic-numbers", "severity": 1, "message": "No magic number: 7.", "line": 10, "column": 24},
  {"ruleId": "complexity", "severity": 2, "message": "Arrow function has a complexity of 12. Maximum allowed is 10.", "line": 12, "column": 11}
]}]
EOF
printf 'src/svc.js\t%s\n' 1 2 9 10 11 12 13 14 > "$d/added4.tsv"
bash "$S/metrics-report.sh" "$d/head4.json" "$repo" "$d/base4.json" "$base" - "$d/added4.tsv" "$d/o4" >/dev/null
at() { awk -F'\t' -v l="$1" -v metric="$2" -v c="$3" '$1 == "src/svc.js" && $2 == l && $3 == metric { print $c }' "$4"; }
assert_eq "new" "$(at 10 max-depth 8 "$d/o4/metrics.tsv")" "baseline: a new max-depth in the same file is not hidden by an old one"
assert_eq "new" "$(at 10 no-magic-numbers 8 "$d/o4/metrics.tsv")" "baseline: a new magic number is not hidden by an old one in the same file"
assert_eq "new" "$(at 12 complexity 8 "$d/o4/metrics.tsv")" "baseline: a new anonymous function over complexity is not hidden by an old one"
assert_eq "preexisting" "$(at 4 max-depth 8 "$d/o4/metrics-preexisting.tsv")" "baseline: the old max-depth on a moved, unchanged line stays pre-existing"
assert_eq "preexisting" "$(at 4 no-magic-numbers 8 "$d/o4/metrics-preexisting.tsv")" "baseline: the old magic number stays pre-existing"
assert_eq "preexisting" "$(at 6 complexity 8 "$d/o4/metrics-preexisting.tsv")" "baseline: the old anonymous function stays pre-existing"
assert_eq "-" "$(at 10 max-depth 7 "$d/o4/metrics.tsv")" "statement-level rows have no function: -"
assert_eq "(anonymous)" "$(at 12 complexity 7 "$d/o4/metrics.tsv")" "a function-level row without a name says (anonymous)"

# no-magic-numbers: the value column is the literal as written, in every numeric form
mkdir -p "$d/o5"
cat > "$d/head5.json" <<EOF
[{"filePath": "$repo/src/lits.js", "messages": [
  {"ruleId": "no-magic-numbers", "severity": 1, "message": "No magic number: 0x56cd.", "line": 1, "column": 9},
  {"ruleId": "no-magic-numbers", "severity": 1, "message": "No magic number: 1e-3.", "line": 2, "column": 9},
  {"ruleId": "no-magic-numbers", "severity": 1, "message": "No magic number: -5.", "line": 3, "column": 9},
  {"ruleId": "no-magic-numbers", "severity": 1, "message": "No magic number: 1_000.", "line": 4, "column": 9},
  {"ruleId": "no-magic-numbers", "severity": 1, "message": "No magic number: 10n.", "line": 5, "column": 9},
  {"ruleId": "no-magic-numbers", "severity": 1, "message": "No magic number: 0.66.", "line": 6, "column": 9}
]}]
EOF
printf 'src/lits.js\t%s\n' 1 2 3 4 5 6 > "$d/added5.tsv"
bash "$S/metrics-report.sh" "$d/head5.json" "$repo" - - - "$d/added5.tsv" "$d/o5" >/dev/null
lit() { awk -F'\t' -v l="$1" '$1 == "src/lits.js" && $2 == l && $3 == "no-magic-numbers" { print $4 }' "$d/o5/metrics.tsv"; }
assert_eq "0x56cd" "$(lit 1)" "magic number: a hex literal is reported as written, not as 0"
assert_eq "1e-3" "$(lit 2)" "magic number: an exponent literal keeps its exponent"
assert_eq "-5" "$(lit 3)" "magic number: a negative literal keeps its sign"
assert_eq "1_000" "$(lit 4)" "magic number: numeric separators are kept"
assert_eq "10n" "$(lit 5)" "magic number: a BigInt literal keeps its suffix"
assert_eq "0.66" "$(lit 6)" "magic number: a decimal loses only the message's full stop"

# empty head report
echo '[]' > "$d/empty.json"
s=$(bash "$S/metrics-report.sh" "$d/empty.json" "$repo" - - - "$d/added.tsv" "$d/o3")
assert_eq "0 over (0 blocker, 0 major, 0 minor)" "$s" "empty report summary"
assert_eq "" "$(cat "$d/o3/metrics.tsv")" "empty report -> empty tsv"

finish
