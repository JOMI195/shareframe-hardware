# Deploy-Configs (`configs/`)

Ein Config-Ordner **pro Gerät**. Bündelt alles, was sich zwischen
Auslieferungen ändert, an **einem** Ort — getrennt vom getrackten `overlay/`, damit
private Dateien nicht im Repo-Overlay liegen und nicht zwischen Builds hängen bleiben.

## Workflow

```sh
cp -r configs/example configs/<kunde>     # neuen Config-Ordner anlegen
$EDITOR configs/<kunde>/config.env        # Mode/Profile/Pfade setzen
# echte Secrets + WLAN in den privaten Overlay legen:
#   configs/<kunde>/overlay/usr/share/shareframe/.env.secrets.toml.default
#   configs/<kunde>/overlay/usr/share/shareframe/wpa_supplicant.conf.default
./automation.sh build configs/<kunde>     # baut artifacts/sdcard/sdcard.img
# -> SD deployen, danach direkt naechsten Kunden bauen
```

Ohne Argument (`./automation.sh build`) bleibt das alte Verhalten: Env-Defaults
(`prod`/`prod`) und die getrackten `.template`-Seeds.

## Inhalt eines Config-Ordners

| Datei | Zweck |
|-------|-------|
| `config.env` | Settings, von `automation.sh` ge-source't: `SHAREFRAME_MODE`, `SHAREFRAME_PROFILE`, optionale `*_OVERRIDE_SRCDIR` (lokale Checkouts der externen Projekte), `SHAREFRAME_CONFIG_LABEL`. |
| `overlay/` | 2. Buildroot-Rootfs-Overlay. Spiegelt das Rootfs-Layout. Hier liegen die privaten zu kopierenden Dateien. |

Die privaten Seed-Dateinamen sind genau die, die die Seed-Skripte erwarten:

- `overlay/usr/share/shareframe/.env.secrets.toml.default` → auf erstem Boot nach
  `/data/shareframe/.env.secrets.toml` (siehe `seed-shareframe-secrets`).
- `overlay/usr/share/shareframe/wpa_supplicant.conf.default` → nach
  `/data/wifi/wpa_supplicant.conf` (siehe `seed-wifi-config`).

Fehlt eine `.default`, fällt das Seed-Skript auf das getrackte `.template` zurück.

## Wie es technisch greift

- `config.env` wird vor dem Build exportiert; `SHAREFRAME_MODE/PROFILE` validiert
  `buildroot()` wie gehabt.
- `<config>/overlay` wird als **zweiter** `BR2_ROOTFS_OVERLAY` an `.config`
  angehängt (überschreibt/ergänzt das getrackte `../../overlay`).
- `*_OVERRIDE_SRCDIR` landen in `buildroot/src/local.mk` (Buildroots nativer
  Override-Mechanismus für `local`-Site-Pakete). `local.mk` wird jeden Build neu
  geschrieben — kein Override bleibt hängen.
- Vor dem Build entfernt `automation.sh` die zwei bekannten Seed-Defaults aus dem
  Target, damit kein Secret eines vorigen Kunden in den nächsten Build leakt.

## git

Nur `configs/example/` ist getrackt — als credless Vorlage. Alle anderen
`configs/<kunde>/` sind gitignored.

**In `configs/example` (getrackt) niemals echte Credentials ablegen.** Bei
grundlegendem Overlay-Wechsel im Zweifel `./automation.sh clean` vor dem Build.
