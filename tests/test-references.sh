#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
SK="$REPO_ROOT/skill"
R="$SK/references"

for f in workflow.md tooling.md severity-verdict.md report-format.md gitlab.md \
         checklist-correctness.md checklist-security.md checklist-architecture.md \
         checklist-performance.md checklist-clean-code.md checklist-sdd-tdd.md; do
  assert_file "$R/$f" "$f exists"
done

# every `references/...` or `scripts/...` path in backticks in workflow.md must exist
while read -r p; do
  [[ -e "$SK/$p" ]] && pass || fail "workflow.md references missing path $p"
done < <(grep -oE '`(references|scripts)/[A-Za-z0-9_./-]+`' "$R/workflow.md" | tr -d '`' | sort -u)

# every references/x.md (section "Heading"[, ...]) citation in workflow.md must resolve
while read -r l; do
  p=$(grep -oE 'references/[a-z-]+\.md' <<<"$l" | head -1)
  while read -r h; do
    [[ -z "$h" ]] && continue
    grep -q "^## .*$h\$" "$SK/$p" && pass || fail "heading '$h' missing in $p"
  done < <(grep -oE '"[^"]+"' <<<"$l" | tr -d '"')
done < <(grep -oE '`?references/[a-z-]+\.md`? *\(sections? "[^"]+"(, *"[^"]+")*\)' "$R/workflow.md")

# all seven agents are named in the workflow
for a in correctness security architecture performance clean-code sdd-tdd verifier; do
  grep -q "nodejs-review-$a" "$R/workflow.md" && pass || fail "workflow names agent $a"
done

# every checklist has the three structural headings
for c in correctness security architecture performance clean-code sdd-tdd; do
  f="$R/checklist-$c.md"
  grep -q '^## How to work' "$f" && pass || fail "checklist-$c has How to work"
  grep -q '^## Evidence to cite' "$f" && pass || fail "checklist-$c has Evidence to cite"
  [[ "$(grep -c '^## ' "$f")" -ge 4 ]] && pass || fail "checklist-$c has topic sections"
done

# clean-code: thresholds and the output block; sdd-tdd: coverage and .only rules; verdict additions
grep -q '> 30' "$R/checklist-clean-code.md" && pass || fail "clean-code names the BLOCKER cognitive threshold"
grep -qi 'cognitive' "$R/checklist-clean-code.md" && pass || fail "clean-code names cognitive complexity"
grep -q '^## Output' "$R/checklist-clean-code.md" && pass || fail "clean-code defines its output block"
grep -q 'coverage-changed.txt' "$R/checklist-sdd-tdd.md" && pass || fail "sdd-tdd reads changed-line coverage"
grep -q '\.only' "$R/checklist-sdd-tdd.md" && pass || fail "sdd-tdd has the .only rule"
grep -q '^## Output' "$R/checklist-sdd-tdd.md" && pass || fail "sdd-tdd defines its output block"
grep -q 'clean-code' "$R/severity-verdict.md" && pass || fail "severity lists the clean-code dimension"

# report format: the two new blocks and the tools line rules
grep -q '^CLEAN CODE' "$R/report-format.md" && pass || fail "report has the CLEAN CODE block"
grep -q 'Changed lines covered' "$R/report-format.md" && pass || fail "report has changed-line coverage"
grep -q 'NO_RECORD' "$R/tooling.md" && pass || fail "tooling explains NO_RECORD coverage rows"
grep -q 'function column is `-`' "$R/workflow.md" && pass || fail "workflow titles statement-level metric rows without a function"
grep -q 'duplication <lines> lines' "$R/workflow.md" && pass || fail "workflow titles duplication rows by the other side, not a function"
grep -q 'verify-<n>.json' "$R/workflow.md" && pass || fail "workflow hands verifiers their findings as a file in the work dir"
grep -q 'NO_RECORD' "$R/checklist-sdd-tdd.md" && pass || fail "sdd-tdd treats a file no test loaded as unexecuted"
grep -q 'not loaded by any test' "$R/report-format.md" && pass || fail "report names changed files no test loaded"
grep -q 'scrubbed env' "$R/report-format.md" && pass || fail "report names the scrubbed environment"
grep -q 'one fix removes both' "$R/severity-verdict.md" && pass || fail "dedup merges only findings with one root cause"
grep -q 'Never merge two rule-based findings' "$R/severity-verdict.md" && pass || fail "dedup keeps each metric, coverage and SDD row a separate finding"
grep -q 'same file and line' "$R/severity-verdict.md" && fail "dedup still merges on file and line alone" || pass

# the large-diff split covers every changed file, not only source: package.json, lockfiles, migrations, tests
ld=$(awk '/^Large diffs:/,/^$/' "$R/workflow.md" | tr '\n' ' ')
assert_contains "$ld" '`changed-files.txt`' "large-diff split groups every changed file"
assert_not_contains "$ld" 'split `changed-src-files.txt`' "large-diff split is not limited to source files"

# stack.env and meta.env carry package.json values: the orchestrator reads them as data
grep -qi 'never source' "$R/workflow.md" && grep -qF "sed -n 's/^BASE=//p'" "$R/workflow.md" && pass || fail "workflow reads stack.env and meta.env as data, never sources them"

# tooling: the prune variable, the forbidden list, budgets, the tools table
grep -q 'ASSERT_CLEAN_PRUNE=node_modules' "$R/tooling.md" && pass || fail "tooling sets the prune list"
grep -qi 'never' "$R/tooling.md" && grep -q 'npx' "$R/tooling.md" && pass || fail "tooling forbids npx"
grep -q 'NODEJS_REVIEW_TIMEOUT_' "$R/tooling.md" && pass || fail "tooling documents budgets"
for t in typecheck lint metrics test coverage audit; do
  grep -q "\`$t\`" "$R/tooling.md" || grep -q "^| $t" "$R/tooling.md" || grep -q "$t " "$R/tooling.md" && pass || fail "tooling mentions the $t row"
done
grep -qF 'whole seconds' "$R/tooling.md" && pass || fail "tooling says budgets are whole seconds"
# the shared scripts take our name from SKILL.md; nothing has the orchestrator export it
grep -q 'REVIEW_TOOL' "$R/tooling.md" "$R/workflow.md" && fail "tooling.md or workflow.md still exports REVIEW_TOOL" || pass
grep -q 'exports as' "$R/gitlab.md" && fail "gitlab.md still says the marker name is exported" || pass

# gitlab.md is go-review's with our name
grep -q 'nodejs-review' "$R/gitlab.md" && pass || fail "gitlab.md names nodejs-review"
grep -q 'go-review' "$R/gitlab.md" && fail "gitlab.md still says go-review" || pass
grep 'worktree add' "$R/gitlab.md" | grep -q 'core.hooksPath=/dev/null' && pass || fail "gitlab.md creates the MR worktree with repository hooks disabled"

# branch mode reviews the branch, not whatever the checkout holds
branch=$(awk '/^   - Branch name:/,/^   - MR/' "$R/workflow.md")
assert_contains "$branch" "worktree add" "workflow.md checks a branch that is not checked out into a worktree"
assert_contains "$branch" "core.hooksPath=/dev/null" "the branch worktree is made with repository hooks disabled"
assert_contains "$branch" "status --porcelain" "a dirty checkout of the branch is also reviewed from a worktree"
assert_contains "$branch" 'REVIEW_REPO=$WORK/wt' "branch mode then reviews the worktree"
step1=$(awk '/^## 1\. /,/^## 2\. /' "$R/workflow.md")
assert_not_contains "$step1" "In MR mode also pass" "step 1 passes --status-repo for any temporary worktree, not only MR mode"
grep -qF 'not checked out' "$R/tooling.md" && pass || fail "tooling.md says collect.sh refuses a --head that is not checked out"
inst=$(awk '/^5\. `--install`/,/^6\. /' "$R/workflow.md")
assert_contains "$inst" "temporary worktree" "--install is tied to the temporary worktree"
assert_not_contains "$inst" "only meaningful in MR mode" "--install also serves a branch reviewed from a worktree"
grep -q 'MR mode only' "$SK/SKILL.md" && fail "SKILL.md still limits --install to MR mode" || pass

# the verifier re-reads the reviewed tree (the worktree when there is one)
step4=$(awk '/^## 4\. /,/^## 5\. /' "$R/workflow.md")
assert_contains "$step4" 'Repo: <REVIEW_REPO>' "the verifier prompt names the reviewed tree"
assert_contains "$step4" 'Work dir: <WORK>' "the verifier prompt names the work dir"

# assert-clean: an unreadable directory, and files dated in the future
exit1=$(awk '/assert-clean.sh` exits 1/,/^$/' "$R/workflow.md")
assert_contains "$exit1" "could not read" "workflow.md names an unreadable directory as an assert-clean exit 1"
grep -qF 'Not scanned' "$R/workflow.md" && pass || fail "workflow.md says the Not scanned lines are not files to remove"
grep -qF 'cannot read' "$R/tooling.md" && pass || fail "tooling.md explains what an unreadable directory does to the scan"
grep -qF 'later than the check' "$R/tooling.md" && pass || fail "tooling.md says future mtimes are not counted"

# assert-clean exit 3 (writes git status cannot attribute: the user's editor,
# a service's log) is reported as such, never as files to remove
exit3=$(awk '/assert-clean.sh` exits 3/,/^$/' "$R/workflow.md")
assert_contains "$exit3" "WRITTEN DURING THE RUN" "workflow.md gives assert-clean exit 3 its own heading"
assert_contains "$exit3" "never tell the user to remove them" "workflow.md never has the user remove unattributed writes"
grep -qF 'exits 3 instead of 2' "$R/tooling.md" && pass || fail "tooling.md explains when assert-clean exits 3"

finish
