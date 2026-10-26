# nodejs-review

High-standard code review skill for Node.js and TypeScript backends, for
Claude Code, with clean code and test-driven development as review
dimensions in their own right.

    /nodejs-review [target] [--base <ref>] [--comment] [--no-tools] [--full-tests] [--full-audit] [--install] [--package <dir>] [--spec <path>] [--skip-sdd "<reason>"]

Reviews a local diff, a branch, or a GitLab MR. Detects the package manager,
TypeScript, the test runner and the linter; runs typecheck (new errors only),
lint on changed lines, complexity/length/nesting/duplication metrics, the
related tests with changed-line coverage, and a dependency audit when the
lockfile changed; dispatches read-only specialist agents for correctness,
security, architecture, performance, clean code, and spec/test-driven
compliance; verifies findings; prints an English report with a verdict;
optionally posts to the MR. Leaves the reviewed repo untouched and proves it.

## Install

    git clone https://github.com/winwin2211/nodejs-review.git ~/Projects/personal/nodejs-review
    cd ~/Projects/personal/nodejs-review && bash install.sh

`install.sh` links `skill/` to `~/.claude/skills/nodejs-review` and each
`agents/nodejs-review-*.md` into `~/.claude/agents/` (`CLAUDE_HOME` overrides
`~/.claude`), then installs the toolbelt with `npm ci --ignore-scripts`. That
install is the only time the skill touches the network, apart from the
dependency audit (only when `package.json` or the lockfile changed, or with `--full-audit`),
`--install` in MR mode, and GitLab calls. `bash install.sh --uninstall` removes the links;
`--toolbelt-only` reinstalls the toolbelt. Open a new Claude Code session
afterwards: agents installed mid-session are not dispatchable by type.

Requires `git`, `jq`, `perl` (timeouts) and Node.js `>= 20` with `npm`.
The toolbelt's lockfile pins `eslint-visitor-keys@5.0.1`
(`^20.19.0 || ^22.13.0 || >=24`) and `brace-expansion@5.0.12`
(`20 || >=22`), so `npm ci` in `install.sh` warns (`EBADENGINE`) on Node
below 20.19, on 21, and on 22 below 22.13. The test suite passes on 22.4.0
despite that warning; the other versions in that set are not tested.
`glab` is needed for MR targets and `--comment`. The toolbelt (`skill/toolbelt/`) pins ESLint, typescript-eslint,
eslint-plugin-sonarjs, jscpd and TypeScript for the metrics and the fallback
lint. The reviewed repo's own `tsc`, linter and test runner run from its
`node_modules/.bin`: without a repo ESLint or Biome, lint uses the toolbelt's
strict config; without a repo `tsc`, typecheck is reported unavailable.

## Layout

- `skill/` — SKILL.md, references (workflow, checklists, rubric, report format), scripts, toolbelt
- `agents/` — six read-only reviewers and the verifier
- `tests/` — `bash tests/run.sh` (needs the toolbelt installed); `tests/recordings/` holds real runner output
- `fixtures/` — `make-fixtures.sh <outdir>` generates throwaway repos (`dirty`, `clean`, `ts`)
- `scripts/sync-shared.sh` — copies the language-independent core from a sibling `go-review` checkout
- `docs/superpowers/` — design spec and implementation plan

`skill/scripts/{lib,find-specs,assert-clean,gitlab-post}.sh` and `tests/lib.sh`
are shared with go-review and must stay byte-identical: change them there,
then run `bash scripts/sync-shared.sh` (`--check` reports drift;
`GO_REVIEW_DIR` points at the sibling).

## Tuning the standard

Edit `skill/references/checklist-*.md` to change what is flagged, and
`skill/references/severity-verdict.md` to change severities and the verdict.
Metric thresholds live in `skill/toolbelt/eslint.metrics.config.js` and
`skill/toolbelt/jscpd.json`; `skill/scripts/metrics-report.sh` maps them to
severities and repeats each threshold in its output, so keep it and
`checklist-clean-code.md` in step.
Tool time budgets are `NODEJS_REVIEW_TIMEOUT_<TOOL>` (TYPECHECK, LINT,
METRICS, TEST, AUDIT; seconds). Changes take effect on the next run; no
reinstall needed.
