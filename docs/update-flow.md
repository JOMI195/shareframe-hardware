# Update flow (OTA, A/B)

How an update travels from the dev machine to a committed slot on the board, and
what separates dev from prod. For cutting a release see [RELEASING.md](releasing.md).

## In one sentence

Signed RAUC bundle (rootfs + kernel set) → server → board downloads, verifies
checksum + signature, writes the inactive slot → one-shot tryboot into the new
slot → health gate → commit; any failure before commit falls back to the old slot.

## Step by step

1. **Build + bundle** (dev machine): `./automation.sh build`, then
   `scripts/make-release.sh` (`--mode dev|prod`) produces the signed verity
   `.raucb` + `.sha256`. Contents: the rootfs squashfs (full system incl. kernel),
   a boot tarball (zImage, dtb, overlays, initramfs, cmdline), and an install hook
   (cmdline slot fixup + optional pre/post scripts).
2. **Server** (manual): upload and publish the bundle — see RELEASING.md step 4.
3. **Check** (board update service): periodically (6 h) or on the dashboard
   button. Queries the server's `/latest` (token auth) → version newer than the
   installed one? `Critical` starts immediately, otherwise it waits for the button.
4. **Download**: streams the bundle to `/data/cache` with a token-auth header;
   progress from Content-Length drives the dashboard bar.
5. **Integrity check**: file sha256 must equal the server checksum, else abort
   ("checksum mismatch"). That is transport protection — the actual **security**
   is the RAUC signature check against the on-target CA cert at install.
6. **Install** (`rauc install`): signature + compatible string verified; the
   install-check hook runs (optional `pre.sh`, may abort); the rootfs is written
   raw to the inactive slot; the boot set goes into that slot's `A/` or `B/`
   subdir on the boot partition with `rauc.slot=<slot>` patched into the cmdline;
   optional `post.sh`. The tryboot backend then stages the slot as pending.
7. **Reboot**: clean s6 shutdown; the final shutdown step sees the tryboot flag
   and reboots with the firmware one-shot tryboot, so the firmware loads
   `tryboot.txt` (new slot) **once** instead of `config.txt` (old slot).
8. **First boot in the new slot**: the initramfs mounts the slot's rootfs, system
   migrations run (idempotent, on /data), then the mark-good gate waits for the
   app services + health and commits (swaps the two `os_prefix` lines in
   config.txt/tryboot.txt).
9. **Failure = automatic rollback**: kernel panic (`panic=10`), watchdog, power
   loss, health gate not reached, or a plain reboot before commit — the next boot
   loads `config.txt` again (old slot). The boot-time reconcile clears the pending
   flag and writes "rolled back" to the update history.

## Dev vs prod

| | Dev | Prod |
|---|---|---|
| Signing keys | rauc package `files/` (gen-dev-keys.sh, gitignored) | `~/.shareframe-release-keys/` (gen-prod-keys.sh, offline) |
| Trust anchor in image | dev CA (package install) | prod profile overlay's `ca.cert.pem` (overlay wins) |
| Cross-acceptance | prod board rejects a dev bundle and vice versa (different CA) | |
| Build mode | `dev`: verbose firmware UART log | `prod`: quiet |
| Delivery | server — identical to prod, just dev-signed | server; boards pull themselves |
| Version | any (git-sha fallback) | numeric semver (server-enforced) |

## Persistence across updates

Kernel + rootfs are fully replaced. `/` is squashfs + a tmpfs overlay: **any
runtime change outside /data is lost on a normal reboot** — not just on update.
/data (f2fs) is never touched by RAUC and survives both update and rollback:

| What | Where |
|---|---|
| Photos | `/data/shareframe/images` |
| SQLite DB (auth token, settings, image metadata, display metrics) | `/data/shareframe/db` |
| Wi-Fi credentials + AP fallback | `/data/wifi/` |
| Frame identity (ed25519 secret) + initial dashboard password | `/data/shareframe/.env.secrets.toml` |
| SSH host keys | `/data/dropbear` (bind-mounted to /etc/dropbear) |
| Time seed | `/data/fake-hwclock` |
| Health log, boot count, update history, migration state | `/data/shareframe/` |
| RAUC slot status (pending, status, good/bad) | `/data/rauc` |
| Bundle download (transient) | `/data/cache` |

Deliberately **not** persistent: app/system logs (tmpfs, to spare the SD — only
the health log survives), resolv.conf/DHCP state (regenerated each boot), the app
config + profile (versioned in the image; runtime settings live in the DB),
timezone/hostname (build time).

## Protecting /data against a broken release

RAUC never touches /data, but /data is **one** f2fs partition shared by both
slots: a faulty new release (migration/seed/app) could delete a file. The
update-verify tool backs up a fixed list of irreplaceable /data files before the
slot write and restores any the new release lost, in the commit gate:

| Path | Tier |
|---|---|
| `/data/shareframe/.env.secrets.toml` (frame identity) | required |
| `/data/shareframe/db` (token/settings/metadata) | required |
| `/data/wifi/wpa_supplicant.conf` | important |
| `/data/wifi/ap.conf` | important (regenerable from the serial) |

- **backup** runs in the **old system** in the install-check hook (wired into
  every bundle, not per release) → copies existing paths into a backup area
  (DB as a tar).
- **restore** runs in the **new system** in the mark-good gate: missing paths are
  replayed from the backup (existing ones are never overwritten). If a **required**
  path is gone *and* unrestorable, the gate stays shut → no commit → rollback.
  Per-path result in `update-verify/last.json` (`present`/`restored`/`missing`).
