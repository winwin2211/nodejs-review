#!/usr/bin/env bash
# Detect the Node.js stack of a repository into $OUT/stack.env.
#
#   detect-stack.sh --repo R --out O [--changed-files F] [--package DIR]
#
# Keys written: PM LOCKFILE TS RUNNER LINTER WORKSPACES PACKAGES
# PACKAGES_OVERFLOW NODE ENGINES ENGINES_MATCH PKG_ROOT. Nothing is executed
# from the repository; only files are read.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/lib.sh"
command -v jq >/dev/null || die "jq not found on PATH"

REPO="" OUT="" CHANGED="" FORCE_PKG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --changed-files) CHANGED=$2; shift 2 ;;
    --package) FORCE_PKG=$2; shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done
[[ -n "$REPO" && -n "$OUT" ]] || die "usage: detect-stack.sh --repo R --out O [--changed-files F] [--package DIR]"
REPO=$(cd "$REPO" && pwd -P)
assert_outside "$OUT" "$REPO"
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd -P)

# --- package root: the repo root, else the shallowest package.json ---
if [[ -f "$REPO/package.json" ]]; then
  PKG_ROOT="."
else
  PKG_ROOT=$(cd "$REPO" && find . \( -name node_modules -o -name .git \) -prune -o -name package.json -print 2>/dev/null |
    awk '{ n = gsub("/", "/"); print n "\t" $0 }' | sort -n | head -1 | cut -f2 | xargs -I{} dirname {} | sed 's#^\./##')
  [[ -n "$PKG_ROOT" ]] || die "not a Node.js repo: no package.json under $REPO"
fi
PKG_JSON="$REPO/$PKG_ROOT/package.json"
# pj FILTER -> its output from package.json, a line break inside a string read as a space
pj() { jq -r "($1) | if type == \"string\" then gsub(\"[\\r\\n]\"; \" \") else . end" "$PKG_JSON" 2>/dev/null || true; }
rel() { # path relative to repo, no leading ./
  local p=$1; p=${p#"$REPO"/}; p=${p#./}; printf '%s\n' "$p"
}
in_pkg_root() { [[ -e "$REPO/$PKG_ROOT/$1" ]]; }

# --- package manager ---
PM=unknown LOCKFILE=""
pm_field=$(pj '.packageManager // ""')
if [[ -n "$pm_field" ]]; then
  name=${pm_field%%@*}; ver=${pm_field#*@}; major=${ver%%.*}
  case "$name" in
    npm) PM=npm ;; pnpm) PM=pnpm ;; bun) PM=bun ;;
    yarn) if [[ "$major" =~ ^[0-9]+$ && "$major" -ge 2 ]] || in_pkg_root .yarnrc.yml; then PM=yarn-berry; else PM=yarn; fi ;;
  esac
fi
for lf in package-lock.json npm-shrinkwrap.json pnpm-lock.yaml yarn.lock bun.lock bun.lockb; do
  if in_pkg_root "$lf"; then
    LOCKFILE=$(rel "$PKG_ROOT/$lf")
    if [[ "$PM" == unknown ]]; then
      case "$lf" in
        package-lock.json|npm-shrinkwrap.json) PM=npm ;;
        pnpm-lock.yaml) PM=pnpm ;;
        yarn.lock) if in_pkg_root .yarnrc.yml; then PM=yarn-berry; else PM=yarn; fi ;;
        bun.lock|bun.lockb) PM=bun ;;
      esac
    fi
    break
  fi
done

# --- workspaces ---
WORKSPACES=0
ws_globs=$(pj '(.workspaces // empty) | if type == "array" then .[] else (.packages // [])[] end')
if [[ -z "$ws_globs" ]] && in_pkg_root pnpm-workspace.yaml; then
  ws_globs=$(awk '/^packages:/ { on = 1; next } on && /^[[:space:]]*-/ { s = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", s); gsub(/["'\'']/, "", s); print s; next } on && !/^[[:space:]]/ { on = 0 }' "$REPO/$PKG_ROOT/pnpm-workspace.yaml")
fi
# ws_expand GLOB -> the directories (relative to the package root) the glob
# names that hold a package.json. A glob may match nothing, or a README; `**`
# matches any depth (bash 3.2 has no globstar); one entry may hold a space.
ws_expand() {
  local g=$1 d IFS=
  if [[ "$g" == *"**"* ]]; then
    find "./${g%%\*\**}" \( -name node_modules -o -name .git \) -prune -o -name package.json -print 2>/dev/null | sed 's#/package\.json$##'
  else
    for d in $g; do if [[ -f "$d/package.json" ]]; then printf '%s\n' "$d"; fi; done
  fi
}
ws_dirs=""
if [[ -n "$ws_globs" ]]; then
  WORKSPACES=1
  ws_dirs=$(cd "$REPO/$PKG_ROOT" && while IFS= read -r g; do
    if [[ -n "$g" && "$g" != !* ]]; then ws_expand "$g"; fi
  done <<<"$ws_globs" | while IFS= read -r d; do rel "$PKG_ROOT/$d"; done | sed 's#^\./##' | awk '$0 != "." && $0 != ""' | sort -u)
fi

# --- packages owning the changed files (at most 4) ---
PACKAGES_OVERFLOW=0
if [[ -n "$FORCE_PKG" ]]; then
  PACKAGES=$(rel "$FORCE_PKG")
elif [[ "$WORKSPACES" -eq 1 && -n "$CHANGED" && -s "$CHANGED" ]]; then
  owners=$(while read -r f; do
    [[ -z "$f" ]] && continue
    best=""
    while read -r d; do
      [[ -z "$d" ]] && continue
      if [[ "$f" == "$d/"* && ${#d} -gt ${#best} ]]; then best=$d; fi
    done <<<"$ws_dirs"
    printf '%s\n' "${best:-$PKG_ROOT}"
  done < "$CHANGED" | sort -u)
  n=$(printf '%s\n' "$owners" | grep -c . || true)
  if [[ "$n" -gt 4 ]]; then PACKAGES_OVERFLOW=1; owners=$(printf '%s\n' "$owners" | head -4); fi
  PACKAGES=$(printf '%s\n' "$owners" | paste -sd: -)
else
  PACKAGES=$PKG_ROOT
fi
[[ -n "$PACKAGES" ]] || PACKAGES=$PKG_ROOT

# --- TypeScript ---
TS=0
IFS=: read -ra pkg_list <<<"$PACKAGES"
for p in "${pkg_list[@]}" "$PKG_ROOT"; do [[ -f "$REPO/$p/tsconfig.json" ]] && TS=1; done
[[ "$(pj '(.dependencies.typescript // .devDependencies.typescript) // ""')" != "" ]] && TS=1

# --- test runner: config files, then the test script, then dependencies ---
RUNNER=none
has_cfg() { # basename-without-ext ext...
  local b=$1; shift; local e
  for e in "$@"; do in_pkg_root "$b.$e" && return 0; done
  return 1
}
if has_cfg vitest.config js ts mjs mts cjs cts || has_cfg vitest.workspace js ts mjs mts; then RUNNER=vitest
elif { for e in js ts mjs mts cjs cts; do in_pkg_root "vite.config.$e" && grep -qE '^[[:space:]]*test[[:space:]]*:' "$REPO/$PKG_ROOT/vite.config.$e" && echo hit; done; } | grep -q hit; then RUNNER=vitest
elif has_cfg jest.config js ts mjs cjs json || [[ "$(pj '.jest // ""')" != "" ]]; then RUNNER=jest
else
  script=$(pj '.scripts.test // ""')
  case "$script" in
    *"node --test"*|*"node --experimental-test"*) RUNNER=node-test ;;
    *vitest*) RUNNER=vitest ;;
    *jest*) RUNNER=jest ;;
    *mocha*) RUNNER=mocha ;;
    *"bun test"*) RUNNER=bun-test ;;
    *ava*) RUNNER=ava ;;
    *)
      deps=$(pj '((.dependencies // {}) + (.devDependencies // {})) | keys[]')
      for r in vitest jest mocha ava; do grep -qx "$r" <<<"$deps" && { RUNNER=$r; break; }; done
      ;;
  esac
fi

# --- linter ---
LINTER=none
if has_cfg eslint.config js mjs cjs ts mts cts || in_pkg_root .eslintrc || has_cfg .eslintrc js cjs json yml yaml || [[ "$(pj '.eslintConfig // ""')" != "" ]]; then LINTER=eslint
elif in_pkg_root biome.json || in_pkg_root biome.jsonc; then LINTER=biome; fi

# --- node version vs engines ---
NODE=$(node --version 2>/dev/null || echo unknown)
ENGINES=$(pj '.engines.node // ""')
ENGINES_MATCH=unknown
if [[ -n "$ENGINES" && "$NODE" =~ ^v([0-9]+)\.([0-9]+) ]]; then
  cur_major=${BASH_REMATCH[1]}; cur_minor=${BASH_REMATCH[2]}
  ENGINES_MATCH=$(awk -v range="$ENGINES" -v cm="$cur_major" -v cn="$cur_minor" '
    BEGIN {
      n = split(range, alts, /\|\|/); result = "0"; unknown = 0
      for (i = 1; i <= n; i++) {
        a = alts[i]; gsub(/^[ \t]+|[ \t]+$/, "", a)
        if (a ~ /^(>=|\^|~|>)?[0-9]+(\.[0-9]+)?(\.[0-9x]+)?$/) {
          op = a; sub(/[0-9].*/, "", op); v = a; sub(/^[^0-9]*/, "", v)
          split(v, parts, "."); M = parts[1] + 0; m = (parts[2] == "" || parts[2] == "x") ? 0 : parts[2] + 0
          ok = 0
          if (op == ">=" || op == "") { if (op == "" && v !~ /\./) ok = (cm == M); else ok = (cm > M || (cm == M && cn >= m)) }
          else if (op == ">") ok = (cm > M || (cm == M && cn > m))
          else if (op == "^") ok = (cm == M && cn >= m)
          else if (op == "~") ok = (cm == M && cn == m)
          if (ok) result = "1"
        } else unknown = 1
      }
      print (result == "1") ? "1" : (unknown ? "unknown" : "0")
    }')
fi

# one KEY=value line per key: a line break in a value (a directory name) would add a key
kv() { local v=${2//$'\n'/ }; printf '%s=%s\n' "$1" "${v//$'\r'/ }"; }
{
  kv PKG_ROOT "$PKG_ROOT"
  kv PM "$PM"
  kv LOCKFILE "$LOCKFILE"
  kv TS "$TS"
  kv RUNNER "$RUNNER"
  kv LINTER "$LINTER"
  kv WORKSPACES "$WORKSPACES"
  kv PACKAGES "$PACKAGES"
  kv PACKAGES_OVERFLOW "$PACKAGES_OVERFLOW"
  kv NODE "$NODE"
  kv ENGINES "$ENGINES"
  kv ENGINES_MATCH "$ENGINES_MATCH"
} > "$OUT/stack.env"
