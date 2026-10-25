# Performance, reliability, and observability checklist

## How to work

1. Read `diff.patch`. Mark each changed function as hot (request handler,
   middleware, resolver, consumer loop, cron tick, per-row callback) or cold
   (startup, admin, one-off script). Apply allocation and blocking rules to
   hot paths only.
2. For every DB/cache/HTTP/queue call in the diff, find the loop it is in
   (`grep -n "for \|forEach\|map(" <file>`) and whether the call has a
   timeout and a bound.
3. Read `tools/coverage-changed.txt` only to see whether hot paths have
   tests; do not report coverage numbers as findings.

## Database and cache

- N+1: a query inside a loop over a result set (`for (const o of orders) await prisma.user.findUnique`),
  ORM lazy relations touched per item (TypeORM `lazy: true`, Mongoose
  `populate` per document), per-item Redis `GET` instead of `MGET`/pipeline,
  GraphQL resolvers without a DataLoader. MAJOR.
- Unbounded query: `findMany()` without `take`, `find({})` without `limit`,
  list endpoints without a max page size, `SELECT *`/no `select` where only
  ids are needed. MAJOR.
- Missing index for a new filter or sort column (check `schema.prisma`,
  entity decorators, migrations, Mongoose schema indexes), or a query that
  cannot use an existing index (function on the column, leading wildcard
  `LIKE '%x'`, `$regex` without an anchor). MAJOR.
- Transactions held across outbound HTTP calls or user waits. MAJOR.
- Cache: no TTL, unbounded key cardinality (per-request keys), stampede on
  expiry for hot keys without single-flight, caching errors. MAJOR.
- Redis blocking commands, `KEYS`, `SMEMBERS` on large sets on request paths.
  MAJOR.
- Bulk work row by row where `createMany`/`insertMany`/batch upsert exists.
  MINOR, MAJOR in a consumer.
- Connection pool: a new client per request (`new PrismaClient()`,
  `new Pool()`, `createClient()` inside a handler) or pool size unrelated to
  the DB's limits. MAJOR.

## Event loop, allocation and memory

- Synchronous blocking on a hot path: `fs.readFileSync`, `crypto.pbkdf2Sync`,
  `scryptSync`, `zlib.gzipSync`, `execSync`, `JSON.parse` of multi-megabyte
  bodies, large regex on user input, CPU loops over big arrays (move to a
  worker thread or stream). MAJOR.
- Reading whole files or responses into memory where a stream would do
  (`fs.readFile` for uploads, `await res.text()` for large payloads,
  `Buffer.concat` of an unbounded stream). MAJOR.
- Unbounded in-memory growth: module-level `Map`/array caches with no
  eviction, per-user state never removed, listeners added per request
  (`emitter.on` in a handler), closures retaining request objects. MAJOR.
- Timers per request not cleared (`setInterval` in a handler). MAJOR.
- Regex compiled per call in a hot loop (`new RegExp` in a `map`);
  `JSON.parse(JSON.stringify(x))` as a deep clone of large objects on hot
  paths; spreading large arrays in a loop (`acc = [...acc, x]`, O(n²)). MINOR,
  MAJOR when demonstrably on a request path with large inputs.
- Sequential `await` in a loop over independent calls where
  `Promise.all` with a concurrency bound (`p-limit`) was the intent. MINOR;
  MAJOR in a consumer handling many items.
- Unbounded concurrency: `Promise.all(items.map(fetch))` over user-controlled
  list sizes. MAJOR.

## Reliability

- Outbound call without timeout (`fetch` without `AbortSignal.timeout`, axios
  without `timeout`, `pg` without `statement_timeout`/`connectionTimeoutMillis`,
  ioredis without `commandTimeout`), or with a timeout longer than the
  caller's budget. MAJOR.
- No retry on transient failure for an idempotent call, retry without
  backoff + jitter + max attempts, or retry on a non-idempotent call. MAJOR.
- Circuit breaking / bulkhead absent on a dependency that already has an
  established pattern in the repo. MINOR.
- Graceful shutdown: new server, consumer, worker, cron, or interval not
  hooked into the shutdown sequence (`server.close`, NestJS
  `enableShutdownHooks`/`onModuleDestroy`, BullMQ `worker.close()`, `SIGTERM`
  handler); in-flight requests dropped on deploy. MAJOR.
- Startup: dependency checks that crash-loop instead of degrading; readiness
  and liveness not distinguished for a new dependency. MINOR.
- Queue consumers (BullMQ, SQS, Kafka, RabbitMQ): no ack/nack strategy, poison
  messages retried forever, no dead-letter path, ordering assumptions the
  transport does not give, concurrency unbounded. MAJOR.
- Schedulers (`node-cron`, `@nestjs/schedule`, BullMQ repeatable): overlapping
  runs not prevented across replicas, no jitter, timezone assumptions. MAJOR.
- Backpressure: a producer writing to a stream or queue faster than the
  consumer drains with no bound. MAJOR.

## Observability

- New error path without a log line carrying the ids needed to debug it
  (request id, user/order id), or logging at the wrong level (errors at
  `info`, expected conditions at `error`). MINOR.
- `console.log`/`console.error` where the repo has a structured logger
  (pino, winston, NestJS `Logger`); unstructured string interpolation where
  siblings pass fields. MINOR (MAJOR when it leaks the full payload on a
  request path).
- New external call or consumer without metrics/tracing where siblings have
  them (OpenTelemetry spans, prom-client counters). MINOR.
- Log spam: logging inside a hot loop per item, or logging the full body.
  MAJOR.
- Unhandled rejections or `uncaughtException` not routed to the error
  reporter; a `process.on('uncaughtException')` that keeps the process alive
  in an unknown state. MAJOR.

## Evidence to cite

Cite the call line and the enclosing loop or handler line. For timeouts cite
the client construction line. For shutdown cite where siblings register
their hooks. For memory growth cite the module-level declaration and the
line that adds without removing.
