# Build configs (`configs/`)

One config dir **per device**. Bundles everything that changes between
deployments in a single place, kept separate from the tracked
`br2-external/overlay/` so private files never land in the repo overlay or leak
between builds.

## Workflow

```sh
cp -r configs/example configs/<name>   # new config dir
$EDITOR configs/<name>/config.env      # set mode / profile / paths
# put real secrets + Wi-Fi into the dir's private overlay (mirrors the
# rootfs layout), then build the SD image:
./automation.sh build configs/<name>
```

Without an argument (`./automation.sh build`) the tracked defaults and the
`.template` seeds are used instead.

## What a config dir holds

| Path | Role |
|------|------|
| `config.env` | Sourced by `automation.sh`: build mode, profile, optional override paths to local checkouts of external projects, config label. |
| `overlay/` | Second Buildroot rootfs overlay, mirroring the target layout. Holds the private files to copy in (secrets, Wi-Fi). |

Seed scripts on the device look for the private `.default` seed files in the
overlay; if one is missing they fall back to the tracked `.template`.

## How it works

- `config.env` is exported before the build; the build mode / profile are
  validated as usual.
- The dir's `overlay/` is appended as the **second** `BR2_ROOTFS_OVERLAY`, so
  it overrides and extends the tracked one.
- Override paths go into Buildroot's `local.mk`, rewritten on every build so no
  override sticks across runs.
- Known secret seeds are wiped from the target before each build, so one
  device's credentials can't leak into the next build.

## git

Only `configs/example/` is tracked, as a credless template; every other
`configs/<name>/` is gitignored. **Never put real credentials in `example`.**
On a fundamental overlay change, `./automation.sh clean` before building if in
doubt.

See [RELEASING.md](RELEASING.md) for turning a build into a signed release.
