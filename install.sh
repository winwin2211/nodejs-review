#!/usr/bin/env bash
# Symlink the nodejs-review skill and agents into a Claude Code home, then
# install the toolbelt (the only install this skill ever performs, and the
# only time it touches the network).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
CLAUDE_HOME=${CLAUDE_HOME:-$HOME/.claude}

die() { echo "install.sh: $*" >&2; exit 1; }
usage() { die "usage: install.sh [--uninstall|--toolbelt-only]"; }

link() { # target linkpath
  if [[ -L "$2" ]]; then rm "$2"; elif [[ -e "$2" ]]; then
    echo "refusing to replace non-symlink: $2" >&2; exit 1; fi
  ln -s "$1" "$2"
  echo "linked $2 -> $1"
}

unlink_if_ours() { # linkpath
  [[ -L "$1" ]] && rm "$1" && echo "removed $1" || true
}

install_toolbelt() {
  [[ "${NODEJS_REVIEW_SKIP_TOOLBELT:-0}" == 1 ]] && return 0
  [[ -f "$ROOT/skill/toolbelt/package.json" ]] || { echo "no toolbelt package.json yet; skipping toolbelt install"; return 0; }
  command -v npm >/dev/null || die "npm not found on PATH; the toolbelt needs it"
  (cd "$ROOT/skill/toolbelt" && npm ci --ignore-scripts)
  echo "toolbelt installed in $ROOT/skill/toolbelt/node_modules"
}

case "${1:-}" in
  "") ;;
  --toolbelt-only) install_toolbelt; exit 0 ;;
  --uninstall)
    unlink_if_ours "$CLAUDE_HOME/skills/nodejs-review"
    for f in "$CLAUDE_HOME"/agents/nodejs-review-*.md; do unlink_if_ours "$f"; done
    exit 0
    ;;
  *) usage ;;
esac

mkdir -p "$CLAUDE_HOME/skills" "$CLAUDE_HOME/agents"
link "$ROOT/skill" "$CLAUDE_HOME/skills/nodejs-review"
for f in "$ROOT"/agents/nodejs-review-*.md; do
  [[ -f "$f" ]] || continue
  link "$f" "$CLAUDE_HOME/agents/$(basename "$f")"
done
install_toolbelt
