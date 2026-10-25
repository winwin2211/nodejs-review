# Tooling: collecting evidence without touching the repo

All scripts live in `scripts/` next to this file. `$SKILL` is the directory
containing `SKILL.md`. `$WORK` is a directory created with `mktemp -d`; it
must be outside the reviewed repo. Scripts need `git`, `jq`, `node` and
`perl` (the timeout wrapper) on PATH. Export `REVIEW_TOOL=nodejs-review` and
`ASSERT_CLEAN_PRUNE=node_modules` before calling any of them.

`$REPO` is the user's checkout. `$REVIEW_REPO` is the tree that holds the
code under review: the same as `$REPO` in local modes, the temporary
worktree `$WORK/wt` in MR mode (`gitlab.md`). Everything that reads the
reviewed code — `collect.sh`, `find-specs.sh`, the project rule files —
takes `$REVIEW_REPO`; only the no-artifact baseline and check
(`--status-repo`, `assert-clean.sh --repo`) take `$REPO`.

## Commands

Local diff (working tree + branch vs base):

    bash "$SKILL/scripts/collect.sh" --repo "$REVIEW_REPO" --head WORKTREE --out "$WORK" [--base <ref>] [--package <dir>] [--no-tools] [--full-tests] [--full-audit]

Branch, or MR head checked out in `$WORK/wt`:

    bash "$SKILL/scripts/collect.sh" --repo "$REVIEW_REPO" --head <ref-or-sha> --out "$WORK" [--base <ref>] [--status-repo "$REPO"] [--install] [--package <dir>] [--no-tools] [--full-tests] [--full-audit]

`--status-repo` names the working tree the no-artifact baselines are taken
from; it defaults to `--repo`. Pass it whenever `--repo` is the MR worktree.
`--install` installs dependencies into that worktree (frozen lockfile, no
lifecycle scripts) when its lockfile differs from the checkout's; it is
refused when `--repo` is the checkout itself.

Spec candidates (run after collect so `changed-packages.txt` exists):

    bash "$SKILL/scripts/find-specs.sh" --repo "$REVIEW_REPO" --out "$WORK" --base <ref> --head <ref|WORKTREE> --branch "<branch>" --title "<mr title or empty>" [--spec <path>]

Final no-artifact check (always run, even after errors):

    ASSERT_CLEAN_PRUNE=node_modules bash "$SKILL/scripts/assert-clean.sh" --repo "$REPO" --out "$WORK" [--worktree "$WORK/wt"]
    rm -rf "$WORK"

## Reading the outputs

| File | Meaning |
|---|---|
| `meta.env` | `REPO, BASE, HEAD, HEAD_SHA, MERGE_BASE, MODE, PKG_DIR, PKG_NAME, NODE_MODULES` (`present`, `linked-from-checkout`, `installed`, `absent`) |
| `stack.env` | `PKG_ROOT, PM, LOCKFILE, TS, RUNNER, LINTER, WORKSPACES, PACKAGES, PACKAGES_OVERFLOW, NODE, ENGINES, ENGINES_MATCH` |
| `diff.patch`, `changed-files.txt` | unified diff; the review scope |
| `changed-src-files.txt`, `changed-test-files.txt` | existing source / test files in the diff (`*.test.*`, `*.spec.*`, `__tests__/`, `test/`, `tests/`, `__mocks__/`, `*.stories.*` are tests) |
| `changed-packages.txt` | workspace package names, or the changed source directories' basenames |
| `changed-symbols.txt` | added declarations plus the declaration enclosing every added line |
| `nontest-lines.txt` | added+removed non-test source lines; > 50 means substantive |
| `added-lines.tsv` | `file<TAB>line` for every added line (new-file numbering) |
| `tools/summary.txt` | `name<TAB>OK|FAIL|UNAVAILABLE(reason)<TAB>detail`, names `typecheck lint metrics test coverage audit`; with several packages one row per tool per package, detail prefixed `<package>: `, outputs under `tools/<slug>/` and concatenated at the top level |
| `tools/typecheck.txt`, `typecheck-base.txt`, `typecheck-new.txt` | `tsc --pretty false` at head, at the merge-base, and the errors present only at head (compared by file, code and message) |
| `tools/lint.json`, `tools/lint-changed.json` | ESLint JSON; the second filtered to added lines (Biome output is unfiltered) |
| `tools/metrics.json`, `metrics-base.json`, `tools/jscpd/jscpd-report.json` | raw toolbelt runs at head and base, raw jscpd |
| `tools/metrics.tsv`, `metrics-preexisting.tsv` | `file line metric value threshold severity function origin`; the first is findings (`new`/`hunk`), the second was already over at the merge-base |
| `tools/test.json` or `tools/test.txt` | runner report (Vitest/Jest JSON, node:test TAP) |
| `tools/test-classified.txt` | `file<TAB>test<TAB>FAIL|NOT_RUNNABLE` for failing tests, then `PASS= FAIL= NOT_RUNNABLE= SKIP=` |
| `tools/coverage/lcov.info`, `tools/coverage-changed.txt` | lcov from the runner; per changed source file (tests and docs are not lines under test) `covered total uncovered-ranges uncovered-functions`, then `TOTAL=c/t`; a file no test loaded is `0 0 <its added lines> NO_RECORD` and is not in `TOTAL` |
| `tools/audit.json`, `tools/audit-new.tsv` | raw audit; `package version severity advisory introduced|preexisting` |
| `specs.tsv`, `specs-all.txt` | spec candidates as in go-review (`path<TAB>convention<TAB>signals`) |

Interpretation rules:

- `typecheck FAIL`: every line of `typecheck-new.txt` is a BLOCKER finding
  (dimension `tools`, rule-based). Errors also present at the merge-base are
  pre-existing and never block. `no-baseline(...)` in the detail means every
  head error counted as new; say so in the report.
- `test FAIL`: every `FAIL` row of `test-classified.txt` is a BLOCKER
  (dimension `tools`, rule-based) with the failure message as evidence.
  `NOT_RUNNABLE` rows are tests that ended on an environment error under the
  scrubbed environment; they are counted in the Tools line and never affect
  the verdict. When in doubt the classifier says `FAIL`.
- `metrics FAIL`: every row of `metrics.tsv` is a clean-code finding at the
  severity in column 6 (`no-magic-numbers` rows aggregated per file).
  `metrics-preexisting.tsv` is informational.
- `coverage`: `coverage-changed.txt` feeds the SDD/TDD rules; there is no
  percentage threshold. A `NO_RECORD` row is a changed source file that no
  test loaded: every added line in it is unexecuted, and the summary detail
  counts these files (`, N changed file(s) not loaded by any test`).
- `audit FAIL`: every `introduced` row with severity `high` or `critical` is
  a BLOCKER (dimension `security`, rule-based). `preexisting` rows go to the
  pre-existing list. The audit runs only when `package.json` or the lockfile
  changed, or with `--full-audit`; it sends the dependency list to the
  registry, and the detail says `(registry queried)`.
- `lint`: `N new` counts ESLint messages on added lines; they are evidence
  for agents, never findings. `(strict fallback)` means the repo has no
  linter and the toolbelt's strict config ran. `UNAVAILABLE(...)` means no
  linter evidence; agents must then not assume the linter caught anything.
- `UNAVAILABLE(no-node_modules)`: the checkout has no `node_modules`; tell
  the user to install (the skill never does). `UNAVAILABLE(lockfile-differs)`
  (MR mode): the MR changed the lockfile; rerun with `--install`.

## Never run

Inside the reviewed repo the orchestrator and every agent must never run:
`npx`, `pnpm dlx`, `yarn dlx`, `bunx`, any `install`/`add`/`update`/`dedupe`,
`npm run <script>` or any package script, `node <file>`, `node -e`, `tsx`,
`ts-node` on repository code (a module may connect to real services on
import), `--fix`, `--write`, `-u`/`--update` (snapshots), formatters, `git
stash`, `git checkout` of files, `git add`, or any command with a redirect
into the repo. `node --check <file>` (syntax only) is allowed. If a tool is
missing, print the hint from `tools/summary.txt` and continue.

Test runs execute the repository's code by design. They run under a
scrubbed environment (`PATH HOME TMPDIR LANG LC_ALL TERM` plus `CI=true
NODE_ENV=test NO_COLOR=1`, nothing else) so variables that point at real
services are absent; a test that then fails on a missing variable or a
refused connection is `NOT_RUNNABLE`. `CI=true` also stops Vitest and Jest
from writing new snapshots and disables watch mode.

The no-artifact guarantee in `assert-clean.sh` compares tracked status,
ignored-file status, and the stash list before and after the run, and lists
every file under the repo whose mtime is newer than the marker `collect.sh`
wrote at its start. `ASSERT_CLEAN_PRUNE=node_modules` prunes `node_modules`
from that scan (tool caches such as `node_modules/.vite` live there and are
not source); `git status --ignored` still covers everything else. Outside
the guarantee: `.git` internal writes made by `git fetch` or worktree
add/remove, and a write that restores the file's previous mtime. A file the
user edits while the review runs is also listed; the banner says so. Every
worktree the skill creates is added with `-c core.hooksPath=/dev/null`, so no
git hook (husky's included) runs during the review.

## Timeouts

typecheck 180s, lint 180s, metrics 120s, test 600s, audit 120s; override with
`NODEJS_REVIEW_TIMEOUT_TYPECHECK|LINT|METRICS|TEST|AUDIT=<seconds>` in the
environment of `collect.sh`. Typecheck and metrics budgets cover the head run
and the merge-base run together; a baseline that does not fit is
`no-baseline(timeout)` and the head result stands. A wrapper timeout is
`UNAVAILABLE(timeout)`, never `FAIL`, and kills every process the tool
started. The test runner's own timeout (`--testTimeout` for Vitest and Jest,
`--test-timeout` for node:test) is set 10s below the test budget so a hung
test fails inside the runner, with its report as evidence. Suggest
`--no-tools`, `--full-tests`, or a larger `NODEJS_REVIEW_TIMEOUT_TEST` in
the report when a timeout hides evidence.
