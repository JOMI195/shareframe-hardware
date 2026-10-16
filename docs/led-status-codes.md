# LED status codes

The onboard ACT LED encodes the board state as counted blinks, modelled on
the Raspberry Pi firmware's
[LED warning flash codes](https://www.raspberrypi.com/documentation/computers/configuration.html#led-warning-flash-codes).
All states are set through `shareframe-led <state>`.

## Reading a code

Short blink ≈ 0.2 s, long blink ≈ 0.8 s. A 2 s dark pause marks the restart
of the pattern — count from there. `normal` is a single short blink every
10 s.

| Blinks | State | Meaning |
|---|---|---|
| heartbeat | `booting` | boot in progress |
| 1 short / 10 s | `normal` | all good (sign of life) |
| 2 short | `wifi-connecting` | joining known Wi-Fi |
| 3 short | `wifi-down` | associated, no internet |
| 4 short | `ap-mode` | setup access point active |
| 1 long | `updating` | update installing — do not power off |
| 2 long | `protected` | display safe mode after a boot or display crash loop; panel left blank |
| solid on | `error` | critical fault; latched until reboot |
| off | `off` | shut down (or no power) |

## Ownership

The wifi manager owns the wifi/normal codes and writes only on change.
`error` and `updating` are asserted on top and survive; `error` latches
until reboot. `off` is written on shutdown and right before the post-update
reboot.

`protected` is set when `/run/shareframe/safe-mode` exists and owns the LED
until reboot: every other state except `updating` and `off` is ignored.
Safe mode starts after 5 boots in a row that each end within 10 minutes
(`boot-guard`) or 5 display crashes within 15 minutes (`display-crash-guard`).
The display stays down while wifi, heartbeat, updates and the dashboard keep
running. To leave it, keep the frame powered for 10 minutes, then reboot or
replug it.

## Configuration

Timings and per-state blink counts are overridable via
`/etc/shareframe/led.conf` (image default, shipped as a commented template
listing every tunable) and `/data/shareframe/led.conf` (per device, wins).
Plain shell assignments only. State names and the `booting`/`error`/`off`
behavior are fixed. Invalid values make the write fail and the LED keeps
its previous state.

## Notes

The GPIO ACT LED only accepts brightness 0/1 and cannot render interpolated
patterns, so codes are written as step tuples. Kernels without the pattern
trigger fall back to plain timer blinking, one distinguishable rate per
state.
