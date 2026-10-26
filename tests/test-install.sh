#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
export NODEJS_REVIEW_SKIP_TOOLBELT=1

home=$(tmpdir)
mkdir -p "$home/skills" "$home/agents"

CLAUDE_HOME="$home" bash "$REPO_ROOT/install.sh" >/dev/null
assert_link "$home/skills/nodejs-review" "skill symlink created"
assert_eq "$REPO_ROOT/skill" "$(readlink "$home/skills/nodejs-review")" "skill symlink target"
for f in "$REPO_ROOT"/agents/nodejs-review-*.md; do
  [[ -f "$f" ]] || continue
  assert_link "$home/agents/$(basename "$f")" "agent symlink $(basename "$f")"
done

# idempotent
CLAUDE_HOME="$home" bash "$REPO_ROOT/install.sh" >/dev/null
assert_link "$home/skills/nodejs-review" "skill symlink survives reinstall"

# a non-symlink in the way is never replaced
rm "$home/skills/nodejs-review"; mkdir "$home/skills/nodejs-review"
assert_exit 1 env CLAUDE_HOME="$home" bash "$REPO_ROOT/install.sh"
[[ -d "$home/skills/nodejs-review" && ! -L "$home/skills/nodejs-review" ]] && pass || fail "a real directory at the link path survives"
rmdir "$home/skills/nodejs-review"

CLAUDE_HOME="$home" bash "$REPO_ROOT/install.sh" >/dev/null
CLAUDE_HOME="$home" bash "$REPO_ROOT/install.sh" --uninstall >/dev/null
[[ -e "$home/skills/nodejs-review" ]] && fail "skill symlink removed" || pass
n=$(find "$home/agents" -name 'nodejs-review-*.md' | wc -l | tr -d ' ')
assert_eq "0" "$n" "agent symlinks removed"

# unknown arguments are rejected, not silently treated as "install"
assert_exit 1 env CLAUDE_HOME="$home" bash "$REPO_ROOT/install.sh" uninstall
[[ -e "$home/skills/nodejs-review" ]] && fail "bare 'uninstall' arg must not install" || pass

# --toolbelt-only without a toolbelt is a no-op that still exits 0 and links nothing
assert_exit 0 env CLAUDE_HOME="$home" bash "$REPO_ROOT/install.sh" --toolbelt-only
[[ -e "$home/skills/nodejs-review" ]] && fail "--toolbelt-only must not link the skill" || pass

finish
