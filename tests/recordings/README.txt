# Recorded 2026-10-25 from scratch projects (outside this repo): jest@29 (CJS) with
# --ci --json --outputFile --coverage --coverageDirectory --coverageReporters=lcov (accepted by jest 29.x CLI);
# node v22.4.0 --test --test-reporter=tap/lcov on the dirty fixture. Absolute paths rewritten to /repo.
# vitest@5.0.5 + @vitest/coverage-v8@5.0.5 (ESM) with --reporter=json --outputFile --coverage.enabled
# --coverage.reportOnFailure --coverage.reporter=lcov --coverage.reportsDirectory: without reportOnFailure
# Vitest writes NO coverage when any test fails. Skipped tests have status "skipped" (Jest: "pending").
# node-test-describe.tap: node v22.4.0 --test --test-reporter=tap on a scratch describe() file (an ECONNREFUSED
# subtest, two assertion failures, one nested describe, one pass). Absolute paths rewritten to /repo/test.
