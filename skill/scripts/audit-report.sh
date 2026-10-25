#!/usr/bin/env bash
# Split an npm/pnpm audit into advisories this change introduced and ones that
# were already there.
#
#   audit-report.sh npm|pnpm AUDIT.json HEAD_LOCK|- BASE_LOCK|- OUT.tsv
#
# OUT.tsv rows: package<TAB>version<TAB>severity<TAB>advisory<TAB>introduced|preexisting.
# `introduced` means the vulnerable package's version at head differs from the
# merge-base lockfile (or the package, or the lockfile, is absent there).
# Prints "N introduced (H high/critical), M pre-existing". Exit 1 on an
# unsupported package manager or a file that is not an audit report.
set -euo pipefail
PM=${1:?usage: audit-report.sh npm|pnpm AUDIT.json HEAD_LOCK|- BASE_LOCK|- OUT.tsv}
AUDIT=${2:?}; HEAD_LOCK=${3:?}; BASE_LOCK=${4:?}; OUTF=${5:?}
command -v jq >/dev/null || { echo "audit-report.sh: jq not found" >&2; exit 1; }
case "$PM" in npm|pnpm) ;; *) echo "audit-report.sh: unsupported package manager: $PM" >&2; exit 1 ;; esac
jq -e 'type == "object" and (has("vulnerabilities") or has("advisories"))' "$AUDIT" >/dev/null 2>&1 ||
  { echo "audit-report.sh: not an audit report: $AUDIT" >&2; exit 1; }

# version of NAME in a lockfile: npm lockfile v2/v3 by node path or name; pnpm-lock.yaml by `name@ver` / `/name/ver` keys.
# The format is read from the content: collect.sh saves the merge-base lockfile without its extension.
lock_version() { # LOCK NAME NODEPATH
  local lock=$1 name=$2 node=$3 v=""
  [[ "$lock" != "-" && -f "$lock" ]] || { echo ""; return; }
  if jq -e 'type == "object"' "$lock" >/dev/null 2>&1; then
    v=$(jq -r --arg p "$node" --arg n "$name" '(.packages[$p].version // .packages["node_modules/" + $n].version // .dependencies[$n].version // "")' "$lock" 2>/dev/null || true)
  else
    local esc; esc=$(printf '%s' "$name" | sed 's/[][\\.^$*+?(){}|]/\\&/g')
    v=$(grep -oE "^  /?'?${esc}@[^':(]+" "$lock" 2>/dev/null | head -1 | sed -E 's#^.*@##' || true)
    [[ -n "$v" ]] || v=$(grep -oE "^  /${esc}/[^':(]+" "$lock" 2>/dev/null | head -1 | sed -E 's#^.*/##' || true)
  fi
  echo "$v"
}

# rows: name<TAB>severity<TAB>advisory<TAB>version-or-nodepath
if jq -e 'has("vulnerabilities")' "$AUDIT" >/dev/null; then
  rows=$(jq -r '.vulnerabilities | to_entries[] | .value as $v
    | ($v.via | map(select(type == "object")) | first) as $adv
    | [ $v.name, ($v.severity // "unknown"),
        (if $adv != null then (($adv.url // $adv.title // "advisory") | sub(".*/"; "")) else ("via " + (($v.via | map(select(type == "string"))) | join(","))) end),
        ($v.nodes[0] // ("node_modules/" + $v.name)) ] | @tsv' "$AUDIT")
  fmt=npm
else
  rows=$(jq -r '.advisories | to_entries[] | .value as $a
    | [ $a.module_name, ($a.severity // "unknown"), (($a.url // $a.title // "advisory") | sub(".*/"; "")), ($a.findings[0].version // "") ] | @tsv' "$AUDIT")
  fmt=v6
fi

: > "$OUTF"
intro=0; hc=0; pre=0
while IFS=$'\t' read -r name sev adv hint; do
  [[ -n "$name" ]] || continue
  if [[ $fmt == npm ]]; then
    head_v=$(lock_version "$HEAD_LOCK" "$name" "$hint")
    base_v=$(lock_version "$BASE_LOCK" "$name" "$hint")
  else
    head_v=$hint
    base_v=$(lock_version "$BASE_LOCK" "$name" "")
  fi
  if [[ "$BASE_LOCK" == "-" || -z "$base_v" || "$base_v" != "$head_v" ]]; then origin=introduced; intro=$((intro + 1)); case "$sev" in high|critical) hc=$((hc + 1)) ;; esac
  else origin=preexisting; pre=$((pre + 1)); fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$head_v" "$sev" "$adv" "$origin" >> "$OUTF"
done <<<"$rows"
echo "$intro introduced ($hc high/critical), $pre pre-existing"
