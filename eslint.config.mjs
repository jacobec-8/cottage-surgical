import { defineConfig, globalIgnores } from 'eslint/config'
import nextVitals from 'eslint-config-next/core-web-vitals'
import nextTypeScript from 'eslint-config-next/typescript'

export default defineConfig([
  ...nextVitals,
  ...nextTypeScript,
  {
    rules: {
      // The live catalog uses dynamic Shopify/Supabase origins and incomplete
      // source dimensions. Keep behavior stable during the framework move.
      '@next/next/no-img-element': 'off',
      // These legacy screens intentionally hydrate browser storage/query state
      // from effects; refactoring them is separate from framework parity.
      'react-hooks/set-state-in-effect': 'off',
      // Supabase relationship payloads are not generated from a Database type
      // yet. Existing narrow page-level casts remain during this migration.
      '@typescript-eslint/no-explicit-any': 'off',
    },
  },
  globalIgnores(['.next/**', 'dist/**', 'playwright-report/**', 'test-results/**']),
])
