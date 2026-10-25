#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
S="$REPO_ROOT/skill/scripts"
REC="$REPO_ROOT/tests/recordings"
d=$(tmpdir)
repo="$d/repo"; mkdir -p "$repo/src"

cat > "$d/lcov.info" <<EOF
TN:
SF:$repo/src/a.js
FN:3,placeOrder
FN:20,other
FNF:2
FNH:1
FNDA:0,placeOrder
FNDA:1,other
DA:3,0
DA:4,0
DA:5,0
DA:6,0
DA:20,1
DA:21,1
LF:6
LH:2
end_of_record
EOF
# added: 4,5,6 (unexecuted, inside placeOrder) and 21 (executed, inside other); 7 has no DA (not executable)
printf 'src/a.js\t4\nsrc/a.js\t5\nsrc/a.js\t6\nsrc/a.js\t7\nsrc/a.js\t21\n' > "$d/added.tsv"

bash "$S/coverage-changed.sh" "$d/lcov.info" "$d/added.tsv" "$repo" > "$d/out.txt"
assert_eq $'src/a.js\t1\t4\t4-6\tplaceOrder:3-19' "$(grep -v '^TOTAL=' "$d/out.txt")" "covered/total, uncovered range, uncovered function with its range"
assert_eq "TOTAL=1/4" "$(tail -1 "$d/out.txt")" "total line"

# relative SF path (Jest, Vitest, node:test all emit relative paths) resolves the same
sed "s#SF:$repo/#SF:#" "$d/lcov.info" > "$d/lcov-rel.info"
bash "$S/coverage-changed.sh" "$d/lcov-rel.info" "$d/added.tsv" "$repo" > "$d/out-rel.txt"
assert_eq "$(cat "$d/out.txt")" "$(cat "$d/out-rel.txt")" "relative SF paths give the same result"

# a package subdirectory: lcov paths relative to the package, added lines repo-relative
mkdir -p "$repo/packages/api/src"
sed "s#SF:$repo/src/a.js#SF:src/a.js#" "$d/lcov.info" > "$d/lcov-pkg.info"
printf 'packages/api/src/a.js\t4\npackages/api/src/a.js\t21\n' > "$d/added-pkg.tsv"
bash "$S/coverage-changed.sh" "$d/lcov-pkg.info" "$d/added-pkg.tsv" "$repo" packages/api > "$d/out-pkg.txt"
assert_contains "$(cat "$d/out-pkg.txt")" $'packages/api/src/a.js\t1\t2\t4\tplaceOrder:3-19' "PKG_DIR prefixes package-relative SF paths"

# a changed file with no lcov record is reported, not dropped
printf 'src/a.js\t4\nsrc/untested.js\t1\nsrc/untested.js\t2\n' > "$d/added2.tsv"
bash "$S/coverage-changed.sh" "$d/lcov.info" "$d/added2.tsv" "$repo" > "$d/out2.txt"
assert_contains "$(cat "$d/out2.txt")" $'src/untested.js\t0\t0\t\tNO_RECORD' "file without a coverage record is listed as NO_RECORD"
assert_eq "TOTAL=0/1" "$(tail -1 "$d/out2.txt")" "NO_RECORD files add nothing to the total"

# a diff with no added lines (deleted files only)
: > "$d/none.tsv"
assert_eq "TOTAL=0/0" "$(bash "$S/coverage-changed.sh" "$d/lcov.info" "$d/none.tsv" "$repo")" "nothing added -> TOTAL=0/0 only"

# the real recordings: calc.js has lines 2,5,8,11 executable, 8 (mul) unexecuted
printf 'src/calc.js\t7\nsrc/calc.js\t8\nsrc/calc.js\t9\n' > "$d/added-calc.tsv"
for rec in vitest jest; do
  bash "$S/coverage-changed.sh" "$REC/$rec-lcov.info" "$d/added-calc.tsv" "$repo" > "$d/$rec.txt"
  assert_contains "$(cat "$d/$rec.txt")" $'src/calc.js\t0\t1\t8\tmul:7-9' "$rec recording: the untested mul body is uncovered"
done

finish
