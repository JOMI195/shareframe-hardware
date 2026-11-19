import { readFile, writeFile } from 'node:fs/promises';
import { test as base, expect, type APIRequestContext } from '@playwright/test';
import { BoardApi, FakeServer, onBoard } from '@board/board';

/** Fixtures for the system specs: the real board and the fake server, without the e2e container's state resets. */
export const test = base.extend<{ server: FakeServer; board: BoardApi }>({
  server: async ({ request }, use) => {
    await use(new FakeServer(request));
  },
  board: async ({ playwright, baseURL }, use) => {
    const request = await playwright.request.newContext({ baseURL });
    const board = new BoardApi(request);
    await board.login();
    await use(board);
    await request.dispose();
  },
});

export { expect };

// Harness state of tests/system/sim.sh, mounted into the runner.
const SIM_RUN = process.env.SIM_RUN_DIR ?? '/simrun';

/** The board's surroundings: access points, uplink and phone (configs/sim/overlay/usr/libexec/sim/world). */
export async function world(...args: string[]) {
  return (await onBoard(`/usr/libexec/sim/world ${args.map((a) => `'${a}'`).join(' ')}`)).toString().trim();
}

export type WifiMode = {
  mode: 'connected' | 'connecting' | 'ap';
  ssid: string;
  internet: boolean;
  server_connected: boolean | null;
  last_failed_secs_ago: number | null;
};

export async function wifiMode(request: APIRequestContext): Promise<WifiMode> {
  return (await (await request.get('/api/connection/mode')).json()).data;
}

/** Waits until the real Wi-Fi stack reports the mode; the board's own timers decide how long that takes. */
export async function waitForWifi(request: APIRequestContext, want: Partial<WifiMode>, timeout = 10 * 60_000) {
  await expect
    .poll(async () => {
      const mode = await wifiMode(request).catch(() => null);
      return mode && Object.entries(want).every(([k, v]) => mode[k as keyof WifiMode] === v) ? 'ok' : JSON.stringify(mode);
    }, { message: `wifi ${JSON.stringify(want)}`, timeout, intervals: [3000] })
    .toBe('ok');
}

/** Puts the simulator's surroundings back: both access points up with their passwords, uplink up, phone idle. */
export async function resetWorld() {
  await waitForBoard();
  await world('phone', 'leave');
  await world('uplink', 'up');
  await world('ap', 'home', 'psk', 'home-pass-123');
  await world('ap', 'office', 'psk', 'office-pass-123');
  await world('ap', 'home', 'up');
  await world('ap', 'office', 'up');
}

export const bootedSlot = async () => (await onBoard('shareframe-slot booted')).toString().trim();
export const pendingSlot = async () => (await onBoard('shareframe-slot pending')).toString().trim();
export const installedVersion = async () =>
  (await onBoard("sed -n 's/^VERSION=//p' /etc/shareframe-release")).toString().trim();

/** Boots the firmware stand-in has done, e.g. `boot 2 slot=B from=tryboot.txt`; power cuts and
 *  power-offs are left out. */
export async function boots(): Promise<string[]> {
  const log = await readFile(`${SIM_RUN}/boots.log`, 'utf8').catch(() => '');
  return log.split('\n').map((l) => l.replace(/^\S+ /, '')).filter((l) => /^boot \d+ /.test(l));
}

/** Makes the next trial boot panic, like a release that does not come up. */
export async function breakNextTrial() {
  await writeFile(`${SIM_RUN}/break-trial`, '');
}

/** Waits until the board answers on ssh and sim.sh has put its routers back after the boot. */
export async function waitForBoard(timeout = 10 * 60_000) {
  await expect
    .poll(async () => onBoard('test -f /run/sim/ready').then(() => true, () => false), {
      message: 'board back up with its routers', timeout, intervals: [3000],
    })
    .toBe(true);
}

/** Pulls the plug: QEMU dies without a shutdown and the firmware stand-in boots again. */
export async function powerCut() {
  await writeFile(`${SIM_RUN}/power-cut`, '');
}

/** One key of shareframe-sysinfo on the board. */
export async function sysinfo(key: string) {
  return (await onBoard(`shareframe-sysinfo | sed -n 's/^${key}=//p'`)).toString().trim();
}

/** The board's last boot record from its event log, e.g. `version=1.0.0 slot=A boot_count=3 unclean=0`. */
export async function lastBootRecord() {
  return (await onBoard("shareframe-event --since 0 | grep '\\[boot\\]' | tail -1 | cut -d' ' -f4-")).toString().trim();
}
