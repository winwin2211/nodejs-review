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
grep -q 'NO_RECORD' "$R/checklist-sdd-tdd.md" && pass || fail "sdd-tdd treats a file no test loaded as unexecuted"
grep -q 'not loaded by any test' "$R/report-format.md" && pass || fail "report names changed files no test loaded"
grep -q 'scrubbed env' "$R/report-format.md" && pass || fail "report names the scrubbed environment"

# tooling: the prune variable, the forbidden list, budgets, the tools table
grep -q 'ASSERT_CLEAN_PRUNE=node_modules' "$R/tooling.md" && pass || fail "tooling sets the prune list"
grep -qi 'never' "$R/tooling.md" && grep -q 'npx' "$R/tooling.md" && pass || fail "tooling forbids npx"
grep -q 'NODEJS_REVIEW_TIMEOUT_' "$R/tooling.md" && pass || fail "tooling documents budgets"
for t in typecheck lint metrics test coverage audit; do
  grep -q "\`$t\`" "$R/tooling.md" || grep -q "^| $t" "$R/tooling.md" || grep -q "$t " "$R/tooling.md" && pass || fail "tooling mentions the $t row"
done
grep -q 'REVIEW_TOOL=nodejs-review' "$R/tooling.md" && pass || fail "tooling sets REVIEW_TOOL"

# gitlab.md is go-review's with our name
grep -q 'nodejs-review' "$R/gitlab.md" && pass || fail "gitlab.md names nodejs-review"
grep -q 'go-review' "$R/gitlab.md" && fail "gitlab.md still says go-review" || pass

finish
