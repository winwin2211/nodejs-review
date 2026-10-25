# Correctness checklist

## How to work

1. Read `stack.env` (runtime, TypeScript or not, runner) and `diff.patch`
   fully. For every changed function, open the file and read the whole
   function plus its direct callers (`grep -rn "name("`).
2. Read `tools/summary.txt`, `tools/typecheck-new.txt`,
   `tools/test-classified.txt` and the failure messages in `tools/test.json`
   or `tools/test.txt`. A failing test or a new type error is already a
   BLOCKER finding made by the orchestrator; use them as evidence for the
   defect behind them, do not restate them.
3. Walk the list below against each changed function. Report only what you
   can point to at a `file:line` on a changed line. Pre-existing defects on
   unchanged lines go in a separate list with `"line"` set and the title
   prefixed `PRE-EXISTING:`.
4. Do not report what `tools/lint-changed.json` already reports unless lint
   is UNAVAILABLE.

## Promises and async

- Promise not awaited and its value used: `const user = repo.find(id); if (!user)`
  is always truthy. Callback-style APIs given an `async` function whose
  rejection nobody handles: `array.forEach(async ...)`, `emitter.on('x', async ...)`,
  `setTimeout(async ...)`, Express 4 handlers (`app.get(path, async (req, res) =>`
  without an error wrapper or `express-async-errors`; Express 5 and Fastify
  forward rejections).
- Floating promise on a request or consumer path (fire-and-forget without
  `.catch`, `void` without a handler); `Promise.all` where one rejection must
  not abort the others (`Promise.allSettled`); `Promise.race` leaking the
  losers; sequential `await` in a loop where the calls are independent and
  order does not matter (correctness only when it changes semantics;
  performance owns the rest).
- `return await` missing inside `try` (the catch never fires); `try/catch`
  around a call that returns a promise without awaiting it.
- `async` function used as an event-loop blocker: a long synchronous loop or
  `fs.*Sync`/`crypto.pbkdf2Sync`/`zlib.*Sync`/`child_process.execSync` inside
  a request handler or consumer.
- Unhandled rejection or `uncaughtException` handler that logs and continues
  with corrupted state; `process.on('unhandledRejection')` used to hide bugs.
- Timers and intervals created on request paths and never cleared; `AbortSignal`
  accepted but not forwarded to `fetch`/`pg`/`ioredis`; cancellation ignored.

## Errors

- Error swallowed: `catch {}`, `catch (e) { return null }` on a path the
  caller must know about, `.catch(() => {})`.
- Error rethrown without context: `throw err` from a function that made an
  outbound call or has several error sources; prefer a typed error with
  `{ cause }` carrying the id of the thing being processed.
- `instanceof` checks on errors crossing module boundaries with duplicated
  class definitions, or on errors thrown by a library that does not export
  the class; checking `err.message` text instead of `err.code`.
- HTTP mapping: every error becomes 500 although the service throws typed
  validation/not-found errors (NestJS: filters/`HttpException`; Express:
  the error middleware's `instanceof` chain; Fastify: `setErrorHandler`);
  the reverse: internal error text or stack leaked to clients.
- Partial success not surfaced: batch loops that `continue` on error without
  collecting or counting failures; `Promise.allSettled` results not inspected.
- Errors logged and rethrown (double reporting), or logged and dropped on a
  path the caller must know about.
- `process.exit` in library code; `finally` that overrides the thrown error
  with its own `return`/`throw`.

## Resources and transactions

- Streams: `pipe` without error handling on every stream (`pipeline` from
  `node:stream/promises`), a readable never consumed or destroyed, request
  body read twice, backpressure ignored (`write` return value).
- Handles not released on every path: DB clients from a pool (`client.release()`
  in `finally` for `pg`), file descriptors, sockets, `setInterval`, event
  listeners added per request (`MaxListenersExceededWarning`), `AbortController`
  never aborted.
- Transactions: Prisma `$transaction` callback that awaits work outside the
  transaction client, or a long-running interactive transaction; TypeORM
  `QueryRunner` without `release()` in `finally`, `manager` used instead of
  the transaction manager; Knex `trx` not passed to every query, missing
  `trx.rollback` on error (or not using the callback form); Mongoose sessions
  not passed to every operation, `withTransaction` body doing work outside
  the session; raw `pg` `BEGIN` without `ROLLBACK` on every error path.
- Two writes that must be atomic done without a transaction; transaction held
  while awaiting an external HTTP call.
- Read-modify-write on a row without `SELECT ... FOR UPDATE`, an optimistic
  version check, or an atomic `UPDATE ... SET x = x + $1`: balances,
  counters, inventory, Mongo `findOne` then `save` instead of `findOneAndUpdate`.
- Idempotency: a retried operation (queue consumer, HTTP client with retry,
  BullMQ job with attempts) that inserts, increments, or sends without an
  idempotency key or dedup check.
- Cache: write-through order (DB then cache), stale read after write, cache
  key missing a tenant/user dimension, no TTL on unbounded keys.

## Logic and types

- Nullish: `||` where `??` was meant (0, '' and false collapse to the
  default); optional chaining that hides a required value; `in` on a
  possibly-null object; `Array.prototype.find` result used without a check.
- TypeScript escape hatches that hide a runtime bug: `as` casting a request
  body or JSON parse result to a type without validation (zod/joi/
  class-validator) so the type lies; non-null `!` on a lookup result; `any`
  at a boundary (`req.body as any`); `@ts-ignore` over a real error.
- Numbers: float math on money (use integers in minor units or a decimal
  library); `parseInt` without radix or on a float string; `Number('')`
  is 0; `BigInt` mixed with `Number`; `JSON.stringify` on `BigInt` throws.
- Dates: `new Date(string)` parsing locale-dependent input; local time vs
  UTC mixed; `Date.now()` without a clock abstraction in code that must be
  tested; month off-by-one (`getMonth()`); duration units mixed (ms vs s).
- Collections: mutating an array while iterating; `Array.sort` without a
  comparator on numbers; `delete arr[i]`; object key order relied on;
  `Object.keys` on a `Map`; `for...in` over arrays.
- Pagination and boundaries: `limit`/`offset` from input without bounds;
  cursor comparison `>` vs `>=`; inclusive/exclusive time windows; `slice`
  with negative or `NaN` indices.
- Equality: `==` with mixed types; comparing objects or dates with `===`;
  `NaN` comparisons; `switch` without `default` on a union that grew (use
  `never` exhaustiveness in TS).
- JSON contracts: `undefined` fields dropped by `JSON.stringify` where the
  client expects `null`; dates serialized as strings and compared as
  objects; `int64` ids as `Number` losing precision past 2^53.
- Retry loops with no max attempts or no backoff/jitter; retrying
  non-idempotent calls; retrying on non-retryable errors (4xx, validation).
- Module state: a mutable module-level cache or counter shared across
  requests (and across tests) without reset; singletons that capture config
  at import time.

## Evidence to cite

Quote the exact changed line(s). For a floating promise, cite the call line
and the line that uses the result. For a swallowed error cite the catch and
the caller that cannot distinguish failure. For transactions cite the query
that runs outside the transaction client. For tool findings quote the
`tools/*` line.
