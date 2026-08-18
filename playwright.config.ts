import { defineConfig, devices } from '@playwright/test'

const baseURL = 'http://127.0.0.1:5173'
const placeholderSupabaseUrl = 'http://127.0.0.1:55439'
const placeholderSupabaseKey = 'public-anon-placeholder'

export default defineConfig({
  testDir: './tests/e2e',
  fullyParallel: true,
  forbidOnly: Boolean(process.env.CI),
  failOnFlakyTests: Boolean(process.env.CI),
  retries: process.env.CI ? 1 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: process.env.CI
    ? [['github'], ['html', { open: 'never' }]]
    : [['list'], ['html', { open: 'never' }]],
  expect: {
    timeout: 10_000,
  },
  use: {
    baseURL,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
  webServer: [
    {
      command: 'node tests/e2e/supabase-fixture-server.mjs',
      url: `${placeholderSupabaseUrl}/health`,
      reuseExistingServer: false,
      timeout: 10_000,
    },
    {
      // CI builds explicitly before Playwright. Local runs build first so the
      // browser always verifies the production server instead of the dev server.
      command: process.env.CI ? 'npm run start' : 'npm run build && npm run start',
      url: baseURL,
      reuseExistingServer: !process.env.CI,
      timeout: 180_000,
      env: {
        // E2E runs never read a developer's or CI's live Supabase project.
        NEXT_PUBLIC_SUPABASE_URL: placeholderSupabaseUrl,
        NEXT_PUBLIC_SUPABASE_ANON_KEY: placeholderSupabaseKey,
      },
    },
  ],
})
