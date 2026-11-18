import { defineConfig } from '@playwright/test';

// The real image under QEMU: every step waits on the board's own timers and an emulated ARMv6.
export default defineConfig({
  testDir: './specs',
  workers: 1,
  fullyParallel: false,
  timeout: 40 * 60_000,
  expect: { timeout: 60_000 },
  reporter: [['list'], ['html', { open: 'never', outputFolder: process.env.E2E_REPORT_DIR ?? 'playwright-report' }]],
  outputDir: process.env.E2E_RESULTS_DIR ?? 'test-results',
  use: {
    baseURL: process.env.E2E_BASE_URL,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    locale: 'de-DE',
    timezoneId: 'Europe/Berlin',
    viewport: { width: 1600, height: 900 },
    actionTimeout: 30_000,
    navigationTimeout: 60_000,
  },
  projects: [{ name: 'system' }],
});
