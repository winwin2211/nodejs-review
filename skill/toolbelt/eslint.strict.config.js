// Fallback lint config for repositories that have no linter of their own.
// Syntactic rules only (no type information), run from the reviewed package
// directory as:
//   eslint --no-config-lookup -c <toolbelt>/eslint.strict.config.js -f json <changed files>
import js from "@eslint/js";
import globals from "globals";
import tseslint from "typescript-eslint";

export default [
  { files: ["**/*.{js,mjs,cjs,jsx,ts,mts,cts,tsx}"] },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    languageOptions: {
      globals: { ...globals.node, ...globals.es2021 },
      parserOptions: { ecmaVersion: "latest", sourceType: "module", ecmaFeatures: { jsx: true } },
    },
    rules: {
      "no-console": "warn",
      eqeqeq: "error",
      "no-var": "error",
      "prefer-const": "error",
    },
  },
];
