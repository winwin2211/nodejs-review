#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
S="$REPO_ROOT/skill/scripts"
out=$(tmpdir)

# mkrepo NAME -> prints a fresh git repo path with a package.json written by the caller
mkrepo() {
  local d; d=$(tmpdir)
  git -C "$d" init -q -b main
  printf '%s\n' "$d"
}
# val FILE KEY -> the value of KEY= in FILE
val() { sed -n "s/^$2=//p" "$1"; }

# (a) npm + vitest config + tsconfig + flat eslint config, single package
a=$(mkrepo)
echo '{"name":"a","devDependencies":{"vitest":"^5.0.0","typescript":"^5.0.0","eslint":"^9.0.0"}}' > "$a/package.json"
: > "$a/package-lock.json"; : > "$a/vitest.config.ts"; echo '{}' > "$a/tsconfig.json"; : > "$a/eslint.config.js"
bash "$S/detect-stack.sh" --repo "$a" --out "$out/a"
f="$out/a/stack.env"
assert_eq "npm" "$(val "$f" PM)" "a: npm from package-lock.json"
assert_eq "package-lock.json" "$(val "$f" LOCKFILE)" "a: lockfile recorded"
assert_eq "1" "$(val "$f" TS)" "a: TypeScript detected"
assert_eq "vitest" "$(val "$f" RUNNER)" "a: vitest from config file"
assert_eq "eslint" "$(val "$f" LINTER)" "a: eslint from flat config"
assert_eq "0" "$(val "$f" WORKSPACES)" "a: no workspaces"
assert_eq "." "$(val "$f" PACKAGES)" "a: root package"
assert_eq "$(node --version)" "$(val "$f" NODE)" "a: node version recorded"
assert_eq "" "$(val "$f" ENGINES)" "a: no engines"
assert_eq "unknown" "$(val "$f" ENGINES_MATCH)" "a: engines match unknown when none declared"

# (b) pnpm workspace; the changed file picks the owning package
b=$(mkrepo)
echo '{"name":"b","private":true}' > "$b/package.json"; : > "$b/pnpm-lock.yaml"
printf 'packages:\n  - "packages/*"\n' > "$b/pnpm-workspace.yaml"
mkdir -p "$b/packages/api/src" "$b/packages/web/src"
echo '{"name":"@acme/api"}' > "$b/packages/api/package.json"; echo '{"name":"@acme/web"}' > "$b/packages/web/package.json"
printf 'packages/api/src/x.ts\n' > "$out/b-changed.txt"
bash "$S/detect-stack.sh" --repo "$b" --out "$out/b" --changed-files "$out/b-changed.txt"
f="$out/b/stack.env"
assert_eq "pnpm" "$(val "$f" PM)" "b: pnpm from lockfile"
assert_eq "1" "$(val "$f" WORKSPACES)" "b: workspaces detected"
assert_eq "packages/api" "$(val "$f" PACKAGES)" "b: only the package owning the changed file"
assert_eq "0" "$(val "$f" PACKAGES_OVERFLOW)" "b: no overflow"

# (b2) a glob entry without a package.json, a glob that matches nothing, `**`, a space: none ends the script
b2=$(mkrepo); echo '{"name":"b2","workspaces":["packages/*","libs/*"]}' > "$b2/package.json"
mkdir -p "$b2/packages/api" "$b2/packages/zz-notes"; echo '{"name":"api"}' > "$b2/packages/api/package.json"; : > "$b2/packages/zz-notes/README.md"
printf 'packages/api/src/x.ts\n' > "$out/b2-changed.txt"
bash "$S/detect-stack.sh" --repo "$b2" --out "$out/b2" --changed-files "$out/b2-changed.txt"; rc=$?
assert_eq "0" "$rc" "b2: a workspace dir without package.json does not end the script"
assert_eq "packages/api" "$(val "$out/b2/stack.env" PACKAGES)" "b2: the owning package found"
b3=$(mkrepo); echo '{"name":"b3"}' > "$b3/package.json"; printf 'packages:\n  - "packages/**"\n' > "$b3/pnpm-workspace.yaml"
mkdir -p "$b3/packages/group/api"; echo '{"name":"api"}' > "$b3/packages/group/api/package.json"
printf 'packages/group/api/src/x.ts\n' > "$out/b3-changed.txt"
bash "$S/detect-stack.sh" --repo "$b3" --out "$out/b3" --changed-files "$out/b3-changed.txt"; rc=$?
assert_eq "0" "$rc" "b3: a ** workspace glob does not end the script"
assert_eq "packages/group/api" "$(val "$out/b3/stack.env" PACKAGES)" "b3: ** matches nested packages"
b4=$(mkrepo); echo '{"name":"b4","workspaces":["packages/my api"]}' > "$b4/package.json"
mkdir -p "$b4/packages/my api"; echo '{"name":"my-api"}' > "$b4/packages/my api/package.json"
printf 'packages/my api/x.js\n' > "$out/b4-changed.txt"
bash "$S/detect-stack.sh" --repo "$b4" --out "$out/b4" --changed-files "$out/b4-changed.txt"; rc=$?
assert_eq "0" "$rc" "b4: a workspace path with a space does not end the script"
assert_eq "packages/my api" "$(val "$out/b4/stack.env" PACKAGES)" "b4: a workspace path with a space is one package"

# (c) packageManager field wins over the lockfile name; yarn berry from .yarnrc.yml
c=$(mkrepo)
echo '{"name":"c","packageManager":"yarn@4.1.0"}' > "$c/package.json"; : > "$c/yarn.lock"; echo 'nodeLinker: node-modules' > "$c/.yarnrc.yml"
bash "$S/detect-stack.sh" --repo "$c" --out "$out/c"
assert_eq "yarn-berry" "$(val "$out/c/stack.env" PM)" "c: yarn berry"
c2=$(mkrepo)
echo '{"name":"c2"}' > "$c2/package.json"; : > "$c2/yarn.lock"
bash "$S/detect-stack.sh" --repo "$c2" --out "$out/c2"
assert_eq "yarn" "$(val "$out/c2/stack.env" PM)" "c2: yarn classic from a bare yarn.lock"

# (d) jest key in package.json, biome.json
d=$(mkrepo)
echo '{"name":"d","jest":{"testEnvironment":"node"},"devDependencies":{"jest":"^29.0.0"}}' > "$d/package.json"; echo '{}' > "$d/biome.json"
bash "$S/detect-stack.sh" --repo "$d" --out "$out/d"
assert_eq "jest" "$(val "$out/d/stack.env" RUNNER)" "d: jest from package.json key"
assert_eq "biome" "$(val "$out/d/stack.env" LINTER)" "d: biome"
assert_eq "0" "$(val "$out/d/stack.env" TS)" "d: no TypeScript"

# (e) node --test from the test script; (f) mocha; (f2) bun test; (f3) nothing
e=$(mkrepo); echo '{"name":"e","scripts":{"test":"node --test"}}' > "$e/package.json"
bash "$S/detect-stack.sh" --repo "$e" --out "$out/e"
assert_eq "node-test" "$(val "$out/e/stack.env" RUNNER)" "e: node:test from the test script"
assert_eq "none" "$(val "$out/e/stack.env" LINTER)" "e: no linter"
assert_eq "unknown" "$(val "$out/e/stack.env" PM)" "e: no lockfile -> unknown"
f1=$(mkrepo); echo '{"name":"f","scripts":{"test":"mocha --recursive"}}' > "$f1/package.json"
bash "$S/detect-stack.sh" --repo "$f1" --out "$out/f1"
assert_eq "mocha" "$(val "$out/f1/stack.env" RUNNER)" "f: mocha"
f2=$(mkrepo); echo '{"name":"f2","scripts":{"test":"bun test"}}' > "$f2/package.json"; : > "$f2/bun.lock"
bash "$S/detect-stack.sh" --repo "$f2" --out "$out/f2"
assert_eq "bun-test" "$(val "$out/f2/stack.env" RUNNER)" "f2: bun test"
assert_eq "bun" "$(val "$out/f2/stack.env" PM)" "f2: bun from bun.lock"
f3=$(mkrepo); echo '{"name":"f3"}' > "$f3/package.json"
bash "$S/detect-stack.sh" --repo "$f3" --out "$out/f3"
assert_eq "none" "$(val "$out/f3/stack.env" RUNNER)" "f3: no runner"

# (g) engines mismatch and match
g=$(mkrepo); echo '{"name":"g","engines":{"node":">=99"}}' > "$g/package.json"
bash "$S/detect-stack.sh" --repo "$g" --out "$out/g"
assert_eq ">=99" "$(val "$out/g/stack.env" ENGINES)" "g: engines recorded"
assert_eq "0" "$(val "$out/g/stack.env" ENGINES_MATCH)" "g: engines mismatch"
g2=$(mkrepo); echo '{"name":"g2","engines":{"node":">=18"}}' > "$g2/package.json"
bash "$S/detect-stack.sh" --repo "$g2" --out "$out/g2"
assert_eq "1" "$(val "$out/g2/stack.env" ENGINES_MATCH)" "g2: engines match"

# (g3) a newline in a package.json value cannot add a key to stack.env
g3=$(mkrepo); printf '{"name":"g3","engines":{"node":">=18\\nOUT=/elsewhere\\rRUNNER=jest"}}\n' > "$g3/package.json"
bash "$S/detect-stack.sh" --repo "$g3" --out "$out/g3"
assert_eq "12" "$(wc -l < "$out/g3/stack.env" | tr -d ' ')" "g3: one line per key"
assert_eq "" "$(val "$out/g3/stack.env" OUT)" "g3: no OUT= line injected"
assert_eq "none" "$(val "$out/g3/stack.env" RUNNER)" "g3: no RUNNER= line injected"
assert_eq ">=18 OUT=/elsewhere RUNNER=jest" "$(val "$out/g3/stack.env" ENGINES)" "g3: line breaks in a value become spaces"

# (h) five changed workspace packages overflow the four-package cap
h=$(mkrepo); echo '{"name":"h","workspaces":["packages/*"]}' > "$h/package.json"; : > "$h/package-lock.json"
: > "$out/h-changed.txt"
for p in p1 p2 p3 p4 p5; do mkdir -p "$h/packages/$p"; echo "{\"name\":\"$p\"}" > "$h/packages/$p/package.json"; echo "packages/$p/index.js" >> "$out/h-changed.txt"; done
bash "$S/detect-stack.sh" --repo "$h" --out "$out/h" --changed-files "$out/h-changed.txt"
assert_eq "1" "$(val "$out/h/stack.env" PACKAGES_OVERFLOW)" "h: overflow flagged"
assert_eq "4" "$(val "$out/h/stack.env" PACKAGES | tr ':' '\n' | wc -l | tr -d ' ')" "h: at most four packages kept"
# --package forces the selection
bash "$S/detect-stack.sh" --repo "$h" --out "$out/h2" --changed-files "$out/h-changed.txt" --package packages/p5
assert_eq "packages/p5" "$(val "$out/h2/stack.env" PACKAGES)" "h2: --package forces the package"
assert_eq "0" "$(val "$out/h2/stack.env" PACKAGES_OVERFLOW)" "h2: no overflow with --package"

# (i) no package.json anywhere
i=$(mkrepo); echo hi > "$i/README.md"
assert_exit 1 bash "$S/detect-stack.sh" --repo "$i" --out "$out/i"
r=$(bash "$S/detect-stack.sh" --repo "$i" --out "$out/i" 2>&1 || true)
assert_contains "$r" "not a Node.js repo" "i: clear message"

# (j) --out inside the repo is refused
assert_exit 1 bash "$S/detect-stack.sh" --repo "$a" --out "$a/.review"
[[ -e "$a/.review" ]] && fail "j: refused --out must create nothing" || pass

# (k) the dirty fixture
fx=$(tmpdir); bash "$REPO_ROOT/fixtures/make-fixtures.sh" "$fx" >/dev/null
bash "$S/detect-stack.sh" --repo "$fx/dirty" --out "$out/k"
f="$out/k/stack.env"
assert_eq "unknown" "$(val "$f" PM)" "k: dirty has no lockfile"
assert_eq "node-test" "$(val "$f" RUNNER)" "k: dirty uses node:test"
assert_eq "none" "$(val "$f" LINTER)" "k: dirty has no linter"
assert_eq "0" "$(val "$f" TS)" "k: dirty is JavaScript"
bash "$S/detect-stack.sh" --repo "$fx/ts" --out "$out/k2"
assert_eq "1" "$(val "$out/k2/stack.env" TS)" "k2: ts fixture is TypeScript"
assert_eq "none" "$(val "$out/k2/stack.env" RUNNER)" "k2: ts fixture has no runner"

finish
