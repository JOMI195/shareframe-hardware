# Building & releasing

Three separate steps: **config → build → release**. A build turns a config into
one self-contained, versioned artifact under `artifacts/builds/<label>-<version>/`;
a release signs a chosen build into a `.raucb` the server ships to boards. Boards
install into the inactive A/B slot and boot via tryboot — a failed boot rolls back
automatically.

## Configs

Configs bundle everything that changes between deployments, kept separate from the
tracked `br2-external/overlay/` so private files never land in the repo overlay or
leak between builds. Two kinds, by lifecycle:

| Dir | For | Carries | Used |
|-----|-----|---------|------|
| `configs/per-device/<board>/` | initial SD flash of one board | CA cert **+** that board's secret seeds (`.env`, Wi-Fi, AP) | once per device |
| `configs/fleet/<env>/` | OTA updates to a whole group | CA cert **only** (credless) | every release build |

**Why the split:** the config overlay is baked into the rootfs squashfs, and the
squashfs ships inside every OTA bundle. A per-device config's secret seeds would
therefore be distributed to the whole assigned group. So updates are built from a
fleet config (no secret seeds); per-device secrets live only on each board's
`/data` and survive updates untouched.

### Per-device (initial flash)

```sh
cp -r configs/per-device/example configs/per-device/<board>
$EDITOR configs/per-device/<board>/config.env     # mode / profile / label / paths
# put real secrets + Wi-Fi into overlay/usr/share/shareframe/*.default and the
# CA cert into overlay/etc/rauc/ca.cert.pem (see that dir's README), then:
./automation.sh build configs/per-device/<board> --release <release>
# flash artifacts/builds/<board>-<version>/sdcard.img — once per board.
```

`<board>` (the config dir) becomes the build label; `<release>` is the release dir
`releases/<release>/`, whose `config.env` holds the version that gets baked — the
version itself is never typed here. Flash at the current fleet version so the board
boots up-to-date and waits for the next release. The seeds are copied to `/data`
on first boot only if absent (idempotent), so the board keeps its identity/Wi-Fi
across reboots and A/B updates.

### Fleet (OTA updates)

```sh
cp -r configs/fleet/example configs/fleet/<env>
$EDITOR configs/fleet/<env>/config.env            # mode / profile / label
cp ~/.shareframe-release-keys/ca.cert.pem configs/fleet/<env>/overlay/etc/rauc/ca.cert.pem
./automation.sh build configs/fleet/<env> --release <release>
```

Without an argument (`./automation.sh build`) the tracked defaults and the
credless `.template` seeds are used, and the build defaults to **dev mode** (so the
prod guards don't apply) — handy for QEMU, but it lacks the prod CA so prod boards
reject those bundles.

### What a config dir holds

| Path | Role |
|------|------|
| `config.env` | Sourced by `automation.sh`: build mode, profile, optional override paths, config label (`SHAREFRAME_CONFIG_LABEL`; defaults to the dir name). |
| `overlay/etc/rauc/ca.cert.pem` | Trust anchor — both kinds need it so boards verify update signatures. |
| `overlay/usr/share/shareframe/*.default` | **Per-device only.** Secret seeds copied to `/data` on first boot. Never in a fleet config. |

Seed scripts on the device look for the private `.default` seed files in the
overlay; if one is missing they fall back to the tracked `.template`.

### How it works

- `config.env` is exported before the build; build mode / profile are validated.
- The dir's `overlay/` is the **second** `BR2_ROOTFS_OVERLAY`, so it overrides and
  extends the tracked one.
- Override paths go into Buildroot's `local.mk`, rewritten every build so no
  override sticks across runs.
- Known secret seeds are wiped from the target before each build, so a fleet build
  ships only credless `.template` seeds and one device's credentials can't leak
  into the next build.

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
(`/etc/shareframe-release`, RAUC manifest) — it is the build's identity, the same
whether the build is per-device or fleet. Omit both and it falls back to the git
SHA (QEMU/dev only; a fielded board needs a real semver for the server compare).

A **prod build** (`SHAREFRAME_BUILD_MODE=prod`, the default) aborts up front unless
all three hold: `SHAREFRAME_PROFILE=prod`, `SHAREFRAME_ROOT_PASSWD` set, and a PEM
CA cert at `<config>/overlay/etc/rauc/ca.cert.pem`. For QEMU/dev iteration use a
dev-mode config instead.

Each build lands in its own dir, keyed `<label>-<version>` (label =
`SHAREFRAME_CONFIG_LABEL`, else the config dir name, else `default`):

```
artifacts/builds/<label>-<version>/
  build.json        config, version, sha, mode, profile, epd, secrets, built_at/by
  rootfs.squashfs   release input + qemu
  boot.tar          release input
  sdcard.img        flash
  qemu/             zImage, dtb, dtbo, initramfs
  releases/         signed bundles (created by `release`)
artifacts/builds/latest -> <label>-<version>
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

> **Build updates from a fleet config** (`configs/fleet/<env>/`, CA cert only),
> never a per-device config — its secret seeds would ship inside the bundle to the
> whole group. Devices keep their own `/data` secrets regardless.

This is enforced from the build manifest: `release` refuses a per-device build
(`secrets: true` — would OTA secrets to the group), and a prod release refuses a
non-prod-mode build.

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
`release-<version>-<mode>.json` (version, config, criticality, sha256, size,
notes). The same build can be signed again (dev + prod) — mode is in the filename,
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

## Watch out for

- **Root password** is baked into the rootfs `/etc/shadow` (not `/data`), so every
  update overwrites it fleet-wide. Set `SHAREFRAME_ROOT_PASSWD` on **every** fleet
  build, or the update resets root to the Buildroot default (`"root"`).
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
