# shareframe-hardware

Buildroot-based embedded Linux image for the Shareframe-Board (Raspberry Pi
Zero W). Single entry point: `./automation.sh`.

```sh
./automation.sh build [configs/<name>] [--version X.Y.Z]   # build SD image + artifacts
./automation.sh release <dev|prod> --version X.Y.Z          # signed RAUC update bundle
./automation.sh qemu_rpi0                                   # boot latest build in QEMU
./automation.sh clean [--linux|--buildroot|--toolchain]    # tidy caches
```

## Layout

| Path | Role |
|------|------|
| `automation.sh` | Entry point — build / release / qemu / clean orchestration. |
| `br2-external/` | **All tracked hardware code** — the Buildroot `BR2_EXTERNAL` tree: `external.{desc,mk}`, `Config.in`, `board/ package/ modules/ overlay/ patches/ fragments/`, and the defconfigs in `br2-external/configs/`. |
| `configs/` | **Customizable, per-device** build configs. Only `configs/example/` is tracked; every `configs/<name>/` is gitignored. See [docs/build-configs.md](docs/build-configs.md). |
| `releases/` | **Customizable, per-release** hooks. Dir name **is** the `X.Y.Z` version. Only `releases/example/` + `releases/README` are tracked; real releases are gitignored. |
| `scripts/` | Host + build-time helpers (make-release, gen-keys, post-build, …). |
| `docs/` | Build, release, and update-flow docs. |
| `artifacts/` | Build output (gitignored). |
| `build/` | Downloaded + extracted Buildroot/toolchain sources (gitignored cache). |

> Two different `configs/`: the **root** `configs/` holds per-device deploy
> configs; `br2-external/configs/` holds the Buildroot defconfig + busybox
> fragment.

See [docs/RELEASING.md](docs/releasing.md) for cutting a release.
