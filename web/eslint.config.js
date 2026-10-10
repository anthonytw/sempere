import js from "@eslint/js";
import tseslint from "typescript-eslint";

export default tseslint.config(
  // smoke*.mjs drive Playwright untyped (smoke-cache.mjs through the pinned dev dependency, the others a global one).
  { ignores: ["dist/", "node_modules/", "test/fixtures/", "test/golden/", "scripts/smoke-lib.mjs", "scripts/smoke.mjs", "scripts/smoke-attachments.mjs", "scripts/smoke-video.mjs", "scripts/smoke-cache.mjs", "scripts/smoke-passkey.mjs", "scripts/smoke-search-keys.mjs", "scripts/smoke-pan.mjs", "scripts/smoke-language.mjs", "scripts/smoke-release.mjs"] },
  js.configs.recommended,
  ...tseslint.configs.recommendedTypeChecked,
  {
    languageOptions: {
      parserOptions: { projectService: { allowDefaultProject: ["eslint.config.js"] }, tsconfigRootDir: import.meta.dirname },
    },
    rules: {
      // The viewer never builds markup from strings (CSP: Trusted Types).
      "no-restricted-properties": ["error",
        { property: "innerHTML", message: "Build DOM nodes; never parse markup." },
        { property: "outerHTML", message: "Build DOM nodes; never parse markup." },
        { property: "insertAdjacentHTML", message: "Build DOM nodes; never parse markup." }],
      "no-eval": "error",
      "no-implied-eval": "error",
      "@typescript-eslint/no-non-null-assertion": "error",
      "@typescript-eslint/no-unused-vars": ["error", { argsIgnorePattern: "^_" }],
    },
  },
);
