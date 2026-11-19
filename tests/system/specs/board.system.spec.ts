import { onBoard } from '@board/board';
import { signIn } from '@board/fixtures';
import {
  boots, consoleLog, expect, rebootCleanly, lastBootRecord, powerCut, resetWorld, sysinfo, test, waitForBoard, waitForWifi, world,
} from '../support/sim';

// The board's own life on the real image: power, remote commands, its services and its
// support package, as the admin and the owner see them.
test.describe.configure({ mode: 'serial' });

test.beforeEach(async ({ request }) => {
  await resetWorld();
  await waitForWifi(request, { mode: 'connected', internet: true });
});

const bootCount = async () => (await boots()).length;

test('a power cut is an unclean boot: counted, and the board comes back to its network', async ({ request }) => {
  const before = Number(await sysinfo('unclean_resets'));
  const n = await bootCount();
  // A board that has been up a while has its counters on the card; seconds after a write
  // they still sit in the page cache and a power cut takes them along.
  await onBoard('sync');
  await powerCut();
  await expect.poll(bootCount, { message: 'booted again', timeout: 5 * 60_000, intervals: [3000] }).toBe(n + 1);
  await waitForBoard();

  expect(await lastBootRecord()).toMatch(/unclean=1/);
  expect(Number(await sysinfo('unclean_resets'))).toBe(before + 1);
  await waitForWifi(request, { mode: 'connected', ssid: 'home', internet: true });
});

test('a remote reboot is answered, then the board shuts down cleanly and comes back', async ({ server }) => {
  await server.waitForFrame();
  const n = await bootCount();
  const id = await server.sendCommand('reboot');
  await server.expectCommandResult(id, 'accepted');
  await expect.poll(bootCount, { message: 'booted again', timeout: 5 * 60_000, intervals: [3000] }).toBe(n + 1);
  await waitForBoard();

  expect(await lastBootRecord()).toMatch(/unclean=0/);
  expect((await boots()).at(-1)).toMatch(/from=config\.txt$/);
  await expect.poll(async () => (await server.state()).connectedFrames, { message: 'frame back on the server', timeout: 5 * 60_000 })
    .toBeGreaterThan(0);
  const again = await server.sendCommand('reboot');
  expect((await server.expectCommandResult(again, 'rejected')).reason).toMatch(/less than 30 minutes ago/);
  await onBoard('rm -f /data/shareframe/remote-reboot-at');
});

test('the services page shows what s6 supervises on the board', async ({ board }) => {
  for (const service of await board.services()) {
    const pid = (await onBoard(`s6-svstat -o pid /run/service/shareframe-${service.id}`)).toString().trim();
    expect(String(service.pid), service.id).toBe(pid);
    expect(service.running, service.id).toBe(true);
  }
});

test('the support package carries the real board state and no Wi-Fi password', async ({ page, server }) => {
  await signIn(page);
  await page.goto('/general/');
  await page.getByRole('button', { name: 'Diagnose senden' }).click();
  await expect(page.getByText('Diagnose an den Support gesendet')).toBeVisible({ timeout: 120_000 });

  const sent = (await server.diagnostics()).at(-1)!;
  expect(sent.trigger).toBe('owner');
  expect(sent.text).toMatch(/shareframe-display: up \(pid \d+/);
  expect(sent.text).toContain('===== dmesg =====');
  expect(sent.text).toContain('[boot]');
  expect(sent.text).not.toContain('home-pass-123');
});

test('the hotspot password changed on the dashboard is the one a phone needs', async ({ request, board }) => {
  await board.post('/api/connection/ap-password', { password: 'new-hotspot-1' });
  await world('ap', 'home', 'down');
  await waitForWifi(request, { mode: 'ap' });

  await expect(world('phone', 'join', 'shareframe-sim', 'hotspot123')).rejects.toThrow();
  expect(await world('phone', 'join', 'shareframe-sim', 'new-hotspot-1')).toContain('joined shareframe-sim');
  await world('phone', 'leave');
  await board.post('/api/connection/ap-password', { password: 'hotspot123' });
});

test('the data partition reaches the end of the card on the first boot, and grows only then', async () => {
  const gap = Number((await onBoard(
    'b=/sys/block/mmcblk0; echo $(( $(cat $b/size) - $(cat $b/mmcblk0p6/start) - $(cat $b/mmcblk0p6/size) ))',
  )).toString().trim());
  expect(gap).toBeLessThan(32768);
  await rebootCleanly();
  expect((await consoleLog()).match(/expand-data: growing/g)).toHaveLength(1);
});
