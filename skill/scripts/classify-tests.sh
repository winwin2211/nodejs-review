#!/usr/bin/env bash
# Classify failing tests from a runner report.
#
#   classify-tests.sh vitest|jest REPORT.json
#   classify-tests.sh node-test REPORT.tap
#
# Prints one row per failing test, `file<TAB>name<TAB>FAIL|NOT_RUNNABLE`, then
# a last line `PASS=n FAIL=n NOT_RUNNABLE=n SKIP=n`. A failure is NOT_RUNNABLE
# only when its message *ends* on an environment error (connection refused,
# unknown host, missing env); a test that logged such an error and then failed
# an assertion is FAIL. Stack lines (`    at ...`) never decide.
set -euo pipefail
RUNNER=${1:?usage: classify-tests.sh vitest|jest|node-test REPORT}
REPORT=${2:?usage: classify-tests.sh vitest|jest|node-test REPORT}
NODE_NOT_RUNNABLE_RE='ECONNREFUSED|ENOTFOUND|EAI_AGAIN|ETIMEDOUT|ECONNRESET|EHOSTUNREACH|ENETUNREACH|getaddrinfo|MongoNetworkError|MongoServerSelectionError|[Ee]nvironment variable .* (is )?(not set|missing|undefined|required)|Missing (required )?env|\.env.*ENOENT'

classify() { # failure text on stdin -> FAIL | NOT_RUNNABLE
  local last
  last=$(grep -vE '^[[:space:]]*at |^[[:space:]]*$' | tail -1 || true)
  if printf '%s' "$last" | grep -qE "$NODE_NOT_RUNNABLE_RE"; then echo NOT_RUNNABLE; else echo FAIL; fi
}

case "$RUNNER" in
  vitest|jest)
    # a report without a testResults array is no evidence of a passing run
    jq -e '.testResults | type == "array"' "$REPORT" >/dev/null 2>&1 || { echo "classify-tests.sh: no testResults array in $REPORT" >&2; exit 1; }
    pass=0; fail=0; nr=0; skip=0
    while IFS=$'\t' read -r file title status msg; do
      case "$status" in
        passed) pass=$((pass + 1)) ;;
        skipped|pending|todo|disabled) skip=$((skip + 1)) ;;
        failed)
          c=$(printf '%b' "$msg" | classify)
          if [[ $c == FAIL ]]; then fail=$((fail + 1)); else nr=$((nr + 1)); fi
          printf '%s\t%s\t%s\n' "$file" "$title" "$c"
          ;;
      esac
    # a file that failed to load (bad import, syntax error, a failing hook) has
    # no failed assertion: its suite message stands for it as one row
    done < <(jq -r '.testResults[] | .name as $f
      | ((.assertionResults // [])[] | [$f, (.fullName // .title), .status, ((.failureMessages // []) | join("\n"))]),
        (select(.status == "failed" and ([(.assertionResults // [])[] | select(.status == "failed")] | length) == 0)
          | [$f, "(suite failed to run)", "failed", (.message // .failureMessage // "")])
      | @tsv' "$REPORT")
    echo "PASS=$pass FAIL=$fail NOT_RUNNABLE=$nr SKIP=$skip"
    ;;
  node-test)
    awk -v re="$NODE_NOT_RUNNABLE_RE" '
      function strip_quotes(s) { sub(/^'"'"'/, "", s); sub(/'"'"'$/, "", s); return s }
      function flush(   n, lines, last, i, cls) {
        if (!inblock) return
        last = ""
        n = split(err, lines, "\n")
        for (i = 1; i <= n; i++) if (lines[i] ~ /[^[:space:]]/ && lines[i] !~ /^[[:space:]]*at /) last = lines[i]
        if (last == "") last = code
        cls = (last ~ re || code ~ re) ? "NOT_RUNNABLE" : "FAIL"
        if (cls == "FAIL") failn++; else nrn++
        print (loc == "" ? "?" : loc) "\t" name "\t" cls
        inblock = 0
      }
      /^not ok [0-9]+ - / { flush(); inblock = 1; name = $0; sub(/^not ok [0-9]+ - /, "", name); sub(/ # (SKIP|TODO).*$/, "", name); loc = ""; err = ""; code = ""; inerr = 0; next }
      /^ok [0-9]+ - / { flush(); next }
      inblock && /^  location: / { loc = $0; sub(/^  location: /, "", loc); loc = strip_quotes(loc); sub(/:[0-9]+:[0-9]+$/, "", loc); next }
      inblock && /^  error: \|-?$/ { inerr = 1; err = ""; next }
      inblock && /^  error: / { inerr = 0; err = $0; sub(/^  error: /, "", err); err = strip_quotes(err); next }
      inblock && inerr && /^    / { l = $0; sub(/^    /, "", l); err = err (err == "" ? "" : "\n") l; next }
      inblock && /^  code: / { inerr = 0; code = $0; sub(/^  code: /, "", code); code = strip_quotes(code); next }
      inblock && /^  [A-Za-z_]+: / { inerr = 0; next }
      inblock && /^  \.\.\.$/ { flush(); next }
      /^# pass [0-9]+/ { pass = $3 + 0 }
      /^# fail [0-9]+/ { failt = $3 + 0 }
      /^# skipped [0-9]+/ { skipc = $3 + 0 }
      /^# todo [0-9]+/ { todoc = $3 + 0 }
      END {
        flush()
        if (failt > failn + nrn) failn += failt - failn - nrn
        print "PASS=" pass + 0 " FAIL=" failn + 0 " NOT_RUNNABLE=" nrn + 0 " SKIP=" skipc + todoc + 0
      }
    ' "$REPORT"
    ;;
  *) echo "classify-tests.sh: unsupported runner: $RUNNER" >&2; exit 1 ;;
esac
