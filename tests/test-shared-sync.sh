#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
SHARED="skill/scripts/lib.sh skill/scripts/find-specs.sh skill/scripts/assert-clean.sh skill/scripts/gitlab-post.sh tests/lib.sh"
SYNC="$REPO_ROOT/scripts/sync-shared.sh"

for f in $SHARED; do assert_file "$REPO_ROOT/$f" "shared copy exists: $f"; done

sib="${GO_REVIEW_DIR:-$REPO_ROOT/../go-review}"
if [[ ! -d "$sib" ]]; then
  echo "notice: sibling go-review checkout absent at $sib, sync check skipped"
  finish
fi

# our copies match the sibling byte for byte
assert_exit 0 bash "$SYNC" --check

# a diverged copy is reported by name, and --check never modifies anything
fake=$(tmpdir)
for f in $SHARED; do mkdir -p "$fake/$(dirname "$f")"; cp "$sib/$f" "$fake/$f"; done
echo "# drift" >> "$fake/skill/scripts/lib.sh"
before=$(cat "$REPO_ROOT/skill/scripts/lib.sh")
r=$(GO_REVIEW_DIR="$fake" bash "$SYNC" --check 2>&1 || true)
assert_exit 1 env GO_REVIEW_DIR="$fake" bash "$SYNC" --check
assert_contains "$r" "lib.sh" "--check names the diverged file"
assert_not_contains "$r" "find-specs.sh" "--check does not name files that match"
assert_eq "$before" "$(cat "$REPO_ROOT/skill/scripts/lib.sh")" "--check leaves our copy untouched"

# without --check the sibling's content replaces a drifted copy
echo "# local drift" >> "$REPO_ROOT/skill/scripts/lib.sh"
assert_exit 1 bash "$SYNC" --check
bash "$SYNC" >/dev/null
assert_exit 0 bash "$SYNC" --check
assert_eq "$(cat "$sib/skill/scripts/lib.sh")" "$(cat "$REPO_ROOT/skill/scripts/lib.sh")" "sync restores the sibling's content"

# a missing sibling is a usage error (exit 2), distinct from drift (exit 1)
assert_exit 2 env GO_REVIEW_DIR="$fake/does-not-exist" bash "$SYNC" --check

finish
