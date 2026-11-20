import { onBoard } from '@board/board';
import { signIn } from '@board/fixtures';
import { boots, expect, powerCut, rebootCleanly, resetWorld, test, waitForBoard, waitForWifi } from '../support/sim';

// The display's safe mode on the real image: boot-guard and display-crash-guard keep a loop
// from wearing out the panel, the admin sees why in the heartbeat, a clean boot lifts it.
test.describe.configure({ mode: 'serial' });

test.beforeEach(async ({ request }) => {
  await resetWorld();
  await waitForWifi(request, { mode: 'connected', internet: true });
});

const DISPLAY = '/run/service/shareframe-display';
const safeMode = async () => (await onBoard('cat /run/shareframe/safe-mode 2>/dev/null || true')).toString().trim();
const displayUp = async () => (await onBoard(`s6-svstat -o up ${DISPLAY}`)).toString().trim() === 'true';
const displayCrashes = async () =>
  Number((await onBoard('shareframe-event --since 0 | grep -c "\\[crash\\] shareframe-display signal 11" || true')).toString().trim());
const displayPid = async () => Number((await onBoard(`s6-svstat -o pid ${DISPLAY}`)).toString().trim());

test('power cuts in a row put the display into safe mode until a clean boot', async ({ server }) => {
  for (let i = 1; i <= 5; i++) {
    const n = (await boots()).length;
    await powerCut();
    await expect.poll(async () => (await boots()).length, { message: `power cut ${i}`, timeout: 5 * 60_000, intervals: [3000] })
      .toBe(n + 1);
    await waitForBoard();
    if (i < 5) expect(await safeMode()).toBe('');
  }

  expect(await safeMode()).toBe('boot-loop');
  await expect.poll(displayUp, { message: 'display kept down' }).toBe(false);
  await expect.poll(async () => (await server.state()).heartbeats.at(-1)?.safe_mode, { timeout: 2 * 60_000 })
    .toBe('boot-loop');

  await rebootCleanly();
  expect(await safeMode()).toBe('');
  await expect.poll(displayUp, { message: 'display back' }).toBe(true);
});

/** Crashes the display five times in a row, which trips its safe mode. */
async function crashDisplayFiveTimes() {
  await expect.poll(displayUp).toBe(true);
  let pid = await displayPid();
  for (let i = 1; i <= 5; i++) {
    expect(pid).toBeGreaterThan(1);
    await onBoard(`kill -SEGV ${pid}`);
    if (i === 5) break;
    const crashed = pid;
    // Down in between (pid -1) until s6 has started it again.
    await expect.poll(async () => { pid = await displayPid(); return pid > 1 && pid !== crashed; },
      { message: `display restarted after crash ${i}` }).toBe(true);
  }
  await expect.poll(safeMode, { message: 'safe mode tripped' }).toBe('display-crash');
}

test('a display that keeps crashing is kept down until the next boot', async ({ server }) => {
  const crashes = await displayCrashes();
  await crashDisplayFiveTimes();

  await expect.poll(displayUp, { message: 'display kept down' }).toBe(false);
  expect(await displayCrashes()).toBe(crashes + 5);
  await expect.poll(async () => (await server.state()).heartbeats.at(-1)?.safe_mode, { timeout: 2 * 60_000 })
    .toBe('display-crash');

  await rebootCleanly();
  expect(await safeMode()).toBe('');
  await expect.poll(displayUp, { message: 'display back' }).toBe(true);
});

// Without this the owner would only see a frame that went blank.
test('the owner sees why the display is off and turns it back on from the dashboard', async ({ page }) => {
  await crashDisplayFiveTimes();
  await expect.poll(displayUp, { message: 'display kept down' }).toBe(false);

  await signIn(page);
  const notice = page.getByRole('region', { name: 'Anzeige ausgeschaltet' });
  await expect(notice.getByText(/mehrmals abgestürzt/)).toBeVisible({ timeout: 30_000 });
  await notice.getByRole('button', { name: 'Anzeige wieder einschalten' }).click();

  await expect.poll(displayUp, { message: 'display back' }).toBe(true);
  expect(await safeMode()).toBe('');
  await expect(notice).toBeHidden({ timeout: 30_000 });
});
