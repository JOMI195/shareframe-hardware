import { BoardApi, DASHBOARD_PASSWORD, onBoard } from '@board/board';
import { boots, expect, lastBootRecord, resetWorld, test, waitForBoard, waitForWifi } from '../support/sim';

// The admin's factory reset on the real card: /data is formatted on the next boot and seeded
// again from the factory partition, so the owner's changes are gone and the frame's identity
// and its factory network stay.
test.beforeEach(async ({ request }) => {
  await resetWorld();
  await waitForWifi(request, { mode: 'connected', internet: true });
});

const apPass = async () => (await onBoard('. /data/wifi/ap.conf; echo "$AP_PASS"')).toString().trim();

test('a factory reset brings the factory state back and keeps the frame who it is', async ({ request, server, board }) => {
  await server.waitForFrame();
  const serial = (await board.get('/api/system/info')).serial_number;
  await server.sendPicture('gradient.jpg');
  await expect.poll(async () => (await board.get('/api/frame/slideshow/images')).images.length, { timeout: 60_000 })
    .toBeGreaterThan(0);
  await board.post('/api/auth/change-password', { current_password: DASHBOARD_PASSWORD, new_password: 'owner-pass-123' });
  await board.post('/api/connection/ap-password', { password: 'owner-hotspot-1' });
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
  expect((await owner.get('/api/system/info')).serial_number).toBe(serial);
  await expect.poll(async () => (await server.state()).tokenRequests, { message: 'a new token for the same frame', timeout: 5 * 60_000 })
    .toBeGreaterThan(tokenRequests);
  await server.waitForFrame();
});
