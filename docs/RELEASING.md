# Releases erstellen

Ein Release ist ein signiertes RAUC-Bundle (`shareframe-<version>.raucb`) mit
komplettem Image (rootfs + Kernel + dtb + Overlays + Boot-Dateien). Die Boards
holen es vom Server, installieren in den inaktiven Slot und booten per
tryboot — bei Fehlern automatischer Rollback.

## Voraussetzungen (einmalig)

- **Dev-Keys** (für lokale Tests): `scripts/gen-dev-keys.sh`
  → `br2-external/package/shareframe-rauc/files/{ca.cert,cert,key}.pem` (gitignored)
- **Prod-Keys** (offline, niemals ins Repo): `scripts/gen-prod-keys.sh`
  → `~/.shareframe-release-keys/`. Danach einmalig den Trust-Anchor ins
  Prod-Profil kopieren:
  `cp ~/.shareframe-release-keys/ca.cert.pem configs/prod-local/overlay/etc/rauc/ca.cert.pem`
- Prod-Boards akzeptieren **nur** prod-signierte Bundles, Dev-Boards nur
  dev-signierte. `~/.shareframe-release-keys/{ca.key,key}.pem` sichern —
  ohne sie können keine Updates mehr signiert werden, die existierende
  Boards akzeptieren.

## Ablauf

### 1. Version setzen

`shareframe-board/VERSION.toml`: `version = "1.2.0"`

- **Numerisches Semver, Pflicht** (`x.y.z`). Der Server lehnt anderes ab
  (Regex im Release-Model) und sortiert per semver; das Board installiert nur
  Versionen, die *größer* als die laufende sind. Versionsnummern nie
  wiederverwenden (unique am Server).

### 2. Optional: Release-Skripte / Migrationen

Zwei verschiedene Mechanismen — nicht verwechseln:

| | `releases/<version>/pre.sh / post.sh` | `br2-external/overlay/usr/share/shareframe/system-migrations/NNN-name.sh` |
|---|---|---|
| Läuft | genau einmal, mit diesem Update | bei jedem Versionswechsel |
| System | **altes** System (vor Reboot) | **neues** System (erster Boot, vor App + Commit) |
| Zweck | Sonderfälle dieses Releases; `pre.sh` ≠ 0 bricht Installation ab | idempotente /data-Anpassungen |

Migrations-Kontrakt (siehe README im migrations-Ordner): idempotent und
**rückwärtskompatibel** — nach einem Rollback liest die alte App das bereits
migrierte /data. Nur additiv ändern, nichts löschen/umschreiben.

`releases/<version>/notes.md` wird als Release-Notes in `release.json`
übernommen (im Dashboard sichtbar).

### 3. Bauen

```sh
./automation.sh build configs/prod-local         # Image + Artefakte
./automation.sh release prod --criticality Minor # signiert mit ~/.shareframe-release-keys
```

`release prod` ist nur ein Wrapper um `scripts/make-release.sh` und verdrahtet
die Offline-Keys automatisch (Keydir per `SHAREFRAME_RELEASE_KEYDIR` änderbar).
Explizit entspricht das:

```sh
SHAREFRAME_RELEASE_CERT=~/.shareframe-release-keys/cert.pem \
SHAREFRAME_RELEASE_KEY=~/.shareframe-release-keys/key.pem \
scripts/make-release.sh --mode prod --criticality Minor
```

Ergebnis: `artifacts/release/<version>/shareframe-<version>.raucb` +
`shareframe-<version>.raucb.sha256` (Checksum-Datei, `sha256sum -c`-kompatibel)
+ `release.json` (Version, Criticality, sha256, Größe, Notes).

Criticality (`Critical | Important | Minor | Patch`): maßgeblich ist **nur
der Wert am Server** (Release-Feld); die Boards lesen ihn aus der
`/latest`-Antwort. Der `--criticality`-Flag landet lediglich in
`release.json` als Vorbelegung fürs Admin-Formular — im Bundle selbst steckt
keine Criticality, Ändern am Server wirkt sofort ohne neues Signieren.
**Achtung: `Critical` installieren die Boards beim nächsten periodischen
Check automatisch** (Standard alle 6 h). Alles andere wartet auf den
Dashboard-Button.

### 4. Auf den Server (manuell)

Im Django-Admin → Frame updates → Releases → Add:

- version, file (die `.raucb`-Datei hochladen), checksum (**Hash-String aus
  der `.sha256`-Datei** — das Board lehnt den Download bei abweichender
  Checksum ab), criticality, notes
- **groups zuweisen + is_active setzen** — ohne Gruppe sieht kein Frame das
  Release (Sichtbarkeit läuft über FrameGroups). Für gestaffelten Rollout:
  erst Testgruppe, dann alle.

### 5. Verifizieren (vor breitem Rollout)

Auf einem Testboard (Gruppe "test"):

1. Dashboard → Updates → neue Version sichtbar → „Jetzt installieren"
2. Fortschritt Download/Installation, Reboot, danach: neue Version unter
   „Aktuelle Version", Verwaltung → Update-Verlauf → Eintrag `Erfolgreich`
3. `rauc status` per SSH: booted Slot = primary, kein pending
4. Bei Hooks/Migrationen: Wirkung auf /data prüfen

Schlägt der Boot der neuen Version fehl, rollt das Board automatisch zurück —
sichtbar als „Zurückgerollt" im Update-Verlauf. Das Release dann am Server
deaktivieren (`is_active` aus) und Ursache fixen.

## Dev-Releases

Gleicher Ablauf wie Prod, nur ohne Key-Umgebungsvariablen:

```sh
./automation.sh build         # Image bauen
./automation.sh release dev   # Update-Dateien erzeugen (dev-signiert)
```

Update-Dateien liegen danach in `artifacts/release/<version>/` und gehen wie
bei Prod über den Server an Dev-Boards (dev-signiert; Prod-Boards lehnen sie
ab).

## Worauf achten

- **Reihenfolge bei Key-Rotation**: neues CA-Cert zuerst per normalem Update
  (noch mit altem Key signiert) ausrollen, erst danach mit dem neuen Key
  signieren.
- **Bootloader/Firmware (p1)** wird von Updates nie angefasst; Änderung nur
  bewusst per `post.sh`-Hook.
- Ein nicht bestätigtes Update (pending) blockiert weitere Updates, bis es
  committed oder zurückgerollt ist — Status zeigt es als „Update wird
  bestätigt".
- `compatible=shareframe-pi0w` ist fest verdrahtet (system.conf ↔ Manifest);
  RAUC verweigert fremde Bundles.
- Der sha256 in release.json ist Transport-Metadatum fürs Admin-Formular;
  die eigentliche Sicherheit ist die RAUC-Signatur, die das Board prüft.
