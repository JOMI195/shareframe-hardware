# Building & releasing

Three separate steps: **config → build → release**. A build turns a config into
one self-contained, versioned artifact under `artifacts/builds/<label>-<version>/`;
a release signs a chosen build into a `.raucb` the server ships to boards. Boards
install into the inactive A/B slot and boot via tryboot — a failed boot rolls back
automatically.

## The easy path: `scripts/deploy.sh`

An interactive runner over the three steps below. It lists the configs, releases,
builds and devices it finds on disk, prints the config behind every pick, shows
the exact commands plus the paths they will produce, and only then runs them —
so a wrong mode, a missing CA cert or a version mismatch fails in a second
instead of after a build.

```sh
scripts/deploy.sh                      # menu: what do you want to do?
scripts/deploy.sh --update  --config configs/fleet/<env> --release <rel> --mode prod
scripts/deploy.sh --sdcard  --config configs/fleet/<env> --release <rel> --device <board>
scripts/deploy.sh --steps release --from <label>-<version> --release <rel> --mode prod
scripts/deploy.sh --steps image   --from <label>-<version> --device <board>
```

Flows: `--update` = build + release, `--sdcard` = build + image, `--full` = all
three; `--steps build,release,image` picks them explicitly. Every prompt has a
matching flag (`--config --release --version --device --from --mode`), so a run
is repeatable; `--dry-run` stops at the summary, `--yes` skips the confirm. It
never writes a block device — it prints the `dd` line, like `provision-device.sh`.

`--steps release` / `--steps image` are the no-rebuild paths: they sign or
provision from a build that already exists in `artifacts/builds/`.

The rest of this document is the reference for what those steps actually do.

## Configs

Configs bundle everything that changes between deployments, kept separate from the
tracked `br2-external/overlay/` so private files never land in the repo overlay or
leak between builds. Two kinds, by lifecycle:

| Dir | For | Carries | Used |
|-----|-----|---------|------|
| `configs/fleet/<env>/` | **every build** (flash + OTA) | CA cert only (credless) | once per release |
| `configs/per-device/<board>/` | provisioning one board's flash image | that board's `factory/` files (identity, Wi-Fi, root pw) | once per device, **no build** |

**One build serves all devices.** The rootfs is always fleet-generic; per-device
identity lives on the **factory partition (p5)** and on `/data` — never in the
squashfs. `scripts/provision-device.sh` turns a fleet `sdcard.img` into a
device's flash image in seconds by injecting its `factory/` files into p5.

### Fleet (the only build input)

```sh
cp -r configs/fleet/example configs/fleet/<env>
$EDITOR configs/fleet/<env>/config.env            # mode / profile / label
cp ~/.shareframe-release-keys/ca.cert.pem configs/fleet/<env>/overlay/etc/rauc/ca.cert.pem
./automation.sh build configs/fleet/<env> --release <release>
```

Without an argument (`./automation.sh build`) the tracked defaults are used and
the build defaults to **dev mode** (so the prod guards don't apply) — handy for
QEMU, but it lacks the prod CA so prod boards reject those bundles.

### Per-device (provision, no rebuild)

```sh
cp -r configs/per-device/example configs/per-device/<board>
scripts/gen-device-key.sh --device configs/per-device/<board>   # identity
$EDITOR configs/per-device/<board>/factory/*      # Wi-Fi, AP, dashboard pw
scripts/provision-device.sh --device configs/per-device/<board> [--root-passwd]
dd if=artifacts/flash/<board>-<version>.img of=/dev/sdX bs=4M conv=fsync
```

`gen-device-key.sh` creates the board's ed25519 keypair on this host and writes
the private seed into `factory/.env.secrets.toml`. It prints the frame id and the
public key, paste the public key into the server's Frame admin (add or change
frame), the frame id is derived from it. The private key never leaves this host
and the card. It refuses to replace an existing key unless `--force` is given,
`--selftest` checks the derivation against a known vector.

`--from <label>` picks a stored build (default `latest`); `--root-passwd` prompts
and writes the crypt hash to `factory/rootpw`. The factory files are seeded to
`/data` on first boot only if absent (idempotent), so the board keeps its
identity/Wi-Fi across reboots, A/B updates — and a factory reset restores exactly
these files.

### What the dirs hold

| Path | Role |
|------|------|
| `fleet/<env>/config.env` | Sourced by `automation.sh`: build mode, profile, optional override paths, config label. |
| `fleet/<env>/overlay/etc/rauc/ca.cert.pem` | Trust anchor — boards verify update signatures against it. |
| `per-device/<board>/factory/.env.secrets.toml` | Device identity (required). |
| `per-device/<board>/factory/{wpa_supplicant.conf,ap.conf,rootpw}` | Optional Wi-Fi / AP / root-pw defaults. |

Seed scripts on the device read the staged factory store
(`/run/shareframe/factory/`, from p5); if a file is missing they fall back to the
tracked `.template` (AP config: derived from the board serial).

### How a build works

- `config.env` is exported before the build; build mode / profile are validated.
- The dir's `overlay/` is the **second** `BR2_ROOTFS_OVERLAY`, so it overrides and
  extends the tracked one.
- Override paths go into Buildroot's `local.mk`, rewritten every build so no
  override sticks across runs.

### git

Only `configs/per-device/example/` and `configs/fleet/example/` are tracked, as
credless templates; every other `configs/per-device/<board>/` and
`configs/fleet/<env>/` is gitignored. **Never put real credentials in either
`example`.** On a fundamental overlay change, `./automation.sh clean` first.

## Build

```sh
./automation.sh build configs/<...> --release <release>   # version from the release cfg
./automation.sh build configs/<...> --version X.Y.Z       # or set it directly
```

`--release` reads the version from `releases/<release>/config.env`; `--version`
sets it directly (mutually exclusive). The version is baked into the rootfs
(`/etc/shareframe-release`, RAUC manifest) — it is the build's identity. Omit
both and it falls back to the git SHA (QEMU/dev only; a fielded board needs a
real semver for the server compare).

### Three identifiers

A build carries three separate identities; only the first is a semver and only
the first drives the OTA compare.

| Key | Value | Written to | Dashboard row |
|---|---|---|---|
| `version` | `X.Y.Z` from the release cfg | `/etc/shareframe-release:VERSION`, RAUC manifest | "Version" |
| `os_sha` | `shareframe-hardware` short sha | `:OS_SHA`, `os-release` `VERSION_ID`/`BUILD_ID`, kernel `LOCALVERSION` | "System" |
| `app_sha` | `shareframe-board` short sha | `:APP_SHA` **and compiled into the binaries** (`-DSHAREFRAME_APP_SHA`) | "Anwendung" |

Those three keys are the whole contract — `/api/system/info`, the heartbeat and
`shareframe-sysinfo` all use exactly these names. Only `version` is a semver and
only `version` drives the OTA compare.

The app sha is baked in rather than read from a file: `shareframe-board.mk` pins
nothing (`SITE_METHOD = local`), so without it a bundle carries no record of which
app commit is inside. A `-dirty` suffix means the checkout had uncommitted changes.

A **prod build** (`SHAREFRAME_BUILD_MODE=prod`, the default) aborts up front unless
all three hold: `SHAREFRAME_PROFILE=prod`, `SHAREFRAME_ROOT_PASSWD` set, and a PEM
CA cert at `<config>/overlay/etc/rauc/ca.cert.pem`. For QEMU/dev iteration use a
dev-mode config instead.

Each build lands in its own dir, keyed `<label>-<version>` (label =
`SHAREFRAME_CONFIG_LABEL`, else the config dir name, else `default`):

```
artifacts/builds/<label>-<version>/
  build.json        config, version, sha, mode, profile, epd, built_at/by
  rootfs.squashfs   release input + qemu
  boot.tar          release input
  sdcard.img        flash input (provision-device.sh injects factory files)
  qemu/             zImage, dtb, dtbo, initramfs
  releases/         signed bundles (created by `release`)
artifacts/builds/latest -> <label>-<version>
artifacts/flash/<board>-<version>.img   provisioned per-device images
```

Builds don't clobber each other, so several boards / versions coexist; `release`
picks one with `--from`. Rebuilding a `<label>-<version>` that already holds signed
bundles is refused — bump the version (they're unique) or `rm -rf` the dir on
purpose.

## Release

A release signs a stored build into a signed RAUC bundle
(`shareframe-<version>-<mode>.raucb`) carrying the full image (rootfs + boot
files). It's a separate step from the build — run it dev + prod, or days later,
without rebuilding.

### Prerequisites (once)

- **Dev keys** (local testing): `scripts/gen-dev-keys.sh` → dev signing CA + cert
  + key under the rauc package's `files/` (gitignored).
- **Prod keys** (offline, never in the repo): `scripts/gen-prod-keys.sh` →
  `~/.shareframe-release-keys/`. Copy the trust anchor into the fleet config once:
  `cp ~/.shareframe-release-keys/ca.cert.pem configs/fleet/<env>/overlay/etc/rauc/ca.cert.pem`
- Prod boards accept **only** prod-signed bundles, dev boards only dev-signed.
  Back up the prod CA + signing keys — without them you can't sign updates existing
  boards will accept.

All builds are fleet builds (credless) — per-device secrets are never baked, so
nothing can leak into a bundle. A prod release refuses a non-prod-mode build
(checked from the build manifest).

### 1. Author the release dir

The dir name is arbitrary (e.g. `launch`), **not** the version:

```sh
cp -r releases/example releases/<release>
$EDITOR releases/<release>/config.env     # SHAREFRAME_VERSION + SHAREFRAME_CRITICALITY
```

`config.env` is the single source of the version — `build` and `release` both read
it. Numeric semver required (`x.y.z`); the server sorts by semver and a board
installs only versions greater than the one it runs. Never reuse a version (unique
on the server). Optional alongside: `notes.md` (→ dashboard), `pre.sh`/`post.sh`
hooks.

### 2. Hooks vs migrations

Two distinct mechanisms — don't confuse them:

| | `releases/<release>/pre.sh` / `post.sh` | `system-migrations/NNN-name.sh` |
|---|---|---|
| Runs | once, with this update | on every version change |
| System | old (before reboot) | new (first boot, before app + commit) |
| Purpose | special cases of this release; `pre.sh` ≠ 0 aborts install | idempotent /data adjustments |

Migration contract (see `br2-external/overlay/usr/share/shareframe/system-migrations/README`):
idempotent and **backward-compatible** — after a rollback the old app reads the
already-migrated /data. Change additively only; never delete or rewrite.

### 3. Build, then release

```sh
./automation.sh build configs/fleet/<env> --release <release>   # bakes the version
./automation.sh release prod --release <release> --from <env>-<version>
```

`--from` selects the stored build (defaults to `latest`). `release prod` wires in
the offline keys automatically (key dir overridable via
`SHAREFRAME_RELEASE_KEYDIR`). Explicitly:

```sh
SHAREFRAME_RELEASE_CERT=~/.shareframe-release-keys/cert.pem \
SHAREFRAME_RELEASE_KEY=~/.shareframe-release-keys/key.pem \
scripts/make-release.sh --mode prod --release-dir releases/<release> \
  --from <env>-<version>
```

Output: `artifacts/builds/<label>/releases/` with `shareframe-<version>-<mode>.raucb`,
a `.sha256` checksum file (`sha256sum -c`-compatible), and
`release-<version>-<mode>.json` (version, config, os_sha, app_sha, criticality,
sha256, size, notes). The same build can be signed again (dev + prod) — mode is in the filename,
so both coexist. **Dev releases** are identical without the key env vars
(`release dev …`); prod boards reject dev-signed bundles.

Criticality (`Critical | Important | Minor | Patch`): only the **server value**
counts (boards read it from the `/latest` response). The flag / `config.env` value
just pre-fills `release.json` for the admin form — the bundle carries none, so
changing it on the server takes effect without re-signing. **Boards install
`Critical` automatically** at the next periodic check (default every 6 h);
everything else waits for the dashboard button.

### 4. Upload to the server (manual)

In the Django admin → Frame updates → Releases → Add:

- version, file (upload the `.raucb`), checksum (**the hash string from the
  `.sha256` file** — a board rejects the download on mismatch), criticality, notes
- **assign groups + set `is_active`** — without a group no frame sees the release
  (visibility is per FrameGroup). For a staged rollout: test group first, then all.

### 5. Verify (before a wide rollout)

On a test board (group "test"):

1. Dashboard → Updates → new version visible → "Install now"
2. Watch download/install, reboot, then: new version under "Current version" and a
   `Success` entry in the update history
3. `rauc status` over SSH: booted slot = primary, no pending
4. With hooks/migrations: check the effect on /data

If the new version fails to boot, the board rolls back automatically ("Rolled
back" in the history). Deactivate the release on the server and fix the cause.

## Factory partition & factory reset

The SD card layout: p1 boot FAT (A/B kernel slots), p2/p3 rootfs squashfs (RAUC
A/B), p4 extended container, **p5 factory (vfat, 32M)**, p6 `/data` (f2fs, grows
to card end on first boot).

**p5 is the durable per-device store.** Updates never touch it (RAUC writes
p2/p3 and the A/B subdirs on p1 only); a `/data` wipe doesn't either. On every
boot `stage-factory` mounts p5 read-only and stages its files to
`/run/shareframe/factory/`, where the seed scripts (and `apply-rootpw`) read
them. The store is schema-free: any file dropped onto p5 gets staged — future
per-device knobs need no new mechanism.

**Root password:** the baked `/etc/shadow` hash is copied to `factory/rootpw` at
image build; on first boot it's seeded to `/data/shareframe/rootpw`, and
`apply-rootpw` re-applies it to the tmpfs `/etc/shadow` on every boot — so a
fleet update can no longer revert root. `passwd` on the device persists the new
hash to `/data` automatically (wrapper). `SHAREFRAME_ROOT_PASSWD` remains the
baked fallback for un-provisioned cards.

**Factory reset** (total wipe, SSH/serial):

```sh
shareframe-factory-reset --yes
```

Marks `/data`, reboots; `mount-data` reformats p6 on the way up, then the normal
seed path repopulates identity from p5 — fresh SSH host keys, factory secrets,
factory (or serial-derived) AP creds, factory root pw. The rootfs and the RAUC
trust anchor are untouched, so the board still receives updates after a reset.
A pending (uncommitted) update is discarded — intended.

**Changing the store on a live board:**

- SSH: `shareframe-factory list | get <name> | set <name> <file>` — `set` updates
  the *defaults* (what a reset restores), not the live `/data` state.
- Server-targeted update: assign a device-specific release whose `pre.sh` writes
  `/data` (live half) and whose `post.sh` mounts p5 rw and writes the durable
  half — see the commented recipe in `releases/example/{pre,post}.sh`. **The
  bundle is signed but not encrypted** — key material rides readable inside it;
  assign such a release strictly to the one target device.

## Watch out for

- **Root password**: persisted on `/data` and re-applied each boot (see above).
  `SHAREFRAME_ROOT_PASSWD` is still required for prod builds as the baked
  fallback, but updates no longer reset a provisioned board's password.
- After a buildroot `clean`, `release` falls back to a **system `rauc`** and warns;
  the verity format may differ from the buildroot host rauc — rebuild if unsure.
- **Key rotation order**: roll out the new CA cert first via a normal update (still
  signed with the old key), only then sign with the new key.
- **Bootloader/firmware (p1)** is never touched by updates; change it only
  deliberately via a `post.sh` hook.
- An unconfirmed (pending) update blocks further updates until committed or rolled
  back — shown as "confirming update".
- The compatible string is hard-wired (system.conf ↔ manifest); RAUC refuses
  foreign bundles.
- The sha256 in release.json is transport metadata for the admin form; the actual
  security is the RAUC signature the board verifies.
