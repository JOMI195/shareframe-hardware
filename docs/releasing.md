# Cutting a release

A release is a signed RAUC bundle (`shareframe-<version>.raucb`) carrying the
full image (rootfs + kernel + dtb + overlays + boot files). Boards fetch it from
the server, install into the inactive slot, and boot it via tryboot — any failure
rolls back automatically. For the runtime flow see [update-flow.md](update-flow.md).

## Prerequisites (once)

- **Dev keys** (local testing): `scripts/gen-dev-keys.sh` → dev signing CA + cert
  + key under the rauc package's `files/` (gitignored).
- **Prod keys** (offline, never in the repo): `scripts/gen-prod-keys.sh` →
  `~/.shareframe-release-keys/`. Then copy the trust anchor into the prod config
  profile once:
  `cp ~/.shareframe-release-keys/ca.cert.pem configs/prod-local/overlay/etc/rauc/ca.cert.pem`
- Prod boards accept **only** prod-signed bundles, dev boards only dev-signed.
  Back up the prod CA + signing keys — without them you can no longer sign
  updates that existing boards will accept.

## Steps

### 1. Set the version

Set the version in the board's `VERSION.toml` (e.g. `version = "1.2.0"`).

Numeric semver is required (`x.y.z`). The server rejects anything else and sorts
by semver; a board installs only versions greater than the one it runs. Never
reuse a version number (unique on the server).

### 2. Optional: release scripts / migrations

Two distinct mechanisms — don't confuse them:

| | `releases/<version>/pre.sh` / `post.sh` | `system-migrations/NNN-name.sh` |
|---|---|---|
| Runs | once, with this update | on every version change |
| System | old (before reboot) | new (first boot, before app + commit) |
| Purpose | special cases of this release; `pre.sh` ≠ 0 aborts install | idempotent /data adjustments |

Migration contract (see the migrations folder README): idempotent and
**backward-compatible** — after a rollback the old app reads the already-migrated
/data. Change additively only; never delete or rewrite.

`releases/<version>/notes.md` is copied into `release.json` as release notes
(shown on the dashboard).

### 3. Build

```sh
./automation.sh build configs/prod-local          # image + artifacts
./automation.sh release prod --criticality Minor   # signed with the offline keys
```

`release prod` wraps `scripts/make-release.sh` and wires in the offline keys
automatically (key dir overridable via `SHAREFRAME_RELEASE_KEYDIR`). Explicitly:

```sh
SHAREFRAME_RELEASE_CERT=~/.shareframe-release-keys/cert.pem \
SHAREFRAME_RELEASE_KEY=~/.shareframe-release-keys/key.pem \
scripts/make-release.sh --mode prod --criticality Minor
```

Output: `artifacts/release/<version>/` with the `.raucb`, a `.sha256` checksum
file (`sha256sum -c`-compatible), and `release.json` (version, criticality,
sha256, size, notes).

Criticality (`Critical | Important | Minor | Patch`): only the **server value**
counts (boards read it from the `/latest` response). The `--criticality` flag
just pre-fills `release.json` for the admin form — the bundle carries none, so
changing it on the server takes effect without re-signing. **Boards install
`Critical` automatically at the next periodic check** (default every 6 h);
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
2. Watch download/install progress, reboot, then: new version under "Current
   version", and a `Success` entry in the update history
3. `rauc status` over SSH: booted slot = primary, no pending
4. With hooks/migrations: check the effect on /data

If the new version fails to boot, the board rolls back automatically (shown as
"Rolled back" in the history). Deactivate the release on the server and fix the
cause.

## Dev releases

Same flow as prod, just without the key env vars:

```sh
./automation.sh build
./automation.sh release dev
```

The update files land in `artifacts/release/<version>/` and ship via the server
to dev boards (dev-signed; prod boards reject them).

## Watch out for

- **Key rotation order**: roll out the new CA cert first via a normal update
  (still signed with the old key), only then sign with the new key.
- **Bootloader/firmware (p1)** is never touched by updates; change it only
  deliberately via a `post.sh` hook.
- An unconfirmed (pending) update blocks further updates until it is committed or
  rolled back — shown as "confirming update".
- The compatible string is hard-wired (system.conf ↔ manifest); RAUC refuses
  foreign bundles.
- The sha256 in release.json is transport metadata for the admin form; the actual
  security is the RAUC signature the board verifies.
