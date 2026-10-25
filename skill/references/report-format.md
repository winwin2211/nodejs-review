# Report format (English)

## Terminal report

Print exactly this structure. Omit a severity section when it has no
findings. Keep each finding under 12 lines.

```
nodejs-review — <repo-name> <target> vs <base> @ <short-sha>   node <NODE> (engines <ENGINES> — mismatch)
Stack: <PM> | <TypeScript|JavaScript> | <RUNNER> | <LINTER> | <N> package(s)   tools from checkout's node_modules
Tools: typecheck OK | lint 0 new | metrics 2 over | test 42 pass, 3 not runnable locally (scrubbed env) | coverage 14/19 changed lines | audit skipped (lockfile unchanged)
Verdict: REQUEST CHANGES (2 blockers, 1 major)

BLOCKER
[B1] <title> — <file>:<line>
  Evidence: <verbatim>
  Why: <why>
  Fix: <fix>
  Spec: <spec_ref>                      (only when non-empty)

MAJOR
[M1] ...

MINOR
[N1] ...

CLEAN CODE
  Complexity: max cognitive 18 (placeOrder, src/services/order_service.js:7) | longest function 64 lines (placeOrder)
  Duplication: 1 block (21 lines) src/services/legacy_order_service.js:5 <-> src/services/order_service.js:34
  Escape hatches added: as any x1, eslint-disable x1, @ts-ignore x0, @ts-expect-error x0
  Pre-existing over threshold (not blocking): <N> rows in metrics-preexisting.tsv

SDD/TDD
  Skip-SDD: <reason>                    (only when --skip-sdd "<reason>" was given)
  Change: substantive (<nontest-lines> non-test lines; new handler getOrders)   | trivial (reason)
  Spec: <path> (matched by ticket:NR-100, git-log)                           | none found (nearest: <path>, <path>)
  Plan: <path>                                                               | none
  Spec rubric: 8/10 (missing: risks/rollback, acceptance criteria)
  Requirement -> test
    AC1 valid order saved once         -> placeOrder › saves a valid order once (test/order_service.test.js:8)
    AC2 qty 0 -> InvalidQuantityError  -> placeOrder › rejects qty 0 without saving (test/order_service.test.js:15)
    AC3 repo error wrapped             -> MISSING (critical: error path of external call)
  Changed lines covered: 14/19 — uncovered: placeOrder 42-47 (src/services/order_service.js)

Needs human judgment
  - <title> — <file>:<line> (score 65): <why>

Pre-existing (not blocking)
  - <title> — <file>:<line>

No artifacts left: verified
```

Header rules: the `node` part prints `NODE` from `stack.env`; add
`(engines <ENGINES> — mismatch)` only when `ENGINES_MATCH=0`. The Stack line
ends with `tools from checkout's node_modules` when `meta.env` has
`NODE_MODULES=linked-from-checkout`, `dependencies installed in worktree`
when `installed`, and `no node_modules: tool evidence unavailable` when
`absent`.

Tools line rules, one entry per row of `tools/summary.txt` in order
`typecheck lint metrics test coverage audit`:
- `typecheck`: `OK`, `N new` on FAIL, `unavailable (<reason>)`; append
  `, no baseline` when the detail says `no-baseline`.
- `lint`: `N new`, with ` (strict fallback)` or ` (biome, unfiltered)` when
  the detail says so.
- `metrics`: `N over`, or `OK` when 0.
- `test`: `N pass, F failing, R not runnable locally (scrubbed env)`; omit
  the `R ...` part when R is 0.
- `coverage`: `C/T changed lines` or `unavailable (<reason>)`.
- `audit`: `OK`, `N introduced` on FAIL, `skipped (lockfile unchanged)`, or
  `unavailable (<reason>)`.
- Any `UNAVAILABLE(reason)` shows as `<tool> unavailable (<reason>)`.
When `tools/summary.txt` has more than one row per tool (several packages),
print one Tools line per package, each prefixed with the package name.

Ids: BLOCKER B1..Bn, MAJOR M1..Mn, MINOR N1..Nn, in order of file path then
line.

CLEAN CODE block: `Complexity` from the highest `sonarjs/cognitive-complexity`
row and the longest `max-lines-per-function` row in `tools/metrics.tsv`
(or `clean-code.json` when the agent computed them); `Duplication` lists the
`duplication` rows; `Escape hatches added` comes from `clean-code.json`.
Print `none over threshold` when `metrics.tsv` is empty.

SDD/TDD block: `Changed lines covered` is `TOTAL=` from
`tools/coverage-changed.txt` followed by the uncovered functions of its rows;
print `coverage unavailable (<reason>)` when the coverage row is UNAVAILABLE.

## MR summary

`summary.md` is Markdown with the same content, except each finding is one
bullet in the following form (the body goes into the inline discussion):

```
- **B1** <title> — <file>:<line>
```

Start with the Verdict line, then Stack and Tools, then the bullets by
severity, then the CLEAN CODE and SDD/TDD blocks as fenced blocks, then
Needs human judgment. Do not include "No artifacts left".
