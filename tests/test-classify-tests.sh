#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
S="$REPO_ROOT/skill/scripts"
REC="$REPO_ROOT/tests/recordings"
d=$(tmpdir)

# vitest and jest share the JSON shape: one FAIL (assertion), one NOT_RUNNABLE (ECONNREFUSED), one skipped
for runner in vitest jest; do
  bash "$S/classify-tests.sh" "$runner" "$REC/$runner-report.json" > "$d/$runner.txt"
  body=$(grep -v '^PASS=' "$d/$runner.txt")
  assert_eq "2" "$(printf '%s\n' "$body" | grep -c .)" "$runner: two failing tests listed"
  assert_contains "$body" $'/repo/test/calc.test.js\tsub is wrong on purpose\tFAIL' "$runner: the assertion failure is FAIL"
  assert_contains "$body" $'/repo/test/calc.test.js\tdb connects\tNOT_RUNNABLE' "$runner: ECONNREFUSED is NOT_RUNNABLE"
  assert_eq "PASS=1 FAIL=1 NOT_RUNNABLE=1 SKIP=1" "$(tail -1 "$d/$runner.txt")" "$runner: counts line"
done

# node:test TAP from the dirty fixture: one assertion failure, five passes
bash "$S/classify-tests.sh" node-test "$REC/node-test.tap" > "$d/node.txt"
assert_contains "$(cat "$d/node.txt")" $'/repo/test/order_handler.test.js\tgetOrders returns 404 for an unknown user\tFAIL' "node-test: failing subtest located by its file"
assert_eq "PASS=5 FAIL=1 NOT_RUNNABLE=0 SKIP=0" "$(tail -1 "$d/node.txt")" "node-test: counts from the TAP summary"

# TAP with an environment failure, a todo and a skip
cat > "$d/env.tap" <<'EOF'
TAP version 13
# Subtest: connects to the database
not ok 1 - connects to the database
  ---
  duration_ms: 3.1
  location: '/repo/test/db.test.js:4:1'
  failureType: 'testCodeFailure'
  error: |-
    connect ECONNREFUSED 127.0.0.1:5432
  code: 'ECONNREFUSED'
  stack: |-
    TestContext.<anonymous> (file:///repo/test/db.test.js:6:3)
  ...
# Subtest: later
ok 2 - later # TODO
  ---
  duration_ms: 0.1
  ...
# Subtest: flaky
ok 3 - flaky # SKIP
  ---
  duration_ms: 0.1
  ...
1..3
# tests 3
# suites 0
# pass 0
# fail 1
# cancelled 0
# skipped 1
# todo 1
# duration_ms 10
EOF
bash "$S/classify-tests.sh" node-test "$d/env.tap" > "$d/env.txt"
assert_contains "$(cat "$d/env.txt")" $'/repo/test/db.test.js\tconnects to the database\tNOT_RUNNABLE' "node-test: ECONNREFUSED in the error block is NOT_RUNNABLE"
assert_eq "PASS=0 FAIL=0 NOT_RUNNABLE=1 SKIP=2" "$(tail -1 "$d/env.txt")" "node-test: skipped and todo both count as SKIP"

# describe() nests subtests by indentation: each failing test is a row, a suite row
# (type 'suite', failureType 'subtestsFailed') is not, and the YAML is read at the test's indent
bash "$S/classify-tests.sh" node-test "$REC/node-test-describe.tap" > "$d/describe.txt"
body=$(grep -v '^PASS=' "$d/describe.txt")
assert_contains "$body" $'/repo/test/orders.test.mjs\tneeds the database\tNOT_RUNNABLE' "describe: an ECONNREFUSED subtest is NOT_RUNNABLE"
assert_contains "$body" $'/repo/test/orders.test.mjs\tadds totals\tFAIL' "describe: an assertion subtest is FAIL, by name"
assert_contains "$body" $'/repo/test/orders.test.mjs\tdeep fails\tFAIL' "describe: a test two levels deep is found"
assert_eq "3" "$(printf '%s\n' "$body" | grep -c .)" "describe: suites are not rows"
assert_eq "PASS=1 FAIL=2 NOT_RUNNABLE=1 SKIP=0" "$(tail -1 "$d/describe.txt")" "describe: counts"

# a failure that merely logs a connection error but ends on an assertion is FAIL
jq '.testResults[0].assertionResults[1].failureMessages = ["Error: connect ECONNREFUSED 127.0.0.1:9 (retry 1)\nAssertionError: expected 2 to be 3\n    at /repo/test/calc.test.js:9:1"]' "$REC/vitest-report.json" > "$d/mixed.json"
bash "$S/classify-tests.sh" vitest "$d/mixed.json" > "$d/mixed.txt"
assert_contains "$(cat "$d/mixed.txt")" $'sub is wrong on purpose\tFAIL' "a message ending on an assertion is FAIL despite an earlier ECONNREFUSED line"

# a test file that fails to load has no assertion results: it is still a failure,
# classified by its suite message (a bad import is FAIL, an unreachable database is not)
cat > "$d/suite.json" <<'EOF'
{ "success": false, "numFailedTestSuites": 2, "testResults": [
  { "name": "/repo/test/broken.test.js", "status": "failed", "assertionResults": [],
    "message": "Error: Cannot find module '../src/gone.js'\n    at Object.<anonymous> (/repo/test/broken.test.js:1:1)" },
  { "name": "/repo/test/db.test.js", "status": "failed", "assertionResults": [],
    "message": "Error: connect ECONNREFUSED 127.0.0.1:5432" },
  { "name": "/repo/test/ok.test.js", "status": "passed", "message": "",
    "assertionResults": [ { "fullName": "adds", "title": "adds", "status": "passed", "failureMessages": [] } ] } ] }
EOF
for runner in vitest jest; do
  bash "$S/classify-tests.sh" "$runner" "$d/suite.json" > "$d/suite-$runner.txt"
  assert_contains "$(cat "$d/suite-$runner.txt")" $'/repo/test/broken.test.js\t(suite failed to run)\tFAIL' "$runner: a test file that fails to load is FAIL"
  assert_contains "$(cat "$d/suite-$runner.txt")" $'/repo/test/db.test.js\t(suite failed to run)\tNOT_RUNNABLE' "$runner: a suite that cannot reach its database is NOT_RUNNABLE"
  assert_eq "PASS=1 FAIL=1 NOT_RUNNABLE=1 SKIP=0" "$(tail -1 "$d/suite-$runner.txt")" "$runner: suite failures are counted"
done
echo '{ "testResults": [ { "name": "/repo/test/x.test.js", "status": "failed", "message": "SyntaxError: Unexpected token" } ] }' > "$d/noassert.json"
bash "$S/classify-tests.sh" vitest "$d/noassert.json" > "$d/noassert.txt" 2>&1
assert_eq "PASS=0 FAIL=1 NOT_RUNNABLE=0 SKIP=0" "$(tail -1 "$d/noassert.txt")" "a suite with no assertionResults key is counted"
# a report without testResults is not a passing run
assert_exit 1 bash "$S/classify-tests.sh" vitest <(echo '{ "error": "boom" }')

# unknown runner
assert_exit 1 bash "$S/classify-tests.sh" mocha "$d/env.tap"

finish
