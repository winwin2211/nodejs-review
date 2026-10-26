#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
SHARED="skill/scripts/lib.sh skill/scripts/find-specs.sh skill/scripts/assert-clean.sh skill/scripts/gitlab-post.sh tests/lib.sh"
SYNC="$REPO_ROOT/scripts/sync-shared.sh"

for f in $SHARED; do assert_file "$REPO_ROOT/$f" "shared copy exists: $f"; done

# the shared lib.sh names this skill from our SKILL.md, whatever REVIEW_TOOL the environment carries
r=$(REVIEW_TOOL=go-review bash -c "source '$REPO_ROOT/skill/scripts/lib.sh'; die boom" 2>&1)
assert_eq "nodejs-review: boom" "$r" "an inherited REVIEW_TOOL (go-review's) does not change our prefix"
r=$(env -u REVIEW_TOOL bash -c "source '$REPO_ROOT/skill/scripts/lib.sh'; die boom" 2>&1)
assert_eq "nodejs-review: boom" "$r" "without REVIEW_TOOL exported the prefix is still ours"

# this test never writes the real checkout: every sync below targets a copy (--root)
keep=$(tmpdir); cp "$REPO_ROOT/skill/scripts/lib.sh" "$keep/lib.sh"

# an absent sibling skips the rest of this file with exit 0 (checked by running the file again)
if [[ -z "${NR_SYNC_INNER:-}" ]]; then
  NR_SYNC_INNER=1 GO_REVIEW_DIR="$keep/absent" bash "$0" >/dev/null 2>&1; rc=$?
  assert_eq 0 "$rc" "an absent go-review sibling skips the sync test"
fi

sib="${GO_REVIEW_DIR:-$REPO_ROOT/../go-review}"
if [[ ! -d "$sib" ]]; then
  echo "notice: sibling go-review checkout absent at $sib, sync check skipped"
  finish
  exit $?
fi

# our copies match the sibling byte for byte
assert_exit 0 bash "$SYNC" --check

# a copy of our tree to check and sync into
root=$(tmpdir)
for f in $SHARED; do mkdir -p "$root/$(dirname "$f")"; cp "$REPO_ROOT/$f" "$root/$f"; done

# a diverged copy is reported by name, and --check never modifies anything
fake=$(tmpdir)
for f in $SHARED; do mkdir -p "$fake/$(dirname "$f")"; cp "$sib/$f" "$fake/$f"; done
echo "# drift" >> "$fake/skill/scripts/lib.sh"
before=$(cat "$root/skill/scripts/lib.sh")
r=$(GO_REVIEW_DIR="$fake" bash "$SYNC" --check --root "$root" 2>&1 || true)
assert_exit 1 env GO_REVIEW_DIR="$fake" bash "$SYNC" --check --root "$root"
assert_contains "$r" "lib.sh" "--check names the diverged file"
assert_not_contains "$r" "find-specs.sh" "--check does not name files that match"
assert_eq "$before" "$(cat "$root/skill/scripts/lib.sh")" "--check leaves the copy untouched"

# without --check the sibling's content replaces a drifted copy
echo "# local drift" >> "$root/skill/scripts/lib.sh"
assert_exit 1 bash "$SYNC" --check --root "$root"
bash "$SYNC" --root "$root" >/dev/null
assert_exit 0 bash "$SYNC" --check --root "$root"
assert_eq "$(cat "$sib/skill/scripts/lib.sh")" "$(cat "$root/skill/scripts/lib.sh")" "sync restores the sibling's content"

# a missing sibling is a usage error (exit 2), distinct from drift (exit 1)
assert_exit 2 env GO_REVIEW_DIR="$fake/does-not-exist" bash "$SYNC" --check

cmp -s "$keep/lib.sh" "$REPO_ROOT/skill/scripts/lib.sh" && pass || fail "the test wrote the real checkout's lib.sh"

finish
