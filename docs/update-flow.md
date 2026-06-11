# Update-Flow (OTA, A/B)

Wie ein Update vom Dev-Rechner bis zum committeten Slot auf dem Board läuft,
und was Dev von Prod unterscheidet. Release-Erstellung im Detail:
[RELEASING.md](RELEASING.md).

## Architektur in einem Satz

Signiertes RAUC-Bundle (rootfs + Kernel-Set) → Server → Board lädt, prüft
Checksum + Signatur, schreibt den inaktiven Slot → einmaliger tryboot-Boot in
den neuen Slot → Health-Gate → Commit; jeder Fehler davor fällt automatisch
auf den alten Slot zurück.

## Ablauf im Detail

1. **Build + Bundle** (Dev-Rechner): `./automation.sh build` baut das Image,
   danach manuell `scripts/make-release.sh` (`--mode dev|prod`) für
   `shareframe-<ver>.raucb` (verity-Format, signiert) + `.sha256`-Datei. Inhalt: `rootfs.squashfs` (komplettes System
   inkl. Kernel-Quellen) + `boot.tar` (zImage, dtb, overlays, initramfs,
   cmdline) + `hook.sh` (cmdline-Slot-Fixup, optionale pre/post-Skripte).
2. **Server** (manuell): `.raucb` im Django-Admin hochladen, Checksum-String
   aus der `.sha256`-Datei ins `checksum`-Feld, Criticality + Groups +
   `is_active` setzen.
3. **Check** (Board, `shareframe-update`-Dienst): periodisch (6 h) oder per
   Dashboard-Button. `GET /api/frame-updates/latest/` (TokenAuth) → Version
   neuer als `/etc/shareframe-release`? `Critical` startet sofort, sonst
   wartet das Board auf den Button.
4. **Download**: `HTTPClient::downloadToFile` streamt die `download_url`
   (TokenAuth-Header) nach `/data/cache/…raucb.part`; Fortschritt aus
   Content-Length → Dashboard-Balken.
5. **Integritätsprüfung**: sha256 der Datei == `checksum` vom Server, sonst
   Abbruch („Checksum mismatch" im Update-Verlauf). Das ist Transportschutz —
   die **Sicherheit** ist die RAUC-Signaturprüfung gegen
   `/etc/rauc/ca.cert.pem` beim Install.
6. **Install** (`rauc install`): Signatur + `compatible=shareframe-pi0w`
   geprüft; `install-check`-Hook (optionales `pre.sh`, kann abbrechen);
   rootfs roh in den inaktiven Slot (p2/p3); Boot-Set per `slot-install`-Hook
   in das Unterverzeichnis `A/` bzw. `B/` der Boot-Partition (p1), cmdline
   bekommt `rauc.slot=<Slot>`; optionales `post.sh`. Danach staged der
   tryboot-Backend `set-primary` den Slot (`/data/rauc/pending` +
   `/run/tryboot`).
7. **Reboot**: sauberer s6-Shutdown; `rc.shutdown.final` sieht `/run/tryboot`
   und ruft `tryboot-reboot` (reboot-Syscall mit „0 tryboot") — die Firmware
   lädt dadurch **einmalig** `tryboot.txt` (`os_prefix=B/`) statt
   `config.txt` (`os_prefix=A/`).
8. **Erster Boot im neuen Slot**: initramfs mountet das rootfs des Slots
   (`rauc.slot=` → p2/p3), System-Migrationen laufen
   (`/usr/share/shareframe/system-migrations/`, idempotent, auf /data),
   `rauc-mark-good` wartet auf App-Dienste + Health, dann
   `rauc status mark-good` → Backend **committet** (tauscht die beiden
   `os_prefix`-Zeilen in config.txt/tryboot.txt).
9. **Fehlerfälle = automatischer Rollback**: Kernel-Panic (`panic=10`),
   Watchdog (Userspace-Hänger), Stromausfall, Health-Gate nicht erreicht,
   einfacher `reboot` vor dem Commit — der nächste Boot lädt wieder
   `config.txt` = alter Slot. `rauc-reconcile` räumt `pending` ab und
   schreibt „Zurückgerollt" in den Update-Verlauf
   (`/data/shareframe/update-history.jsonl`, Dashboard → Verwaltung).

## Dev vs. Prod

| | Dev | Prod |
|---|---|---|
| Signatur-Keys | `br2-external/package/shareframe-rauc/files/` (gen-dev-keys.sh, gitignored) | `~/.shareframe-release-keys/` (gen-prod-keys.sh, offline) |
| Trust-Anchor im Image | Dev-CA (Paket-Install) | `configs/prod-local/overlay/etc/rauc/ca.cert.pem` (Overlay gewinnt) |
| Bundles gegenseitig | Prod-Board lehnt Dev-Bundle ab und umgekehrt (anderer CA) | |
| `SHAREFRAME_BUILD_MODE` | `dev`: `uart_2ndstage=1` (Firmware-UART-Log) | `prod`: still |
| Auslieferung | Server/Django-Admin — identisch zu Prod, nur dev-signiert | Server/Django-Admin, Boards holen selbst |
| Version | beliebig (git-sha-Fallback) | numerisches Semver (Server-Pflicht) |

## Persistenz bei Updates

Kernel + rootfs werden komplett ersetzt. `/` ist squashfs + tmpfs-Overlay:
**jede Laufzeit-Änderung außerhalb von /data stirbt schon beim normalen
Reboot** — nicht erst beim Update. /data (f2fs, p4) wird von RAUC nie
angefasst und überlebt Update wie Rollback:

| Was | Wo |
|---|---|
| Fotos | `/data/shareframe/images` |
| SQLite-DB (Auth-Token, Settings, Bild-Metadaten, Display-Metriken) | `/data/shareframe/db` |
| WLAN-Zugangsdaten + AP-Fallback | `/data/wifi/wpa_supplicant.conf`, `/data/wifi/ap.conf` |
| Frame-Identität (ed25519-Secret) + initiales Dashboard-Passwort | `/data/shareframe/.env.secrets.toml` |
| SSH-Hostkeys | `/data/dropbear` (bind-mount nach /etc/dropbear) |
| Zeit-Seed | `/data/fake-hwclock` |
| Health-Log, Boot-Zähler, Update-Verlauf, Migrationsstand | `/data/shareframe/{health.log,boot_count,update-history.jsonl,migrations.state}` |
| RAUC-Slot-Status (pending, status.ini, good/bad) | `/data/rauc` |
| Bundle-Download (transient) | `/data/cache` |

Bewusst **nicht** persistent: App-/System-Logs (tmpfs, SD-Schonung — nur
health.log überlebt), resolv.conf/DHCP-Zustand (wird je Boot neu erzeugt),
App-Konfiguration `config.toml` + Profil (versioniert im Image; Laufzeit-
Einstellungen liegen in der DB), Zeitzone/Hostname (Build-Zeit).

## /data-Sicherung gegen kaputte Releases

RAUC fasst /data nie an, aber /data ist **eine** f2fs-Partition für beide Slots:
ein fehlerhaftes neues Release (Migration/Seed/App) könnte eine Datei löschen.
Den rootfs muss man dafür nicht prüfen (verity + Signatur). `shareframe-update-verify`
sichert vor dem Slot-Schreiben eine feste Liste unersetzlicher /data-Dateien und
stellt im Commit-Gate die wieder her, die das neue Release verloren hat:

| Pfad | Tier |
|---|---|
| `/data/shareframe/.env.secrets.toml` (Frame-Identität) | required |
| `/data/shareframe/db` (Token/Settings/Metadaten) | required |
| `/data/wifi/wpa_supplicant.conf` | wichtig |
| `/data/wifi/ap.conf` | wichtig (aus Seriennr. regenerierbar) |

- **`backup`** läuft im **alten System** im `install-check`-Hook (in jedem Bundle
  fest verdrahtet, nicht per Release) → kopiert vorhandene Pfade nach
  `/data/shareframe/update-verify/backup/` (DB als `db.tar`).
- **`restore`** läuft im **neuen System** in `rauc-mark-good`: fehlende Pfade aus
  dem Backup zurückspielen (vorhandene werden nie überschrieben). Ist ein
  **required**-Pfad weg *und* nicht wiederherstellbar, bleibt das Gate zu →
  kein Commit → Rollback. Ergebnis je Pfad in
  `/data/shareframe/update-verify/last.json` (`present`/`restored`/`missing`).
