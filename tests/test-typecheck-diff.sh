#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
S="$REPO_ROOT/skill/scripts"
d=$(tmpdir)

cat > "$d/head.txt" <<'EOF'
src/b.ts(3,32): error TS2554: Expected 2 arguments, but got 1.
src/c.ts(10,5): error TS2322: Type 'string' is not assignable to type 'number'.
Found 2 errors in 2 files.
EOF
# the same c.ts error exists at base, two lines further down; b.ts is new
cat > "$d/base.txt" <<'EOF'
src/c.ts(12,5): error TS2322: Type 'string' is not assignable to type 'number'.
Found 1 error in 1 file.
EOF

r=$(bash "$S/typecheck-diff.sh" "$d/head.txt" "$d/base.txt")
assert_eq "src/b.ts(3,32): error TS2554: Expected 2 arguments, but got 1." "$r" "only the error absent at base is new; line numbers do not matter"

r=$(bash "$S/typecheck-diff.sh" "$d/head.txt" -)
assert_eq "2" "$(printf '%s\n' "$r" | grep -c 'error TS')" "without a baseline every head error is new"
assert_not_contains "$r" "Found 2 errors" "summary lines are never errors"

: > "$d/empty.txt"
assert_eq "" "$(bash "$S/typecheck-diff.sh" "$d/empty.txt" "$d/base.txt")" "a clean head yields nothing"

# the same error text twice in one file, once at base: one of the two is new
printf '%s\n' "src/a.ts(3,5): error TS2554: Expected 2 arguments, but got 1." > "$d/base-dup.txt"
printf '%s\n' "src/a.ts(3,5): error TS2554: Expected 2 arguments, but got 1." "src/a.ts(9,5): error TS2554: Expected 2 arguments, but got 1." > "$d/head-dup.txt"
r=$(bash "$S/typecheck-diff.sh" "$d/head-dup.txt" "$d/base-dup.txt")
assert_eq "1" "$(printf '%s' "$r" | grep -c 'error TS2554')" "a second occurrence of an error the base had once is new"

finish
