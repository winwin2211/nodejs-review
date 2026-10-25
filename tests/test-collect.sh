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
sqlline=$(grep -nF "WHERE user = '\${user}'" "$fx/dirty/src/repos/order_repo.js" | cut -d: -f1)
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

# --- not a Node.js repo ---
nn=$(tmpdir); git -C "$nn" init -q -b main; echo hi > "$nn/README.md"
git -C "$nn" -c user.email=f@e -c user.name=f add -A; git -C "$nn" -c user.email=f@e -c user.name=f commit -q -m base
r=$(bash "$S/collect.sh" --repo "$nn" --base main --head WORKTREE --out "$out/nn" --no-tools 2>&1 || true)
assert_contains "$r" "not a Node.js repo" "no package.json is a clear error"

finish
