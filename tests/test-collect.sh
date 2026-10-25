#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
S="$REPO_ROOT/skill/scripts"
fx=$(tmpdir); bash "$REPO_ROOT/fixtures/make-fixtures.sh" "$fx" >/dev/null
out=$(tmpdir)
val() { sed -n "s/^$2=//p" "$1"; }

# --- dirty, ref mode, no tools ---
bash "$S/collect.sh" --repo "$fx/dirty" --base main --head feature/NR-100-orders --out "$out/d" --no-tools
assert_file "$out/d/meta.env" "meta written"
assert_eq "ref" "$(val "$out/d/meta.env" MODE)" "ref mode"
assert_eq "." "$(val "$out/d/meta.env" PKG_DIR)" "single package dir"
assert_eq "dirty" "$(val "$out/d/meta.env" PKG_NAME)" "package name from package.json"
assert_eq "main" "$(val "$out/d/meta.env" BASE)" "base recorded"
assert_file "$out/d/stack.env" "stack.env produced by collect"
assert_eq "node-test" "$(val "$out/d/stack.env" RUNNER)" "stack detected inside collect"
src=$(cat "$out/d/changed-src-files.txt"); tst=$(cat "$out/d/changed-test-files.txt")
assert_contains "$src" "src/services/order_service.js" "changed source file listed"
assert_contains "$src" "src/services/legacy_order_service.js" "new source file listed"
assert_not_contains "$src" "test/order_service.test.js" "test file not in source list"
assert_contains "$tst" "test/order_service.test.js" "test file in test list"
assert_contains "$tst" "test/order_handler.test.js" "second test file in test list"
assert_contains "$(cat "$out/d/changed-symbols.txt")" "placeOrder" "changed symbol listed"
assert_contains "$(cat "$out/d/changed-symbols.txt")" "legacyDiscount" "new exported function listed"
[[ "$(cat "$out/d/nontest-lines.txt")" -gt 50 ]] && pass || fail "nontest-lines > 50 (got $(cat "$out/d/nontest-lines.txt"))"
sqlline=$(grep -nF "WHERE user_id = '\${user}'" "$fx/dirty/src/repos/order_repo.js" | cut -d: -f1)
assert_contains "$(cat "$out/d/added-lines.tsv")" $'src/repos/order_repo.js\t'"$sqlline" "added-lines has the SQL concat line"
assert_not_contains "$(cat "$out/d/added-lines.tsv")" $'test/order_service.test.js\t0' "added-lines never emits line 0"
pk=$(cat "$out/d/changed-packages.txt")
assert_contains "$pk" "services" "changed-packages has the services dir"
assert_contains "$pk" "repos" "changed-packages has the repos dir"
assert_eq "" "$(grep -x '\.' "$out/d/changed-packages.txt" || true)" "changed-packages never contains a bare dot"
for t in typecheck lint metrics test coverage audit; do
  assert_contains "$(cat "$out/d/tools/summary.txt")" "$t"$'\tUNAVAILABLE(skipped)' "--no-tools row for $t"
done
assert_file "$out/d/status-before.txt" "baseline status"
assert_file "$out/d/status-ignored-before.txt" "baseline ignored status"
assert_file "$out/d/stash-before.txt" "baseline stash"
assert_file "$out/d/mtime-marker" "mtime marker"
assert_eq "" "$(git -C "$fx/dirty" status --porcelain)" "dirty repo untouched"
r=$(ASSERT_CLEAN_PRUNE=node_modules bash "$S/assert-clean.sh" --repo "$fx/dirty" --out "$out/d"); assert_eq "No artifacts left: verified" "$r" "collect leaves no artifacts (node_modules pruned)"

# --- clean, worktree mode with an uncommitted change and an untracked file ---
echo '// touched' >> "$fx/clean/src/handlers/order_handler.js"
echo 'export const extra = 1;' > "$fx/clean/src/extra.js"
bash "$S/collect.sh" --repo "$fx/clean" --base main --head WORKTREE --out "$out/c" --no-tools
assert_eq "worktree" "$(val "$out/c/meta.env" MODE)" "worktree mode"
assert_contains "$(cat "$out/c/changed-src-files.txt")" "src/handlers/order_handler.js" "uncommitted change included"
assert_contains "$(cat "$out/c/changed-src-files.txt")" "src/extra.js" "untracked file included"
assert_contains "$(cat "$out/c/added-lines.tsv")" $'src/extra.js\t1' "untracked file's line is an added line"
rm "$fx/clean/src/extra.js"; git -C "$fx/clean" checkout -q -- src/handlers/order_handler.js

# --- rename + delete: new path only, no rows for the deleted file ---
rd=$(tmpdir)
git -C "$rd" init -q -b main
git -C "$rd" config user.email fixture@example.com; git -C "$rd" config user.name fixture
echo '{"name":"rd","type":"module"}' > "$rd/package.json"
printf 'export const a = 1;\nexport const aa = 2;\nexport const aaa = 3;\n' > "$rd/a.js"
printf 'export const c = 1;\n' > "$rd/c.js"
mkdir -p "$rd/__tests__"; printf 'export const t = 1;\n' > "$rd/__tests__/a.test.js"
git -C "$rd" add -A && git -C "$rd" commit -q -m base
git -C "$rd" checkout -q -b feature/x
git -C "$rd" mv a.js b.js && git -C "$rd" rm -q c.js
printf 'export const t = 1;\nexport const t2 = 2;\n' > "$rd/__tests__/a.test.js"
git -C "$rd" add -A && git -C "$rd" commit -q -m "rename and delete"
bash "$S/collect.sh" --repo "$rd" --base main --head feature/x --out "$out/rd" --no-tools
assert_eq "b.js" "$(cat "$out/rd/changed-src-files.txt")" "renamed file listed under its new name only"
assert_not_contains "$(cat "$out/rd/added-lines.tsv")" "c.js" "deleted file has no added lines"
assert_contains "$(cat "$out/rd/changed-test-files.txt")" "__tests__/a.test.js" "__tests__ directory counts as tests"
assert_eq "1" "$(cat "$out/rd/nontest-lines.txt")" "a pure rename adds nothing; the deleted file's one removed line counts"

# --- refuses to write inside the repo ---
assert_exit 1 bash "$S/collect.sh" --repo "$fx/dirty" --base main --head WORKTREE --out "$fx/dirty/.review" --no-tools
[[ -e "$fx/dirty/.review" ]] && fail "refused --out must create nothing" || pass

# --- baselines exist even when --base is bad; the run fails ---
bad=$(tmpdir)
rc=0; bash "$S/collect.sh" --repo "$fx/dirty" --base no-such-branch-xyz --head WORKTREE --out "$bad" --no-tools >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] && pass || fail "a bad --base must fail the run"
assert_file "$bad/status-before.txt" "baseline written before merge-base can fail"
assert_file "$bad/mtime-marker" "mtime marker written before merge-base can fail"

# --- Task 7: tool resolution, scrubbed environment, budgets, slugs (via --fn dispatch) ---
ws=$(tmpdir)
mkdir -p "$ws/node_modules/.bin" "$ws/packages/api/src" "$ws/packages/web/node_modules/.bin"
echo '{"name":"ws","workspaces":["packages/*"]}' > "$ws/package.json"
printf '#!/bin/sh\necho root-eslint\n' > "$ws/node_modules/.bin/eslint"; chmod +x "$ws/node_modules/.bin/eslint"
printf '#!/bin/sh\necho web-eslint\n' > "$ws/packages/web/node_modules/.bin/eslint"; chmod +x "$ws/packages/web/node_modules/.bin/eslint"
assert_eq "$ws/node_modules/.bin/eslint" "$(bash "$S/collect.sh" --repo "$ws" --fn find_bin eslint packages/api)" "find_bin walks up to the workspace root"
assert_eq "$ws/packages/web/node_modules/.bin/eslint" "$(bash "$S/collect.sh" --repo "$ws" --fn find_bin eslint packages/web)" "find_bin prefers the package's own binary"
assert_eq "" "$(bash "$S/collect.sh" --repo "$ws" --fn find_bin tsc packages/api)" "find_bin prints nothing when the binary is absent"
assert_eq "|true|test" "$(SECRET_URL=x bash "$S/collect.sh" --fn scrubbed_run sh -c 'echo "$SECRET_URL|$CI|$NODE_ENV"')" "scrubbed_run drops the caller's variables and sets CI/NODE_ENV"
assert_eq "20000" "$(NODEJS_REVIEW_TIMEOUT_TEST=30 bash "$S/collect.sh" --fn runner_timeout_ms)" "runner timeout is the test budget minus 10s, in ms"
assert_eq "590000" "$(bash "$S/collect.sh" --fn runner_timeout_ms)" "default runner timeout from the 600s budget"
assert_eq "1000" "$(NODEJS_REVIEW_TIMEOUT_TEST=5 bash "$S/collect.sh" --fn runner_timeout_ms)" "runner timeout floors at 1000ms"
assert_eq "packages__api" "$(bash "$S/collect.sh" --fn pkg_slug packages/api)" "pkg_slug replaces slashes"
assert_eq "root" "$(bash "$S/collect.sh" --fn pkg_slug .)" "pkg_slug of the root package is root"

# --- Task 8: typecheck with a merge-base baseline, no .tsbuildinfo left behind ---
bash "$S/collect.sh" --repo "$fx/ts" --base main --head feature/NR-100-orders --out "$out/ts"
assert_contains "$(cat "$out/ts/tools/summary.txt")" $'typecheck\tFAIL\t1 new, 0 pre-existing' "ts: the broken caller is one new error"
assert_contains "$(cat "$out/ts/tools/typecheck-new.txt")" "src/b.ts" "ts: the new error names the unchanged caller"
assert_file "$out/ts/tools/typecheck-base.txt" "ts: baseline typecheck ran"
assert_eq "1" "$(git -C "$fx/ts" worktree list | wc -l | tr -d ' ')" "ts: the baseline worktree was removed"
r=$(ASSERT_CLEAN_PRUNE=node_modules bash "$S/assert-clean.sh" --repo "$fx/ts" --out "$out/ts" 2>&1 || true)
assert_eq "No artifacts left: verified" "$r" "ts: incremental tsc left no .tsbuildinfo in the repo"
assert_contains "$(cat "$out/d/tools/summary.txt" 2>/dev/null; bash "$S/collect.sh" --repo "$fx/dirty" --base main --head feature/NR-100-orders --out "$out/d2" >/dev/null; cat "$out/d2/tools/summary.txt")" $'typecheck\tUNAVAILABLE(not-typescript)' "dirty: no TypeScript, no typecheck"

# one changed package that is not the root: typecheck-new.txt is repo-relative like every other output
sp=$(tmpdir); git -C "$sp" init -q -b main
echo '{ "name": "sp", "workspaces": ["packages/*"], "devDependencies": { "typescript": "5" } }' > "$sp/package.json"
: > "$sp/package-lock.json"; printf 'node_modules\n' > "$sp/.gitignore"; mkdir -p "$sp/node_modules/.bin" "$sp/packages/api/src"
printf '#!/bin/sh\ncase " $* " in *" --showConfig "*) echo "{\\"compilerOptions\\":{}}"; exit 0 ;; esac\ncase "$PWD" in */base/*) exit 0 ;; esac\necho "src/x.ts(1,14): error TS2322: canned"\nexit 2\n' > "$sp/node_modules/.bin/tsc"
chmod +x "$sp/node_modules/.bin/tsc"
echo '{ "name": "api" }' > "$sp/packages/api/package.json"; echo '{}' > "$sp/packages/api/tsconfig.json"
printf 'export const x: number = 1;\n' > "$sp/packages/api/src/x.ts"
git -C "$sp" -c user.email=f@e -c user.name=f add -A; git -C "$sp" -c user.email=f@e -c user.name=f commit -q -m base
printf 'export const x: number = 2;\n' > "$sp/packages/api/src/x.ts"
bash "$S/collect.sh" --repo "$sp" --base main --head WORKTREE --out "$out/sp" >/dev/null 2>&1
assert_contains "$(cat "$out/sp/tools/summary.txt")" $'typecheck\tFAIL\t1 new' "single package: the head-only error is new"
assert_eq "packages/api/src/x.ts(1,14): error TS2322: canned" "$(cat "$out/sp/tools/typecheck-new.txt")" "single non-root package: typecheck-new.txt is repo-relative"

# a lockfile change does not cost metrics their baseline: the toolbelt reads only source
lk=$(tmpdir); git -C "$lk" init -q -b main; mkdir -p "$lk/src"
echo '{ "name": "lk", "type": "module" }' > "$lk/package.json"
echo '{ "lockfileVersion": 3, "packages": { "": {}, "node_modules/lodash": { "version": "4.17.20" } } }' > "$lk/package-lock.json"
cat > "$lk/src/legacy.js" <<'EOF'
export function legacyDeep(a, b, c) {
  let n = 0;
  for (const x of a) {
    if (x > 1) {
      for (const y of b) {
        if (y > x) {
          if (c) { n += 1; } else if (y) { n += 2; } else { n += 3; }
        } else if (y < x) {
          while (n < 3) { n++; if (n === 2) break; }
        }
      }
    } else if ((x < 0 && b.length) || c) {
      n--;
    }
  }
  return n;
}

export function small() {
  return 1;
}
EOF
git -C "$lk" -c user.email=f@e -c user.name=f add -A; git -C "$lk" -c user.email=f@e -c user.name=f commit -q -m base
echo '{ "lockfileVersion": 3, "packages": { "": {}, "node_modules/lodash": { "version": "4.17.21" } } }' > "$lk/package-lock.json"
sed -i '' 's/  return 1;/  return 0;/' "$lk/src/legacy.js"
bash "$S/collect.sh" --repo "$lk" --base main --head WORKTREE --out "$out/lk" >/dev/null 2>&1
assert_not_contains "$(grep $'^metrics\t' "$out/lk/tools/summary.txt")" "no-baseline" "lockfile change: metrics keep their baseline"
assert_eq "" "$(grep 'sonarjs/cognitive-complexity' "$out/lk/tools/metrics.tsv")" "lockfile change: the untouched legacy function is not blamed on the edit below it"
assert_contains "$(cat "$out/lk/tools/metrics-preexisting.tsv")" "sonarjs/cognitive-complexity" "lockfile change: the legacy function is pre-existing"

# tsc that checked nothing is never `typecheck OK`: a global error (TS18003, no
# file prefix) and a solution-style tsconfig (only references) are UNAVAILABLE
for kind in global solution; do
  tg=$(tmpdir); git -C "$tg" init -q -b main; mkdir -p "$tg/src" "$tg/node_modules/.bin"
  echo '{ "name": "tg", "type": "module", "devDependencies": { "typescript": "5" } }' > "$tg/package.json"; printf 'node_modules\n' > "$tg/.gitignore"
  ln -s "$REPO_ROOT/skill/toolbelt/node_modules/typescript/bin/tsc" "$tg/node_modules/.bin/tsc"
  if [[ $kind == global ]]; then echo '{ "include": ["lib"] }' > "$tg/tsconfig.json"
  else echo '{ "files": [], "references": [{ "path": "./src" }] }' > "$tg/tsconfig.json"; echo '{ "compilerOptions": { "composite": true } }' > "$tg/src/tsconfig.json"; fi
  printf 'export const x: number = 1;\n' > "$tg/src/x.ts"
  git -C "$tg" -c user.email=f@e -c user.name=f add -A; git -C "$tg" -c user.email=f@e -c user.name=f commit -q -m base
  printf 'export const x: number = "oops";\n' > "$tg/src/x.ts"
  bash "$S/collect.sh" --repo "$tg" --base main --head WORKTREE --out "$out/tg-$kind" >/dev/null 2>&1
  row=$(grep $'^typecheck\t' "$out/tg-$kind/tools/summary.txt")
  assert_not_contains "$row" $'\tOK\t' "tsc $kind: not reported OK"
done
assert_contains "$(grep $'^typecheck\t' "$out/tg-global/tools/summary.txt")" $'UNAVAILABLE(tsc-error)\terror TS18003' "tsc global: UNAVAILABLE(tsc-error) with the error"
assert_contains "$(grep $'^typecheck\t' "$out/tg-solution/tools/summary.txt")" "UNAVAILABLE(solution-tsconfig)" "tsc solution: UNAVAILABLE(solution-tsconfig)"

# multi-package: one typecheck row per package, outputs under tools/<slug>/
mp=$(tmpdir)
git -C "$mp" init -q -b main
git -C "$mp" config user.email fixture@example.com; git -C "$mp" config user.name fixture
echo '{"name":"mp","workspaces":["packages/*"],"devDependencies":{"typescript":"5.9.3"}}' > "$mp/package.json"
: > "$mp/package-lock.json"; printf 'node_modules\n' > "$mp/.gitignore"
mkdir -p "$mp/node_modules/.bin"
cat > "$mp/node_modules/.bin/tsc" <<'EOF'
#!/bin/sh
case " $* " in *" --showConfig "*) echo '{"compilerOptions":{}}'; exit 0 ;; esac
echo 'src/x.ts(1,1): error TS2322: canned'
exit 2
EOF
chmod +x "$mp/node_modules/.bin/tsc"
for p in a b; do
  mkdir -p "$mp/packages/$p/src"
  echo "{\"name\":\"$p\"}" > "$mp/packages/$p/package.json"
  echo '{"compilerOptions":{"strict":true}}' > "$mp/packages/$p/tsconfig.json"
  echo 'export const x: number = 1;' > "$mp/packages/$p/src/x.ts"
done
git -C "$mp" add -A && git -C "$mp" commit -q -m base
git -C "$mp" checkout -q -b feature/x
for p in a b; do echo 'export const y: number = 2;' >> "$mp/packages/$p/src/x.ts"; done
git -C "$mp" add -A && git -C "$mp" commit -q -m change
bash "$S/collect.sh" --repo "$mp" --base main --head feature/x --out "$out/mp"
assert_eq "2" "$(grep -c $'^typecheck\t' "$out/mp/tools/summary.txt")" "mp: one typecheck row per package"
assert_contains "$(cat "$out/mp/tools/summary.txt")" $'typecheck\tOK\ta: 0 new, 1 pre-existing' "mp: package a's detail starts with its name; the canned error exists at base too"
assert_contains "$(cat "$out/mp/tools/summary.txt")" $'typecheck\tOK\tb: 0 new, 1 pre-existing' "mp: package b's row"
assert_file "$out/mp/tools/packages__a/typecheck.txt" "mp: per-package output dir for a"
assert_file "$out/mp/tools/packages__b/typecheck.txt" "mp: per-package output dir for b"

# MR mode: node_modules linked from the checkout when the lockfile is identical
mr=$(tmpdir)
git -C "$mr" init -q -b main
git -C "$mr" config user.email fixture@example.com; git -C "$mr" config user.name fixture
echo '{"name":"mr","devDependencies":{"typescript":"5.9.3"}}' > "$mr/package.json"
echo '{"lockfileVersion":3}' > "$mr/package-lock.json"; printf 'node_modules\n' > "$mr/.gitignore"
echo '{"compilerOptions":{"strict":true}}' > "$mr/tsconfig.json"
mkdir -p "$mr/src" "$mr/node_modules/.bin"; echo 'export const x: number = 1;' > "$mr/src/x.ts"
cp "$mp/node_modules/.bin/tsc" "$mr/node_modules/.bin/tsc"
git -C "$mr" add -A && git -C "$mr" commit -q -m base
mrwt="$out/mrwt"; git -C "$mr" worktree add -q --detach "$mrwt" main
bash "$S/collect.sh" --repo "$mrwt" --status-repo "$mr" --base main --head WORKTREE --out "$out/mr1"
assert_eq "linked-from-checkout" "$(val "$out/mr1/meta.env" NODE_MODULES)" "mr: node_modules linked from the checkout"
assert_link "$mrwt/node_modules" "mr: the worktree's node_modules is a symlink"
assert_contains "$(cat "$out/mr1/tools/summary.txt")" $'typecheck\tOK' "mr: tools ran through the linked node_modules"
rm "$mrwt/node_modules"
echo '{"lockfileVersion":3,"changed":true}' > "$mrwt/package-lock.json"
bash "$S/collect.sh" --repo "$mrwt" --status-repo "$mr" --base main --head WORKTREE --out "$out/mr2"
assert_eq "absent" "$(val "$out/mr2/meta.env" NODE_MODULES)" "mr: differing lockfile -> no link"
assert_contains "$(cat "$out/mr2/tools/summary.txt")" $'typecheck\tUNAVAILABLE(lockfile-differs)' "mr: typecheck unavailable with the --install hint"
[[ -e "$mrwt/node_modules" ]] && fail "mr: nothing linked when lockfiles differ" || pass
git -C "$mr" worktree remove --force "$mrwt"
# --install never touches the reviewed checkout itself
noinst=$(tmpdir)
git -C "$noinst" init -q -b main
git -C "$noinst" config user.email fixture@example.com; git -C "$noinst" config user.name fixture
echo '{"name":"noinst"}' > "$noinst/package.json"; : > "$noinst/package-lock.json"
git -C "$noinst" add -A && git -C "$noinst" commit -q -m base
r=$(bash "$S/collect.sh" --repo "$noinst" --base main --head WORKTREE --out "$out/noinst" --install 2>&1 || true)
assert_contains "$r" "refusing to install into the reviewed checkout" "install: refused when --repo is the checkout"
[[ -e "$noinst/node_modules" ]] && fail "install: nothing installed into the checkout" || pass

# --- Task 9: lint (strict fallback on dirty), metrics and duplication on the fixtures ---
bash "$S/collect.sh" --repo "$fx/dirty" --base main --head feature/NR-100-orders --out "$out/d9"
s9=$(cat "$out/d9/tools/summary.txt")
assert_contains "$s9" $'lint\t' "dirty: lint row present"
assert_contains "$(grep $'^lint\t' "$out/d9/tools/summary.txt")" "(strict fallback)" "dirty: no linter -> toolbelt strict config"
assert_file "$out/d9/tools/lint.json" "dirty: lint json kept as evidence"
assert_file "$out/d9/tools/lint-changed.json" "dirty: hunk-filtered lint json"
assert_contains "$s9" $'metrics\tFAIL' "dirty: metrics over threshold"
m9="$out/d9/tools/metrics.tsv"
assert_file "$m9" "dirty: metrics.tsv"
assert_contains "$(awk -F'\t' '$3 == "sonarjs/cognitive-complexity" { print $1 ":" $7 ":" $6 }' "$m9")" "src/services/order_service.js:placeOrder:MAJOR" "dirty: placeOrder cognitive complexity is a MAJOR row"
assert_contains "$(awk -F'\t' '$3 == "duplication" { print $1 " " $7 }' "$m9")" "legacy_order_service.js" "dirty: the copied discount block is a duplication row"
assert_contains "$(awk -F'\t' '$3 == "max-depth" { print $1 }' "$m9")" "src/services/order_service.js" "dirty: nesting depth row"
assert_file "$out/d9/tools/metrics-base.json" "dirty: metrics ran at the merge-base too"
assert_eq "" "$(git -C "$fx/dirty" status --porcelain --ignored | grep -v node_modules || true)" "dirty: repo untouched by lint/metrics"
r=$(ASSERT_CLEAN_PRUNE=node_modules bash "$S/assert-clean.sh" --repo "$fx/dirty" --out "$out/d9"); assert_eq "No artifacts left: verified" "$r" "dirty: no artifacts after lint/metrics"
bash "$S/collect.sh" --repo "$fx/clean" --base main --head feature/NR-100-orders --out "$out/c9"
assert_contains "$(cat "$out/c9/tools/summary.txt")" $'metrics\tOK' "clean: metrics within thresholds"
assert_eq "" "$(cat "$out/c9/tools/metrics.tsv")" "clean: no metric rows"

# --- Task 10: tests, classification and changed-line coverage on the fixtures (node:test) ---
s10=$(cat "$out/d9/tools/summary.txt")
assert_contains "$s10" $'test\tFAIL\t' "dirty: the handler test fails"
assert_contains "$(grep $'^test\t' "$out/d9/tools/summary.txt")" "1 failing" "dirty: one failing test counted"
assert_contains "$(grep $'^test\t' "$out/d9/tools/summary.txt")" "(scrubbed env)" "dirty: header says the environment was scrubbed"
assert_contains "$(cat "$out/d9/tools/test-classified.txt")" $'order_handler.test.js\tgetOrders returns 404 for an unknown user\tFAIL' "dirty: the failing test is named"
assert_contains "$s10" $'coverage\tOK\t' "dirty: coverage collected"
assert_file "$out/d9/tools/coverage/lcov.info" "dirty: lcov written under the work dir"
assert_contains "$(cat "$out/d9/tools/coverage-changed.txt")" $'src/services/order_service.js\t' "dirty: changed-line coverage row for the service"
[[ -e "$fx/dirty/coverage" ]] && fail "dirty: no coverage dir written into the repo" || pass
cov9=$(grep -v '^TOTAL=' "$out/d9/tools/coverage-changed.txt")
assert_not_contains "$cov9" "test/order_handler.test.js" "dirty: test files are not lines under test (no coverage row)"
assert_contains "$cov9" $'src/services/legacy_order_service.js\t0\t0\t1-27\tNO_RECORD' "dirty: the file no test loads lists its added lines as unexecuted"
assert_contains "$(grep $'^coverage\t' "$out/d9/tools/summary.txt")" "1 changed file not loaded by any test" "dirty: summary names the files no test loaded"
c10=$(cat "$out/c9/tools/summary.txt")
assert_contains "$c10" $'test\tOK\t' "clean: tests pass"
assert_contains "$(grep $'^test\t' "$out/c9/tools/summary.txt")" "0 failing" "clean: zero failing"
tot=$(tail -1 "$out/c9/tools/coverage-changed.txt"); tot=${tot#TOTAL=}
[[ "${tot%%/*}" -gt 0 && "${tot%%/*}" == "${tot##*/}" ]] && pass || fail "clean: every changed line executed (got TOTAL=$tot)"
assert_not_contains "$(cat "$out/c9/tools/coverage-changed.txt")" ".md"$'\t' "clean: spec and plan are not lines under test (no coverage row)"

# a fake vitest without a coverage provider: tests still classified, coverage UNAVAILABLE(no-coverage-provider)
fv=$(tmpdir)
git -C "$fv" init -q -b main
git -C "$fv" config user.email fixture@example.com; git -C "$fv" config user.name fixture
echo '{"name":"fv","type":"module","devDependencies":{"vitest":"^5.0.0"}}' > "$fv/package.json"
: > "$fv/vitest.config.ts"; : > "$fv/package-lock.json"; printf 'node_modules\n' > "$fv/.gitignore"
mkdir -p "$fv/node_modules/.bin" "$fv/src" "$fv/test"
cat > "$fv/node_modules/.bin/vitest" <<EOF
#!/bin/sh
case " \$* " in *" --coverage.enabled "*) echo "Error: Cannot find module '@vitest/coverage-v8'" >&2; exit 1 ;; esac
out=""
for a in "\$@"; do case "\$a" in --outputFile=*) out=\${a#--outputFile=} ;; esac; done
cp "$REPO_ROOT/tests/recordings/vitest-report.json" "\$out"
exit 1
EOF
chmod +x "$fv/node_modules/.bin/vitest"
echo 'export const x = 1;' > "$fv/src/calc.js"; echo 'import { x } from "../src/calc.js";' > "$fv/test/calc.test.js"
git -C "$fv" add -A && git -C "$fv" commit -q -m base
git -C "$fv" checkout -q -b feature/x
echo 'export const y = 2;' >> "$fv/src/calc.js"
git -C "$fv" add -A && git -C "$fv" commit -q -m change
bash "$S/collect.sh" --repo "$fv" --base main --head feature/x --out "$out/fv"
assert_contains "$(cat "$out/fv/tools/summary.txt")" $'test\tFAIL\t' "fake vitest: the recording's failure is reported"
assert_contains "$(cat "$out/fv/tools/summary.txt")" $'coverage\tUNAVAILABLE(no-coverage-provider)' "fake vitest: missing provider is reported, tests still ran"
assert_contains "$(cat "$out/fv/tools/test-classified.txt")" $'sub is wrong on purpose\tFAIL' "fake vitest: classification from the JSON report"
# a report the classifier cannot read is UNAVAILABLE, never `test OK 0 pass`, and collect still finishes
fvb=$(tmpdir); cp -R "$fv/." "$fvb"
printf '#!/bin/sh\nfor a in "$@"; do case "$a" in --outputFile=*) echo "{\\"error\\":\\"boom\\"}" > "${a#--outputFile=}" ;; esac; done\nexit 1\n' > "$fvb/node_modules/.bin/vitest"
bash "$S/collect.sh" --repo "$fvb" --base main --head feature/x --out "$out/fvb" >/dev/null 2>&1; rc=$?
assert_eq 0 "$rc" "bad test report: collect exits 0"
assert_contains "$(cat "$out/fvb/tools/summary.txt")" $'test\tUNAVAILABLE(bad-report)' "bad test report: test row is UNAVAILABLE(bad-report)"
assert_contains "$(cat "$out/fvb/tools/summary.txt")" $'audit\t' "bad test report: the audit row still runs"

# --- Task 11: audit only when dependencies changed; introduced advisories fail ---
assert_contains "$(cat "$out/c9/tools/summary.txt")" $'audit\tUNAVAILABLE(skipped)\tlockfile unchanged' "clean: no dependency change -> audit skipped"
bash "$S/collect.sh" --repo "$fx/dirty" --base main --head feature/NR-100-orders --out "$out/d11" --full-audit
assert_contains "$(cat "$out/d11/tools/summary.txt")" $'audit\tUNAVAILABLE(unsupported-audit)' "dirty --full-audit: no lockfile/package manager -> unsupported, never FAIL"
assert_not_contains "$(grep $'^audit\t' "$out/d11/tools/summary.txt")" "FAIL" "dirty --full-audit: not FAIL"

# a fake npm on PATH answers the audit; the lockfile change downgrades lodash into a vulnerable range
au=$(tmpdir)
git -C "$au" init -q -b main
git -C "$au" config user.email fixture@example.com; git -C "$au" config user.name fixture
echo '{"name":"au","dependencies":{"lodash":"4.17.21"}}' > "$au/package.json"
echo '{ "lockfileVersion": 3, "packages": { "": {}, "node_modules/lodash": { "version": "4.17.21" } } }' > "$au/package-lock.json"
git -C "$au" add -A && git -C "$au" commit -q -m base
git -C "$au" checkout -q -b feature/x
echo '{"name":"au","dependencies":{"lodash":"4.17.20"}}' > "$au/package.json"
echo '{ "lockfileVersion": 3, "packages": { "": {}, "node_modules/lodash": { "version": "4.17.20" } } }' > "$au/package-lock.json"
git -C "$au" add -A && git -C "$au" commit -q -m "downgrade lodash"
fakebin=$(tmpdir); mkdir -p "$fakebin"
cat > "$fakebin/npm" <<'EOF'
#!/bin/sh
case "$*" in *audit*) cat <<'JSON'
{ "auditReportVersion": 2, "vulnerabilities": { "lodash": { "name": "lodash", "severity": "high", "isDirect": true,
  "via": [ { "source": 1, "name": "lodash", "title": "Prototype Pollution in lodash", "url": "https://github.com/advisories/GHSA-p6mc-m468-83gw", "severity": "high", "range": "<4.17.21" } ],
  "range": "<4.17.21", "nodes": ["node_modules/lodash"], "fixAvailable": true } }, "metadata": {} }
JSON
exit 1 ;; esac
echo "fake npm: unexpected call $*" >&2; exit 2
EOF
chmod +x "$fakebin/npm"
PATH="$fakebin:$PATH" bash "$S/collect.sh" --repo "$au" --base main --head feature/x --out "$out/au"
assert_contains "$(cat "$out/au/tools/summary.txt")" $'audit\tFAIL\t1 introduced (1 high/critical), 0 pre-existing' "audit: introduced high advisory fails"
assert_contains "$(cat "$out/au/tools/audit-new.tsv")" $'lodash\t4.17.20\thigh\tGHSA-p6mc-m468-83gw\tintroduced' "audit: row written"
assert_file "$out/au/tools/audit.json" "audit: raw report kept"

# --- package.json values are data: stack.env is read, never sourced ---
# engines ">=..." once became a redirect that wrote a file named "=22.12.0" into
# the reviewed repo; "$(...)" would have run a command from the repo
ev=$(tmpdir); canary="$ev.canary"; git -C "$ev" init -q -b main
printf '{ "name": "ev", "type": "module", "engines": { "node": ">=22.12.0 $(touch %s)" } }\n' "$canary" > "$ev/package.json"
printf 'export const a = 1;\n' > "$ev/a.js"
git -C "$ev" -c user.email=f@e -c user.name=f add -A; git -C "$ev" -c user.email=f@e -c user.name=f commit -q -m base
printf 'export const a = 2;\n' > "$ev/a.js"
(cd "$ev" && bash "$S/collect.sh" --repo "$ev" --base main --head WORKTREE --out "$out/ev" --no-tools >/dev/null 2>&1) || true
[[ -e "$canary" ]] && fail "a \$(...) in package.json engines ran a command" || pass
[[ -e "$ev/=22.12.0" ]] && fail "an engines '>' wrote a file into the reviewed repo" || pass
assert_eq "" "$(git -C "$ev" status --porcelain --ignored | grep -v ' a.js$')" "nothing but the change itself in the repo after collect"
assert_eq ">=22.12.0 \$(touch $canary)" "$(val "$out/ev/stack.env" ENGINES)" "engines recorded verbatim in stack.env"
assert_eq "ev" "$(val "$out/ev/meta.env" PKG_NAME)" "collect still reads stack.env and finishes"

# a newline in engines once added an OUT= line to stack.env, and collect.sh took it as its out dir
ej=$(tmpdir); elsewhere=$(tmpdir); git -C "$ej" init -q -b main
printf '{ "name": "ej", "type": "module", "engines": { "node": ">=18\\nOUT=%s" } }\n' "$elsewhere" > "$ej/package.json"
printf 'export const a = 1;\n' > "$ej/a.js"
git -C "$ej" -c user.email=f@e -c user.name=f add -A; git -C "$ej" -c user.email=f@e -c user.name=f commit -q -m base
printf 'export const a = 2;\n' > "$ej/a.js"
bash "$S/collect.sh" --repo "$ej" --base main --head WORKTREE --out "$out/ej" --no-tools >/dev/null 2>&1
assert_eq "" "$(ls -A "$elsewhere")" "a key injected through package.json does not redirect collect's output"
assert_file "$out/ej/meta.env" "collect writes meta.env to its own --out"

# --- the diff is parsed the same whatever the user's git config, and paths may hold spaces or non-ASCII ---
gc=$(tmpdir); git -C "$gc" init -q -b main
git -C "$gc" config user.email f@e; git -C "$gc" config user.name f
mkdir -p "$gc/src"; echo '{ "name": "gc", "type": "module" }' > "$gc/package.json"
printf 'export const a = 1;\n' > "$gc/src/a.js"; printf 'export const o = 1;\nexport const p = 2;\n' > "$gc/src/old.js"
git -C "$gc" add -A; git -C "$gc" commit -q -m base; git -C "$gc" checkout -q -b feature/x
printf 'let count = 0;\n++ count;\n' > "$gc/src/my file.js"; printf 'export const c = 1;\n' > "$gc/src/café.js"
git -C "$gc" rm -q src/old.js; git -C "$gc" add -A; git -C "$gc" commit -q -m change
printf 'export const a = 1;\nexport const b = 2;\n' > "$gc/src/a.js"; printf 'export const n = 1;\n' > "$gc/src/new one.js"
printf '#!/bin/sh\necho EXTERNAL DIFF TOOL OUTPUT\n' > "$gc.ext"; chmod +x "$gc.ext"
git -C "$gc" config diff.mnemonicPrefix true; git -C "$gc" config color.ui always; git -C "$gc" config diff.external "$gc.ext"
bash "$S/collect.sh" --repo "$gc" --base main --head WORKTREE --out "$out/gc" --no-tools >/dev/null 2>&1
al=$(cat "$out/gc/added-lines.tsv")
assert_contains "$al" $'src/a.js\t2' "git config: an added line in a modified file"
assert_contains "$al" $'src/my file.js\t1' "git config: a path with a space"
assert_contains "$al" $'src/my file.js\t2' "git config: an added line starting with ++ is content, not a header"
assert_contains "$al" $'src/café.js\t1' "git config: a non-ASCII path"
assert_contains "$al" $'src/new one.js\t1' "git config: an untracked file with a space"
assert_eq "5" "$(grep -c . "$out/gc/added-lines.tsv")" "git config: exactly the five added lines"
assert_eq "7" "$(cat "$out/gc/nontest-lines.txt")" "git config: added and removed source lines counted"
assert_eq $'src/a.js\nsrc/café.js\nsrc/my file.js\nsrc/new one.js\nsrc/old.js' "$(cat "$out/gc/changed-files.txt")" "git config: changed files unquoted, deleted file listed"
assert_not_contains "$(cat "$out/gc/diff.patch")" "EXTERNAL DIFF TOOL" "git config: diff.external is not used"

# a workspace package's own runner runs, though the workspace root names none
mr=$(tmpdir); git -C "$mr" init -q -b main
echo '{ "name": "mr", "private": true, "workspaces": ["packages/*"], "scripts": { "test": "npm test -ws" } }' > "$mr/package.json"
: > "$mr/package-lock.json"; printf 'node_modules\n' > "$mr/.gitignore"
mkdir -p "$mr/packages/api/src" "$mr/packages/api/node_modules/.bin"
echo '{ "name": "api", "type": "module", "devDependencies": { "vitest": "^5.0.0" } }' > "$mr/packages/api/package.json"
: > "$mr/packages/api/vitest.config.ts"; cp "$fv/node_modules/.bin/vitest" "$mr/packages/api/node_modules/.bin/vitest"
printf 'export const a = 1;\n' > "$mr/packages/api/src/a.js"
git -C "$mr" -c user.email=f@e -c user.name=f add -A; git -C "$mr" -c user.email=f@e -c user.name=f commit -q -m base
printf 'export const a = 2;\n' > "$mr/packages/api/src/a.js"
bash "$S/collect.sh" --repo "$mr" --base main --head WORKTREE --out "$out/mr" >/dev/null 2>&1
assert_contains "$(cat "$out/mr/tools/summary.txt")" $'test\tFAIL\t' "monorepo: the package's vitest ran (the recording has one failure)"
assert_not_contains "$(cat "$out/mr/tools/summary.txt")" "no-runner" "monorepo: not UNAVAILABLE(no-runner)"

# a workspace package whose path holds a space is one package
ws=$(tmpdir); git -C "$ws" init -q -b main
echo '{ "name": "ws", "workspaces": ["packages/my api"] }' > "$ws/package.json"
mkdir -p "$ws/packages/my api"; echo '{ "name": "my-api", "type": "module" }' > "$ws/packages/my api/package.json"
printf 'export const a = 1;\n' > "$ws/packages/my api/a.js"
git -C "$ws" -c user.email=f@e -c user.name=f add -A; git -C "$ws" -c user.email=f@e -c user.name=f commit -q -m base
printf 'export const a = 2;\n' > "$ws/packages/my api/a.js"
bash "$S/collect.sh" --repo "$ws" --base main --head WORKTREE --out "$out/ws" >/dev/null 2>&1; rc=$?
assert_eq "0" "$rc" "space in a package path: collect finishes"
assert_eq "my-api" "$(cat "$out/ws/changed-packages.txt")" "space in a package path: one package named"
assert_eq "packages/my api" "$(val "$out/ws/meta.env" PKG_DIR)" "space in a package path: PKG_DIR kept whole"

# --- the repo's own linter loads repo code (eslint.config.js): it runs in the scrubbed env too ---
for lt in eslint biome; do
  lr=$(tmpdir); envdump="$lr.env"; git -C "$lr" init -q -b main
  echo "{ \"name\": \"lr\", \"type\": \"module\", \"devDependencies\": { \"$lt\": \"1.0.0\" } }" > "$lr/package.json"
  if [[ $lt == eslint ]]; then : > "$lr/eslint.config.js"; else echo '{}' > "$lr/biome.json"; fi
  printf 'node_modules\n' > "$lr/.gitignore"; mkdir -p "$lr/node_modules/.bin"
  printf '#!/bin/sh\nenv > "%s"\nfor a in "$@"; do [ "$prev" = "-o" ] && echo "[]" > "$a"; prev=$a; done\necho "{\\"diagnostics\\":[]}"\n' "$envdump" > "$lr/node_modules/.bin/$lt"
  chmod +x "$lr/node_modules/.bin/$lt"; printf 'export const a = 1;\n' > "$lr/a.js"
  git -C "$lr" -c user.email=f@e -c user.name=f add -A; git -C "$lr" -c user.email=f@e -c user.name=f commit -q -m base
  printf 'export const a = 2;\n' > "$lr/a.js"
  NR_CANARY_SECRET=leaked bash "$S/collect.sh" --repo "$lr" --base main --head WORKTREE --out "$out/lr-$lt" >/dev/null 2>&1
  assert_file "$envdump" "$lt: the repo's linter ran"
  assert_not_contains "$(cat "$envdump" 2>/dev/null)" "NR_CANARY_SECRET" "$lt: the repo's linter does not see the caller's environment"
done

# --- the merge-base worktree runs no repository hook (husky sets core.hooksPath to a tracked dir) ---
hk=$(tmpdir); hcanary="$hk.hook-ran"; git -C "$hk" init -q -b main
git -C "$hk" config user.email f@e; git -C "$hk" config user.name f; git -C "$hk" config core.hooksPath .husky
mkdir -p "$hk/.husky"; printf '#!/bin/sh\ntouch "%s"\n' "$hcanary" > "$hk/.husky/post-checkout"; chmod +x "$hk/.husky/post-checkout"
echo '{ "name": "hk", "type": "module" }' > "$hk/package.json"; printf 'export const a = 1;\n' > "$hk/a.js"
git -C "$hk" add -A; git -C "$hk" commit -q -m base
rm -f "$hcanary"; git -C "$hk" checkout -q -b feature/x; rm -f "$hcanary"
printf 'export const a = 2;\n' > "$hk/a.js"; git -C "$hk" commit -q -am change
bash "$S/collect.sh" --repo "$hk" --base main --head feature/x --out "$out/hk" >/dev/null 2>&1
[[ -e "$hcanary" ]] && fail "creating the merge-base worktree ran the repo's post-checkout hook" || pass
assert_contains "$(cat "$out/hk/tools/summary.txt")" $'metrics\t' "hook repo: collect still ran the tools"

# --- node:test runs with the script's loader flags and file patterns ---
nt=$(tmpdir)
jq -n '{name: "nt", scripts: {test: "node --import tsx --experimental-strip-types --test --test-concurrency=1 '"'"'test/**/*.test.ts'"'"' && eslint ."}}' > "$nt/a.json"
assert_eq $'F\t--import\nF\ttsx\nF\t--experimental-strip-types\nP\ttest/**/*.test.ts' "$(bash "$S/collect.sh" --fn node_test_args "$nt/a.json")" "node_test_args: loader flags and the pattern, nothing after &&"
jq -n '{name: "nt", scripts: {test: "tsx --test test/a.test.ts"}}' > "$nt/b.json"
assert_eq $'F\t--import\nF\ttsx\nP\ttest/a.test.ts' "$(bash "$S/collect.sh" --fn node_test_args "$nt/b.json")" "node_test_args: tsx --test is node --import tsx --test"
jq -n '{name: "nt", scripts: {test: "node --test"}}' > "$nt/c.json"
assert_eq "" "$(bash "$S/collect.sh" --fn node_test_args "$nt/c.json")" "node_test_args: plain node --test adds nothing"
# end to end: a test file outside node's default patterns is found through the script's pattern
nr=$(tmpdir); git -C "$nr" init -q -b main; mkdir -p "$nr/src" "$nr/checks"
jq -n '{name: "nr", type: "module", scripts: {test: "node --test checks/*.check.js"}}' > "$nr/package.json"
printf 'export const sum = (a, b) => a + b;\n' > "$nr/src/sum.js"
printf 'import { test } from "node:test";\nimport assert from "node:assert/strict";\nimport { sum } from "../src/sum.js";\ntest("sums", () => assert.equal(sum(1, 2), 3));\n' > "$nr/checks/sum.check.js"
git -C "$nr" -c user.email=f@e -c user.name=f add -A; git -C "$nr" -c user.email=f@e -c user.name=f commit -q -m base
printf 'export const sum = (a, b) => a + b;\nexport const two = 2;\n' > "$nr/src/sum.js"
bash "$S/collect.sh" --repo "$nr" --base main --head WORKTREE --out "$out/nr" >/dev/null 2>&1
assert_contains "$(grep $'^test\t' "$out/nr/tools/summary.txt")" $'OK\t1 pass' "node:test: the script's pattern finds the test"

# --- not a Node.js repo ---
nn=$(tmpdir); git -C "$nn" init -q -b main; echo hi > "$nn/README.md"
git -C "$nn" -c user.email=f@e -c user.name=f add -A; git -C "$nn" -c user.email=f@e -c user.name=f commit -q -m base
r=$(bash "$S/collect.sh" --repo "$nn" --base main --head WORKTREE --out "$out/nn" --no-tools 2>&1 || true)
assert_contains "$r" "not a Node.js repo" "no package.json is a clear error"

finish
