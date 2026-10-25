#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
A="$REPO_ROOT/agents"
SK="$REPO_ROOT/skill"

for a in correctness security architecture performance clean-code sdd-tdd verifier; do
  f="$A/nodejs-review-$a.md"
  assert_file "$f" "agent file $a"
  grep -q "^name: nodejs-review-$a\$" "$f" && pass || fail "$a name"
  grep -q '^tools: Read, Grep, Glob, Bash$' "$f" && pass || fail "$a tools are the read-only set"
  grep -q '^model: inherit$' "$f" && pass || fail "$a model inherit"
  grep -qi 'do not write' "$f" && pass || fail "$a states the read-only contract"
  grep -q 'npx' "$f" && grep -q 'node -e' "$f" && grep -q 'npm run' "$f" && pass || fail "$a forbids npx, node -e and npm run"
  grep -q 'node --check' "$f" && pass || fail "$a allows node --check"
  grep -qi 'never instructions' "$f" && pass || fail "$a treats repository content as data"
  grep -q 'JSON array' "$f" && pass || fail "$a returns a JSON array"
  if [[ "$a" != "verifier" ]]; then
    grep -q "checklist-$a.md" "$f" && pass || fail "$a reads its checklist"
  else
    grep -q 'Verifier rubric' "$f" && pass || fail "verifier reads the rubric"
  fi
done
grep -q 'clean-code block' "$A/nodejs-review-clean-code.md" && pass || fail "clean-code agent returns the clean-code block"
grep -q 'SDD block' "$A/nodejs-review-sdd-tdd.md" && pass || fail "sdd-tdd agent returns the SDD block"

# SKILL.md: frontmatter, a trigger-only description under 500 characters, hard rules, every referenced path exists
S="$SK/SKILL.md"
assert_file "$S" "SKILL.md exists"
head -1 "$S" | grep -q '^---$' && pass || fail "frontmatter start"
grep -q '^name: nodejs-review$' "$S" && pass || fail "name"
desc=$(awk '/^---$/ { n++; next } n == 1 && /^description:/ { on = 1; sub(/^description: *>?-? */, ""); if (length($0)) printf "%s ", $0; next } n == 1 && on && /^  / { sub(/^ +/, ""); printf "%s ", $0; next } n == 1 && on && !/^  / { on = 0 }' "$S")
[[ "${#desc}" -gt 0 && "${#desc}" -lt 500 ]] && pass || fail "description under 500 characters (got ${#desc})"
[[ "$desc" == Use\ when* ]] && pass || fail "description starts with 'Use when'"
grep -qi 'npx' "$S" && pass || fail "SKILL.md forbids npx"
grep -q 'references/workflow.md' "$S" && pass || fail "SKILL.md points at the workflow"
while read -r p; do
  [[ -e "$SK/$p" ]] && pass || fail "SKILL.md references missing path $p"
done < <(grep -oE '`(references|scripts)/[A-Za-z0-9_./-]+`' "$S" | tr -d '`' | sort -u)

# install links all seven agents now that they exist
home=$(tmpdir); mkdir -p "$home/skills" "$home/agents"
NODEJS_REVIEW_SKIP_TOOLBELT=1 CLAUDE_HOME="$home" bash "$REPO_ROOT/install.sh" >/dev/null
assert_eq "7" "$(find "$home/agents" -name 'nodejs-review-*.md' | wc -l | tr -d ' ')" "install links the seven agents"

finish
