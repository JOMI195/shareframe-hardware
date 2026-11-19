# Testing

Tests for the image: its scripts, its build and release tooling, and the whole board
under QEMU. The board apps have their own suites in shareframe-board (`README.tests.md`
there); the system tier here runs both repos together.

```bash
./test.sh lint          # shellcheck: image scripts as busybox ash, tooling as bash
./test.sh unit          # lint + one .bats per script, seconds
./test.sh contract      # formats shared with shareframe-board, both directions
./test.sh build         # release + provisioning tools, s6-rc graph, kernel patches
./test.sh integration   # nginx and the USB link's DHCP in rootless namespaces
./test.sh all           # lint + unit + contract + build + integration, about a minute
./test.sh everything    # all, then shareframe-board's ./test.sh all, then system
./test.sh shell         # a shell in the test container, repo at /src (read-only)
./test.sh system        # real image under QEMU (see "System tier"), slow
```

Everything except `system` runs in `tests/docker` (Debian with busybox built from
`br2-external/configs/busybox.conf`, bats, shellcheck), as your user, with the repo mounted
read-only. JUnit reports land in `build/test-reports/<tier>/`. Extra arguments go to bats or
Playwright: `./test.sh unit -f commit`, `./test.sh system --grep rollback`.

## Unit tier

```
tests/
├─ docker/          the test image
├─ support/         NO TESTS LIVE HERE — common.bash: sf_setup, host_setup, stub, quiet_stub,
│                   called/assert_called/refute_called, eventually
└─ unit/            one <script>.bats per script, by where it lives on the image:
   ├─ bin/          br2-external/overlay/usr/bin
   ├─ s6/           br2-external/overlay/usr/libexec/s6
   ├─ rauc/         br2-external/package/shareframe-rauc/files
   ├─ init/         shareframe-init's skel scripts and the dhcpcd hook
   ├─ lib/          br2-external/overlay/usr/lib/shareframe/lib.sh
   ├─ sysinfo/      the sysinfo banner, compiled for the host
   ├─ scripts/      host tooling in scripts/ and automation.sh
   └─ inventory.bats  every script has a test or a line in tests/UNTESTED
```

`tests/UNTESTED` names each script without a unit test, the tier that covers it (`system`,
`integration`, `hardware`) and why: mounts of the real card, daemons that only `exec`, the
initramfs. A new script gets a `.bats` file or a line there, or `inventory.bats` fails.

**Which tier?** One script against stubbed commands and a temp tree → unit. Real mounts,
network namespaces or daemons talking to each other → integration. The real image → system.

- `#!/bin/sh` is busybox ash, and busybox applets come before Debian's tools on `PATH`, so a
  script sees the userland it gets on the board. Host tooling (`scripts/`, `automation.sh`)
  runs with `host_setup` instead: GNU userland, no busybox.
- Every path a script touches is an environment variable with the board's path as default
  (`DATA_DIR="${DATA_DIR:-/data/shareframe}"`); tests point them into `$T`
  (`$BATS_TEST_TMPDIR`). A script without such a variable gets one before it gets a test.
- Commands at the edge of the script are stubs: `stub name [body]` records `name args` in
  `$CALLS` and runs body; `quiet_stub name body` only runs body. The image's own tools
  (`$BIN`, e.g. `shareframe-led`) are on `PATH` for real, unless a test stubs them.
- Waits are `eventually <seconds> <command>` with a function as command, never a fixed
  sleep; a script's own polling sleep is stubbed down (`quiet_stub sleep 'exec /usr/bin/sleep 0.05'`).
- A daemon or background job started by a test runs with `3>&-` (bats waits on fd 3) and is
  stopped in `teardown`.

## Contract tier

The board apps parse what these scripts print and write, and these scripts read what the
apps write. The producer owns the golden, the consumer reads it from the other checkout:

- `tests/contract/golden/` is what this repo produces: `shareframe-wifi list`/`status`,
  `wifi-mode.json`, `s6-svstat` (s6 itself, the version the image builds), the event log,
  the update history, the tryboot backend's slot, the frame identity. Each is written by a
  test next to its script's unit tests, tagged `# bats test_tags=contract`, from fixed input
  and a fixed clock (`fixed_clock`), and compared with `assert_golden`. shareframe-board's
  `tests/contract/hardware` feeds them to its real parsers.
- `tests/contract/consume.bats` feeds shareframe-board's own goldens (the staged update
  meta, the profiles, the flag paths) to the scripts that read them.

`./test.sh contract` runs both and needs `../shareframe-board` (or `SHAREFRAME_BOARD_DIR`).
A deliberate format change: `./test.sh contract --update-golden`, then the board side, both
repos in one go.

## Build tier

`tests/build/`, run against fixtures made in each test's temp dir:

- `make-release.bats`: a bundle from a tiny squashfs and boot.tar, signed with a CA and
  key generated per test (openssl, never committed), verified with `rauc info --keyring`;
  the release JSON against the bundle; the version and prod-key guards.
- `provision-device.bats`: a six-partition card with the genimage layout in small;
  factory files land in p5 of a copy and nothing before it changes.
- `s6-rc.bats`: `s6-rc-compile` (built in the test image, s6-rc 0.5.5.0 like Buildroot)
  over `shareframe-init/source`; every referenced service exists, every service is started
  by the default bundle or a dependency of it, the orderings the design relies on hold,
  and every script an `up`/`run`/`finish` calls exists and can run.
- `kernel-patches.bats`: the patches are applied in Buildroot's kernel tree. Without
  `build/buildroot` it skips; `./test.sh build --strict` fails instead.

## Integration tier

`tests/integration/`: real daemons with the image's config, each scenario a script inside
`in_ns` (`tests/support/ns.bash`: `unshare -rmn`, root mapped to your user). It binds the
image's files over their paths and wires veth pairs; peers are entered with `nsenter --net`
(`ip netns exec` wants to remount `/sys`, which a container refuses). The container gets
`seccomp`, `apparmor` and `label` relaxed, never `--privileged` or devices.

- `nginx.bats`: the dashboard SPA and its client routes, `/api` to the backend (also one
  that serves a single request per connection, like the board's), the board's JSON envelope
  when the backend is down, its errors in syslog, the captive-portal probes, SSDP.
- `usb0.bats`: `setup-usb0` and the image's `udhcpd.conf` lease 10.55.0.2 to the
  computer on the cable, without a router or DNS.

Wi-Fi daemons, the card's mounts and hwsim stay in the system tier.

## System tier

`tests/system/sim.sh` runs the **real board image** (initramfs → squashfs slot → s6 → all
services, ARMv6) under QEMU `raspi0`, with simulated Wi-Fi around it, the fake Shareframe
server, and a stand-in for the Pi firmware that boots the A/B slots. Use it for anything the
Docker e2e board fakes: the Wi-Fi stack (wifi-mode-manager, wpa_supplicant, hostapd, dhcpcd,
dnsmasq), the init and service scripts of this repo, the board apps from `../shareframe-board`, the ARM build, RAUC updates
across a reboot, rollback, and anything that has to survive a reboot on `/data`.

**Which tier?** Real image, init, s6 ordering, Wi-Fi daemons, A/B update across a reboot →
system. Everything else stays in the cheaper tiers, here and in shareframe-board; the specs
only hold flows nothing cheaper can show.

```bash
tests/system/sim.sh build        # once (long), and after changing the image; incremental afterwards
tests/system/sim.sh up           # boots in about a minute; dashboard http://127.0.0.1:8090
tests/system/sim.sh status       # slots, version, wifi state, services, server state
tests/system/sim.sh down         # stops everything and deletes the run state
./test.sh system [--keep]     # up → specs → down
./test.sh system check        # specs and their imports resolve, no board needed
```

### Topology

| Piece | How |
|---|---|
| Board Wi-Fi `wlan0` | hwsim radio 0; the real s6 Wi-Fi stack owns it |
| Router `home` / `office` | netns `world` on the board: hwsim radios 1 and 2 run hostapd, bridged onto QEMU's user-mode uplink. DHCP and internet come from QEMU (10.0.2.0/24), the fake server is `10.0.2.2:9000`. The host needs internet: the board pings 1.1.1.1 and syncs from pool.ntp.org |
| Phone | netns `phone`: hwsim radio 3, joins the board's hotspot |
| USB link `usb0` | `10.55.0.1`, as on real hardware, with no default route, so it never hides a Wi-Fi state. Host ports `127.0.0.1:2222` (ssh) and `:8090` (dashboard) |
| Fake server | shareframe-board's `tests/e2e/fake-server` as container `shareframe-sim-fake-server` on `127.0.0.1:9000` |
| Firmware stand-in | QEMU skips the VideoCore firmware, so `sim.sh` reads `config.txt` (or `tryboot.txt` after `reboot '0 tryboot'`) from the card's boot partition and boots that slot's kernel, initramfs and cmdline. QEMU exits on every reboot and the next boot picks the slot again, so a trial boot that panics comes back on the committed slot — the real rollback path |

The image is `configs/sim` (dev build, the board's `config.sim.toml` profile, mock
display, hwsim and bridge in the kernel, iproute2). The firmware stand-in adds
`mac80211_hwsim.radios=4` and the watchdog blacklist to every cmdline.

### Commands

| Command | Does |
|---|---|
| `build [version]` | builds the image (default `1.0.0`) and provisions it with `configs/sim/factory` plus the generated identity |
| `up` / `down` / `reset` | boot a fresh copy of the card / stop and delete all run state / both |
| `purge [--yes]` | deletes everything the simulator ever created: Buildroot tree, images, bundles, logs, run state, its Docker images |
| `status` | boots so far, booted/pending slot, version, `wifi-mode.json`, world, services, server state |
| `ssh [cmd]`, `console`, `logs [-f] [service]` | shell; serial console (Ctrl-] leaves); serial history or `/var/log/shareframe/shareframe-<service>.log` (`system` = syslog) |
| `panel [out.png]` | `panel.json` and the frame as PNG |
| `collect [dir]` | board logs, serial console and server state into a dir; `test` does this by itself when a spec fails |
| `wifi home\|office up\|down\|psk <pass>` | an access point disappears, comes back, or gets another password |
| `wifi uplink up\|down` | the router loses its internet (before association: no DHCP either) |
| `wifi phone join [ssid pass]\|leave\|get <path>` | a phone joins the hotspot (default: the board's `ap.conf`) and fetches from the board |
| `wifi status` | `wifi-mode.json` and the world |
| `server ...` | `picture [file] [expires]`, `remove <id>...`, `clear`, `send <json>`, `garbage`, `outage on\|off`, `unregistered on\|off`, `disconnect [code]`, `state`, `reset` |
| `update bundle <version>` | builds the image at that version and signs a dev bundle into the cache |
| `update bundle <version> --foreign-key` | the same build signed with a key made in the cache, which the board does not trust |
| `update bundle <version> --with-migration` | an image carrying `fixtures/990-sim-break-data.sh`, a migration that deletes what `/data/shareframe/sim-break` names, once (only this build has it) |
| `update offer <version> [--corrupt] [--criticality C]` | the fake server offers it; install from the dashboard or `POST /api/system/updates/perform-update` |
| `update break-trial` | the next trial boot panics, so the update rolls back |
| `update power-cut` | pulls the plug: QEMU dies without a shutdown and the board boots again |
| `deploy` | builds the working tree of both repos into a bundle and installs it with RAUC: the real update path, no copied binaries |
| `test [playwright args]` | runs `tests/system/specs` in a container against the running board |
| `check` | lists the specs in that container: every import resolves, no board needed |

Typical session: `up` → open the dashboard on :8090 and act as the owner → `wifi`, `server`
and `update` to change the world → `status`, `panel`, `logs` to see what the board did →
`reset` for a pristine card → `down`.

### State and cleanup

- Everything lives in `~/.cache/shareframe-sim`: Buildroot tree, builds, provisioned image,
  bundles, logs, Playwright report, and the run state in `run/` (qcow2 overlay over the image,
  serial log, `boots.log`, extracted boot files). `down` deletes `run/`, so every `up` starts
  from a pristine card; `purge` deletes everything and checks that nothing is left.
- Nothing is written into either repo, and no key is committed: the first `build` generates
  an ssh key and the frame's ed25519 identity into the cache and builds from a copy of
  `configs/sim` that carries them. ssh never touches `~/.ssh`. Only `127.0.0.1` ports are
  opened, and nothing on the host needs root.
- Ports: `SIM_SSH_PORT`, `SIM_HTTP_PORT`, `SIM_SERVER_PORT`. The board repo is
  `../shareframe-board` unless `SHAREFRAME_BOARD_DIR` says otherwise.

### Specs

`tests/system/specs/*.system.spec.ts`, with `playwright.config.ts` and `tsconfig.json` next to
them:

- `network`: the saved network, the hotspot and a phone setting up a new one, roaming, a
  changed router password, an internet outage.
- `update`: a corrupt bundle, one signed with a foreign key, a trial boot that fails and
  rolls back, a real install that is committed and survives a reboot, a release whose
  migration deletes the identity, the database and the Wi-Fi config (the trial boot restores
  them before anything reads `/data`, the update commits, nothing is lost).
- `clock`: NTP corrects a wrong clock and saves it; a boot without network starts from the
  saved time and the apps still come up; a request the clock steps forward in is answered.
- `board`: a power cut (counted unclean), a remote reboot (clean, rate-limited), the
  services page against real s6, the support package, the hotspot password a phone needs,
  `/data` grown to the end of the card on the first boot only.
- `factory-reset`: the admin's reset wipes the owner's pictures (files too), passwords and
  networks and the ssh host key, the frame keeps its identity and its factory network; a
  power cut before or in the middle of the format still ends in the factory state.
- `resources`: a process eating all memory is killed by earlyoom, not the kernel; the
  dashboard and the heartbeat show it, the board's services keep running.
- `safe-mode`: power cuts in a row and a crashing display keep the display down, the
  heartbeat tells the admin why, a clean boot lifts it.

`support/sim.ts` has `world()`, `waitForWifi()`, slots, `boots()`, `breakNextTrial()`,
`powerCut()`, `rebootCleanly()`, `offlineNextBoot()`, `clockOffset()`, `sysinfo()`, `lastBootRecord()` and
`consoleLog()`. Everything else comes from shareframe-board's `tests/e2e/support`
through `@board/*`: `FakeServer`, `BoardApi`, `signIn`, the panel helpers. The runner mounts
both repos side by side under `/w` with one `node_modules` from the board repo's lockfile,
so the Playwright version is the board's. The panel is read over ssh (`BOARD_SSH`). There
are no shims: assert on the board's real state, the server and the panel.

### Limits and timings

- No SPI e-paper, GPIO, LED or brcmfmac; hwsim stands in for the radio and the panel is the
  mock display. The VideoCore tryboot is the stand-in described above.
- Wi-Fi timers are the real ones: 45 s to associate before the hotspot, 30 s between link
  checks, 3 min between hotspot retries. A network spec takes minutes.
- `config.sim.toml` shortens the display refresh gap (5 s), heartbeat (30 s) and expiry
  cleanup (30 s), so the specs don't wait on them.
- The emulated CPU and USB network are slow: a 30 MB bundle downloads in about 4 minutes,
  and the first `build` takes about an hour. QEMU cannot snapshot a VM with USB network, so
  `reset` is a cold boot.
- `power-cut` quits QEMU over its QMP socket, without a shutdown in the guest. Killing
  QEMU instead would also drop the disk writes it still holds, not only the guest's.
- Two QEMU quirks are worked around in the simulator's own parts, never in board code:
  - `usb-net` holds a received packet until the next one arrives, so `world` keeps a ping
    running on both NICs.
  - A vCPU stall during host I/O can outlast the system timer's 15 µs minimum delta, so the
    kernel's next timer event is missed until the 32-bit counter wraps (about 71 min). Every
    sleep and timeout on the board then stops while interrupts still work; it shows as
    `rauc install` stuck in an f2fs checkpoint. The sim image carries a kernel patch
    (`configs/sim/linux-patches`) that detects the missed deadline
    and reprograms the timer.

  A transfer that stalls at its very end, or a board where `sleep 1` never returns, points
  at these first.

## Hardware-only checklist

What no tier here can reach, checked by hand on a real Pi Zero W with the release image,
before a release and after changes to the parts named. Serial console or `ssh root@10.55.0.1`
over the USB cable.

| Part | Check | Expected |
|---|---|---|
| e-paper (SPI) | boot; change a picture on the server | boot screen, then the picture; no ghosting after the refresh gap |
| ACT LED | `shareframe-led wifi-down`, `ap-mode`, `updating`, then `normal` | the codes in `docs/led-status-codes.md` |
| brcmfmac | join a WPA2 network; pull the router's power for 2 min | joined within 45 s; hotspot after the timeout; rejoins when the router is back |
| hotspot | join from a phone, open any site | the captive portal opens the dashboard |
| USB gadget (dwc2) | plug into a computer | the computer gets 10.55.0.2; `ssh root@10.55.0.1` works, not over Wi-Fi |
| tryboot | install an update; then one whose trial is broken | the first commits after its reboot; the second boots back to the old slot |
| SD card power cut | pull the power during a picture change, 5 times | boots every time, `unclean_resets` counts each, pictures and settings kept |
| pstore | `echo c > /proc/sysrq-trigger` | after the reset: an unclean boot event with `pstore=`, the panic in the diagnostics `last-reset` section |
| clock | boot without network, then with | time from the saved clock first, NTP once online; certificates accepted |
| temperature | an hour of slideshow at the fastest interval | `/run/shareframe/health.json` reads the real thermal zone and stays `"temp":"ok"` |
