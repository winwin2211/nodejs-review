#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"

out=$(tmpdir)
bash "$REPO_ROOT/fixtures/make-fixtures.sh" "$out" >/dev/null

for r in dirty clean ts; do
  d="$out/$r"
  assert_file "$d/package.json" "$r has package.json"
  assert_eq "feature/NR-100-orders" "$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null)" "$r on feature branch"
  assert_exit 0 git -C "$d" rev-parse --verify main
  assert_eq "" "$(git -C "$d" status --porcelain 2>/dev/null)" "$r working tree clean"
  assert_link "$d/node_modules" "$r node_modules is a symlink to the toolbelt"
  assert_eq "$REPO_ROOT/skill/toolbelt/node_modules" "$(readlink "$d/node_modules" 2>/dev/null)" "$r node_modules target"
  grep -qE '^node_modules/?$' "$d/.gitignore" 2>/dev/null && pass || fail "$r ignores node_modules"
done

# dirty: seeded defects are where the plan says, and the suite fails
( cd "$out/dirty" && node --test >/dev/null 2>&1 ) && fail "dirty suite must fail (handler test)" || pass
grep -q 'test\.only' "$out/dirty/test/order_service.test.js" && pass || fail "dirty has test.only"
grep -qF "WHERE user_id = '\${user}'" "$out/dirty/src/repos/order_repo.js" && pass || fail "dirty has SQL concatenation"
# `user` is a reserved word in PostgreSQL (the fixtures use $1 placeholders): an
# unquoted `user` column is a real defect, and clean must have none
for n in dirty clean; do
  grep -rnE '\(id, user,|WHERE user = ' "$out/$n/src" && fail "$n: SQL uses the reserved word user as a column" || pass
done
grep -q 'eslint-disable' "$out/dirty/src/repos/order_repo.js" && pass || fail "dirty has an eslint-disable without reason"
grep -q 'repos/order_repo.js' "$out/dirty/src/handlers/order_handler.js" && pass || fail "dirty handler imports the repo directly"
grep -q 'repo.fetchUser(id)' "$out/dirty/src/handlers/order_handler.js" && pass || fail "dirty handler has the un-awaited fetchUser"
grep -q 'catch {}' "$out/dirty/src/services/order_service.js" && pass || fail "dirty service swallows an error"
assert_file "$out/dirty/src/services/legacy_order_service.js" "dirty has the duplicated legacy service"
[[ -d "$out/dirty/docs" ]] && fail "dirty has no docs" || pass
n=$(git -C "$out/dirty" diff main --numstat -- src | awk '{ s += $1 + $2 } END { print s + 0 }')
[[ "$n" -gt 50 ]] && pass || fail "dirty non-test diff exceeds 50 lines (got $n)"

# clean: suite passes, spec and plan exist
( cd "$out/clean" && node --test >/dev/null 2>&1 ) && pass || fail "clean suite passes"
assert_file "$out/clean/docs/superpowers/specs/2026-10-01-NR-100-orders-design.md" "clean spec"
assert_file "$out/clean/docs/superpowers/plans/2026-10-01-NR-100-orders-plan.md" "clean plan"
for h in 'Goal' 'Scope' 'Current' 'Design' 'Contract' 'Error' 'Data' 'Risk' 'Testing' 'Acceptance'; do
  grep -qi "^## .*$h" "$out/clean/docs/superpowers/specs/2026-09-01-NR-100-orders-design.md" 2>/dev/null \
    || grep -qi "^## .*$h" "$out/clean/docs/superpowers/specs/2026-10-01-NR-100-orders-design.md" && pass || fail "clean spec has a $h section"
done

# ts: the feature branch breaks an unchanged caller; main typechecks.
# --incremental false keeps this raw tsc run from writing a .tsbuildinfo into the fixture.
TSC="$out/ts/node_modules/.bin/tsc"
( cd "$out/ts" && "$TSC" --noEmit --incremental false -p tsconfig.json >/dev/null 2>&1 ) && fail "ts feature branch must not typecheck" || pass
grep -q '"incremental": true' "$out/ts/tsconfig.json" && pass || fail "ts tsconfig is incremental (the .tsbuildinfo trap)"
wt="$out/ts-main"; git -C "$out/ts" worktree add -q "$wt" main
( cd "$wt" && "$TSC" --noEmit --incremental false -p tsconfig.json >/dev/null 2>&1 ) && pass || fail "ts main typechecks"
git -C "$out/ts" worktree remove --force "$wt"
assert_eq "" "$(git -C "$out/ts" status --porcelain)" "ts working tree still clean after the tsc runs"

finish
