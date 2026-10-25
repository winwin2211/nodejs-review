#!/usr/bin/env bash
# Generate throwaway Node git repos used to test nodejs-review.
# Usage: make-fixtures.sh <outdir>   -> <outdir>/dirty, <outdir>/clean, <outdir>/ts
#
# All three are ESM JavaScript (or TypeScript for ts) with no dependencies of
# their own: node_modules is a symlink to the skill's toolbelt so eslint and
# tsc resolve "from the repo" without any network. dirty and clean share the
# same base commit; their feature branches add the same feature well and badly.
set -euo pipefail
OUT=${1:?usage: make-fixtures.sh <outdir>}
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd -P)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TOOLBELT_NM="$ROOT/skill/toolbelt/node_modules"
[[ -d "$TOOLBELT_NM" ]] || { echo "make-fixtures.sh: toolbelt not installed (bash install.sh --toolbelt-only)" >&2; exit 1; }

init_repo() { # dir
  rm -rf "$1"; mkdir -p "$1"
  git -C "$1" init -q -b main
  git -C "$1" config user.email fixture@example.com
  git -C "$1" config user.name fixture
  printf 'node_modules\ncoverage/\n' > "$1/.gitignore"
  ln -s "$TOOLBELT_NM" "$1/node_modules"
}

# ---------- shared base for dirty and clean ----------
write_base() { # dir name
  local D=$1 NAME=$2
  mkdir -p "$D/src/handlers" "$D/src/services" "$D/src/repos" "$D/test"
  cat > "$D/package.json" <<EOF
{
  "name": "$NAME",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "scripts": { "test": "node --test" }
}
EOF
  cat > "$D/src/db.js" <<'EOF'
// Fake database: records every query, answers a few canned ones.
export const calls = [];

export async function query(sql, params = []) {
  calls.push({ sql, params });
  if (params.includes('fail') || /'fail'/.test(sql)) {
    throw new Error('connection reset by peer');
  }
  if (/FROM users/.test(sql) && (params[0] === 'u1' || /'u1'/.test(sql))) {
    return [{ id: 'u1', name: 'Alice' }];
  }
  if (/FROM orders/.test(sql) && (params[0] === 'u1' || /'u1'/.test(sql))) {
    return [{ id: 'o1', user: 'u1', qty: 2 }];
  }
  return [];
}
EOF
  cat > "$D/src/repos/order_repo.js" <<'EOF'
import { query } from '../db.js';

export async function save(order) {
  await query('INSERT INTO orders (id, user, qty) VALUES ($1, $2, $3)', [order.id, order.user, order.qty]);
  return order;
}
EOF
  cat > "$D/src/services/order_service.js" <<'EOF'
import * as repo from '../repos/order_repo.js';

export class InvalidQuantityError extends Error {}

export function validateQuantity(qty) {
  if (!Number.isInteger(qty) || qty <= 0) {
    throw new InvalidQuantityError(`invalid qty ${qty}`);
  }
}

export async function placeOrder(order) {
  validateQuantity(order.qty);
  return repo.save(order);
}
EOF
  cat > "$D/src/handlers/order_handler.js" <<'EOF'
import * as service from '../services/order_service.js';

export async function postOrder(req) {
  try {
    const order = await service.placeOrder(req.body);
    return { status: 201, body: order };
  } catch (err) {
    if (err instanceof service.InvalidQuantityError) {
      return { status: 400, body: { error: err.message } };
    }
    throw err;
  }
}
EOF
  cat > "$D/test/order_service.test.js" <<'EOF'
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { placeOrder, InvalidQuantityError } from '../src/services/order_service.js';
import { calls } from '../src/db.js';

test('placeOrder saves a valid order once', async () => {
  const before = calls.length;
  const saved = await placeOrder({ id: 'o1', user: 'u1', qty: 2 });
  assert.equal(saved.user, 'u1');
  assert.equal(calls.length, before + 1);
});

test('placeOrder rejects qty 0 without saving', async () => {
  const before = calls.length;
  await assert.rejects(placeOrder({ id: 'o2', user: 'u1', qty: 0 }), InvalidQuantityError);
  assert.equal(calls.length, before);
});
EOF
  cat > "$D/test/order_handler.test.js" <<'EOF'
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { postOrder } from '../src/handlers/order_handler.js';

test('postOrder returns 201 for a valid order', async () => {
  const res = await postOrder({ body: { id: 'o1', user: 'u1', qty: 2 } });
  assert.equal(res.status, 201);
});

test('postOrder returns 400 for an invalid quantity', async () => {
  const res = await postOrder({ body: { id: 'o2', user: 'u1', qty: -1 } });
  assert.equal(res.status, 400);
});
EOF
  git -C "$D" add -A && git -C "$D" commit -q -m "base: order placement"
  git -C "$D" checkout -q -b feature/NR-100-orders
}

# ---------- dirty ----------
D="$OUT/dirty"; init_repo "$D"; write_base "$D" dirty

# D1 (security): string-built SQL from a request parameter, with an unexplained eslint-disable
cat > "$D/src/repos/order_repo.js" <<'EOF'
import { query } from '../db.js';

export async function save(order) {
  await query('INSERT INTO orders (id, user, qty) VALUES ($1, $2, $3)', [order.id, order.user, order.qty]);
  return order;
}

export async function fetchUser(id) {
  const rows = await query('SELECT * FROM users WHERE id = $1', [id]);
  return rows[0] ?? null;
}

export async function listOrders(user) {
  // eslint-disable-next-line
  return query(`SELECT * FROM orders WHERE user = '${user}'`);
}
EOF

# D2 (correctness + architecture): un-awaited promise, handler importing the repo directly
cat > "$D/src/handlers/order_handler.js" <<'EOF'
import * as service from '../services/order_service.js';
import * as repo from '../repos/order_repo.js';

export async function postOrder(req) {
  try {
    const order = await service.placeOrder(req.body);
    return { status: 201, body: order };
  } catch (err) {
    if (err instanceof service.InvalidQuantityError) {
      return { status: 400, body: { error: err.message } };
    }
    throw err;
  }
}

export async function getOrders(req) {
  const id = req.params.id;
  const user = repo.fetchUser(id);
  if (!user) {
    return { status: 404, body: { error: 'unknown user' } };
  }
  const orders = await repo.listOrders(id);
  return { status: 200, body: orders };
}
EOF

# D3 (clean code + correctness): one long, deeply nested function that swallows the save error
cat > "$D/src/services/order_service.js" <<'EOF'
import * as repo from '../repos/order_repo.js';

export class InvalidQuantityError extends Error {}

const TIERS = [[100, 0.1], [50, 0.05]];

export async function placeOrder(order) {
  let total = 0;
  let discount = 0;
  const warnings = [];
  if (!order) {
    throw new InvalidQuantityError('missing order');
  }
  if (!Number.isInteger(order.qty) || order.qty <= 0) {
    throw new InvalidQuantityError(`invalid qty ${order.qty}`);
  }
  const items = order.items || [];
  for (let i = 0; i < items.length; i++) {
    const item = items[i];
    if (item.price > 0) {
      if (item.qty > 0) {
        if (item.taxable || order.region === 'EU') {
          total += item.price * item.qty * 1.2;
        } else {
          total += item.price * item.qty;
        }
      } else if (item.free) {
        warnings.push(`item ${i} is free`);
      }
    } else {
      warnings.push(`item ${i} has no price`);
    }
  }
  if (order.coupon) {
    if (order.coupon.startsWith('VIP')) {
      discount = total * 0.2;
    } else if (order.coupon.startsWith('NEW')) {
      discount = Math.min(total * 0.1, 20);
    } else {
      discount = 0;
    }
  }
  for (const [threshold, rate] of TIERS) {
    if (total - discount > threshold) {
      discount += (total - discount) * rate;
      break;
    }
  }
  if (order.region === 'EU' && discount > total * 0.5) {
    discount = total * 0.5;
  }
  if (discount < 0) {
    discount = 0;
  }
  switch (order.region) {
    case 'EU':
      total += 5;
      break;
    case 'US':
      total += 7;
      break;
    default:
      total += 9;
  }
  const saved = { ...order, total: total - discount, warnings };
  try {
    await repo.save(saved);
  } catch {}
  return saved;
}
EOF

# D4 (clean code): the discount block copied verbatim into a second module
cat > "$D/src/services/legacy_order_service.js" <<'EOF'
const TIERS = [[100, 0.1], [50, 0.05]];

export function legacyDiscount(order, total) {
  let discount = 0;
  if (order.coupon) {
    if (order.coupon.startsWith('VIP')) {
      discount = total * 0.2;
    } else if (order.coupon.startsWith('NEW')) {
      discount = Math.min(total * 0.1, 20);
    } else {
      discount = 0;
    }
  }
  for (const [threshold, rate] of TIERS) {
    if (total - discount > threshold) {
      discount += (total - discount) * rate;
      break;
    }
  }
  if (order.region === 'EU' && discount > total * 0.5) {
    discount = total * 0.5;
  }
  if (discount < 0) {
    discount = 0;
  }
  return discount;
}
EOF

# D5 (tdd): .only committed, an assertion-less test, and a handler test that fails because of D2
cat > "$D/test/order_service.test.js" <<'EOF'
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { placeOrder, InvalidQuantityError } from '../src/services/order_service.js';
import { calls } from '../src/db.js';

test.only('placeOrder saves a valid order once', async () => {
  const before = calls.length;
  const saved = await placeOrder({ id: 'o1', user: 'u1', qty: 2 });
  assert.equal(saved.user, 'u1');
  assert.equal(calls.length, before + 1);
});

test('placeOrder rejects qty 0 without saving', async () => {
  const before = calls.length;
  await assert.rejects(placeOrder({ id: 'o2', user: 'u1', qty: 0 }), InvalidQuantityError);
  assert.equal(calls.length, before);
});

test('placeOrder applies a coupon', async () => {
  await placeOrder({ id: 'o3', user: 'u1', qty: 1, coupon: 'VIP1', items: [{ price: 10, qty: 1 }] });
});
EOF
cat > "$D/test/order_handler.test.js" <<'EOF'
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { postOrder, getOrders } from '../src/handlers/order_handler.js';

test('postOrder returns 201 for a valid order', async () => {
  const res = await postOrder({ body: { id: 'o1', user: 'u1', qty: 2 } });
  assert.equal(res.status, 201);
});

test('postOrder returns 400 for an invalid quantity', async () => {
  const res = await postOrder({ body: { id: 'o2', user: 'u1', qty: -1 } });
  assert.equal(res.status, 400);
});

test('getOrders returns 404 for an unknown user', async () => {
  const res = await getOrders({ params: { id: 'nobody' } });
  assert.equal(res.status, 404);
});
EOF
git -C "$D" add -A && git -C "$D" commit -q -m "NR-100: list orders by user"

# ---------- clean ----------
C="$OUT/clean"; init_repo "$C"; write_base "$C" clean
cat > "$C/src/repos/order_repo.js" <<'EOF'
import { query } from '../db.js';

export async function save(order) {
  await query('INSERT INTO orders (id, user, qty) VALUES ($1, $2, $3)', [order.id, order.user, order.qty]);
  return order;
}

export async function fetchUser(id) {
  const rows = await query('SELECT * FROM users WHERE id = $1', [id]);
  return rows[0] ?? null;
}

export async function listOrders(userId) {
  return query('SELECT * FROM orders WHERE user = $1', [userId]);
}
EOF
cat > "$C/src/services/order_service.js" <<'EOF'
import * as repo from '../repos/order_repo.js';

export class InvalidQuantityError extends Error {}
export class UnknownUserError extends Error {}
export class OrderSaveError extends Error {
  constructor(orderId, cause) {
    super(`order ${orderId}: save failed`, { cause });
    this.orderId = orderId;
  }
}

export function validateQuantity(qty) {
  if (!Number.isInteger(qty) || qty <= 0) {
    throw new InvalidQuantityError(`invalid qty ${qty}`);
  }
}

export async function placeOrder(order) {
  validateQuantity(order.qty);
  try {
    return await repo.save(order);
  } catch (err) {
    throw new OrderSaveError(order.id, err);
  }
}

export async function listOrdersForUser(userId) {
  const user = await repo.fetchUser(userId);
  if (!user) {
    throw new UnknownUserError(`unknown user ${userId}`);
  }
  return repo.listOrders(userId);
}
EOF
cat > "$C/src/handlers/order_handler.js" <<'EOF'
import * as service from '../services/order_service.js';

export async function postOrder(req) {
  try {
    const order = await service.placeOrder(req.body);
    return { status: 201, body: order };
  } catch (err) {
    if (err instanceof service.InvalidQuantityError) {
      return { status: 400, body: { error: err.message } };
    }
    throw err;
  }
}

export async function getOrders(req) {
  try {
    const orders = await service.listOrdersForUser(req.params.id);
    return { status: 200, body: orders };
  } catch (err) {
    if (err instanceof service.UnknownUserError) {
      return { status: 404, body: { error: err.message } };
    }
    throw err;
  }
}
EOF
cat > "$C/test/order_service.test.js" <<'EOF'
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  placeOrder, listOrdersForUser, InvalidQuantityError, UnknownUserError, OrderSaveError,
} from '../src/services/order_service.js';
import { calls } from '../src/db.js';

test('placeOrder saves a valid order once', async () => {
  const before = calls.length;
  const saved = await placeOrder({ id: 'o1', user: 'u1', qty: 2 });
  assert.equal(saved.user, 'u1');
  assert.equal(calls.length, before + 1);
});

test('placeOrder rejects qty 0 without saving', async () => {
  const before = calls.length;
  await assert.rejects(placeOrder({ id: 'o2', user: 'u1', qty: 0 }), InvalidQuantityError);
  assert.equal(calls.length, before);
});

test('placeOrder wraps a repository failure with the order id', async () => {
  await assert.rejects(placeOrder({ id: 'o3', user: 'fail', qty: 1 }), (err) => {
    assert.ok(err instanceof OrderSaveError);
    assert.match(err.message, /order o3/);
    assert.equal(err.orderId, 'o3');
    assert.match(err.cause.message, /connection reset/);
    return true;
  });
});

test('listOrdersForUser returns the orders of a known user', async () => {
  const orders = await listOrdersForUser('u1');
  assert.equal(orders.length, 1);
  assert.equal(orders[0].user, 'u1');
});

test('listOrdersForUser rejects an unknown user', async () => {
  await assert.rejects(listOrdersForUser('nobody'), UnknownUserError);
});
EOF
cat > "$C/test/order_handler.test.js" <<'EOF'
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { postOrder, getOrders } from '../src/handlers/order_handler.js';

test('postOrder returns 201 for a valid order', async () => {
  const res = await postOrder({ body: { id: 'o1', user: 'u1', qty: 2 } });
  assert.equal(res.status, 201);
});

test('postOrder returns 400 for an invalid quantity', async () => {
  const res = await postOrder({ body: { id: 'o2', user: 'u1', qty: -1 } });
  assert.equal(res.status, 400);
});

test('postOrder lets a save failure propagate', async () => {
  await assert.rejects(postOrder({ body: { id: 'o3', user: 'fail', qty: 1 } }), /order o3/);
});

test('getOrders returns 200 with the orders of a known user', async () => {
  const res = await getOrders({ params: { id: 'u1' } });
  assert.equal(res.status, 200);
  assert.equal(res.body.length, 1);
});

test('getOrders returns 404 for an unknown user', async () => {
  const res = await getOrders({ params: { id: 'nobody' } });
  assert.equal(res.status, 404);
  assert.match(res.body.error, /unknown user nobody/);
});
EOF
mkdir -p "$C/docs/superpowers/specs" "$C/docs/superpowers/plans"
cat > "$C/docs/superpowers/specs/2026-10-01-NR-100-orders-design.md" <<'EOF'
# NR-100 Order Listing and Save-Failure Handling

## Goal
Clients cannot list a user's orders, and a failed save surfaces as a bare
driver error without the order id, so support cannot trace it.

## Scope and Out of Scope
In: `GET /users/:id/orders`, wrapping save failures. Out: pagination,
authentication (handled by the gateway), order updates.

## Current State
`placeOrder` validates the quantity and calls `repo.save`; the handler maps
`InvalidQuantityError` to 400. There is no read path for orders.

## Design Decisions
The handler calls the service only, never the repository, because the
service owns the "unknown user" rule. Save failures become `OrderSaveError`
carrying the order id and the original error as `cause`, because callers
need both to log and to retry.

## Contracts
- `GET /users/:id/orders` -> 200 `[{id, user, qty}]`; 404 `{error}` when the
  user does not exist.
- `service.listOrdersForUser(userId)` throws `UnknownUserError`.
- `service.placeOrder(order)` throws `InvalidQuantityError | OrderSaveError`.
- Queries are parameterized (`$1`), never interpolated.

## Error Handling and Edge Cases
Unknown user -> 404. Repository failure on save -> `OrderSaveError` with
`orderId` and `cause`; the handler lets it propagate (500 by the framework).
Empty order list for a known user -> 200 `[]`.

## Data / Migration Impact
None: reads existing `users` and `orders` tables.

## Risks and Rollback
Risk: a slow `users` lookup adds latency to listing. Rollback: remove the
route; no data change.

## Testing Strategy
Unit tests against the fake database: valid save once, qty 0 rejected
without a save, save failure wrapped with the order id, known user listing,
unknown user 404, handler mapping for 200/404 and propagation of save
failures.

## Acceptance Criteria
- AC1 a valid order is saved exactly once.
- AC2 qty 0 is rejected with `InvalidQuantityError` and nothing is saved.
- AC3 a repository failure is wrapped in `OrderSaveError` naming the order id.
- AC4 listing for a known user returns their orders with 200.
- AC5 listing for an unknown user returns 404.
EOF
cat > "$C/docs/superpowers/plans/2026-10-01-NR-100-orders-plan.md" <<'EOF'
# NR-100 Implementation Plan

- [x] Task 1: `fetchUser` and parameterized `listOrders` in `src/repos/order_repo.js`
- [x] Task 2: `OrderSaveError`, `UnknownUserError`, `listOrdersForUser` in `src/services/order_service.js`; tests for AC1-AC5
- [x] Task 3: `getOrders` in `src/handlers/order_handler.js` mapping `UnknownUserError` to 404; handler tests
EOF
git -C "$C" add -A && git -C "$C" commit -q -m "NR-100: list orders by user, wrap save failures"

# ---------- ts: a signature change that breaks an unchanged caller ----------
T="$OUT/ts"; init_repo "$T"
mkdir -p "$T/src"
cat > "$T/package.json" <<'EOF'
{
  "name": "ts-fixture",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "scripts": { "typecheck": "tsc --noEmit -p tsconfig.json" },
  "devDependencies": { "typescript": "5.9.3" }
}
EOF
cat > "$T/tsconfig.json" <<'EOF'
{
  "compilerOptions": {
    "strict": true,
    "noEmit": true,
    "incremental": true,
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "rootDir": "src"
  },
  "include": ["src"]
}
EOF
cat > "$T/src/a.ts" <<'EOF'
export function greet(name: string): string {
  return `hi ${name}`;
}
EOF
cat > "$T/src/b.ts" <<'EOF'
import { greet } from './a.js';

export const message: string = greet('reviewer');
EOF
git -C "$T" add -A && git -C "$T" commit -q -m "base"
git -C "$T" checkout -q -b feature/NR-100-orders
cat > "$T/src/a.ts" <<'EOF'
export function greet(name: string, times: number): string {
  return `hi ${name}`.repeat(times);
}
EOF
git -C "$T" add -A && git -C "$T" commit -q -m "NR-100: greet repeats"

echo "fixtures written to $OUT: dirty clean ts"
