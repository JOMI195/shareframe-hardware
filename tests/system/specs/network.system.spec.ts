import { codeOn, onBoard, showsApSetup, showsDefault, showsImage, waitForPanel } from '@board/board';
import { card, signIn } from '@board/fixtures';
import { expect, noNetworkNextBoot, rebootCleanly, resetWorld, test, waitForWifi, wifiMode, world } from '../support/sim';

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
  // The display keeps the setup screen's 10-minute window only for a frame that was set up.
  expect((await onBoard('cat /data/shareframe/wifi-joined')).toString().trim()).toMatch(/^\d+$/);
  // Where ping is blocked, the heartbeat's mark of the last server contact proves the internet.
  const mark = Number((await onBoard('cat /run/shareframe/backend-ok')).toString().trim());
  expect(Math.abs(mark - Number((await onBoard('date +%s')).toString().trim()))).toBeLessThan(120);
});

test('without its network the frame opens the hotspot, and a phone on it sets up a new network', async ({ page, request }) => {
  await world('ap', 'home', 'down');
  await waitForWifi(request, { mode: 'ap' });

  expect(await world('phone', 'join')).toContain('joined shareframe-sim');
  expect(JSON.parse(await world('phone', 'get', '/api/connection/mode')).data.mode).toBe('ap');

  await signIn(page);
  await page.goto('/network/');
  await expect(card(page, 'WLAN einrichten').getByText(/Das WLAN war nicht in Reichweite/)).toBeVisible();
  await page.getByRole('button', { name: 'WLAN hinzufügen' }).click();
  const form = card(page, 'WLAN hinzufügen');
  // Picked from what the radio saw on its last try, not typed.
  await form.getByRole('button', { name: /^office/ }).click();
  await expect(form.getByLabel(/Netzwerkname/)).toHaveValue('office');
  await form.getByLabel(/^Passwort$/).fill('office-pass-123');
  await form.getByRole('button', { name: 'Speichern & verbinden' }).click();
  await waitForWifi(request, { mode: 'connected', ssid: 'office', internet: true });
  await waitForPanel(showsDefault, 'slideshow after connecting', 120_000);
  await expect(world('phone', 'get', '/api/connection/mode'), 'the hotspot is gone').rejects.toThrow();
});

// A set-up frame restarted where its network is gone, e.g. after a router change: the panel shows
// the setup screen with a code for a while, and the code signs the owner in on the hotspot.
test('a frame that restarts without its network shows a setup code that signs the owner in', async ({ page, request }) => {
  await noNetworkNextBoot();
  await rebootCleanly();
  await waitForWifi(request, { mode: 'ap' });
  const code = codeOn(await waitForPanel(showsApSetup, 'setup screen with its code', 180_000));

  await page.goto('/auth/sign-in');
  await expect(page.getByText(/stellt den Hotspot .* bereit/)).toBeVisible();
  await page.getByRole('textbox', { name: 'Einrichtungscode' }).fill(code);
  await page.getByRole('button', { name: 'Anmelden', exact: true }).click();
  await expect(page).toHaveURL(/\/network\/$/);

  await world('ap', 'home', 'up');
  await world('ap', 'office', 'up');
  await card(page, 'WLAN einrichten').getByRole('button', { name: 'Jetzt verbinden' }).click();
  await page.getByRole('dialog').getByRole('button', { name: 'Verbinden' }).click();
  await waitForWifi(request, { mode: 'connected', ssid: 'home', internet: true });
  await waitForPanel(showsDefault, 'slideshow once the frame is back on its network', 120_000);
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

// The real wpa_supplicant tells a refused password apart; saving the network again with the new
// one replaces it instead of adding a second entry.
test('a changed router password is named as such and fixed by saving the network again', async ({ board, request }) => {
  await world('ap', 'home', 'psk', 'changed-pass-999');
  await waitForWifi(request, { mode: 'ap' });
  await expect.poll(async () => (await wifiMode(request)).last_failed_reason).toBe('wrong_password');

  await board.post('/api/connection/connect', { ssid: 'home', password: 'changed-pass-999' });
  expect((await board.get('/api/connection/saved-networks')).networks).toEqual(['home']);
  await board.post('/api/connection/apply');
  await waitForWifi(request, { mode: 'connected', ssid: 'home', internet: true });

  // Back to the password the other tests expect.
  await board.post('/api/connection/connect', { ssid: 'home', password: 'home-pass-123' });
  await world('ap', 'home', 'psk', 'home-pass-123');
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
