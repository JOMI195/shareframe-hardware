# Tryboot hardware gate (Pi Zero W)

Go/no-go on real Zero W hardware.

## Design

ONE boot FAT (p1), A/ and B/ subdirs via `os_prefix`. config.txt =
committed slot, tryboot.txt = other. bootcode.bin partition switching
(autoboot.txt + separate boot partitions) does NOT work on BCM2835 —
tested twice, LED 3/4 flashes, start.elf never loads.

## Tests (UART probe, dev image)

a) Normal boot → getty, `rauc.slot=A`
b) `tryboot-reboot` → `rauc.slot=B`, exactly once
c) Plain `reboot` / power-cut → back to A
d) `set-state B good` → config.txt `os_prefix=B/`, B persists
e) Watchdog fallback → committed slot

## Results

- [ ] (a) normal boot
- [ ] (b) tryboot one-shot
- [ ] (c) flag clears
- [ ] (d) commit
- [ ] (e) watchdog fallback
