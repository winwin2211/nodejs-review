#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
TB="$REPO_ROOT/skill/toolbelt"
ESLINT="$TB/node_modules/.bin/eslint"
JSCPD="$TB/node_modules/.bin/jscpd"
dir=$(tmpdir); out=$(tmpdir)

assert_file "$TB/package.json" "toolbelt package.json"
assert_file "$TB/package-lock.json" "toolbelt lockfile committed"
assert_file "$ESLINT" "toolbelt eslint installed"
assert_file "$JSCPD" "toolbelt jscpd installed"
assert_file "$TB/node_modules/.bin/tsc" "toolbelt tsc installed"

# complex.js: 7 params, nesting depth 5, cognitive complexity well over 15,
# cyclomatic over 10, more than 40 lines. simple.js: nothing to report.
{
  echo 'export function placeOrder(a, b, c, d, e, f, g) {'
  echo '  let total = 0;'
  for i in $(seq 1 45); do echo "  total += 1;"; done
  cat <<'EOF'
  for (let i = 0; i < a.length; i++) {
    if (a[i] > b) {
      if (c && d) {
        for (let j = 0; j < e; j++) {
          if (j % 2 === 0 || f) {
            total += j;
          } else if (g) {
            total -= j;
          } else {
            total += 1;
          }
        }
      } else if (c || d) {
        total += 2;
      }
    } else {
      total -= 1;
    }
  }
  while (total > 100) {
    total -= 7;
  }
  switch (b) {
    case 1: total++; break;
    case 2: total--; break;
    default: total = 0;
  }
  return total;
}
EOF
} > "$dir/complex.js"
echo 'export const add = (a, b) => a + b;' > "$dir/simple.js"

# run from the linted directory with an absolute config path: ESLint 9 scopes
# `files` patterns to its base path (the cwd), so this is how collect.sh runs it too
( cd "$dir" && "$ESLINT" --no-config-lookup -c "$TB/eslint.metrics.config.js" -f json complex.js simple.js > "$out/metrics.json" ) || true
rules=$(jq -r '.[] | select(.filePath | endswith("complex.js")) | .messages[].ruleId' "$out/metrics.json" | sort -u)
for r in sonarjs/cognitive-complexity complexity max-lines-per-function max-params max-depth no-magic-numbers; do
  assert_contains "$rules" "$r" "metrics config reports $r on complex.js"
done
assert_eq "0" "$(jq '[.[] | select(.filePath | endswith("simple.js")) | .messages[]] | length' "$out/metrics.json")" "metrics config is silent on simple.js"
echo "--- recorded metric messages (for metrics-report.sh regexes):"
jq -r '.[] | select(.filePath | endswith("complex.js")) | .messages[] | .ruleId + ": " + .message' "$out/metrics.json" | sort -u

printf 'var x = 1;\nif (x == 1) console.log(x);\n' > "$dir/strict.js"
( cd "$dir" && "$ESLINT" --no-config-lookup -c "$TB/eslint.strict.config.js" -f json strict.js > "$out/strict.json" ) || true
srules=$(jq -r '.[].messages[].ruleId' "$out/strict.json" | sort -u)
for r in no-var eqeqeq no-console; do
  assert_contains "$srules" "$r" "strict config reports $r"
done

# TypeScript syntax parses under both configs without type information
printf 'export function f(a: number, b: string): string {\n  return `${a}${b}`;\n}\n' > "$dir/typed.ts"
( cd "$dir" && "$ESLINT" --no-config-lookup -c "$TB/eslint.metrics.config.js" -f json typed.ts > "$out/typed.json" ) || true
assert_eq "0" "$(jq '[.[].messages[] | select(.fatal == true)] | length' "$out/typed.json")" "metrics config parses TypeScript"

# jscpd: a shared 12-line block is one clone; the report lands in --output,
# never in the scanned dir. Own subdirectory: complex.js above has 45
# identical lines and would be a (correct) self-clone.
mkdir -p "$dir/dup"
{
  echo 'export function a() {'
  for i in $(seq 1 12); do echo "  const v$i = compute($i) + compute($((i + 1))) * factor;"; done
  echo '  return v1;'
  echo '}'
} > "$dir/dup/dup_a.js"
{
  echo 'export function b(input) {'
  echo '  const prefix = input.trim();'
  for i in $(seq 1 12); do echo "  const v$i = compute($i) + compute($((i + 1))) * factor;"; done
  echo '  return prefix + v1;'
  echo '}'
} > "$dir/dup/dup_b.js"
( cd "$dir/dup" && "$JSCPD" -c "$TB/jscpd.json" -o "$out/jscpd" --silent . >/dev/null 2>&1 ) || true
assert_file "$out/jscpd/jscpd-report.json" "jscpd json report written to --output"
assert_eq "1" "$(jq '.duplicates | length' "$out/jscpd/jscpd-report.json" 2>/dev/null)" "jscpd finds the one shared block"
assert_eq "dup_a.js" "$(jq -r '.duplicates[0].firstFile.name | sub(".*/"; "")' "$out/jscpd/jscpd-report.json" 2>/dev/null)" "clone names the first file"
[[ -e "$dir/dup/report" ]] && fail "jscpd must not write a report dir into the scanned directory" || pass

finish
