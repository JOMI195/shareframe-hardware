import { onBoard } from '@board/board';
import { expect, rebootCleanly, resetWorld, test, waitForWifi } from '../support/sim';

// The board under memory pressure on the real image: earlyoom kills the hog before the kernel
// has to, the owner and the admin see it, and the board's own services carry on.
test.beforeEach(async ({ request }) => {
  await resetWorld();
  await waitForWifi(request, { mode: 'connected', internet: true });
});

test('a process eating all memory is killed by earlyoom, reported, and the board carries on', async ({ board, server }) => {
  const pids = Object.fromEntries((await board.services()).map((s) => [s.id, s.pid]));
  // One line without an end: tail keeps all of it in memory.
  await onBoard("nohup sh -c 'head -c 2000m /dev/zero | tail' >/dev/null 2>&1 &");

  await expect.poll(async () => (await onBoard("shareframe-event --since 0 | grep '\\[oom\\]' || true")).toString(),
    { message: 'earlyoom killed the hog', timeout: 3 * 60_000, intervals: [3000] })
    .toMatch(/earlyoom killed pid=\d+ name=tail/);
  expect((await onBoard('dmesg | grep -ci "out of memory" || true')).toString().trim()).toBe('0');

  await expect.poll(async () => {
    const info = await board.get('/api/system/info');
    return { oom: info.health_oom, kills: Number(info.oom_kills) };
  }, { message: 'the dashboard shows the kill', timeout: 2 * 60_000 }).toEqual({ oom: 'critical', kills: 1 });
  await expect.poll(async () => (await server.state()).heartbeats.at(-1)?.health_oom, { timeout: 2 * 60_000 })
    .toBe('critical');

  for (const s of await board.services()) {
    expect(s.running, `${s.id} still running`).toBe(true);
    expect(s.pid, `${s.id} not restarted`).toBe(pids[s.id]);
  }
  await rebootCleanly();
});
