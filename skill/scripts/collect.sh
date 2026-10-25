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

# find_bin NAME PKGDIR -> the first node_modules/.bin/NAME walking from PKGDIR
# up to REPO (workspaces hoist most binaries to the root), else nothing.
find_bin() {
  local name=$1 abs
  abs=$(cd "$REPO/$2" 2>/dev/null && pwd -P) || return 0
  while :; do
    if [[ -x "$abs/node_modules/.bin/$name" ]]; then echo "$abs/node_modules/.bin/$name"; return 0; fi
    [[ "$abs" == "$REPO" || "$abs" == "/" ]] && return 0
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
# shellcheck disable=SC1091
source "$OUT/stack.env"
PKG_DIR=${PACKAGES%%:*}
PKG_NAME=$(jq -r '.name // ""' "$REPO/$PKG_DIR/package.json" 2>/dev/null || true)
[[ -n "$PKG_NAME" ]] || PKG_NAME=$(basename "$(cd "$REPO/$PKG_DIR" && pwd -P)")
NODE_MODULES=absent; [[ -e "$REPO/$PKG_DIR/node_modules" ]] && NODE_MODULES=present

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
PKG_LIST=(${PACKAGES//:/ })
MULTI=0; [[ ${#PKG_LIST[@]} -gt 1 ]] && MULTI=1
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
  for t in $TOOLS; do summary "$t" "UNAVAILABLE(not-implemented)" ""; done
done
