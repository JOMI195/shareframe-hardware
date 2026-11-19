import { BoardApi, DASHBOARD_PASSWORD, onBoard } from '@board/board';
import {
  boots, consoleLog, expect, lastBootRecord, powerCut, resetWorld, test, waitForBoard, waitForWifi,
} from '../support/sim';

// The admin's factory reset on the real card: /data is formatted on the next boot and seeded
// again from the factory partition, so the owner's changes are gone and the frame's identity
// and its factory network stay.
test.beforeEach(async ({ request }) => {
  await resetWorld();
  await waitForWifi(request, { mode: 'connected', internet: true });
});

test.describe.configure({ mode: 'serial' });

const hostKey = async () => (await onBoard('cat /data/dropbear/* | md5sum')).toString().trim();
const pictureFiles = async () => Number((await onBoard('ls -A /data/shareframe/images 2>/dev/null | wc -l')).toString().trim());
const wipes = async () => ((await consoleLog()).match(/mount-data: factory reset/g) ?? []).length;
const apPass = async () => (await onBoard('. /data/wifi/ap.conf; echo "$AP_PASS"')).toString().trim();

test('a factory reset brings the factory state back and keeps the frame who it is', async ({ request, server, board }) => {
  await server.waitForFrame();
  const serial = (await board.get('/api/system/info')).serial_number;
  await server.sendPicture('gradient.jpg');
  await expect.poll(async () => (await board.get('/api/frame/slideshow/images')).images.length, { timeout: 60_000 })
    .toBeGreaterThan(0);
  await board.post('/api/auth/change-password', { current_password: DASHBOARD_PASSWORD, new_password: 'owner-pass-123' });
  await board.post('/api/connection/ap-password', { password: 'owner-hotspot-1' });
  await onBoard('shareframe-wifi add office office-pass-123 >/dev/null');
  expect((await board.get('/api/connection/saved-networks')).networks).toEqual(['home', 'office']);
  expect(await pictureFiles()).toBeGreaterThan(0);
  const key = await hostKey();
  await onBoard('touch /data/shareframe/left-behind');
  const tokenRequests = (await server.state()).tokenRequests;
  const n = (await boots()).length;

  const id = await server.sendCommand('factory_reset');
  await server.expectCommandResult(id, 'accepted');
  await expect.poll(async () => (await boots()).length, { message: 'booted again', timeout: 5 * 60_000, intervals: [3000] })
    .toBe(n + 1);
  await waitForBoard();

  expect(await lastBootRecord()).toMatch(/boot_count=1 /);
  expect((await onBoard('ls -A /data/shareframe')).toString()).not.toContain('left-behind');
  expect(await apPass()).toBe('hotspot123');
  await waitForWifi(request, { mode: 'connected', ssid: 'home', internet: true });

  const owner = new BoardApi(request);
  await owner.login();
  expect((await owner.get('/api/frame/slideshow/images')).images).toEqual([]);
  expect(await pictureFiles()).toBe(0);
  expect((await owner.get('/api/connection/saved-networks')).networks).toEqual(['home']);
  expect(await hostKey(), 'a new ssh host key').not.toBe(key);
  expect((await owner.get('/api/system/info')).serial_number).toBe(serial);
  await expect.poll(async () => (await server.state()).tokenRequests, { message: 'a new token for the same frame', timeout: 5 * 60_000 })
    .toBeGreaterThan(tokenRequests);
  await server.waitForFrame();
});

// mkfs prints all its output when it is done; the wipe's own line goes to the console at once.
const formats = async () => ((await consoleLog()).match(/Info: format successful/g) ?? []).length;

// The plug pulled during the reset: a card still marked is reset again, a half formatted one
// fails its check and is formatted again. Either way the next boot ends in the factory state.
for (const cut of [
  // The format of /data takes about 25 s on the simulated card.
  { when: 'before the format starts', delayMs: 0, wipesAfter: 2 },
  { when: 'in the middle of the format', delayMs: 8000, wipesAfter: 1 },
]) {
  test(`a power cut ${cut.when} still ends in the factory state`, async ({ request, server, board }) => {
    await server.waitForFrame();
    const serial = (await board.get('/api/system/info')).serial_number;
    await board.post('/api/auth/change-password', { current_password: DASHBOARD_PASSWORD, new_password: 'owner-pass-123' });
    await onBoard('touch /data/shareframe/left-behind');
    const wiped = await wipes();
    const formatted = await formats();

    const id = await server.sendCommand('factory_reset');
    await server.expectCommandResult(id, 'accepted');
    await expect.poll(wipes, { message: 'the wipe started', timeout: 5 * 60_000, intervals: [100] }).toBe(wiped + 1);
    await new Promise((r) => setTimeout(r, cut.delayMs));
    expect(await formats(), 'cut before the format finished').toBe(formatted);
    const n = (await boots()).length;
    await powerCut();
    await expect.poll(async () => (await boots()).length, { message: 'booted after the cut', timeout: 5 * 60_000, intervals: [3000] })
      .toBe(n + 1);
    await waitForBoard();

    expect(await wipes(), 'how the boot after the cut found the card').toBe(wiped + cut.wipesAfter);
    expect(await formats(), 'formatted once, after the cut').toBe(formatted + 1);
    expect((await onBoard('ls -A /data/shareframe')).toString()).not.toContain('left-behind');
    expect(await apPass()).toBe('hotspot123');
    await waitForWifi(request, { mode: 'connected', ssid: 'home', internet: true });
    const owner = new BoardApi(request);
    await owner.login();
    expect((await owner.get('/api/system/info')).serial_number).toBe(serial);
    await server.waitForFrame();
  });
}
