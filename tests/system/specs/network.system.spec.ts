import { showsDefault, showsImage, waitForPanel } from '@board/board';
import { card, signIn } from '@board/fixtures';
import { expect, resetWorld, test, waitForWifi, wifiMode, world } from '../support/sim';

// Every step runs on the real Wi-Fi stack, so the waits are the board's own timers:
// 45 s to associate before the hotspot, 30 s between link checks.
test.describe.configure({ mode: 'serial' });

test.beforeEach(async ({ board, request }) => {
  await resetWorld();
  // Every test starts on home with only home saved; the active network cannot be forgotten.
  const others = (await board.get('/api/connection/saved-networks')).networks.filter((n: string) => n !== 'home');
  if (others.length) {
    await world('ap', 'office', 'down');
    await waitForWifi(request, { mode: 'connected', ssid: 'home' });
    for (const ssid of others) await board.post('/api/connection/forget', { ssid });
    await world('ap', 'office', 'up');
  }
  await waitForWifi(request, { mode: 'connected', ssid: 'home', internet: true });
});

test('the frame joins its saved network and reaches the server through it', async ({ server }) => {
  await server.waitForFrame();
  await expect
    .poll(async () => (await server.state()).heartbeats.at(-1), { message: 'heartbeat over Wi-Fi', timeout: 120_000 })
    .toMatchObject({ wifi_mode: 'connected', wlan_connected: true });
});

test('without its network the frame opens the hotspot, and a phone on it sets up a new network', async ({ page, request }) => {
  await world('ap', 'home', 'down');
  await waitForWifi(request, { mode: 'ap' });

  expect(await world('phone', 'join')).toContain('joined shareframe-sim');
  expect(JSON.parse(await world('phone', 'get', '/api/connection/mode')).data.mode).toBe('ap');

  await signIn(page);
  await page.goto('/network/');
  await page.getByRole('button', { name: 'WLAN hinzufügen' }).click();
  const dialog = page.getByRole('dialog');
  await dialog.getByLabel(/Netzwerkname/).fill('office');
  await dialog.getByLabel(/^Passwort$/).fill('office-pass-123');
  await dialog.getByRole('button', { name: 'Hinzufügen' }).click();
  await expect(card(page, 'WLAN').getByRole('listitem')).toContainText(['home', 'office']);

  await card(page, 'WLAN einrichten').getByRole('button', { name: 'Jetzt verbinden' }).click();
  await page.getByRole('dialog').getByRole('button', { name: 'Verbinden' }).click();
  await waitForWifi(request, { mode: 'connected', ssid: 'office', internet: true });
  await waitForPanel(showsDefault, 'slideshow after connecting', 120_000);
  await expect(world('phone', 'get', '/api/connection/mode'), 'the hotspot is gone').rejects.toThrow();
});

test('when the network it is on goes away the frame moves to another saved one', async ({ board, request }) => {
  await board.post('/api/connection/connect', { ssid: 'office', password: 'office-pass-123' });
  await world('ap', 'home', 'down');
  await waitForWifi(request, { ssid: 'office', internet: true });
  await world('ap', 'home', 'up');
  await world('ap', 'office', 'down');
  await waitForWifi(request, { mode: 'connected', ssid: 'home', internet: true });

  await board.post('/api/connection/forget', { ssid: 'office' });
  expect((await board.get('/api/connection/saved-networks')).networks).toEqual(['home']);
});

test('a changed router password ends in the hotspot until it is fixed', async ({ board, request }) => {
  await world('ap', 'home', 'psk', 'changed-pass-999');
  await waitForWifi(request, { mode: 'ap' });
  expect((await wifiMode(request)).last_failed_secs_ago).not.toBeNull();

  await world('ap', 'home', 'psk', 'home-pass-123');
  await board.post('/api/connection/apply');
  await waitForWifi(request, { mode: 'connected', ssid: 'home', internet: true });
});

test('without internet the frame stays on its network and catches up once it is back', async ({ request, server }) => {
  await server.waitForFrame();
  const tokens = (await server.state()).tokenRequests;

  await world('uplink', 'down');
  await waitForWifi(request, { mode: 'connected', ssid: 'home', internet: false });
  await expect.poll(async () => (await wifiMode(request)).server_connected, { message: 'server link lost' }).toBe(false);

  await world('uplink', 'up');
  await waitForWifi(request, { mode: 'connected', ssid: 'home', internet: true });
  await server.waitForFrame();
  expect((await server.state()).tokenRequests, 'the frame kept its token').toBe(tokens);

  const id = await server.sendPicture('gradient.jpg');
  await waitForPanel(showsImage(id), 'picture sent after the outage', 120_000);
  await server.reset();
});
