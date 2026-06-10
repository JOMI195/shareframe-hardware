# Tryboot hardware gate (Pi Zero W)

Go/no-go test for the firmware A/B boot. Run on a real Zero W before trusting
the update path.

## History / design rationale

The first design (autoboot.txt + two boot partitions, bootcode.bin partition
switching) FAILED on Zero W hardware: bootcode.bin selected the partition and
read config.txt, but never launched start.elf (LED 3 flashes on FAT16 slots,
4 flashes on FAT32). bootcode.bin partition switching is not field-proven on
BCM2835. Current design follows Ubuntu's A/B scheme (works on all Pi models):
ONE boot partition (p1), per-slot subdirs A/ and B/, `config.txt` with
`os_prefix=A/` for normal boot, `tryboot.txt` with `os_prefix=B/` loaded by
start.elf when the one-shot tryboot flag is set. The whole bootcode→start.elf
chain is identical to the previously proven single-partition layout.

## Tests (UART probe attached, dev image: uart_2ndstage=1)

a) **Normal boot**: flash sdcard.img, power on. Expect bootcode banner,
   `Read File: start.elf`, verbose MESS log, kernel earlycon, getty.
   Kernel cmdline must show `rauc.slot=A` (from p1:/A/cmdline.txt).

b) **tryboot one-shot**: from the running system:
   `tryboot-reboot` (or `touch /run/tryboot && reboot` for the s6 path).
   Expect: start.elf log mentions tryboot / loads `tryboot.txt`,
   kernel cmdline shows `rauc.slot=B`, exactly once.

c) **flag clears**: after (b), plain `reboot` -> `rauc.slot=A` again.
   Also: power-cut during the slot-B run -> next boot slot A.

d) **commit**: in slot B run
   `/usr/lib/rauc/tryboot-backend set-state B good` -> p1 config.txt now has
   `os_prefix=B/`; plain reboot stays in B.

e) **watchdog fallback**: with pending set and the watchdog-keeper killed,
   board resets after <=15s and boots the committed slot.

## Results

- [ ] (a) normal boot to getty, rauc.slot=A
- [ ] (b) tryboot flag boots B/ exactly once
- [ ] (c) flag clears on plain reboot / power-cut
- [ ] (d) commit swaps os_prefix; B persists
- [ ] (e) watchdog fallback to committed slot
