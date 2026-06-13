<img width="1280" height="324" alt="shareframe-title-hero" src="https://github.com/user-attachments/assets/087fca2d-a08d-4ff4-904c-b76dc3dc6cf5" />

# Shareframe (Hardware)

Shareframe-Board is the custom embedded Linux operating system that runs on the Shareframe e-paper picture frames. It is a Buildroot-built firmware image for the Raspberry Pi Zero W: a read-only squashfs root filesystem, s6 as PID 1, and signed A/B over-the-air updates via RAUC on top of the Raspberry Pi tryboot mechanism. At runtime the board connects to the Shareframe web server over a WebSocket, receives the photos shared to it, and renders them on the e-paper panel as a slideshow.

## Related repos

- [shareframe-board](https://github.com/JOMI195/shareframe-board) — C++ application firmware and local web dashboard of the picture frame Raspberry Pi Zero hardware board
- [shareframe](https://github.com/JOMI195/shareframe) — web application platform: server backend and web frontend

## Highlights

- Read-only squashfs root filesystem with a separate writable f2fs `/data` for per-device persisted state and secrets
- s6 supervised services with ordered startup
- Signed A/B over-the-air updates (RAUC + tryboot) with automatic rollback on a failed slot
- USB-gadget networking for development plus WiFi with a STA → AP fallback so the board is always reachable
- Local management dashboard served on the board itself, discoverable at `shareframe-board.local`

## Project

<table>
  <tr>
    <td>
       <img width="3205" height="2288" alt="picture frame" src="https://github.com/user-attachments/assets/b43545da-41de-4d1b-9fa9-a76141a9124f" />
      Figure 1: Front view of the picture frame
    </td>
    <td>
      <img width="4018" height="2482" alt="IMG_2260" src="https://github.com/user-attachments/assets/38a6e692-b5df-4ef2-9333-f938b9977b61" />
      Figure 2: Back view of the picture frame
    </td>
  </tr>
</table>


## Architecture

<img width="1587" height="1041" alt="shareframe-harware-architecture drawio" src="https://github.com/user-attachments/assets/a40991a5-c6c4-4463-9594-124a1af05a03" />

*Figure 3: Outline of the on-device architecture of the Shareframe-Board firmware*

**Base system**:

- **Buildroot**: Builds the complete SD card image from source — kernel, root filesystem, and all packages below.
- **s6-linux-init + s6-rc**: Runs as PID 1 and supervises every service, bringing the service groups up in a defined order and restarting them on failure.

**Hardware I/O**:

- **usb0**: USB gadget (dwc2) interface used for ethernet-over-USB and serial access during development.
- **wlan0**: Onboard BCM43438 WiFi, the board's primary network link in normal operation.
- **UART ttyS1**: Serial console for low-level debugging.
- **SPI0**: Bus driving the e-paper panel.
- **ACT LED**: Surfaces boot and status codes via the activity LED.

**Networking**:

- **wifi-mode-manager**: Owns `wlan0` and switches it between station (STA) and access-point (AP) mode.
- **wpa_supplicant + dhcpcd**: Default STA mode — connects to the configured home WiFi network.
- **hostapd + dnsmasq**: AP fallback — opens a setup access point when no configured network is reachable.
- **setup-usb0 + udhcpd**: Brings up the USB network; the board (10.55.0.1) hands a `.2` address to any connected device.

**System services**:

- **nginx :80**: Serves the local board management dashboard and proxies its requests.
- **dropbear**: Lightweight SSH server for remote access.
- **avahi**: mDNS hostname resolution on the local network (`shareframe-board.local`).
- **ntpd, watchdog, earlyoom, crond, getty, …**: Supporting system daemons — time sync, hardware watchdog, out-of-memory protection, scheduled jobs, and console login.

**Application (shareframe-board)**:

- **shareframe-dashboard**: Local web UI for configuring and managing the frame.
- **shareframe-websocket**: Maintains the persistent WebSocket link to the Shareframe web server and receives shared photos.
- **shareframe-display**: Drives the e-paper panel slideshow over SPI.
- **shareframe-update**: Pulls and applies signed update bundles.
- **shareframe-heartbeat**: Periodically reports the frame's liveness and status to the server.

**Updates & health**:

- **RAUC + tryboot-backend**: Performs signed A/B partition updates, writing the new firmware to the inactive slot and switching the active slot via tryboot.
- **rauc-mark-good**: Commits the new slot once it boots and validates successfully; otherwise the board automatically rolls back to the previous slot.
- **shareframe-health**: Ongoing system health checks (memory, temperature, disk, crashes).

**Storage (SD card)**:

- **p1 — FAT boot**: Raspberry Pi firmware, A/B `os_prefix` directories, and `config.txt` / `tryboot.txt`.
- **p2 / p3 — squashfs rootfs A/B**: The two read-only root filesystem slots used by A/B updates.
- **p4 — f2fs /data**: Writable partition holding per-device state and secrets.
