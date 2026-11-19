import { BoardApi, onBoard } from '@board/board';
import {
  boots, clockOffset, expect, offlineNextBoot, powerCut, resetWorld, test, waitForBoard, waitForWifi, world,
} from '../support/sim';

// The board has no RTC: NTP sets its clock and saves it to the card, and a boot without
// network starts from the saved time instead of the build's, so TLS and the services
// gated on a real clock still come up.
test.describe.configure({ mode: 'serial' });

test.beforeEach(async ({ request }) => {
  await resetWorld();
  await waitForWifi(request, { mode: 'connected', internet: true });
});

const num = async (cmd: string) => Number((await onBoard(cmd)).toString().trim());
const synced = async () => onBoard('test -f /run/ntp.synced').then(() => true, () => false);

test('NTP corrects a wrong clock and saves it to the card', async () => {
  await onBoard('date -s @1600000000 >/dev/null && rm -f /run/ntp.synced && s6-svc -r /run/service/ntpd');
  expect(await clockOffset()).toBeLessThan(-3600);

  await expect.poll(async () => Math.abs(await clockOffset()), { message: 'clock stepped', timeout: 3 * 60_000, intervals: [3000] })
    .toBeLessThan(60);
  expect(await synced()).toBe(true);
  expect(Math.abs((await num('cat /data/fake-hwclock')) - Date.now() / 1000)).toBeLessThan(120);
});

test('a boot without network starts from the saved clock, and NTP takes over once it is back', async ({ request }) => {
  await onBoard('/usr/libexec/s6/ntpd-handler step');
  const saved = await num('cat /data/fake-hwclock');
  const built = await num('cat /etc/fake-hwclock-default');
  const n = (await boots()).length;
  await offlineNextBoot();
  await powerCut();
  await expect.poll(async () => (await boots()).length, { message: 'booted again', timeout: 5 * 60_000, intervals: [3000] })
    .toBe(n + 1);
  await waitForBoard();

  const now = await num('date +%s');
  expect(now).toBeGreaterThanOrEqual(saved);
  expect(now).toBeGreaterThan(built);
  expect(await synced()).toBe(false);
  const board = new BoardApi(request);
  await board.login();
  // The gates on the internet (120 s) and on a real clock (30 s) give up instead of blocking the apps.
  await expect.poll(async () => (await board.services()).filter((s) => !s.running).map((s) => s.id),
    { message: 'every service up without network', timeout: 5 * 60_000, intervals: [5000] }).toEqual([]);

  await world('uplink', 'up');
  await expect.poll(synced, { message: 'NTP synced once online', timeout: 6 * 60_000, intervals: [5000] }).toBe(true);
  expect(Math.abs(await clockOffset())).toBeLessThan(60);
});

// ntpd steps the clock right when the frame gets online, which is when the owner who just set
// up its network is on the dashboard. A request the step lands in must still be answered.
test('a request the clock steps forward in is still answered', async () => {
  const answer = (await onBoard(
    "( sleep 1; date -s @$(( $(date +%s) + 3600 )) >/dev/null ) & " +
    "( printf 'GET /api/auth/status HTTP/1.1\\r\\nHost: board\\r\\n'; sleep 3; printf '\\r\\n' ) | nc 127.0.0.1 8080; " +
    'wait; date -s @$(( $(date +%s) - 3600 )) >/dev/null',
  )).toString();
  expect(answer).toMatch(/^HTTP\/1\.1 200/);
});
