// Clean-code metrics only. collect.sh runs this from the reviewed package
// directory (ESLint scopes `files` patterns to its cwd) as:
//   eslint --no-config-lookup -c <toolbelt>/eslint.metrics.config.js -f json <changed files>
// No type information: the parser only needs the syntax, so the reviewed
// repository's dependencies and tsconfig are never read.
//
// Message shapes of the pinned versions, which metrics-report.sh parses
// (recorded by tests/test-toolbelt.sh):
//   complexity:                  Function 'placeOrder' has a complexity of 14. Maximum allowed is 10.
//   sonarjs/cognitive-complexity: Refactor this function to reduce its Cognitive Complexity from 22 to the 15 allowed.
//   max-lines-per-function:      Function 'placeOrder' has too many lines (76). Maximum allowed is 40.
//   max-depth:                   Blocks are nested too deeply (5). Maximum allowed is 3.
//   max-params:                  Function 'placeOrder' has too many parameters (7). Maximum allowed is 4.
//   max-nested-callbacks:        Too many nested callbacks (4). Maximum allowed is 3.   (shape from ESLint's rule source; not hit by the test file)
//   no-magic-numbers:            No magic number: 100.
import tseslint from "typescript-eslint";
import sonarjs from "eslint-plugin-sonarjs";

export default [
  {
    files: ["**/*.{js,mjs,cjs,jsx,ts,mts,cts,tsx}"],
    languageOptions: {
      parser: tseslint.parser,
      parserOptions: { ecmaVersion: "latest", sourceType: "module", ecmaFeatures: { jsx: true } },
    },
    plugins: { sonarjs },
    rules: {
      complexity: ["error", 10],
      "max-depth": ["error", 3],
      "max-lines-per-function": ["error", { max: 40, skipBlankLines: true, skipComments: true }],
      "max-params": ["error", 4],
      "max-nested-callbacks": ["error", 3],
      "sonarjs/cognitive-complexity": ["error", 15],
      "no-magic-numbers": [
        "warn",
        { ignore: [0, 1, -1], ignoreArrayIndexes: true, ignoreDefaultValues: true, detectObjects: false },
      ],
    },
  },
];
