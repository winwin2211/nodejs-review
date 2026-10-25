# Clean code checklist

## How to work

1. Read `tools/metrics.tsv` and `tools/metrics-preexisting.tsv` first. Every
   row of `metrics.tsv` is already a rule-based finding made by the
   orchestrator (severity in column 6). Do not report those rows again. Use
   them as evidence and context: a function flagged for cognitive
   complexity is where the judgment items below are most likely to apply.
2. Read `diff.patch` and, for every changed function, the whole function
   and the file around it, so you can judge names and abstraction levels
   against the file's own vocabulary.
3. Read `tools/lint-changed.json`: a lint message on a changed line is
   evidence, never a finding.
4. Walk the judgment rules below. Report only what you can point to at a
   `file:line` on a changed line. Fewer, better findings beat many weak
   ones: a senior engineer names the two things that make the code hard to
   read, not twenty.
5. Compute the clean-code block (Output section) from `metrics.tsv` and the
   diff.

## Metric rules (rule-based, already applied by the tools)

Applied to functions the diff adds or changes. A pre-existing function
counts when its metric is over the threshold at head and was not at the
merge-base (`origin=new`); without a baseline, when the function contains a
changed hunk (`origin=hunk`). Rows already over at the merge-base are in
`metrics-preexisting.tsv` and never block.

| Metric | MINOR | MAJOR | BLOCKER |
|---|---|---|---|
| Cognitive complexity (sonarjs) | — | > 15 | > 30 |
| Cyclomatic complexity | — | > 10 | — |
| Function length (lines, excluding blanks and comments) | > 40 | > 80 | — |
| Nesting depth | — | > 3 | — |
| Parameters | > 4 | > 6 | — |
| Nested callbacks | — | > 3 | — |
| Duplicated block (jscpd, >= 10 lines or >= 70 tokens) inside the change, or between the change and the package | — | always | — |
| Magic number in domain logic (not 0, 1, -1, array indices, named constants) | always | — | — |

## Judgment rules

| Finding | Severity |
|---|---|
| Function does more than its name says (name says one thing, body does two: `validate` also saves, `get` also mutates) | MAJOR |
| Mixed abstraction levels in one function (business rule next to byte-level parsing or raw SQL string building) | MAJOR |
| Module performs side effects on import (connects, reads env into globals, starts timers, registers handlers) | MAJOR |
| Mutable module-level state added where the repo injects dependencies (`let cache = {}` at top level) | MAJOR |
| `as any`, `@ts-ignore`, `@ts-expect-error`, `eslint-disable` introduced without a comment stating why | MAJOR |
| `as T` or `!` introduced where a type guard, `satisfies`, or narrowing was possible | MINOR |
| Dead code introduced: unused export, parameter, import, variable, unreachable branch (`grep` for usages before flagging) | MINOR |
| Commented-out code, stale comment contradicting the code, comment restating the code | MINOR |
| `console.*` in a code path where the repo has a logger | MINOR (MAJOR on a request path) |
| Naming: not intention-revealing (`data`, `tmp`, `handle`), boolean without `is/has/can/should`, abbreviation the repo does not use, two names for the same concept, misleading plural/singular | MINOR |
| TODO/FIXME without a ticket or issue reference | MINOR |
| Error-handling style inconsistent with the file (thrown errors mixed with error returns, callbacks mixed with promises, `.then` chains next to `await`) | MINOR |
| Deep nesting that early returns or extraction would flatten, when no metric row already flags the function | MINOR |
| Boolean parameter that switches behavior (`save(order, true)`) instead of two functions or an options object | MINOR |
| Primitive obsession on a domain concept the repo already models (passing `userId, tenantId, currency` strings where a type exists) | MINOR |

Clean-code MAJORs count toward the verdict exactly like other MAJORs.

## Framework-specific traps

- NestJS: business logic in a controller or in a `@Pipe`/`@Interceptor`;
  a service injecting `Request`; DTO classes with behavior; providers that
  do work in their constructor (use `onModuleInit`).
- Express/Fastify: handler bodies over 40 lines mixing parsing, validation,
  logic and response shaping; middleware mutating `req` with untyped
  properties; route files importing the ORM client.
- Prisma/TypeORM/Knex/Mongoose: query construction spread across layers;
  the same `select`/`include` shape copied into several queries instead of
  one named projection; Mongoose hooks containing business rules.

## Noise rules

Never report formatting (Prettier/Biome format territory), what the repo's
own lint config already reports on changed lines, or metrics on generated
files (`*.generated.*`, `__generated__/`, Prisma client, codegen output) or
on test files, except duplication within test files above 30 lines.

## Output

Return the findings array and, as a second JSON object, the clean-code block:

```
{
  "max_cognitive": {"value": 18, "function": "placeOrder", "file": "src/services/order_service.js", "line": 7} | null,
  "longest_function": {"value": 64, "function": "placeOrder", "file": "...", "line": 7} | null,
  "duplicates": [{"lines": 21, "a": "src/services/legacy_order_service.js:5", "b": "src/services/order_service.js:34"}],
  "escape_hatches": {"as_any": 0, "eslint_disable": 1, "ts_ignore": 0, "ts_expect_error": 0, "non_null": 0},
  "preexisting_over_threshold": 0
}
```

`max_cognitive` and `longest_function` come from the highest
`sonarjs/cognitive-complexity` and `max-lines-per-function` rows of
`metrics.tsv` (null when none); `duplicates` from its `duplication` rows;
`escape_hatches` counts occurrences added in `diff.patch` (`as any`,
`eslint-disable`, `@ts-ignore`, `@ts-expect-error`, non-null `!` on member
access); `preexisting_over_threshold` is the row count of
`metrics-preexisting.tsv`.

## Evidence to cite

Quote the exact changed line(s). For a name, quote the declaration and one
use that shows the mismatch. For mixed abstraction levels quote the two
lines at different levels. For duplication cite both locations from the
`metrics.tsv` row. For an escape hatch quote the line and state what the
type system would have caught.
