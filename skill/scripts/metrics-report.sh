#!/usr/bin/env bash
# Turn the toolbelt metrics run (and a jscpd report) into severity rows.
#
#   metrics-report.sh HEAD.json HEAD_ROOT BASE.json|- BASE_ROOT|- JSCPD.json|- ADDED.tsv OUT_DIR
#
# Writes OUT_DIR/metrics.tsv (the findings) and OUT_DIR/metrics-preexisting.tsv,
# both `file line metric value threshold severity function origin`, and prints
# "N over (K blocker, M major, L minor)" for metrics.tsv.
#
# Thresholds and severities (checklist-clean-code.md):
#   sonarjs/cognitive-complexity >15 MAJOR, >30 BLOCKER | complexity >10 MAJOR
#   max-lines-per-function >40 MINOR, >80 MAJOR | max-depth >3 MAJOR
#   max-params >4 MINOR, >6 MAJOR | max-nested-callbacks >3 MAJOR
#   no-magic-numbers MINOR (value = the literal) | duplication (jscpd) MAJOR, value = lines;
#   a clone between two test files counts only above 30 lines
# The function column is the name in the message (or of a named row on the same
# line), `(anonymous)` for a nameless function, `-` for a statement-level rule.
# Origin: with a baseline, `new` unless the same metric was already over at the
# merge-base for the same named function or, for statement-level rows and
# anonymous functions, on a line with the same source text (lines move between
# the trees; the text does not) — then `preexisting`. Without one, a function-level
# row is `hunk` when an added line falls between its line and the next flagged
# function in the file; a statement-level row when its own line was added;
# everything else is `preexisting`. A clone is kept when either side overlaps
# an added line.
set -euo pipefail
HEAD_J=${1:?usage: metrics-report.sh HEAD.json HEAD_ROOT BASE.json|- BASE_ROOT|- JSCPD.json|- ADDED.tsv OUT_DIR}
HEAD_ROOT=${2:?}; BASE_J=${3:?}; BASE_ROOT=${4:?}; JSCPD_J=${5:?}; ADDED=${6:?}; OUT_DIR=${7:?}
command -v jq >/dev/null || { echo "metrics-report.sh: jq not found" >&2; exit 1; }
mkdir -p "$OUT_DIR"
HEAD_ROOT=$(cd "$HEAD_ROOT" && pwd -P)
[[ "$BASE_ROOT" != "-" ]] && BASE_ROOT=$(cd "$BASE_ROOT" && pwd -P)

flatten() { # JSON ROOT -> file<TAB>line<TAB>rule<TAB>message
  jq -r --arg root "$2/" '
    .[] | .filePath as $abs
    | (if ($abs | startswith($root)) then ($abs | ltrimstr($root)) else $abs end) as $rel
    | .messages[] | select(.ruleId != null)
    | [$rel, (.line | tostring), .ruleId, .message] | @tsv' "$1"
}
flatten "$HEAD_J" "$HEAD_ROOT" > "$OUT_DIR/.head.tsv"
HAS_BASE=0
if [[ "$BASE_J" != "-" && -f "$BASE_J" ]]; then flatten "$BASE_J" "$BASE_ROOT" > "$OUT_DIR/.base.tsv"; HAS_BASE=1; else : > "$OUT_DIR/.base.tsv"; fi
if [[ "$JSCPD_J" != "-" && -f "$JSCPD_J" ]]; then
  jq -r --arg root "$HEAD_ROOT/" '
    def rel: if startswith($root) then ltrimstr($root) else . end;
    .duplicates[]? | [ (.firstFile.name | rel), .firstFile.start, .firstFile.end, .lines, (.secondFile.name | rel), .secondFile.start, .secondFile.end ] | @tsv' "$JSCPD_J" > "$OUT_DIR/.dups.tsv"
else : > "$OUT_DIR/.dups.tsv"; fi

awk -F'\t' -v OFS='\t' -v hasbase="$HAS_BASE" -v headroot="$HEAD_ROOT" -v baseroot="$BASE_ROOT" -v addedf="$ADDED" -v basef="$OUT_DIR/.base.tsv" -v dupsf="$OUT_DIR/.dups.tsv" -v headf="$OUT_DIR/.head.tsv" \
    -v outm="$OUT_DIR/metrics.tsv" -v outp="$OUT_DIR/metrics-preexisting.tsv" '
  function digits(s) { gsub(/[^-0-9.]/, "", s); return s }
  # "Function 'x'", "Async function 'x'", "Method 'x'", "Arrow function 'x'": the first quoted name
  function fname(msg) { if (match(msg, /'"'"'[^'"'"']+'"'"'/)) return substr(msg, RSTART + 1, RLENGTH - 2); return "" }
  function value(rule, msg,   s) {
    if (rule == "sonarjs/cognitive-complexity") { if (match(msg, /from [0-9]+ to/)) return digits(substr(msg, RSTART, RLENGTH)) }
    else if (rule == "complexity") { if (match(msg, /complexity of [0-9]+/)) return digits(substr(msg, RSTART, RLENGTH)) }
    # the literal as written (0x56cd, 1e-3, 1_000, 10n), minus the trailing full stop
    else if (rule == "no-magic-numbers") { if (match(msg, /: -?[0-9][0-9A-Za-z_.+-]*$/)) { s = substr(msg, RSTART + 2); sub(/\.$/, "", s); return s } }
    else if (match(msg, /\([0-9]+\)/)) return digits(substr(msg, RSTART, RLENGTH))
    return "?"
  }
  function threshold(rule) {
    if (rule == "sonarjs/cognitive-complexity") return 15; if (rule == "complexity") return 10
    if (rule == "max-lines-per-function") return 40; if (rule == "max-depth") return 3
    if (rule == "max-params") return 4; if (rule == "max-nested-callbacks") return 3
    if (rule == "duplication") return 10; return 0
  }
  function severity(rule, v) {
    if (rule == "sonarjs/cognitive-complexity") return (v + 0 > 30) ? "BLOCKER" : "MAJOR"
    if (rule == "complexity" || rule == "max-depth" || rule == "max-nested-callbacks" || rule == "duplication") return "MAJOR"
    if (rule == "max-lines-per-function") return (v + 0 > 80) ? "MAJOR" : "MINOR"
    if (rule == "max-params") return (v + 0 > 6) ? "MAJOR" : "MINOR"
    return "MINOR"
  }
  function is_function_level(rule) { return (rule == "sonarjs/cognitive-complexity" || rule == "complexity" || rule == "max-lines-per-function" || rule == "max-params") }
  function dispname(msg, file, line, rule, names,   nm) {
    nm = fname(msg)
    if (nm == "" && names == "base" && ((file SUBSEP line) in bname)) nm = bname[file, line]
    if (nm == "" && names == "head" && ((file SUBSEP line) in hname)) nm = hname[file, line]
    if (nm == "") nm = is_function_level(rule) ? "(anonymous)" : "-"
    return nm
  }
  function srctext(root, file, n,   path, l, k) {
    path = root "/" file
    if (!(path in loaded)) { loaded[path] = 1; k = 0; while ((getline l < path) > 0) srcl[path, ++k] = l; close(path) }
    l = ((path SUBSEP n) in srcl) ? srcl[path, n] : ""
    gsub(/^[ \t]+|[ \t]+$/, "", l)
    return l
  }
  # identity across the two trees: a named function by name, anything else by its line text
  function ident(root, file, line, rule, nm,   t) {
    if (is_function_level(rule) && nm != "(anonymous)") return file SUBSEP rule SUBSEP "fn:" nm
    t = srctext(root, file, line); if (t == "") t = "line:" line
    return file SUBSEP rule SUBSEP "src:" t
  }
  # the test-path rule of collect.sh
  function is_test(p) { return (p ~ /\.(test|spec|stories)\./ || p ~ /(^|\/)(__tests__|__mocks__|test|tests)\//) }
  function range_has_added(file, s, e,   l) { for (l = s; l <= e; l++) if ((file SUBSEP l) in added) return 1; return 0 }
  function next_start(file, line,   k, best, parts, n, i) {
    best = 0; n = split(fstarts[file], parts, " ")
    for (i = 1; i <= n; i++) { k = parts[i] + 0; if (k > line && (best == 0 || k < best)) best = k }
    return best ? best - 1 : 1000000
  }
  FILENAME == addedf { added[$1, $2] = 1; next }
  FILENAME == basef  { nb++; bf[nb] = $1; bl[nb] = $2; br[nb] = $3; bm[nb] = $4; if (fname($4) != "") bname[$1, $2] = fname($4); next }
  FILENAME == dupsf  { nd++; d1[nd] = $1; d1s[nd] = $2; d1e[nd] = $3; dl[nd] = $4; d2[nd] = $5; d2s[nd] = $6; d2e[nd] = $7; next }
  FILENAME == headf  {
    nh++; hf[nh] = $1; hl[nh] = $2; hr[nh] = $3; hm[nh] = $4
    if (fname($4) != "") hname[$1, $2] = fname($4)
    if (is_function_level($3) && !(($1 SUBSEP $2) in seenstart)) { seenstart[$1, $2] = 1; fstarts[$1] = fstarts[$1] " " $2 }
    next
  }
  END {
    for (i = 1; i <= nb; i++) { nm = dispname(bm[i], bf[i], bl[i], br[i], "base"); basekey[ident(baseroot, bf[i], bl[i] + 0, br[i], nm)] = 1 }
    for (i = 1; i <= nh; i++) {
      file = hf[i]; line = hl[i] + 0; rule = hr[i]; msg = hm[i]
      nm = dispname(msg, file, line, rule, "head")
      v = value(rule, msg); sev = severity(rule, v); thr = threshold(rule)
      if (hasbase == 1) origin = (ident(headroot, file, line, rule, nm) in basekey) ? "preexisting" : "new"
      else if (is_function_level(rule)) origin = range_has_added(file, line, next_start(file, line)) ? "hunk" : "preexisting"
      else origin = ((file SUBSEP line) in added) ? "hunk" : "preexisting"
      row = file OFS line OFS rule OFS v OFS thr OFS sev OFS nm OFS origin
      if (origin == "preexisting") print row > outp; else { print row > outm; cnt[sev]++; total++ }
    }
    for (i = 1; i <= nd; i++) {
      # between two test files only a clone above 30 lines counts (shared fixtures are normal)
      both_tests = (is_test(d1[i]) && is_test(d2[i]))
      if (both_tests && dl[i] + 0 <= 30) continue
      thr = both_tests ? 30 : threshold("duplication")
      if (range_has_added(d1[i], d1s[i] + 0, d1e[i] + 0)) { f = d1[i]; s = d1s[i]; o = d2[i] ":" d2s[i] }
      else if (range_has_added(d2[i], d2s[i] + 0, d2e[i] + 0)) { f = d2[i]; s = d2s[i]; o = d1[i] ":" d1s[i] }
      else continue
      print f, s, "duplication", dl[i], thr, "MAJOR", "<-> " o, "hunk" > outm; cnt["MAJOR"]++; total++
    }
    printf "%d over (%d blocker, %d major, %d minor)\n", total + 0, cnt["BLOCKER"] + 0, cnt["MAJOR"] + 0, cnt["MINOR"] + 0
    close(outm); close(outp)
  }
' "$ADDED" "$OUT_DIR/.base.tsv" "$OUT_DIR/.dups.tsv" "$OUT_DIR/.head.tsv"
touch "$OUT_DIR/metrics.tsv" "$OUT_DIR/metrics-preexisting.tsv"
rm -f "$OUT_DIR/.head.tsv" "$OUT_DIR/.base.tsv" "$OUT_DIR/.dups.tsv"
