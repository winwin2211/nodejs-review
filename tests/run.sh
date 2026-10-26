#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
REPO_ROOT=$(cd .. && pwd)
# The suite runs offline, but only after the toolbelt was installed once.
if [[ -f "$REPO_ROOT/skill/toolbelt/package.json" && ! -d "$REPO_ROOT/skill/toolbelt/node_modules" ]]; then
  echo "toolbelt not installed: bash install.sh --toolbelt-only" >&2
  exit 1
fi
rc=0
for t in test-*.sh; do
  echo "== $t"
  bash "$t" || rc=1
done
exit $rc
