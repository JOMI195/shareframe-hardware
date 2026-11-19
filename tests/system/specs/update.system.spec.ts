import { BoardApi, onBoard } from '@board/board';
import { signIn } from '@board/fixtures';
import {
  bootedSlot, boots, breakNextTrial, expect, installedVersion, pendingSlot, rebootCleanly, resetWorld, test, waitForBoard,
  waitForWifi,
} from '../support/sim';

// A real bundle from `tests/system/sim.sh update bundle <version>`; `sim.sh test` builds it when missing.
const VERSION = process.env.SIM_UPDATE_VERSION ?? '1.0.1';
const BUNDLE = `shareframe-${VERSION}.raucb`;
// The same release signed with a key the board does not trust (`sim.sh update bundle <v> --foreign-key`).
const FOREIGN = `shareframe-${VERSION}-foreign.raucb`;
// A later release carrying tests/system/fixtures/990-sim-break-data.sh (`--with-migration`).
const BROKEN = process.env.SIM_MIGRATION_VERSION ?? '1.0.2';

// The corrupt bundle and the rollback run first: both leave the frame on its old release, ready
// for the real install.
test.describe.configure({ mode: 'serial' });

test.beforeEach(async ({ request }) => {
  await resetWorld();
  await waitForWifi(request, { mode: 'connected', internet: true });
});

async function install(board: import('@board/board').BoardApi, server: import('@board/board').FakeServer,
  version = VERSION) {
  await server.waitForFrame();
  await server.offerRelease({ version, bundleFile: `shareframe-${version}.raucb` });
  const trialBoots = (await boots()).filter((b) => b.includes('from=tryboot.txt')).length;
  await board.post('/api/system/updates/perform-update');
  await expect
    .poll(async () => (await boots()).filter((b) => b.includes('from=tryboot.txt')).length, {
      message: 'rebooted into the staged slot', timeout: 25 * 60_000, intervals: [5000],
    })
    .toBe(trialBoots + 1);
}

test('a bundle that is not what the server announced is never installed', async ({ board, server }) => {
  await server.waitForFrame();
  const before = (await boots()).length;
  const version = await installedVersion();
  await server.offerRelease({ version: VERSION, bundleFile: BUNDLE, corrupt: true });
  await board.post('/api/system/updates/perform-update');

  await expect
    .poll(async () => (await board.get('/api/system/updates/status')).phase, { message: 'update failed', timeout: 15 * 60_000, intervals: [5000] })
    .toBe('failed');
  expect((await board.get('/api/system/updates/history')).history[0]).toMatchObject({ result: 'install-failed' });
  expect((await boots()).length).toBe(before);
  expect(await installedVersion()).toBe(version);
  expect(await pendingSlot()).toBe('');
  await onBoard('s6-svc -r /run/service/shareframe-update');
});

test('a bundle signed by someone else is refused', async ({ board, server }) => {
  await server.waitForFrame();
  const before = (await boots()).length;
  const version = await installedVersion();
  await server.offerRelease({ version: VERSION, bundleFile: FOREIGN });
  await board.post('/api/system/updates/perform-update');

  await expect
    .poll(async () => (await board.get('/api/system/updates/status')).phase, { message: 'update failed', timeout: 15 * 60_000, intervals: [5000] })
    .toBe('failed');
  const { error } = await board.get('/api/system/updates/status');
  expect(error).toMatch(/rauc install failed/);
  expect(error).toMatch(/signature|certificate|verif/i);
  expect((await board.get('/api/system/updates/history')).history[0]).toMatchObject({ result: 'install-failed' });
  expect((await boots()).length).toBe(before);
  expect(await installedVersion()).toBe(version);
  expect(await pendingSlot()).toBe('');
  await onBoard('s6-svc -r /run/service/shareframe-update');
});

test('a release that does not come up rolls back to the slot it came from', async ({ board, server }) => {
  const slot = await bootedSlot();
  const version = await installedVersion();
  expect(version).not.toBe(VERSION);

  await breakNextTrial();
  await install(board, server);
  await waitForBoard();

  expect((await boots()).slice(-2).map((b) => b.replace(/^boot \d+ /, ''))).toEqual([
    `slot=${slot === 'A' ? 'B' : 'A'} from=tryboot.txt`,
    `slot=${slot} from=config.txt`,
  ]);
  expect(await bootedSlot()).toBe(slot);
  expect(await installedVersion()).toBe(version);
  await expect.poll(pendingSlot, { message: 'the failed slot is no longer pending' }).toBe('');
});

test('a release installs into the other slot, boots once on trial and is committed', async ({ page, board, server }) => {
  const slot = await bootedSlot();
  const other = slot === 'A' ? 'B' : 'A';

  await install(board, server);
  await waitForBoard();
  expect(await bootedSlot()).toBe(other);
  expect(await installedVersion()).toBe(VERSION);
  await expect.poll(pendingSlot, { message: 'rauc-mark-good committed the slot', timeout: 10 * 60_000 }).toBe('');
  await expect
    .poll(async () => (await server.state()).heartbeats.at(-1), { message: 'heartbeat from the new release', timeout: 120_000 })
    .toMatchObject({ version: VERSION, boot_slot: other });

  await onBoard('(sleep 1; s6-linux-init-shutdown -r now) >/dev/null 2>&1 &');
  await expect
    .poll(async () => (await boots()).at(-1), { message: 'next boot', timeout: 5 * 60_000, intervals: [5000] })
    .toMatch(new RegExp(`slot=${other} from=config.txt$`));
  await waitForBoard();

  await signIn(page);
  await page.goto('/updates/');
  await expect(page.getByText(VERSION).first()).toBeVisible();
});

// /data is shared by both slots and only the new release migrates it. update-verify backs up
// what the frame cannot do without before the install, and the trial boot puts it back right
// after its migrations, before the seeds and the apps could replace it with factory or empty state.
test('a release whose migration deletes the identity, the database and the Wi-Fi config is committed with all of them back', async ({ request, board, server }) => {
  await onBoard('shareframe-wifi add office office-pass-123 >/dev/null');
  await board.post('/api/frame/slideshow/interval', { interval_seconds: 1234 });
  const serial = (await board.get('/api/system/info')).serial_number;
  await onBoard('echo "wifi secrets db" > /data/shareframe/sim-break');
  const other = (await bootedSlot()) === 'A' ? 'B' : 'A';

  await install(board, server, BROKEN);
  await waitForBoard();
  expect(await bootedSlot()).toBe(other);
  expect((await onBoard('test -e /data/shareframe/sim-break && echo still || echo ran')).toString().trim()).toBe('ran');
  await expect.poll(pendingSlot, { message: 'committed', timeout: 10 * 60_000 }).toBe('');
  expect(await installedVersion()).toBe(BROKEN);
  expect(JSON.parse((await onBoard('cat /data/shareframe/update-verify/last.json')).toString()))
    .toMatchObject({ secrets: 'restored', db: 'restored', wpa_supplicant: 'restored', result: 'ok', to_version: BROKEN });

  const owner = new BoardApi(request);
  await owner.login();
  expect((await owner.get('/api/system/info')).serial_number).toBe(serial);
  expect((await owner.slideshowStatus()).interval_seconds).toBe(1234);
  await server.waitForFrame();

  await rebootCleanly();
  expect((await onBoard('cat /data/wifi/wpa_supplicant.conf')).toString()).toContain('office');
  await onBoard('shareframe-wifi del office >/dev/null');
  await owner.login();
  await owner.post('/api/frame/slideshow/interval', { interval_seconds: 900 });
});
