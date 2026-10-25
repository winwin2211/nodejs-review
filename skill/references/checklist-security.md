# Security checklist

## How to work

1. Read `diff.patch`. List every place user- or network-controlled data
   enters the changed code: route params, query, body, headers, cookies,
   GraphQL args, WebSocket messages, queue payloads, config, files,
   environment.
2. For each entry point trace the data to every sink: query builder or raw
   SQL, Mongo filter, shell, file path, URL, template, log, redirect, header,
   `eval`-like APIs, another service.
3. Read `tools/lint-changed.json` (security rules, `no-eval`,
   `no-implied-eval`) and `tools/audit-new.tsv`. Each `introduced` high or
   critical advisory is already a BLOCKER finding made by the orchestrator;
   add a finding only when the diff makes the vulnerable code path reachable
   (cite the import and the call).
4. Report only on changed lines unless a changed line newly exposes a
   pre-existing sink (then cite both).

## Input and injection

- SQL: template strings or concatenation into `query`, Knex `raw`/`whereRaw`,
  Prisma `$queryRawUnsafe`/`$executeRawUnsafe` (the tagged `$queryRaw` is
  parameterized), TypeORM `query()` or `.where(\`col = '${x}'\`)`, Sequelize
  `literal`; `ORDER BY ${column}` or table names from input without an
  allow-list.
- NoSQL: Mongo filters built from the request body (`{ $where }`, operator
  injection via `req.query.x` objects), Mongoose queries that pass the body
  through, Redis keys or Lua scripts from unvalidated input, `KEYS pattern`.
- Command: `child_process.exec`/`execSync` with a template string, `spawn`
  with `shell: true`, arguments not separated; `eval`, `new Function`,
  `vm.runInNewContext` with input.
- Prototype pollution: recursive merge/extend/`set(obj, path, value)` (lodash
  `merge`, `set`, `defaultsDeep`, hand-written deep merge) applied to a
  request body; `__proto__`, `constructor`, `prototype` keys not rejected;
  `Object.assign({}, body)` into a model that drives authorization.
- ReDoS: a regex built from input, or a nested-quantifier pattern
  (`(a+)+`, `(\s*,\s*)*`, `.*` before an alternation) applied to request
  data on a request path.
- Path traversal: `path.join(base, userInput)` without `path.resolve` plus a
  prefix check; `..` accepted; `fs.*` on a user-supplied name; `express.static`
  with `dotfiles: 'allow'`; `res.sendFile` with input.
- SSRF: outbound `fetch`/axios to a URL or host from input without an
  allow-list; redirects followed to internal ranges; DNS rebinding not
  considered for long-lived allow-lists.
- Templates/HTML: `res.send` of interpolated HTML, EJS/Pug `!=`/`!{}`
  unescaped output, `dangerouslySetInnerHTML` server-side; `text/html` for
  user content.
- Deserialization and size: `JSON.parse` of unbounded bodies (`express.json({ limit })`,
  Fastify `bodyLimit`, NestJS raw body), unbounded array lengths and
  nesting, `qs` depth, `yaml.load` on untrusted input, `node-serialize`.
- Validation: numeric bounds (qty, amount, page size), string length, enum
  membership, UUID format; schema validated in the controller/DTO but the
  same service method reachable from a consumer or internal RPC without it
  (NestJS `ValidationPipe` with `whitelist: true`; zod `.strict()`).
- Mass assignment: spreading the body into `prisma.user.update({ data: body })`,
  `Model.create(req.body)`, TypeORM `save(Object.assign(entity, body))`,
  exposing `role`, `balance`, `isAdmin`.
- Integer parsing: `parseInt` results used as indexes or sizes without bounds.
- GraphQL: no depth or complexity limit, no batching cap, introspection on in
  production, resolvers accepting unbounded lists.

## Authentication and authorization

- New route/controller/resolver without the guard or middleware its siblings
  use (NestJS `@UseGuards` missing, global guard bypassed with `@Public()`;
  Express router mounted before the auth middleware; Fastify `preHandler`
  missing); check the registration diff, not just the handler.
- Object-level authorization: fetch by id from input without checking the
  caller owns or may access it (IDOR); list endpoints filtering by a user
  id taken from the request instead of the session.
- Role checks only in the client, only in one of several entry points, or
  done after the side effect.
- JWT: `algorithms` not pinned (`none`, `HS256` vs `RS256` confusion),
  expiry not checked, `jwt.decode` used instead of `verify`, secret from a
  default, tokens accepted from query strings, refresh token reuse not
  detected.
- Sessions and cookies: missing `httpOnly`, `secure`, `sameSite`; session id
  not rotated on login; user id derived from a client-settable header on a
  public path.
- Rate limiting or lockout missing on login, OTP, password reset, expensive
  endpoints (`express-rate-limit`, `@nestjs/throttler`, `@fastify/rate-limit`).
- CSRF: state-changing endpoint authenticated by cookie without a CSRF token
  or `SameSite` plus origin check; webhooks verifying a signature instead
  are acceptable and must not be flagged.

## Secrets and logging

- Secrets, tokens, private keys, connection strings in code, test fixtures,
  `.env` files committed in the diff, or default values.
- Logging request bodies, headers (`authorization`, `cookie`), tokens,
  passwords, PII at any level (`console.log(req)`, pino/winston without
  redaction, NestJS `Logger.log(body)`); error messages that embed them.
- Error responses leaking stack traces (`err.stack`), SQL, file paths or
  hostnames; NestJS default exception filter in production with
  `enableDebugMessages`.
- Debug endpoints (GraphQL playground/introspection, `/metrics`, `/health`
  with dependency details, `inspector`) exposed without auth in non-dev builds.

## Crypto and tokens

- `Math.random` for tokens, OTPs, nonces, session ids (use `crypto.randomBytes`
  / `randomUUID`); predictable ids (`Date.now()`).
- MD5/SHA1 for passwords or signatures; passwords not hashed with
  bcrypt/scrypt/argon2 with a cost factor; comparison of MACs or tokens
  with `===` instead of `crypto.timingSafeEqual`.
- AES in ECB, static IV/nonce, key derived from a short string without a KDF,
  unauthenticated encryption where integrity matters.
- TLS: `rejectUnauthorized: false`, `NODE_TLS_REJECT_UNAUTHORIZED=0`, custom
  `checkServerIdentity` that accepts everything.
- Webhook/callback signature verification missing, done after side effects,
  or without replay protection (timestamp/nonce).

## Network and files

- HTTP client without timeout (`fetch` without `AbortSignal.timeout`, axios
  without `timeout`), server without `requestTimeout`/`headersTimeout`.
- CORS `origin: '*'` with credentials, or reflecting the `Origin` header
  (`cors({ origin: true })` with `credentials: true`).
- Open redirect: `res.redirect(req.query.next)` without an allow-list.
- Files written with permissive modes, predictable temp files, uploads
  without type/size limits (multer limits), served from a user-controllable
  path.
- WebSocket: origin check disabled, no message size limit, no auth on
  upgrade.

## Dependencies

- New dependency in `package.json`: name close to a popular package
  (typosquat), very low download count, install scripts in its own
  `package.json` (`preinstall`/`postinstall`; read `node_modules/<pkg>/package.json`),
  unpinned (`*`, `latest`, git URL), or replacing a stdlib capability
  (`node:crypto`, `node:fs/promises`, `fetch`).
- Lockfile: `resolved` URLs pointing at a non-registry host; `integrity`
  removed; `overrides`/`resolutions` hiding an advisory.
- `audit` unavailable: say so; do not claim dependencies are clean.

## Evidence to cite

Quote the source line where untrusted data enters and the sink line; for
missing auth cite the route registration line and a sibling route that has
the guard. For crypto cite the call. For an advisory cite the
`audit-new.tsv` row and the import that makes it reachable.
