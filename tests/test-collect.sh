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

# --- not a Node.js repo ---
nn=$(tmpdir); git -C "$nn" init -q -b main; echo hi > "$nn/README.md"
git -C "$nn" -c user.email=f@e -c user.name=f add -A; git -C "$nn" -c user.email=f@e -c user.name=f commit -q -m base
r=$(bash "$S/collect.sh" --repo "$nn" --base main --head WORKTREE --out "$out/nn" --no-tools 2>&1 || true)
assert_contains "$r" "not a Node.js repo" "no package.json is a clear error"

finish
