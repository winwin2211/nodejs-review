# Severity, verification, and verdict

## Finding schema

Every agent returns a JSON array. Every object has exactly these keys:

    id           "" (assigned by the orchestrator after verification)
    dimension    correctness | security | architecture | performance | clean-code | sdd-tdd | tools
    severity     BLOCKER | MAJOR | MINOR
    rule_based   true when the finding comes from a rule table (SDD/TDD, metrics, tool failure, advisory); false for judgment findings
    file         path relative to the repo root
    line         integer line in the new file (0 when not applicable)
    title        one line, <= 80 chars, states the defect, not the advice
    evidence     quoted code or tool output line, verbatim, <= 3 lines
    why          what breaks, when, and for whom; 1-2 sentences
    fix          the change to make; 1-2 sentences, a <= 6 line TS/JS snippet allowed
    spec_ref     "path#heading" or ""
    score        0-100 (agent's own confidence; the verifier overwrites it)

## Severity

BLOCKER
- Bug on a reachable path: wrong result, thrown TypeError, un-awaited promise
  whose result is used (always truthy), unhandled rejection on a request or
  consumer path, lost update, off-by-one on money or quantity.
- Data loss or corruption: partial writes without a transaction, migration
  that drops or mis-types data.
- Security: injection (SQL/NoSQL/command/path), prototype pollution, ReDoS on
  a request path, missing authn/authz check, secret in code or logs, broken
  crypto, SSRF, high/critical advisory introduced by the change.
- Tooling: typecheck error introduced by the change, failing test, `.only`
  committed.
- Clean code: cognitive complexity > 30 in a new or changed function.
- SDD/TDD blockers from `checklist-sdd-tdd.md`.

MAJOR
- Bug that needs a specific condition: retry without idempotency, timeout
  missing on an outbound call, swallowed error on a non-critical path, error
  rethrown without `cause` or context, event-loop blocking on a request path.
- Architecture: layer breach, wrong dependency direction, module side
  effects on import, transaction boundary in the wrong layer.
- Performance under production load: N+1, unbounded query, unbounded
  in-memory growth, listener added per request.
- Clean code MAJORs from `checklist-clean-code.md` (complexity, length,
  nesting, duplication, escape hatches without a reason).
- SDD/TDD majors from `checklist-sdd-tdd.md`.

MINOR
- Idiom and naming, small inefficiencies, log message quality, magic
  numbers, dead code, commented-out code, `as`/`!` where narrowing was
  possible, clean code MINORs from `checklist-clean-code.md`.
- SDD/TDD minors from `checklist-sdd-tdd.md`.

Clean-code MAJORs count toward the verdict exactly like other MAJORs.

## Verifier rubric

Score each non-rule finding 0-100 after re-reading the code at `file:line` and its callers:

- 0    Not a defect, pre-existing on unchanged lines, or the code handles it elsewhere.
- 25   Might be real; could not confirm the path is reachable or the input is possible.
- 50   Confirmed real but rarely hit in practice, or a nitpick relative to the rest of the change.
- 75   Confirmed real, reachable, and matters; the change as written is insufficient.
- 100  Confirmed by direct evidence (tool output, a test, or an unambiguous code path) and will happen in normal operation.

Thresholds: >= 80 report; 60-79 "Needs human judgment"; < 60 drop.

Rule-based findings are not scored. The verifier only checks the fact
(spec really absent, section really missing, test really missing, tool
really failed, metric row really present with that value). If the fact is
wrong, drop the finding; otherwise keep the severity from the rule table
and set score to 100.

Dedup: two findings on the same file and line (or the same defect described
twice, e.g. a tool `FAIL` row and an agent finding about the same test)
merge into one, keeping the higher severity and the better evidence.

## Verdict

- Any BLOCKER, or 3 or more MAJOR: REQUEST CHANGES
- Otherwise, any MAJOR or MINOR remaining: APPROVE WITH COMMENTS
- Otherwise: APPROVE

Findings in "Needs human judgment", "Pre-existing", NOT_RUNNABLE tests and
`metrics-preexisting.tsv` rows never affect the verdict.

## Noise rules

Do not report:
- Anything `tools/typecheck-new.txt` or `tools/lint-changed.json` already
  reports (the orchestrator turns those into findings or evidence) unless
  the tool was UNAVAILABLE.
- Formatting: Prettier or Biome formatter territory is never a finding.
- Pre-existing issues on unchanged lines. Put at most 5 of them under "Pre-existing".
- Style the project's own linter config silences.
- Intentional behavior the spec or MR description explains.
- Nitpicks a senior engineer would not raise in a review.
- Missing features outside the stated scope.
- Metrics on generated files (`*.generated.*`, `__generated__/`, Prisma
  client, protobuf or GraphQL codegen output) or on test files.
