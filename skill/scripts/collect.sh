#!/usr/bin/env bash
# Collect diff, changed files, stack and tool evidence for nodejs-review into an out dir.
#
#   collect.sh --repo R --head H|WORKTREE --out O [--base B] [--status-repo P] [--package DIR]
#              [--no-tools] [--full-tests] [--full-audit] [--install]
#
# Order: baselines and mtime-marker, then the diff and file lists, then
# detect-stack.sh (so the owning packages are known), then the tools.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/lib.sh"

# Per-tool budgets in seconds (NODEJS_REVIEW_TIMEOUT_<TOOL> overrides). The
# test runner's own timeout sits 10s below the test budget so a hung test dies
# inside the runner, with its report as evidence, before the wrapper gives up.
T_TYPECHECK=${NODEJS_REVIEW_TIMEOUT_TYPECHECK:-180}
T_LINT=${NODEJS_REVIEW_TIMEOUT_LINT:-180}
T_METRICS=${NODEJS_REVIEW_TIMEOUT_METRICS:-120}
T_TEST=${NODEJS_REVIEW_TIMEOUT_TEST:-600}
T_AUDIT=${NODEJS_REVIEW_TIMEOUT_AUDIT:-120}
runner_timeout_ms() { local ms=$(( (T_TEST - 10) * 1000 )); [[ $ms -lt 1000 ]] && ms=1000; echo "$ms"; }

# Scrubbed environment for anything that executes repository code: an
# allow-list, never the caller's variables, which may point at real services.
# An array rather than a function because run_with_timeout execs its arguments.
SCRUB=(env -i "PATH=$PATH" "HOME=$HOME" "TMPDIR=${TMPDIR:-/tmp}" "LANG=${LANG:-C.UTF-8}" "LC_ALL=${LC_ALL:-}" TERM=dumb CI=true NODE_ENV=test NO_COLOR=1)
scrubbed_run() { "${SCRUB[@]}" "$@"; }

# find_bin NAME PKGDIR [ROOT] -> the first node_modules/.bin/NAME walking from
# PKGDIR up to ROOT (default REPO; workspaces hoist most binaries to the
# root), else nothing.
find_bin() {
  local name=$1 root=${3:-$REPO} abs
  root=$(cd "$root" && pwd -P)
  abs=$(cd "$root/$2" 2>/dev/null && pwd -P) || return 0
  while :; do
    if [[ -x "$abs/node_modules/.bin/$name" ]]; then echo "$abs/node_modules/.bin/$name"; return 0; fi
    [[ "$abs" == "$root" || "$abs" == "/" ]] && return 0
    abs=$(dirname "$abs")
  done
}
pkg_slug() { if [[ "$1" == "." ]]; then echo root; else echo "${1//\//__}"; fi; }

REPO="" BASE="" HEAD="" OUT="" STATUS_REPO="" PKG_OPT="" NO_TOOLS=0 FULL_TESTS=0 FULL_AUDIT=0 INSTALL=0 FN=""
FN_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO=$2; shift 2 ;;
    --base) BASE=$2; shift 2 ;;
    --head) HEAD=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --status-repo) STATUS_REPO=$2; shift 2 ;;
    --package) PKG_OPT=$2; shift 2 ;;
    --no-tools) NO_TOOLS=1; shift ;;
    --full-tests) FULL_TESTS=1; shift ;;
    --full-audit) FULL_AUDIT=1; shift ;;
    --install) INSTALL=1; shift ;;
    --fn) FN=$2; shift 2; FN_ARGS=("$@"); break ;;
    *) die "unknown arg: $1" ;;
  esac
done
# --fn NAME ARGS...: run one helper and exit (tests use this)
if [[ -n "$FN" ]]; then
  [[ -n "$REPO" ]] && REPO=$(cd "$REPO" && pwd -P)
  "$FN" ${FN_ARGS[@]+"${FN_ARGS[@]}"}
  exit $?
fi
[[ -n "$REPO" && -n "$OUT" && -n "$HEAD" ]] || die "usage: collect.sh --repo R --head H|WORKTREE --out O [--base B] [--status-repo P] [--package DIR] [--no-tools] [--full-tests] [--full-audit] [--install]"
command -v jq >/dev/null || die "jq not found on PATH"
REPO=$(cd "$REPO" && pwd -P)
[[ -n "$STATUS_REPO" ]] || STATUS_REPO="$REPO"
STATUS_REPO=$(cd "$STATUS_REPO" && pwd -P)
[[ -n "$BASE" ]] || BASE=$(resolve_base "$REPO")
assert_outside "$OUT" "$REPO"
mkdir -p "$OUT/tools"
OUT=$(cd "$OUT" && pwd -P)

# Baseline snapshots for assert-clean.sh, taken first so a later failure (bad
# --base, tool crash) never leaves the run without them. mtime-marker goes
# before everything: files under the repo newer than it were written during
# the run. Taken against --status-repo (defaults to --repo; differs in MR mode
# where --repo is a throwaway worktree).
touch "$OUT/mtime-marker"
git -C "$STATUS_REPO" status --porcelain > "$OUT/status-before.txt"
git -C "$STATUS_REPO" status --porcelain --ignored > "$OUT/status-ignored-before.txt"
git -C "$STATUS_REPO" stash list > "$OUT/stash-before.txt"

if [[ "$HEAD" == "WORKTREE" ]]; then MODE=worktree; HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
else
  MODE=ref; HEAD_SHA=$(git -C "$REPO" rev-parse "$HEAD")
  actual_head=$(git -C "$REPO" rev-parse HEAD)
  [[ "$actual_head" == "$HEAD_SHA" ]] || log "checked-out HEAD $actual_head differs from --head $HEAD_SHA; tools run against the checkout"
fi
MB=$(merge_base "$REPO" "$BASE" "$HEAD_SHA")

# --- diff ---
if [[ "$MODE" == "worktree" ]]; then
  git -C "$REPO" diff "$MB" > "$OUT/diff.patch"
  git -C "$REPO" ls-files --others --exclude-standard | while read -r f; do
    git -C "$REPO" diff --no-index -- /dev/null "$f" >> "$OUT/diff.patch" || true
  done
  { git -C "$REPO" diff --name-only "$MB"; git -C "$REPO" ls-files --others --exclude-standard; } | sort -u > "$OUT/changed-files.txt"
else
  git -C "$REPO" diff "$MB" "$HEAD_SHA" > "$OUT/diff.patch"
  git -C "$REPO" diff --name-only "$MB" "$HEAD_SHA" | sort -u > "$OUT/changed-files.txt"
fi

# --- file classes: source vs test, existing files only (a deleted path is not reviewable code) ---
is_test_path() {
  case "$1" in
    *.test.*|*.spec.*|*.stories.*) return 0 ;;
    __tests__/*|*/__tests__/*|__mocks__/*|*/__mocks__/*|test/*|*/test/*|tests/*|*/tests/*) return 0 ;;
  esac
  return 1
}
is_src_ext() { case "$1" in *.ts|*.tsx|*.js|*.mjs|*.cjs|*.mts|*.cts|*.jsx) return 0 ;; esac; return 1; }
: > "$OUT/changed-src-files.txt"; : > "$OUT/changed-test-files.txt"
while read -r f; do
  [[ -n "$f" && -f "$REPO/$f" ]] || continue
  is_src_ext "$f" || continue
  if is_test_path "$f"; then echo "$f" >> "$OUT/changed-test-files.txt"; else echo "$f" >> "$OUT/changed-src-files.txt"; fi
done < "$OUT/changed-files.txt"

# every added line as file<TAB>line (new-file numbering), for hunk filtering
awk '
  /^\+\+\+ / { f = $2; if (f == "/dev/null") { f = "" } else { sub(/^b\//, "", f) } next }
  /^@@ / { s = $3; sub(/^\+/, "", s); split(s, parts, ","); line = parts[1] + 0; next }
  /^\\/ { next }
  f != "" && /^\+/ { print f "\t" line; line++; next }
  f != "" && /^-/ { next }
  f != "" && /^ / { line++ }
' "$OUT/diff.patch" > "$OUT/added-lines.tsv"

# changed-symbols.txt: added declaration lines, plus for every added line the
# nearest top-level declaration or class method above it in the head version
# of the file, so a function whose body changed but whose signature line did
# not (the common case) is still listed. Head content comes from the working
# tree in worktree mode and from HEAD_SHA otherwise.
DECL_RE='^\s*(export\s+)?(default\s+)?(async\s+)?(function\*?|class|interface|type|enum)\s+[A-Za-z_$][A-Za-z0-9_$]*|^\s*(export\s+)?(const|let|var)\s+[A-Za-z_$][A-Za-z0-9_$]*\s*=\s*(async\s*)?(\(|function|[A-Za-z_$][A-Za-z0-9_$]*\s*=>)|^\s{2,4}(public\s+|private\s+|protected\s+|static\s+|async\s+|override\s+)*[A-Za-z_$][A-Za-z0-9_$]*\s*\([^)]*\)\s*(:\s*[^{]+)?\{'
ENCL_RE='^(export\s+)?(default\s+)?(async\s+)?(function\*?|class)\s+[A-Za-z_$][A-Za-z0-9_$]*|^(export\s+)?(const|let|var)\s+[A-Za-z_$][A-Za-z0-9_$]*\s*=\s*(async\s*)?(\(|function|[A-Za-z_$][A-Za-z0-9_$]*\s*=>)|^\s{2,4}(public\s+|private\s+|protected\s+|static\s+|async\s+|override\s+)*[A-Za-z_$][A-Za-z0-9_$]*\s*\([^)]*\)\s*(:\s*[^{]+)?\{'
head_file() { # path -> head content on stdout
  if [[ "$MODE" == worktree ]]; then cat "$REPO/$1"; else git -C "$REPO" show "$HEAD_SHA:$1" 2>/dev/null || cat "$REPO/$1"; fi
}
{
  grep -E '^\+' "$OUT/diff.patch" | sed 's/^+//' | grep -E "$DECL_RE" || true
  while read -r f; do
    head_file "$f" | grep -nE "$ENCL_RE" > "$OUT/.decls" || true
    [[ -s "$OUT/.decls" ]] || continue
    awk -F'\t' -v f="$f" '$1 == f { print $2 }' "$OUT/added-lines.tsv" > "$OUT/.lines"
    awk '
      NR == FNR { i = index($0, ":"); n++; dn[n] = substr($0, 1, i - 1) + 0; dt[n] = substr($0, i + 1); next }
      { L = $1 + 0; best = 0; for (k = 1; k <= n; k++) if (dn[k] <= L && dn[k] > best) { best = dn[k]; bt = dt[k] }; if (best) print bt }
    ' "$OUT/.decls" "$OUT/.lines"
  done < <(cat "$OUT/changed-src-files.txt" "$OUT/changed-test-files.txt")
  rm -f "$OUT/.decls" "$OUT/.lines"
} | sort -u > "$OUT/changed-symbols.txt"

# added+removed lines of non-test source files (a deleted file's removed lines count;
# an untracked file is diffed as `a//dev/null` vs `b/<path>`, so the path is $4 there)
awk '
  function is_test(p) { return (p ~ /\.(test|spec|stories)\./ || p ~ /(^|\/)(__tests__|__mocks__|test|tests)\//) }
  function is_src(p) { return (p ~ /\.(ts|tsx|js|mjs|cjs|mts|cts|jsx)$/) }
  /^diff --git/ {
    a = $3; b = $4;
    path = (a == "a//dev/null") ? b : b;
    sub(/^[ab]\//, "", path);
    count_this = (is_src(path) && !is_test(path));
  }
  /^[+-]/ && !/^(\+\+\+|---)/ { if (count_this) n++ }
  END { print n+0 }
' "$OUT/diff.patch" > "$OUT/nontest-lines.txt"

# --- stack and owning packages ---
bash "$HERE/detect-stack.sh" --repo "$REPO" --out "$OUT" --changed-files "$OUT/changed-files.txt" ${PKG_OPT:+--package "$PKG_OPT"}
# stack.env carries values from the repo's package.json (engines ">=22", "$(...)"): read it as data, never source it
while IFS='=' read -r k v; do [[ "$k" =~ ^[A-Z_]+$ ]] && printf -v "$k" '%s' "$v"; done < "$OUT/stack.env"
PKG_DIR=${PACKAGES%%:*}
PKG_LIST=(${PACKAGES//:/ })
PKG_NAME=$(jq -r '.name // ""' "$REPO/$PKG_DIR/package.json" 2>/dev/null || true)
[[ -n "$PKG_NAME" ]] || PKG_NAME=$(basename "$(cd "$REPO/$PKG_DIR" && pwd -P)")

# deps_identical TREE_A TREE_B -> 0 when the lockfile (or, with no lockfile,
# the package.json dependency sections) is identical in both trees
deps_identical() {
  if [[ -n "$LOCKFILE" ]]; then
    cmp -s "$1/$LOCKFILE" "$2/$LOCKFILE"
  else
    cmp -s <(jq -S '{d: .dependencies, dd: .devDependencies}' "$1/$PKG_ROOT/package.json" 2>/dev/null) \
           <(jq -S '{d: .dependencies, dd: .devDependencies}' "$2/$PKG_ROOT/package.json" 2>/dev/null)
  fi
}
# link_node_modules SRC_TREE DST_TREE -> symlink the root and per-package
# node_modules that exist in SRC into DST (a write under $OUT or $WORK/wt,
# never under the reviewed checkout)
link_node_modules() {
  local p
  for p in . "${PKG_LIST[@]}"; do
    if [[ -d "$1/$p/node_modules" && ! -e "$2/$p/node_modules" ]]; then
      ln -s "$(cd "$1/$p/node_modules" && pwd -P)" "$2/$p/node_modules"
    fi
  done
  return 0
}
install_deps() { # frozen-lockfile, no lifecycle scripts, scrubbed env, inside the worktree only
  local cmd=()
  case "$PM" in
    npm) cmd=(npm ci --ignore-scripts) ;;
    pnpm) cmd=(pnpm install --frozen-lockfile --ignore-scripts) ;;
    yarn-berry) cmd=(yarn install --immutable --mode=skip-build) ;;
    yarn) cmd=(yarn install --frozen-lockfile --ignore-scripts) ;;
    bun) cmd=(bun install --frozen-lockfile --ignore-scripts) ;;
    *) log "cannot install: unknown package manager"; return 1 ;;
  esac
  local st; st=$(cd "$REPO/$PKG_ROOT" && run_with_timeout "$T_TEST" "$OUT/tools/install.txt" "${SCRUB[@]}" "${cmd[@]}")
  [[ "$st" == OK ]]
}

# node_modules for the reviewed tree. MR mode (--repo is a worktree, --status-repo
# the checkout): link the checkout's when dependencies are identical, install
# with --install when they differ, else mark absent so every tool row says so.
NM_REASON="" NM_HINT=""
if [[ -e "$REPO/$PKG_DIR/node_modules" || -e "$REPO/node_modules" ]]; then
  NODE_MODULES=present
elif [[ "$REPO" != "$STATUS_REPO" ]] && deps_identical "$REPO" "$STATUS_REPO"; then
  link_node_modules "$STATUS_REPO" "$REPO"; NODE_MODULES=linked-from-checkout
elif [[ $INSTALL -eq 1 ]]; then
  [[ "$REPO" != "$STATUS_REPO" ]] || die "refusing to install into the reviewed checkout; --install is for MR worktrees only"
  if install_deps; then NODE_MODULES=installed; else NODE_MODULES=absent; NM_REASON=install-failed; NM_HINT="see tools/install.txt"; fi
else
  NODE_MODULES=absent
  if [[ "$REPO" != "$STATUS_REPO" ]]; then NM_REASON=lockfile-differs; NM_HINT="rerun with --install"; else NM_REASON=no-node_modules; NM_HINT="run $PM install in the repo first"; fi
fi

# changed-packages.txt: workspace package names, or the changed source directories' basenames; never `.`
: > "$OUT/changed-packages.txt"
if [[ "$WORKSPACES" == 1 ]]; then
  for p in ${PACKAGES//:/ }; do
    n=$(jq -r '.name // ""' "$REPO/$p/package.json" 2>/dev/null || true)
    [[ -n "$n" ]] || n=$(basename "$p")
    [[ "$n" != "." ]] && echo "$n"
  done | sort -u > "$OUT/changed-packages.txt"
else
  while read -r f; do d=$(dirname "$f"); [[ "$d" != "." ]] && basename "$d"; done < "$OUT/changed-src-files.txt" | sort -u > "$OUT/changed-packages.txt" || true
fi

{
  echo "REPO=$REPO"; echo "BASE=$BASE"; echo "HEAD=$HEAD"; echo "HEAD_SHA=$HEAD_SHA"
  echo "MERGE_BASE=$MB"; echo "MODE=$MODE"; echo "PKG_DIR=$PKG_DIR"; echo "PKG_NAME=$PKG_NAME"
  echo "NODE_MODULES=$NODE_MODULES"
} > "$OUT/meta.env"

# --- tools ---
# One pass per owning package. With several packages each pass writes under
# tools/<slug>/ and every summary detail starts with the package name.
DETAIL_PREFIX=""
summary() { printf '%s\t%s\t%s\n' "$1" "$2" "${DETAIL_PREFIX}$3" >> "$OUT/tools/summary.txt"; }
TOOLS="typecheck lint metrics test coverage audit"
: > "$OUT/tools/summary.txt"
if [[ $NO_TOOLS -eq 1 ]]; then
  for t in $TOOLS; do summary "$t" "UNAVAILABLE(skipped)" "--no-tools"; done
  exit 0
fi
MULTI=0; [[ ${#PKG_LIST[@]} -gt 1 ]] && MULTI=1

# Merge-base baseline: a second worktree so typecheck and metrics can report
# only what the change introduced. It shares node_modules by symlink when the
# dependencies are identical; otherwise there is no baseline and the rules
# fall back to hunk filtering (the summary detail says so).
BASE_WT="$OUT/base"; BASELINE=""
cleanup_base() {
  git -C "$REPO" worktree remove --force "$BASE_WT" >/dev/null 2>&1 || rm -rf "$BASE_WT"
  git -C "$REPO" worktree prune >/dev/null 2>&1 || true
}
if git -C "$REPO" worktree add -q --detach "$BASE_WT" "$MB" 2>"$OUT/tools/base-worktree.txt"; then
  trap cleanup_base EXIT
  if [[ "$NODE_MODULES" != absent ]] && deps_identical "$REPO" "$BASE_WT"; then
    link_node_modules "$REPO" "$BASE_WT"
  else
    BASELINE="lockfile-differs"
  fi
else
  BASELINE="no-worktree"
fi

# tsc_flags TSC PKG_ABS TAG -> extra flags: redirect the .tsbuildinfo that an
# incremental or composite project would otherwise write into the repo
tsc_flags() {
  if (cd "$2" && "$1" -p tsconfig.json --showConfig 2>/dev/null | jq -e '((.compilerOptions.incremental // false) or (.compilerOptions.composite // false))' >/dev/null 2>&1); then
    printf '%s\n' --tsBuildInfoFile "$TOOLS_DIR/tsbuildinfo-$3"
  fi
}
count_ts_errors() { grep -cE '^[^(]+\([0-9]+,[0-9]+\): error TS[0-9]+: ' "$1" 2>/dev/null || true; }
run_typecheck() {
  if [[ "$TS" != 1 || ! -f "$PKG_ABS/tsconfig.json" ]]; then summary typecheck "UNAVAILABLE(not-typescript)" ""; return; fi
  if [[ "$NODE_MODULES" == absent ]]; then summary typecheck "UNAVAILABLE($NM_REASON)" "$NM_HINT"; return; fi
  local tsc; tsc=$(find_bin tsc "$PKG")
  [[ -n "$tsc" ]] || { summary typecheck "UNAVAILABLE(no-binary)" "tsc not in node_modules/.bin"; return; }
  local extra=() l; while IFS= read -r l; do extra+=("$l"); done < <(tsc_flags "$tsc" "$PKG_ABS" head)
  local s0=$SECONDS st
  st=$(cd "$PKG_ABS" && run_with_timeout "$T_TYPECHECK" "$TOOLS_DIR/typecheck.txt" "$tsc" --noEmit -p tsconfig.json --pretty false ${extra[@]+"${extra[@]}"})
  case $st in
    TIMEOUT) summary typecheck "UNAVAILABLE(timeout)" "${T_TYPECHECK}s"; return ;;
    MISSING) summary typecheck "UNAVAILABLE(missing)" "tsc not executable"; return ;;
  esac
  local base_file="-" note=""
  if [[ -n "$BASELINE" ]]; then note=", no-baseline($BASELINE)"
  elif [[ ! -f "$BASE_WT/$PKG/tsconfig.json" ]]; then note=", no-baseline(new-package)"
  else
    local btsc; btsc=$(find_bin tsc "$PKG" "$BASE_WT")
    if [[ -z "$btsc" ]]; then note=", no-baseline(no-binary)"
    else
      local bextra=(); while IFS= read -r l; do bextra+=("$l"); done < <(tsc_flags "$btsc" "$BASE_WT/$PKG" base)
      local budget=$((T_TYPECHECK - (SECONDS - s0))); [[ $budget -lt 1 ]] && budget=1
      local stb; stb=$(cd "$BASE_WT/$PKG" && run_with_timeout "$budget" "$TOOLS_DIR/typecheck-base.txt" "$btsc" --noEmit -p tsconfig.json --pretty false ${bextra[@]+"${bextra[@]}"})
      if [[ $stb == TIMEOUT ]]; then note=", no-baseline(timeout)"; else base_file="$TOOLS_DIR/typecheck-base.txt"; fi
    fi
  fi
  bash "$HERE/typecheck-diff.sh" "$TOOLS_DIR/typecheck.txt" "$base_file" > "$TOOLS_DIR/typecheck-new.txt"
  local n_head n_new; n_head=$(count_ts_errors "$TOOLS_DIR/typecheck.txt"); n_new=$(grep -c . "$TOOLS_DIR/typecheck-new.txt" || true)
  [[ $MULTI -eq 1 ]] && sed "s#^#$PKG/#" "$TOOLS_DIR/typecheck-new.txt" >> "$OUT/tools/typecheck-new.txt"
  local status=OK; [[ $n_new -gt 0 ]] && status=FAIL
  summary typecheck "$status" "$n_new new, $((n_head - n_new)) pre-existing$note"
}

TOOLBELT="$HERE/../toolbelt"
# pkg_files LIST... -> the listed repo-relative paths that belong to PKG, made relative to it
pkg_files() {
  local f
  cat "$@" | while read -r f; do
    [[ -n "$f" ]] || continue
    if [[ "$PKG" == "." ]]; then echo "$f"; elif [[ "$f" == "$PKG/"* ]]; then echo "${f#"$PKG"/}"; fi
  done
}
run_lint() {
  local files=() f bin cfg=() suffix="" st n
  while IFS= read -r f; do files+=("$f"); done < <(pkg_files "$OUT/changed-src-files.txt" "$OUT/changed-test-files.txt")
  [[ ${#files[@]} -gt 0 ]] || { summary lint "UNAVAILABLE(no-changed-files)" ""; return; }
  case "$LINTER" in
    eslint|biome)
      [[ "$NODE_MODULES" != absent ]] || { summary lint "UNAVAILABLE($NM_REASON)" "$NM_HINT"; return; }
      bin=$(find_bin "$LINTER" "$PKG")
      [[ -n "$bin" ]] || { summary lint "UNAVAILABLE(no-linter-binary)" "$LINTER not in node_modules/.bin"; return; }
      ;;
    *)
      bin="$TOOLBELT/node_modules/.bin/eslint"; cfg=(--no-config-lookup -c "$TOOLBELT/eslint.strict.config.js"); suffix=" (strict fallback)"
      [[ -x "$bin" ]] || { summary lint "UNAVAILABLE(no-toolbelt)" "bash install.sh --toolbelt-only"; return; }
      ;;
  esac
  if [[ "$LINTER" == biome ]]; then
    # Biome's JSON carries byte spans, not lines: kept whole as evidence, never hunk-filtered.
    st=$(cd "$PKG_ABS" && run_with_timeout "$T_LINT" "$TOOLS_DIR/lint.json" "$bin" lint --reporter=json "${files[@]}")
    case $st in TIMEOUT) summary lint "UNAVAILABLE(timeout)" "${T_LINT}s"; return ;; MISSING) summary lint "UNAVAILABLE(missing)" ""; return ;; esac
    n=$(jq '.diagnostics | length' "$TOOLS_DIR/lint.json" 2>/dev/null || echo "?")
    if [[ $st == OK ]]; then summary lint OK "$n diagnostics (biome, unfiltered)"; else summary lint FAIL "$n diagnostics (biome, unfiltered)"; fi
    return
  fi
  st=$(cd "$PKG_ABS" && run_with_timeout "$T_LINT" "$TOOLS_DIR/lint.txt" "$bin" ${cfg[@]+"${cfg[@]}"} -f json -o "$TOOLS_DIR/lint.json" "${files[@]}")
  case $st in TIMEOUT) summary lint "UNAVAILABLE(timeout)" "${T_LINT}s"; return ;; MISSING) summary lint "UNAVAILABLE(missing)" ""; return ;; esac
  [[ -f "$TOOLS_DIR/lint.json" ]] || { summary lint "UNAVAILABLE(lint-error)" "$(head -1 "$TOOLS_DIR/lint.txt" | cut -c1-120)"; return; }
  n=$(bash "$HERE/lint-changed.sh" "$TOOLS_DIR/lint.json" "$OUT/added-lines.tsv" "$REPO" "$TOOLS_DIR/lint-changed.json")
  if [[ $MULTI -eq 1 ]]; then
    jq -s 'add' "$OUT/tools/lint-changed.json" "$TOOLS_DIR/lint-changed.json" > "$OUT/tools/.lc" && mv "$OUT/tools/.lc" "$OUT/tools/lint-changed.json"
  fi
  if [[ "$n" -gt 0 ]]; then summary lint FAIL "$n new$suffix"; else summary lint OK "0 new$suffix"; fi
}
run_metrics() {
  local files=() f bin="$TOOLBELT/node_modules/.bin/eslint" cfg="$TOOLBELT/eslint.metrics.config.js" st
  [[ -x "$bin" ]] || { summary metrics "UNAVAILABLE(no-toolbelt)" "bash install.sh --toolbelt-only"; return; }
  while IFS= read -r f; do files+=("$f"); done < <(pkg_files "$OUT/changed-src-files.txt")
  [[ ${#files[@]} -gt 0 ]] || { summary metrics "UNAVAILABLE(no-changed-files)" ""; return; }
  local s0=$SECONDS
  st=$(cd "$PKG_ABS" && run_with_timeout "$T_METRICS" "$TOOLS_DIR/metrics.txt" "$bin" --no-config-lookup -c "$cfg" -f json -o "$TOOLS_DIR/metrics.json" "${files[@]}")
  case $st in TIMEOUT) summary metrics "UNAVAILABLE(timeout)" "${T_METRICS}s"; return ;; MISSING) summary metrics "UNAVAILABLE(missing)" ""; return ;; esac
  [[ -f "$TOOLS_DIR/metrics.json" ]] || { summary metrics "UNAVAILABLE(metrics-error)" "$(head -1 "$TOOLS_DIR/metrics.txt" | cut -c1-120)"; return; }
  # baseline: the same files as they exist at the merge-base
  local base_json="-" base_root="-" note="" budget
  if [[ -n "$BASELINE" ]]; then note=", no-baseline($BASELINE)"
  elif [[ -d "$BASE_WT/$PKG" ]]; then
    local bfiles=()
    for f in "${files[@]}"; do [[ -f "$BASE_WT/$PKG/$f" ]] && bfiles+=("$f"); done
    if [[ ${#bfiles[@]} -eq 0 ]]; then
      echo '[]' > "$TOOLS_DIR/metrics-base.json"; base_json="$TOOLS_DIR/metrics-base.json"; base_root="$BASE_WT"
    else
      budget=$((T_METRICS - (SECONDS - s0))); [[ $budget -lt 1 ]] && budget=1
      local stb; stb=$(cd "$BASE_WT/$PKG" && run_with_timeout "$budget" "$TOOLS_DIR/metrics-base.txt" "$bin" --no-config-lookup -c "$cfg" -f json -o "$TOOLS_DIR/metrics-base.json" "${bfiles[@]}")
      if [[ $stb == TIMEOUT || ! -f "$TOOLS_DIR/metrics-base.json" ]]; then note=", no-baseline(timeout)"; else base_json="$TOOLS_DIR/metrics-base.json"; base_root="$BASE_WT"; fi
    fi
  else note=", no-baseline(new-package)"; fi
  # duplication across the whole package, filtered to clones touching added lines
  local jscpd="$TOOLBELT/node_modules/.bin/jscpd" dup="-"
  if [[ -x "$jscpd" ]]; then
    budget=$((T_METRICS - (SECONDS - s0))); [[ $budget -lt 1 ]] && budget=1
    (cd "$PKG_ABS" && run_with_timeout "$budget" "$TOOLS_DIR/jscpd.txt" "$jscpd" -c "$TOOLBELT/jscpd.json" -o "$TOOLS_DIR/jscpd" --silent . >/dev/null) || true
    [[ -f "$TOOLS_DIR/jscpd/jscpd-report.json" ]] && dup="$TOOLS_DIR/jscpd/jscpd-report.json"
  fi
  local line; line=$(bash "$HERE/metrics-report.sh" "$TOOLS_DIR/metrics.json" "$REPO" "$base_json" "$base_root" "$dup" "$OUT/added-lines.tsv" "$TOOLS_DIR")
  if [[ $MULTI -eq 1 ]]; then
    cat "$TOOLS_DIR/metrics.tsv" >> "$OUT/tools/metrics.tsv"; cat "$TOOLS_DIR/metrics-preexisting.tsv" >> "$OUT/tools/metrics-preexisting.tsv"
  fi
  local n=${line%% *}
  if [[ "$n" -gt 0 ]]; then summary metrics FAIL "$line$note"; else summary metrics OK "$line$note"; fi
}

run_test() {
  local reason=""
  case "$RUNNER" in
    none) reason="no-runner" ;;
    mocha|ava|bun-test) reason="unsupported-runner" ;;
  esac
  if [[ -n "$reason" ]]; then summary test "UNAVAILABLE($reason)" "$RUNNER"; summary coverage "UNAVAILABLE($reason)" ""; return; fi
  local tms f rel_src=() rel_test=() st report="" cov_note="" cmd=() cov=()
  tms=$(runner_timeout_ms)
  while IFS= read -r f; do rel_src+=("$f"); done < <(pkg_files "$OUT/changed-src-files.txt")
  while IFS= read -r f; do rel_test+=("$f"); done < <(pkg_files "$OUT/changed-test-files.txt")
  mkdir -p "$TOOLS_DIR/coverage"
  case "$RUNNER" in
    node-test)
      report="$TOOLS_DIR/test.txt"
      cmd=(node --test --test-reporter=tap --test-reporter-destination="$report" --experimental-test-coverage --test-reporter=lcov --test-reporter-destination="$TOOLS_DIR/coverage/lcov.info" --test-timeout="$tms")
      st=$(cd "$PKG_ABS" && run_with_timeout "$T_TEST" "$TOOLS_DIR/test-stdout.txt" "${SCRUB[@]}" "${cmd[@]}")
      ;;
    vitest|jest)
      if [[ "$NODE_MODULES" == absent ]]; then summary test "UNAVAILABLE($NM_REASON)" "$NM_HINT"; summary coverage "UNAVAILABLE($NM_REASON)" ""; return; fi
      local bin; bin=$(find_bin "$RUNNER" "$PKG")
      [[ -n "$bin" ]] || { summary test "UNAVAILABLE(no-runner-binary)" "$RUNNER not in node_modules/.bin"; summary coverage "UNAVAILABLE(no-runner-binary)" ""; return; }
      report="$TOOLS_DIR/test.json"
      if [[ $RUNNER == vitest ]]; then
        local mode=(run)
        [[ $FULL_TESTS -eq 0 && ${#rel_src[@]} -gt 0 ]] && mode=(related "${rel_src[@]}" ${rel_test[@]+"${rel_test[@]}"} --run)
        cmd=("$bin" "${mode[@]}" --reporter=json --outputFile="$report" --testTimeout="$tms" --passWithNoTests)
        # reportOnFailure: without it Vitest writes no coverage when any test fails
        cov=(--coverage.enabled --coverage.reportOnFailure --coverage.reporter=lcov --coverage.reportsDirectory="$TOOLS_DIR/coverage")
        st=$(cd "$PKG_ABS" && run_with_timeout "$T_TEST" "$TOOLS_DIR/test-stdout.txt" "${SCRUB[@]}" "${cmd[@]}" "${cov[@]}")
        if [[ ! -f "$TOOLS_DIR/coverage/lcov.info" ]] && grep -qiE 'coverage' "$TOOLS_DIR/test-stdout.txt" && grep -qE 'Cannot find|MODULE_NOT_FOUND|not installed|Failed to load' "$TOOLS_DIR/test-stdout.txt"; then
          cov_note="no-coverage-provider"
          st=$(cd "$PKG_ABS" && run_with_timeout "$T_TEST" "$TOOLS_DIR/test-stdout.txt" "${SCRUB[@]}" "${cmd[@]}")
        fi
      else
        cmd=("$bin" --ci --json --outputFile="$report" --coverage --coverageDirectory="$TOOLS_DIR/coverage" --coverageReporters=lcov --testTimeout="$tms" --passWithNoTests)
        [[ $FULL_TESTS -eq 0 && ${#rel_src[@]} -gt 0 ]] && cmd+=(--findRelatedTests "${rel_src[@]}" ${rel_test[@]+"${rel_test[@]}"})
        st=$(cd "$PKG_ABS" && run_with_timeout "$T_TEST" "$TOOLS_DIR/test-stdout.txt" "${SCRUB[@]}" "${cmd[@]}")
      fi
      ;;
  esac
  case $st in
    TIMEOUT) summary test "UNAVAILABLE(timeout)" "${T_TEST}s"; summary coverage "UNAVAILABLE(timeout)" ""; return ;;
    MISSING) summary test "UNAVAILABLE(missing)" "runner not executable"; summary coverage "UNAVAILABLE(missing)" ""; return ;;
  esac
  if [[ ! -s "$report" ]]; then
    summary test "UNAVAILABLE(run-error)" "$(head -1 "$TOOLS_DIR/test-stdout.txt" 2>/dev/null | cut -c1-120)"; summary coverage "UNAVAILABLE(run-error)" ""; return
  fi
  local prefix=""; [[ "$PKG" != "." ]] && prefix="$PKG/"
  if ! bash "$HERE/classify-tests.sh" "$RUNNER" "$report" > "$TOOLS_DIR/.classified" 2> "$TOOLS_DIR/classify.txt"; then
    summary test "UNAVAILABLE(bad-report)" "$(head -1 "$TOOLS_DIR/classify.txt" | cut -c1-120)"; summary coverage "UNAVAILABLE(bad-report)" ""; rm -f "$TOOLS_DIR/.classified"; return
  fi
  sed "s#^$PKG_ABS/#$prefix#" "$TOOLS_DIR/.classified" > "$TOOLS_DIR/test-classified.txt"; rm -f "$TOOLS_DIR/.classified"
  local counts p fl n
  counts=$(tail -1 "$TOOLS_DIR/test-classified.txt")
  p=$(sed -E 's/.*PASS=([0-9]+).*/\1/' <<<"$counts"); fl=$(sed -E 's/.*FAIL=([0-9]+).*/\1/' <<<"$counts"); n=$(sed -E 's/.*NOT_RUNNABLE=([0-9]+).*/\1/' <<<"$counts")
  [[ $MULTI -eq 1 ]] && grep -v '^PASS=' "$TOOLS_DIR/test-classified.txt" >> "$OUT/tools/test-classified.txt"
  local detail="$p pass, $fl failing, $n not runnable locally (scrubbed env)"
  if [[ "$fl" -gt 0 ]]; then summary test FAIL "$detail"; else summary test OK "$detail"; fi
  if [[ -n "$cov_note" ]]; then summary coverage "UNAVAILABLE($cov_note)" "install @vitest/coverage-v8 in the repo"; return; fi
  [[ -f "$TOOLS_DIR/coverage/lcov.info" ]] || { summary coverage "UNAVAILABLE(no-lcov)" "runner wrote no lcov.info"; return; }
  # lines under test are this package's changed source files: not tests, not docs
  awk -F'\t' -v pkg="$PKG" 'FILENAME == ARGV[1] { if (pkg == "." || index($0, pkg "/") == 1) src[$0] = 1; next } ($1 in src)' \
    "$OUT/changed-src-files.txt" "$OUT/added-lines.tsv" > "$TOOLS_DIR/added-src.tsv"
  bash "$HERE/coverage-changed.sh" "$TOOLS_DIR/coverage/lcov.info" "$TOOLS_DIR/added-src.tsv" "$REPO" "$PKG" > "$TOOLS_DIR/coverage-changed.txt"
  local tot nr; tot=$(tail -1 "$TOOLS_DIR/coverage-changed.txt"); tot=${tot#TOTAL=}
  nr=$(grep -c $'\tNO_RECORD$' "$TOOLS_DIR/coverage-changed.txt" || true)
  [[ $MULTI -eq 1 ]] && grep -v '^TOTAL=' "$TOOLS_DIR/coverage-changed.txt" >> "$OUT/tools/coverage-changed.txt"
  local detail="$tot changed lines"
  [[ "$nr" -eq 1 ]] && detail+=", 1 changed file not loaded by any test"
  [[ "$nr" -gt 1 ]] && detail+=", $nr changed files not loaded by any test"
  summary coverage OK "$detail"
}

run_audit() {
  # only when this change touched the dependency set: the audit sends the
  # dependency list to the registry, so it is not run casually
  local dep_changed=0 pj="$PKG/package.json" cmd=() st line hc head_lock="-" base_lock="-"
  [[ "$PKG" == "." ]] && pj="package.json"
  grep -qxF "$pj" "$OUT/changed-files.txt" && dep_changed=1
  [[ -n "$LOCKFILE" ]] && grep -qxF "$LOCKFILE" "$OUT/changed-files.txt" && dep_changed=1
  if [[ $FULL_AUDIT -eq 0 && $dep_changed -eq 0 ]]; then summary audit "UNAVAILABLE(skipped)" "lockfile unchanged"; return; fi
  case "$PM" in
    npm) cmd=(npm audit --json) ;;
    pnpm) cmd=(pnpm audit --json) ;;
    *) summary audit "UNAVAILABLE(unsupported-audit)" "$PM"; return ;;
  esac
  st=$(cd "$PKG_ABS" && run_with_timeout "$T_AUDIT" "$TOOLS_DIR/audit.json" "${SCRUB[@]}" "${cmd[@]}")
  case $st in
    TIMEOUT) summary audit "UNAVAILABLE(timeout)" "${T_AUDIT}s"; return ;;
    MISSING) summary audit "UNAVAILABLE(missing)" "$PM not on PATH"; return ;;
  esac
  if ! jq -e 'type == "object" and (has("vulnerabilities") or has("advisories"))' "$TOOLS_DIR/audit.json" >/dev/null 2>&1; then
    summary audit "UNAVAILABLE(run-error)" "$(head -c 120 "$TOOLS_DIR/audit.json" | tr '\n\t' '  ')"; return
  fi
  if [[ -n "$LOCKFILE" && -f "$REPO/$LOCKFILE" ]]; then
    head_lock="$REPO/$LOCKFILE"
    if git -C "$REPO" show "$MB:$LOCKFILE" > "$TOOLS_DIR/lock-base" 2>/dev/null; then base_lock="$TOOLS_DIR/lock-base"; fi
  fi
  line=$(bash "$HERE/audit-report.sh" "$PM" "$TOOLS_DIR/audit.json" "$head_lock" "$base_lock" "$TOOLS_DIR/audit-new.tsv") || { summary audit "UNAVAILABLE(run-error)" "audit-report.sh failed"; return; }
  [[ $MULTI -eq 1 ]] && cat "$TOOLS_DIR/audit-new.tsv" >> "$OUT/tools/audit-new.tsv"
  hc=$(sed -E 's/.*\(([0-9]+) high\/critical\).*/\1/' <<<"$line")
  if [[ "$hc" -gt 0 ]]; then summary audit FAIL "$line (registry queried)"; else summary audit OK "$line (registry queried)"; fi
}

if [[ $MULTI -eq 1 ]]; then
  : > "$OUT/tools/typecheck-new.txt"; : > "$OUT/tools/metrics.tsv"; : > "$OUT/tools/metrics-preexisting.tsv"; echo '[]' > "$OUT/tools/lint-changed.json"
  : > "$OUT/tools/test-classified.txt"; : > "$OUT/tools/coverage-changed.txt"; : > "$OUT/tools/audit-new.tsv"
fi
for PKG in "${PKG_LIST[@]}"; do
  PKG_ABS=$(cd "$REPO/$PKG" && pwd -P)
  if [[ $MULTI -eq 1 ]]; then
    TOOLS_DIR="$OUT/tools/$(pkg_slug "$PKG")"
    label=$(jq -r '.name // ""' "$PKG_ABS/package.json" 2>/dev/null || true); [[ -n "$label" ]] || label=$(basename "$PKG_ABS")
    DETAIL_PREFIX="$label: "
  else
    TOOLS_DIR="$OUT/tools"; DETAIL_PREFIX=""
  fi
  mkdir -p "$TOOLS_DIR"
  run_typecheck
  run_lint
  run_metrics
  run_test
  run_audit
done
